package engine

// VS-01-IMPL-06 — Worker thread: claim atômico (B1), lotes de até 16 chunks
// (B4), ring de 3 lotes em voo e um vkQueueSubmit2 por lote na fila de
// compute. 1 claim = 1 lote = 1 valor de timeline (determinístico = nº do lote).

import "core:log"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"

@(private)
wait_for_compute_timeline :: proc(target_value: u64) {
	semaphore := app.computeTimelineSemaphore
	value := target_value
	vk_check(
		vk.WaitSemaphores(
			app.vkDevice,
			&vk.SemaphoreWaitInfo {
				sType          = .SEMAPHORE_WAIT_INFO,
				semaphoreCount = 1,
				pSemaphores    = &semaphore,
				pValues        = &value,
			},
			max(u64),
		),
	)
}

worker_thread_process :: proc(worker_thread: ^thread.Thread) {
	context = app.runtimeContext
	ve := active_ve
	submitted_batch_count: u64 = 0

	for {
		sync.mutex_lock(&ve.queue_mutex)
		for len(ve.pending_tasks) == 0 && len(ve.pending_export_tasks) == 0 &&
		    sync.atomic_load(&ve.worker_stop_requested) == 0 {
			sync.cond_wait(&ve.queue_condition, &ve.queue_mutex)
		}
		if sync.atomic_load(&ve.worker_stop_requested) == 1 {
			sync.mutex_unlock(&ve.queue_mutex)
			break
		}

		claimed_batch := SubmittedBatch {
			compute_timeline_value = submitted_batch_count + 1,
		}
		// C2 (VS-04): re-exports do mirror embarcam 1 por lote, antes do dreno
		// normal (são raros e não podem morrer de fome), e pulam o pack abaixo.
		export_only := false
		if len(ve.pending_export_tasks) > 0 {
			claimed_batch.tasks[0] = pop(&ve.pending_export_tasks)
			claimed_batch.task_count = 1
			export_only = true
		} else {
		// B4: drena até 16 tarefas por lote, sempre as mais próximas da câmera
		// (varredura linear nesta fatia — heap fica no backlog de performance).
		for claimed_batch.task_count < MAXIMUM_CHUNKS_PER_BATCH && len(ve.pending_tasks) > 0 {
			best_idx := 0
			best_dist := max(i64)
			for task, i in ve.pending_tasks {
				d := calculate_squared_distance(task.coordinate, ve.priority_camera_chunk)
				if d < best_dist {
					best_dist = d
					best_idx = i
				}
			}
			claimed_batch.tasks[claimed_batch.task_count] = ve.pending_tasks[best_idx]
			claimed_batch.task_count += 1
			unordered_remove(&ve.pending_tasks, best_idx)
		}
		}

		// B1 — CLAIM ATÔMICO: o lote é publicado em submitted_batches ANTES de
		// qualquer trabalho Vulkan, ainda sob queue_mutex. O descarregamento
		// (thread principal) varre os dois conjuntos sob a mesma trava: não
		// existe janela em que a tarefa esteja fora de ambos.
		assigned_timeline := claimed_batch.compute_timeline_value
		append(&ve.submitted_batches, claimed_batch)
		sync.mutex_unlock(&ve.queue_mutex)

		// Backpressure: no máximo 3 lotes em voo antes de regravar o ring.
		if submitted_batch_count >= MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT {
			wait_for_compute_timeline(submitted_batch_count - MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT + 1)
		}

		ring_index := int(submitted_batch_count % MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT)
		job_offset := ring_index * MAXIMUM_CHUNKS_PER_BATCH

		for i in 0 ..< claimed_batch.task_count {
			task := claimed_batch.tasks[i]
			voxel_gpu.generation_jobs_mapped[job_offset + i] = ChunkGenerationJob {
				chunk_world_origin = task.coordinate * CHUNK_SIZE,
				storage_slot_index = task.storage_slot_index,
				mirror_ring_slot   = task.mirror_ring_slot, // C2: -1 = sem export
			}
		}

		cmd := voxel_gpu.compute_command_buffers[ring_index]
		vk_check(vk.ResetCommandBuffer(cmd, {}))
		vk_check(
			vk.BeginCommandBuffer(
				cmd,
				&vk.CommandBufferBeginInfo {
					sType = .COMMAND_BUFFER_BEGIN_INFO,
					flags = {.ONE_TIME_SUBMIT},
				},
			),
		)

		vk.CmdBindDescriptorSets(
			cmd,
			.COMPUTE,
			app.computePipelineLayout,
			0,
			1,
			&voxel_gpu.descriptor_set,
			0,
			nil,
		)

		push_constants := VoxelPushConstants {
			batch_job_offset = u32(job_offset),
		}
		vk.CmdPushConstants(
			cmd,
			app.computePipelineLayout,
			{.COMPUTE},
			0,
			size_of(VoxelPushConstants),
			&push_constants,
		)

		// B4/B9: generate cobre N chunks (thread_id.z / 32 = job local);
		// pack cobre N chunks (group_id.x = job local).
		vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.generation_pipeline)
		vk.CmdDispatch(cmd, 4, 4, 4 * u32(claimed_batch.task_count))

		// C2 (VS-04): lote export_only (re-export do mirror) NÃO roda o pack —
		// o packed já existe e contém edições; repackar a partir do scratch
		// (só worldgen) as apagaria. O ring já saiu escrito pelo generate.
		if !export_only {
		vk.CmdPipelineBarrier2(
			cmd,
			&vk.DependencyInfo {
				sType                = .DEPENDENCY_INFO,
				memoryBarrierCount   = 1,
				pMemoryBarriers      = &vk.MemoryBarrier2 {
					sType         = .MEMORY_BARRIER_2,
					srcStageMask  = {.COMPUTE_SHADER},
					srcAccessMask = {.SHADER_STORAGE_WRITE},
					dstStageMask  = {.COMPUTE_SHADER},
					dstAccessMask = {.SHADER_STORAGE_READ},
				},
			},
		)

		vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.packing_pipeline)
		vk.CmdDispatch(cmd, u32(claimed_batch.task_count), 1, 1)
		}

		vk_check(vk.EndCommandBuffer(cmd))

		submitted_batch_count += 1

		// O valor sinalizado é o MESMO publicado no claim atômico (1 claim = 1
		// lote = 1 valor de timeline).
		vk_check(
			vk.QueueSubmit2(
				app.queues[.Compute].queue,
				1,
				&vk.SubmitInfo2 {
					sType                  = .SUBMIT_INFO_2,
					commandBufferInfoCount = 1,
					pCommandBufferInfos    = &vk.CommandBufferSubmitInfo {
						sType         = .COMMAND_BUFFER_SUBMIT_INFO,
						commandBuffer = cmd,
					},
					signalSemaphoreInfoCount = 1,
					pSignalSemaphoreInfos    = &vk.SemaphoreSubmitInfo {
						sType     = .SEMAPHORE_SUBMIT_INFO,
						semaphore = app.computeTimelineSemaphore,
						value     = assigned_timeline,
						stageMask = {.ALL_COMMANDS},
					},
				},
				{},
			),
		)
	}
}
