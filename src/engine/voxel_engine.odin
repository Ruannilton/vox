package engine

import "core:log"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"
import vma "shared:vma"
import vk "vendor:vulkan"

ChunkState :: enum {
	GENERATING,
	CACHED,
	RENDERABLE,
	EMPTY, // VS-10: chunk de ar puro — registro sem slot, nunca publicado
}

ChunkRecord :: struct {
	state:              ChunkState,
	storage_slot_index: u32,
	generation:         u32, // anti-ABA: distingue "mesmo slot, novo chunk"
}

GenerationTask :: struct {
	coordinate:         ChunkCoordinate,
	storage_slot_index: u32,
	generation:         u32,
	mirror_ring_slot:   i32,
	export_only:        bool,
}

SubmittedBatch :: struct {
	compute_timeline_value: u64,
	tasks:                  [dynamic]GenerationTask, // cap = config.chunks_per_batch (VS-08)
}

RetiringSlot :: struct {
	storage_slot_index:  u32,
	release_frame_value: u64,
}

RetiringComputeSlot :: struct {
	storage_slot_index:     u32,
	release_timeline_value: u64,
}

VoxelEngine :: struct {
	// --- domínio exclusivo da thread principal ---
	active_chunks:                  map[ChunkCoordinate]ChunkRecord,
	free_storage_slots:             [dynamic]u32,
	retiring_slots:                 [dynamic]RetiringSlot,
	retiring_compute_slots:         [dynamic]RetiringComputeSlot,
	slot_generations:               []u32,
	last_camera_chunk:              ChunkCoordinate,
	update_appended_tasks:          int,   // VS-15: tarefas enfileiradas no último update (plot work_items)
	slots_starved:                  bool,
	first_update:                   bool,
	highest_completed_compute_value: u64,
	// VS-10 (REQ-VRT-05): contadores de chunks vazios virtuais.
	empty_chunks_active:            int,   // registros no estado EMPTY
	slots_saved_total:              u64,   // slots devolvidos ao pool (acumulado)
	last_empty_log_time:            time.Tick,
	edit:                           EditManager,
	mirror:                         MirrorManager,

	// --- domínio de queue_mutex (thread principal <-> worker) ---
	queue_mutex:           sync.Mutex,
	queue_condition:       sync.Cond,
	pending_tasks:         [dynamic]GenerationTask,
	pending_export_tasks:  [dynamic]GenerationTask,
	submitted_batches:     [dynamic]SubmittedBatch,
	priority_camera_chunk: ChunkCoordinate,
	worker_stop_requested: u32,

	worker: ^thread.Thread,
}

active_ve: ^VoxelEngine

calculate_squared_distance :: proc "contextless" (a, b: ChunkCoordinate) -> i64 {
	dx := i64(a.x) - i64(b.x)
	dy := i64(a.y) - i64(b.y)
	dz := i64(a.z) - i64(b.z)
	return dx * dx + dy * dy + dz * dz
}

floor_div_i32 :: proc "contextless" (value, divisor: i32) -> i32 {
	q := value / divisor
	if value % divisor != 0 && (value < 0) != (divisor < 0) {
		q -= 1
	}
	return q
}

task_matches :: proc "contextless" (task: GenerationTask, coord: ChunkCoordinate, record: ChunkRecord) -> bool {
	return task.coordinate == coord &&
		task.storage_slot_index == record.storage_slot_index &&
		task.generation == record.generation
}

voxel_engine_init :: proc() -> ^VoxelEngine {
	ve := new(VoxelEngine)
	ve^ = VoxelEngine {
		active_chunks         = make(map[ChunkCoordinate]ChunkRecord),
		free_storage_slots    = make([dynamic]u32, 0, config.resident_slots),
		slot_generations      = make([]u32, config.resident_slots),
		pending_tasks         = make([dynamic]GenerationTask),
		pending_export_tasks  = make([dynamic]GenerationTask),
		submitted_batches     = make([dynamic]SubmittedBatch),
		last_camera_chunk     = {max(i32), max(i32), max(i32)},
	}
	for i in 0 ..< config.resident_slots {
		append(&ve.free_storage_slots, u32(i))
	}
	edit_manager_init(ve)
	mirror_init(ve)

	voxel_gpu_init()

	active_ve = ve
	ve.worker = thread.create(worker_thread_process)
	thread.start(ve.worker)

	log.infof("Voxel engine inicializada: {} slots de chunk", config.resident_slots)
	return ve
}

voxel_engine_destroy :: proc(ve: ^VoxelEngine) {
	sync.atomic_store(&ve.worker_stop_requested, 1)
	tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
	sync.cond_broadcast(&ve.queue_condition)
	tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)
	thread.join(ve.worker)
	thread.destroy(ve.worker)

	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	voxel_gpu_destroy()

	delete(ve.active_chunks)
	delete(ve.free_storage_slots)
	delete(ve.retiring_slots)
	delete(ve.retiring_compute_slots)
	delete(ve.slot_generations)
	delete(ve.pending_tasks)
	delete(ve.pending_export_tasks)
	delete(ve.submitted_batches)
	edit_manager_destroy(ve)
	mirror_destroy(ve)
	active_ve = nil
	free(ve)
}

voxel_engine_service_completions :: proc(ve: ^VoxelEngine) {
	completed_compute: u64
	vk_check(vk.GetSemaphoreCounterValue(app.vkDevice, app.computeTimelineSemaphore, &completed_compute))

	tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
	// VS-10 (REQ-VRT-02): as flags do pack são lidas pela CPU após a
	// timeline do lote (mesma ordenação da promoção a CACHED, mesmo anti-ABA).
	vk_check(
		vma.InvalidateAllocation(
			app.vmaAllocator,
			voxel_gpu.chunk_result_flags.allocation,
			0,
			vk.DeviceSize(voxel_gpu.chunk_result_flags.size),
		),
	)
	completed_count := 0
	for b in ve.submitted_batches {
		if b.compute_timeline_value > completed_compute do break
		for task in b.tasks {
			to_empty := false
			if task.coordinate in ve.active_chunks {
				rec := &ve.active_chunks[task.coordinate]
				if rec.state == .GENERATING &&
				   rec.storage_slot_index == task.storage_slot_index &&
				   rec.generation == task.generation {
					flags := voxel_gpu.chunk_result_flags_mapped[task.storage_slot_index]
					_, has_pending := ve.edit.pending[task.coordinate]
					if (flags & CHUNK_FLAG_EMPTY) != 0 && !has_pending {
						// Chunk de ar puro: vira registro virtual e o slot
						// volta ao pool. Adiado p/ depois do materialize do
						// mirror (ele valida slot+geração do registro).
						to_empty = true
					} else {
						rec.state = .CACHED
					}
				}
			}

			if task.mirror_ring_slot >= 0 {
				mirror_materialize_from_ring(ve, task, b.compute_timeline_value)
			}

			if to_empty {
				rec := &ve.active_chunks[task.coordinate]
				rec.state = .EMPTY
				rec.storage_slot_index = SLOT_INDEX_INVALID
				append(&ve.free_storage_slots, task.storage_slot_index)
				ve.empty_chunks_active += 1
				ve.slots_saved_total += 1
			}
		}
		ve.highest_completed_compute_value = max(ve.highest_completed_compute_value, b.compute_timeline_value)
		completed_count += 1
	}
	for &b in ve.submitted_batches[0:completed_count] {
		delete(b.tasks)
	}
	remove_range(&ve.submitted_batches, 0, completed_count)
	tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)

	for i := len(ve.retiring_compute_slots) - 1; i >= 0; i -= 1 {
		if ve.retiring_compute_slots[i].release_timeline_value <= completed_compute {
			append(&ve.free_storage_slots, ve.retiring_compute_slots[i].storage_slot_index)
			unordered_remove(&ve.retiring_compute_slots, i)
		}
	}

	completed_graphics: u64
	vk_check(vk.GetSemaphoreCounterValue(app.vkDevice, app.timelineSemaphore, &completed_graphics))
	for i := len(ve.retiring_slots) - 1; i >= 0; i -= 1 {
		if ve.retiring_slots[i].release_frame_value <= completed_graphics {
			append(&ve.free_storage_slots, ve.retiring_slots[i].storage_slot_index)
			unordered_remove(&ve.retiring_slots, i)
		}
	}
}

voxel_engine_publish_visible :: proc(ve: ^VoxelEngine, frame_index: u32) -> u32 {
	offset := int(frame_index) * int(config.visible_capacity)
	count: u32 = 0
	for coord, record in ve.active_chunks {
		if record.state != .RENDERABLE do continue
		if count >= config.visible_capacity do break

		entry := VisibleChunk {
			chunk_world_origin = {coord.x * CHUNK_SIZE, coord.y * CHUNK_SIZE, coord.z * CHUNK_SIZE},
			storage_slot_index = record.storage_slot_index,
		}
		for neighbor_offset, i in NEIGHBOR_OFFSETS {
			entry.neighbor_slots[i] = NEIGHBOR_SLOT_INVALID
			neighbor_coord := coord + neighbor_offset
			if neighbor_coord in ve.active_chunks {
				neighbor_record := ve.active_chunks[neighbor_coord]

				// VS-10 (REQ-VRT-03): vizinho contribui slot só se
				// materializado (CACHED/RENDERABLE); EMPTY/GENERATING =
				// NEIGHBOR_SLOT_INVALID, que o shader já trata como ar (B2).
				if neighbor_record.state == .CACHED || neighbor_record.state == .RENDERABLE {
					entry.neighbor_slots[i] = neighbor_record.storage_slot_index
				}
			}
		}
		voxel_gpu.visible_chunks_mapped[offset + int(count)] = entry
		count += 1
	}
	return count
}

// VS-10 (REQ-VRT-05): log periódico dos contadores de chunks vazios
// virtuais (reativos são recontados no map; economia é acumulada).

voxel_engine_update :: proc(ve: ^VoxelEngine, camera_position: [3]f32) {
	{
		ZoneN("service_completions")
		voxel_engine_service_completions(ve)
	}
	ve.update_appended_tasks = 0

	camera_chunk := chunk_coordinate_from_world(camera_position)
	if camera_chunk != ve.last_camera_chunk {
		ZoneN("streaming_update")
		ve.last_camera_chunk = camera_chunk

		tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
		ve.priority_camera_chunk = camera_chunk
		tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)

		to_unload := make([dynamic]ChunkCoordinate, context.temp_allocator)
		for coord in ve.active_chunks {
			if calculate_squared_distance(camera_chunk, coord) > i64(config.radius_unload) * i64(config.radius_unload) {
				append(&to_unload, coord)
			}
		}
		for coord in to_unload {
			record := ve.active_chunks[coord]
			mirror_forget_chunk(ve, coord, record)
			if record.state == .EMPTY {
				// VS-10 (REQ-VRT-01): registro virtual — sem aposentadoria
				// (nada GPU-side); apenas deleta do map. O contador de
				// ativos é recontado no log periódico.
				delete_key(&ve.active_chunks, coord)
				continue
			}
			if record.state == .GENERATING {
				retire_generating_slot(ve, coord, record)
			} else {
				append(&ve.retiring_slots, RetiringSlot{record.storage_slot_index, app.currentTimelineValue})
			}
			delete_key(&ve.active_chunks, coord)
		}

		new_tasks := make([dynamic]GenerationTask, context.temp_allocator)
		slots_exhausted := false
		generation_radius := i32(config.radius_generation)
		generation_radius2 := i64(config.radius_generation) * i64(config.radius_generation)
		for x in -generation_radius ..= generation_radius {
			for y in -generation_radius ..= generation_radius {
				for z in -generation_radius ..= generation_radius {
					coord := camera_chunk + ChunkCoordinate{x, y, z}
					if calculate_squared_distance(camera_chunk, coord) > generation_radius2 do continue
					if coord in ve.active_chunks do continue

					if len(ve.free_storage_slots) == 0 {
						slots_exhausted = true
						continue
					}
					slot := pop(&ve.free_storage_slots)
					ve.slot_generations[slot] += 1
					generation := ve.slot_generations[slot]
					ve.active_chunks[coord] = ChunkRecord{.GENERATING, slot, generation}
					append(&new_tasks, GenerationTask{
						coordinate         = coord,
						storage_slot_index = slot,
						generation         = generation,
						mirror_ring_slot   = -1,
					})
				}
			}
		}
		if slots_exhausted && !ve.slots_starved {
			// um warn por episódio de fome (transição no passo de geração)
			log.warn("Pool de slots de chunk esgotado; novas requisições aguardam reciclagem")
			ve.slots_starved = true
		}
		if !slots_exhausted {
			ve.slots_starved = false
		}
		if len(new_tasks) > 0 {
			tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
			append(&ve.pending_tasks, ..new_tasks[:])
			sync.cond_signal(&ve.queue_condition)
			tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)
		}
		ve.update_appended_tasks = len(new_tasks)
	}

	{
		ZoneN("promote_visibility")
		for coord, record in ve.active_chunks {
			is_visible := calculate_squared_distance(camera_chunk, coord) <= i64(config.radius_vision) * i64(config.radius_vision)
			if record.state == .CACHED && is_visible {
				chunk_record := &ve.active_chunks[coord]
				chunk_record.state = .RENDERABLE
			} else if record.state == .RENDERABLE && !is_visible {
				chunk_record := &ve.active_chunks[coord]
				chunk_record.state = .CACHED
			}
		}
	}

	{
		ZoneN("mirror_service")
		mirror_update_bubble(ve, camera_chunk)
		mirror_service_retries(ve)
	}

	// VS-10 (REQ-VRT-04): edições em chunk EMPTY com pool esgotado ficam na
	// fila; a materialização é retentada a cada update (sem erro, sem perda).
	ve_retry_empty_edits(ve)

	// VS-10 (REQ-VRT-05): log periódico dos contadores de chunks vazios.
	if time.duration_seconds(time.tick_since(ve.last_empty_log_time)) >= 5.0 {
		ve_log_empty_stats(ve)
	}
}

@(private)
chunk_coordinate_from_world :: proc "contextless" (position: [3]f32) -> ChunkCoordinate {
	return {
		floor_div_i32(i32(math.floor(position.x)), CHUNK_SIZE),
		floor_div_i32(i32(math.floor(position.y)), CHUNK_SIZE),
		floor_div_i32(i32(math.floor(position.z)), CHUNK_SIZE),
	}
}

@(private)
retire_generating_slot :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord) {
	tracing_mutex_lock(&ve.queue_mutex, &tracing_queue_lock)
	defer tracing_mutex_unlock(&ve.queue_mutex, &tracing_queue_lock)

	for task, i in ve.pending_tasks {
		if task_matches(task, coord, record) {
			unordered_remove(&ve.pending_tasks, i)
			append(&ve.free_storage_slots, record.storage_slot_index)
			return
		}
	}

	for batch in ve.submitted_batches {
		for task in batch.tasks {
			if task_matches(task, coord, record) {
				append(
					&ve.retiring_compute_slots,
					RetiringComputeSlot{record.storage_slot_index, batch.compute_timeline_value},
				)
				return
			}
		}
	}

	append(&ve.free_storage_slots, record.storage_slot_index)
}

@(private)
ve_log_empty_stats :: proc(ve: ^VoxelEngine) {
	actives := 0
	for _, record in ve.active_chunks {
		if record.state == .EMPTY do actives += 1
	}
	ve.empty_chunks_active = actives
	ve.last_empty_log_time = time.tick_now()
	log.infof(
		"VS-10: chunks EMPTY ativos={} (slots economizados acumulados={}, slots livres={})",
		actives,
		ve.slots_saved_total,
		len(ve.free_storage_slots),
	)
}
