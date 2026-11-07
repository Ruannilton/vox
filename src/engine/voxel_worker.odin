package engine

import "core:sync"
import "core:thread"
import "core:time"
import vk "vendor:vulkan"

worker_thread_process :: proc(worker_thread: ^thread.Thread) {
	context = app.runtimeContext
	ve := active_ve
	submitted_batch_count: u64 = 0

	SetThreadName("voxel_worker")

	for {
		claimed_batch: SubmittedBatch
		export_only := false
		assigned_timeline: u64

		{
			ZoneN("worker_iteration")

			{
				ZoneN("batch_assemble")
				sync.mutex_lock(&ve.queue_mutex)
				for len(ve.pending_tasks) == 0 && len(ve.pending_export_tasks) == 0 &&
				    sync.atomic_load(&ve.worker_stop_requested) == 0 {
					sync.cond_wait(&ve.queue_condition, &ve.queue_mutex)
				}
				if sync.atomic_load(&ve.worker_stop_requested) == 1 {
					sync.mutex_unlock(&ve.queue_mutex)
					break
				}

				claimed_batch = SubmittedBatch {
					compute_timeline_value = submitted_batch_count + 1,
				}

				if len(ve.pending_export_tasks) > 0 {
					append(&claimed_batch.tasks, pop(&ve.pending_export_tasks))
					export_only = true
				} else {

					for len(claimed_batch.tasks) < int(config.chunks_per_batch) && len(ve.pending_tasks) > 0 {
						best_index := 0
						best_distance := max(i64)
						for task, i in ve.pending_tasks {
							d := calculate_squared_distance(task.coordinate, ve.priority_camera_chunk)
							if d < best_distance {
								best_distance = d
								best_index = i
							}
						}
						append(&claimed_batch.tasks, ve.pending_tasks[best_index])
						unordered_remove(&ve.pending_tasks, best_index)
					}
				}

				assigned_timeline = claimed_batch.compute_timeline_value
				append(&ve.submitted_batches, claimed_batch)
				sync.mutex_unlock(&ve.queue_mutex)
			}

			// Backpressure: no máximo config.batches_in_flight lotes em voo antes
			// de regravar o ring.
			if submitted_batch_count >= u64(config.batches_in_flight) {
				wait_for_compute_timeline(submitted_batch_count - u64(config.batches_in_flight) + 1)
			}

			{
				ZoneN("batch_submit")
				ring_index := int(submitted_batch_count % u64(config.batches_in_flight))

				if submitted_batch_count >= u64(config.batches_in_flight) {
					telemetry_collect_compute(ring_index)
				}
				job_offset := ring_index * int(config.chunks_per_batch)

				for task, i in claimed_batch.tasks {
					voxel_gpu.generation_jobs_mapped[job_offset + i] = ChunkGenerationJob {
						chunk_world_origin = task.coordinate * CHUNK_SIZE,
						storage_slot_index = task.storage_slot_index,
						mirror_ring_slot   = task.mirror_ring_slot,
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
					batch_job_offset       = u32(job_offset),
					visible_chunk_capacity = config.visible_capacity,
				}
				vk.CmdPushConstants(
					cmd,
					app.computePipelineLayout,
					{.COMPUTE},
					0,
					size_of(VoxelPushConstants),
					&push_constants,
				)

				compute_pool := telemetry.compute_pools[ring_index]
				telemetry_reset_pool(cmd, compute_pool, TELEMETRY_COMPUTE_QUERY_COUNT)
				telemetry_timestamp_begin(cmd, compute_pool, 0)
				telemetry_begin_label(cmd, "generate")
				vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.generation_pipeline)
				vk.CmdDispatch(cmd, 4, 4, 4 * u32(len(claimed_batch.tasks)))
				telemetry_end_label(cmd)
				telemetry_timestamp_end(cmd, compute_pool, 1)

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
					telemetry_timestamp_begin(cmd, compute_pool, 2)
					telemetry_begin_label(cmd, "pack")
					vk.CmdDispatch(cmd, u32(len(claimed_batch.tasks)), 1, 1)
					telemetry_end_label(cmd)
					telemetry_timestamp_end(cmd, compute_pool, 3)
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

			time.sleep(32 * time.Millisecond)
		}
	}
}

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
