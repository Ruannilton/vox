package engine

// VS-01 — ChunkManager: streaming com histerese (8/8/16), ciclo de vida B1
// (claim atômico, anti-ABA, aposentadoria dual). Domínios de concorrência:
//   - thread principal: active_chunks, free/retiring slots, slot_generations
//   - queue_mutex:      pending_tasks, submitted_batches, priority_camera_chunk
//   - worker thread:    submissão de lotes (voxel_worker.odin)

import "core:log"
import "core:math"
import "core:sync"
import "core:thread"
import vk "vendor:vulkan"

ChunkState :: enum {
	GENERATING,
	CACHED,
	RENDERABLE,
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
	mirror_ring_slot:   i32, // C2 (VS-04): sempre -1 nesta fatia
}

SubmittedBatch :: struct {
	compute_timeline_value: u64,
	task_count:             int,
	tasks:                  [MAXIMUM_CHUNKS_PER_BATCH]GenerationTask,
}

// Slot CACHED/RENDERABLE: liberado quando a timeline GRÁFICA passar do valor.
RetiringSlot :: struct {
	storage_slot_index:  u32,
	release_frame_value: u64,
}

// Slot descarregado em GENERATING: a fila de compute ainda pode escrever nele
// — liberado só quando a TIMELINE DE COMPUTE passar do valor do lote (B1).
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
	first_update:                   bool,
	highest_completed_compute_value: u64,
	edit:                           EditManager, // VS-03 (E1): journal de edição

	// --- domínio de queue_mutex (thread principal <-> worker) ---
	queue_mutex:           sync.Mutex,
	queue_condition:       sync.Cond,
	pending_tasks:         [dynamic]GenerationTask,
	submitted_batches:     [dynamic]SubmittedBatch,
	priority_camera_chunk: ChunkCoordinate,
	worker_stop_requested: u32,

	worker: ^thread.Thread,
}

// Instância ativa (acessada pela worker thread).
active_ve: ^VoxelEngine

// ADR-B8: intermediários de 64 bits — sem overflow para coordenadas extremas.
calculate_squared_distance :: proc "contextless" (a, b: ChunkCoordinate) -> i64 {
	dx := i64(a.x) - i64(b.x)
	dy := i64(a.y) - i64(b.y)
	dz := i64(a.z) - i64(b.z)
	return dx * dx + dy * dy + dz * dz
}

// Divisão com piso (REQ-STREAM-06): mundo -1 -> chunk -1, local 31.
floor_div_i32 :: proc "contextless" (value, divisor: i32) -> i32 {
	q := value / divisor
	if value % divisor != 0 && (value < 0) != (divisor < 0) {
		q -= 1
	}
	return q
}

chunk_coordinate_from_world :: proc "contextless" (pos: [3]f32) -> ChunkCoordinate {
	return {
		floor_div_i32(i32(math.floor(pos.x)), CHUNK_SIZE),
		floor_div_i32(i32(math.floor(pos.y)), CHUNK_SIZE),
		floor_div_i32(i32(math.floor(pos.z)), CHUNK_SIZE),
	}
}

// Identidade completa de uma tarefa: coordenada + slot + geração (anti-ABA).
task_matches :: proc "contextless" (task: GenerationTask, coord: ChunkCoordinate, record: ChunkRecord) -> bool {
	return task.coordinate == coord &&
		task.storage_slot_index == record.storage_slot_index &&
		task.generation == record.generation
}

ve_init :: proc() -> ^VoxelEngine {
	ve := new(VoxelEngine)
	ve^ = VoxelEngine {
		active_chunks         = make(map[ChunkCoordinate]ChunkRecord),
		free_storage_slots    = make([dynamic]u32, 0, MAXIMUM_RESIDENT_CHUNKS),
		slot_generations      = make([]u32, MAXIMUM_RESIDENT_CHUNKS), // zero-init: 1ª alocação = geração 1
		pending_tasks         = make([dynamic]GenerationTask),
		submitted_batches     = make([dynamic]SubmittedBatch),
		last_camera_chunk     = {max(i32), max(i32), max(i32)}, // força a 1ª atualização
	}
	for i in 0 ..< MAXIMUM_RESIDENT_CHUNKS {
		append(&ve.free_storage_slots, u32(i))
	}
	edit_manager_init(ve)

	voxel_gpu_init()

	active_ve = ve
	ve.worker = thread.create(worker_thread_process)
	thread.start(ve.worker)

	log.infof("Voxel engine inicializada: {} slots de chunk", MAXIMUM_RESIDENT_CHUNKS)
	return ve
}

ve_destroy :: proc(ve: ^VoxelEngine) {
	sync.atomic_store(&ve.worker_stop_requested, 1)
	sync.mutex_lock(&ve.queue_mutex)
	sync.cond_broadcast(&ve.queue_condition)
	sync.mutex_unlock(&ve.queue_mutex)
	thread.join(ve.worker)
	thread.destroy(ve.worker)

	// Nenhum lote em voo após o join; ainda assim garante que a GPU terminou
	// antes de destruir os buffers.
	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	voxel_gpu_destroy()

	delete(ve.active_chunks)
	delete(ve.free_storage_slots)
	delete(ve.retiring_slots)
	delete(ve.retiring_compute_slots)
	delete(ve.slot_generations)
	delete(ve.pending_tasks)
	delete(ve.submitted_batches)
	edit_manager_destroy(ve)
	active_ve = nil
	free(ve)
}

// Handler de conclusão (thread principal, todo frame): promove chunks de lotes
// concluídos com validação anti-ABA e recicla slots aposentados cujas
// timelines já passaram.
ve_service_completions :: proc(ve: ^VoxelEngine) {
	completed_compute: u64
	vk_check(vk.GetSemaphoreCounterValue(app.vkDevice, app.computeTimelineSemaphore, &completed_compute))

	sync.mutex_lock(&ve.queue_mutex)
	completed_count := 0
	for b in ve.submitted_batches {
		if b.compute_timeline_value > completed_compute do break
		for i in 0 ..< b.task_count {
			task := b.tasks[i]
			if task.coordinate in ve.active_chunks {
				rec := &ve.active_chunks[task.coordinate]
				if rec.state == .GENERATING &&
				   rec.storage_slot_index == task.storage_slot_index &&
				   rec.generation == task.generation {
					rec.state = .CACHED
				}
			}
		}
		ve.highest_completed_compute_value = max(ve.highest_completed_compute_value, b.compute_timeline_value)
		completed_count += 1
	}
	remove_range(&ve.submitted_batches, 0, completed_count)
	sync.mutex_unlock(&ve.queue_mutex)

	// Aposentadoria de compute: a timeline garante que TODA escrita no slot
	// já concluiu (signal do lote implica visibilidade de memória).
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

// B1 — destino seguro do slot de um chunk descarregado em GENERATING.
// Como o claim do worker (pop + publicação do lote) é um único trecho crítico
// sob queue_mutex, a tarefa está em EXATAMENTE um destes lugares:
//   (a) pending_tasks     -> cancela e devolve o slot na hora
//   (b) submitted_batches -> aposenta contra a timeline de compute do lote
//   (c) nenhum dos dois   -> caminho defensivo: devolve na hora
retire_generating_slot :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord) {
	sync.mutex_lock(&ve.queue_mutex)
	defer sync.mutex_unlock(&ve.queue_mutex)

	for task, i in ve.pending_tasks {
		if task_matches(task, coord, record) {
			unordered_remove(&ve.pending_tasks, i)
			append(&ve.free_storage_slots, record.storage_slot_index)
			return
		}
	}

	for batch in ve.submitted_batches {
		for i in 0 ..< batch.task_count {
			task := batch.tasks[i]
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

// VS-02 (REQ-VIS-01/02, ADR-B2): reconstrói a lista de visíveis do frame no
// ring host-visible. Thread principal; chamada após WaitTimelineSemaphore, que
// garante que a GPU já terminou de ler esta posição do ring.
ve_publish_visible :: proc(ve: ^VoxelEngine, frame_index: u32) -> u32 {
	offset := int(frame_index) * MAXIMUM_VISIBLE_CHUNKS
	count: u32 = 0
	for coord, record in ve.active_chunks {
		if record.state != .RENDERABLE do continue
		if count >= MAXIMUM_VISIBLE_CHUNKS do break

		entry := VisibleChunk {
			chunk_world_origin = {coord.x * CHUNK_SIZE, coord.y * CHUNK_SIZE, coord.z * CHUNK_SIZE},
			storage_slot_index = record.storage_slot_index,
		}
		for neighbor_offset, i in NEIGHBOR_OFFSETS {
			entry.neighbor_slots[i] = NEIGHBOR_SLOT_INVALID
			neighbor_coord := coord + neighbor_offset
			if neighbor_coord in ve.active_chunks {
				neighbor_record := ve.active_chunks[neighbor_coord]
				// Só é seguro ler se a geração já concluiu: slot em
				// GENERATING contém lixo e pode estar sendo escrito
				// pela fila de compute neste instante.
				if neighbor_record.state != .GENERATING {
					entry.neighbor_slots[i] = neighbor_record.storage_slot_index
				}
			}
		}
		voxel_gpu.visible_chunks_mapped[offset + int(count)] = entry
		count += 1
	}
	return count
}

// Streaming com histerese (thread principal). ADR-B5: visão 8, geração 8,
// descarga 16 — como visão = geração, todo chunk concluído vira RENDERABLE.
// A promoção CACHED ⇄ RENDERABLE roda TODO frame (a conclusão de lotes não
// depende da câmera se mover); descarga e novas requisições, só quando o
// chunk da câmera muda.
ve_update :: proc(ve: ^VoxelEngine, camera_position: [3]f32) {
	ve_service_completions(ve)

	camera_chunk := chunk_coordinate_from_world(camera_position)
	if camera_chunk != ve.last_camera_chunk {
		ve.last_camera_chunk = camera_chunk

		sync.mutex_lock(&ve.queue_mutex)
		ve.priority_camera_chunk = camera_chunk
		sync.mutex_unlock(&ve.queue_mutex)

		// 1. Descarrega os distantes (raio 16)
		to_unload := make([dynamic]ChunkCoordinate, context.temp_allocator)
		for coord in ve.active_chunks {
			if calculate_squared_distance(camera_chunk, coord) > i64(RADIUS_UNLOAD) * RADIUS_UNLOAD {
				append(&to_unload, coord)
			}
		}
		for coord in to_unload {
			record := ve.active_chunks[coord]
			if record.state == .GENERATING {
				// B1: NUNCA devolver o slot direto — a GPU pode estar prestes a
				// escrever nele (lote em voo) ou a tarefa pode estar pendente.
				retire_generating_slot(ve, coord, record)
			} else {
				append(&ve.retiring_slots, RetiringSlot{record.storage_slot_index, app.currentTimelineValue})
			}
			delete_key(&ve.active_chunks, coord)
		}

		// 2. Pede novos (raio 8), com identidade anti-ABA por alocação
		new_tasks := make([dynamic]GenerationTask, context.temp_allocator)
		slots_exhausted := false
		for x in -RADIUS_GENERATION ..= RADIUS_GENERATION {
			for y in -RADIUS_GENERATION ..= RADIUS_GENERATION {
				for z in -RADIUS_GENERATION ..= RADIUS_GENERATION {
					coord := camera_chunk + ChunkCoordinate{i32(x), i32(y), i32(z)}
					if calculate_squared_distance(camera_chunk, coord) > i64(RADIUS_GENERATION) * RADIUS_GENERATION do continue
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
		if slots_exhausted {
			log.warn("Pool de slots de chunk esgotado; novas requisições aguardam reciclagem")
		}
		if len(new_tasks) > 0 {
			sync.mutex_lock(&ve.queue_mutex)
			append(&ve.pending_tasks, ..new_tasks[:])
			sync.cond_signal(&ve.queue_condition)
			sync.mutex_unlock(&ve.queue_mutex)
		}
	}

	// 3. Visibilidade (raio 8) — todo frame: lotes concluem de forma
	// assíncrona mesmo com a câmera parada.
	// NOTA: `for coord, &record in map` NÃO persiste a escrita neste
	// toolchain — mutar sempre via ponteiro por índice (ve.active_chunks[coord]).
	for coord, record in ve.active_chunks {
		is_visible := calculate_squared_distance(camera_chunk, coord) <= i64(RADIUS_VISION) * RADIUS_VISION
		if record.state == .CACHED && is_visible {
			rec := &ve.active_chunks[coord]
			rec.state = .RENDERABLE
		} else if record.state == .RENDERABLE && !is_visible {
			rec := &ve.active_chunks[coord]
			rec.state = .CACHED
		}
	}
}
