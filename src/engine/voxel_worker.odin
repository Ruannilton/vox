package engine

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"
import vk "vendor:vulkan"

worker_thread_process :: proc(worker_thread: ^thread.Thread) {
	context = app.runtimeContext
	worker_temp_allocator: runtime.Default_Temp_Allocator
	runtime.default_temp_allocator_init(&worker_temp_allocator, 4 * runtime.Megabyte, context.allocator)
	context.temp_allocator = runtime.default_temp_allocator(&worker_temp_allocator)
	defer runtime.default_temp_allocator_destroy(&worker_temp_allocator)
	ve := active_ve
	submitted_batch_count: u64 = 0
	last_batch_frame: u64 = 0

	SetThreadName("voxel_worker")

	for {
		worker_service_frame(ve)
		free_all(context.temp_allocator)
		if last_batch_frame == ve.requested_frame {
			time.sleep(time.Millisecond)
			continue
		}
		last_batch_frame = ve.requested_frame
		claimed_batch: SubmittedBatch
		export_only := false
		assigned_timeline: u64

		{
			ZoneN("worker_iteration")

			// VS-16 (REQ-CPU-01): claim_batch cobre a aquisição do lote sob
			// queue_mutex (inclui a espera na condvar — o lock aparece
			// "detido" durante o cond_wait no Tracy, por construção).
			{
				ZoneN("claim_batch")
				tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
				for len(ve.pending_tasks) == 0 && len(ve.pending_export_tasks) == 0 &&
				    sync.atomic_load(&ve.worker_stop_requested) == 0 {
					if !sync.cond_wait_with_timeout(&ve.queue_condition, &ve.queue_mutex, 250 * time.Millisecond) {
						break
					}
				}
				if sync.atomic_load(&ve.worker_stop_requested) == 1 {
					sync.mutex_unlock(&ve.queue_mutex)
					break
				}
				if len(ve.pending_tasks) == 0 && len(ve.pending_export_tasks) == 0 {
					sync.mutex_unlock(&ve.queue_mutex)
					continue
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
				tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)
			}

			// Backpressure: no máximo config.batches_in_flight lotes em voo antes
			// de regravar o ring.
			if submitted_batch_count >= u64(config.batches_in_flight) {
				ZoneN("wait_batch_slot")
				wait_for_compute_timeline(submitted_batch_count - u64(config.batches_in_flight) + 1)
				tracing_gpu_collect_compute()
			}

			{
				ZoneN("submit_batch")
				ring_index := int(submitted_batch_count % u64(config.batches_in_flight))

				if submitted_batch_count >= u64(config.batches_in_flight) {
					telemetry_collect_compute(ring_index)
				}
				job_offset := ring_index * int(config.chunks_per_batch)

				{
					ZoneN("build_jobs")
					for task, i in claimed_batch.tasks {
						voxel_gpu.generation_jobs_mapped[job_offset + i] = ChunkGenerationJob {
							chunk_world_origin = task.coordinate * CHUNK_SIZE,
							storage_slot_index = task.storage_slot_index,
							mirror_ring_slot   = task.mirror_ring_slot,
						}
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

				// VS-16 (REQ-GPU-02/03): zonas GPU do contexto compute.
				tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_COMPUTE)

				compute_pool := telemetry.compute_pools[ring_index]
				telemetry_reset_pool(cmd, compute_pool, TELEMETRY_COMPUTE_QUERY_COUNT)
				telemetry_timestamp_begin(cmd, compute_pool, 0)
				telemetry_begin_label(cmd, "generate")
				generate_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_COMPUTE, "generate")
				vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.generation_pipeline)
				vk.CmdDispatch(cmd, 4, 4, 4 * u32(len(claimed_batch.tasks)))
				tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_COMPUTE, generate_query)
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
					pack_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_COMPUTE, "pack")
					vk.CmdDispatch(cmd, u32(len(claimed_batch.tasks)), 1, 1)
					tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_COMPUTE, pack_query)
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

		}
		free_all(context.temp_allocator)
	}
}

@(private)
worker_service_frame :: proc(ve: ^VoxelEngine) {
	sync.mutex_lock(&ve.frame_mutex)
	frame_value := ve.requested_frame
	frame_index := ve.requested_frame_index
	camera_chunk := ve.requested_camera_chunk
	sync.mutex_unlock(&ve.frame_mutex)
	if frame_value == 0 do return

	sync.mutex_lock(&ve.mirror.mutex)
	voxel_engine_update(ve, {f32(camera_chunk.x * CHUNK_SIZE), f32(camera_chunk.y * CHUNK_SIZE), f32(camera_chunk.z * CHUNK_SIZE)})
	edit_update(ve, frame_index)

	publish_required := !ve.has_published || ve.published_camera_chunk != camera_chunk || ve.published_revision != ve.world_revision || ve.consumed_publish_bump != ve.publish_bump
	if publish_required && frame_value >= 3 {
		completed: u64
		vk_check(vk.GetSemaphoreCounterValue(app.vkDevice, app.timelineSemaphore, &completed))
		if completed < frame_value - 2 {
			sync.mutex_unlock(&ve.mirror.mutex)
			return
		}
	}
	if publish_required {
		ZoneN("publish_world")
		visible_count := voxel_engine_publish_visible(ve, frame_index)
		sync.mutex_lock(&ve.frame_mutex)
		ve.published_frame = frame_value
		ve.published_frame_index = frame_index
		ve.published_visible_count = visible_count
		ve.published_compute_value = ve.highest_completed_compute_value
		ve.published_camera_chunk = camera_chunk
		ve.published_revision = ve.world_revision
		ve.consumed_publish_bump = ve.publish_bump
		ve.has_published = true
		sync.cond_broadcast(&ve.frame_condition)
		sync.mutex_unlock(&ve.frame_mutex)
	}
	sync.mutex_unlock(&ve.mirror.mutex)
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
