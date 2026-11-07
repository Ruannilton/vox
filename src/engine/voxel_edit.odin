package engine

import "core:log"
import "core:sync"
import "core:time"
import vma "shared:vma"
import vk "vendor:vulkan"

VoxelEditRequest :: struct {
	world_voxel: [3]i32,
	block_id:    u32,
}

EditRingCounts :: struct {
	job_count:  u32,
	edit_count: u32,
}

EditManager :: struct {
	queue:             [dynamic]VoxelEditRequest,
	lookup:            map[[3]i32]int,
	pending:           map[ChunkCoordinate][dynamic]VoxelEditRequest,
	last_flush:        time.Tick,
	force_next_flush:  bool,
	staged_jobs:       [dynamic]EditChunkJob,
	staged_edits:      [dynamic]u32,
	ring_counts:       [NUM_FRAMES_IN_FLIGHT]EditRingCounts,
	stats_applied:     u64,
	stats_noop:        u64,
	stats_rejected:    u64,
	stats_deferred:    u64,
}

// Mundo -> (chunk, índice denso do voxel). Layout denso igual ao Slang:
// x | z<<5 | y<<10.

ve_request_voxel_edit :: proc(ve: ^VoxelEngine, world_voxel: [3]i32, block_id: u32) {
	if block_id > 65535 do return // fora do domínio de 16 bits do registro do lote
	// VS-10 (REQ-VRT-04): edição em chunk EMPTY. Ar-em-ar é no-op puro;
	// bloco sólido materializa o chunk (geração + pendência do E1).
	chunk, _ := voxel_chunk_and_index(world_voxel)
	if record, found := ve.active_chunks[chunk]; found && record.state == .EMPTY {
		if block_id == 0 {
			log.debugf("VS-10: edição de ar-em-ar em chunk EMPTY {} descartada (no-op)", chunk)
			return
		}
		if !ve_try_materialize_empty(ve, chunk) {
			// pool esgotado: a edição permanece na fila e a materialização
			// é retentada a cada update (ve_retry_empty_edits).
			log.debugf("VS-10: pool de slots esgotado; edição em {} aguarda materialização", chunk)
		}
	}
	if index, found := ve.edit.lookup[world_voxel]; found {
		ve.edit.queue[index].block_id = block_id // última escrita vence
		return
	}
	append(&ve.edit.queue, VoxelEditRequest{world_voxel, block_id})
	ve.edit.lookup[world_voxel] = len(ve.edit.queue) - 1
}

// VS-10 (REQ-VRT-04): materializa um chunk EMPTY — aloca slot, enfileira a
// geração (com mirror sintetizado se na bolha de simulação) e volta para
// GENERATING. A edição segue para a fila/pendências do E1 normalmente.
// Retorna false se o pool de slots estiver vazio (retry por update).

// VS-10 (REQ-VRT-04): retenta a materialização de edições cujo chunk ainda
// está EMPTY (pool esgotado na solicitação). No-op de ar-em-ar é removido.
ve_retry_empty_edits :: proc(ve: ^VoxelEngine) {
	if len(ve.edit.queue) == 0 do return
	kept := make([dynamic]VoxelEditRequest, context.temp_allocator)
	for request in ve.edit.queue {
		chunk, _ := voxel_chunk_and_index(request.world_voxel)
		record, found := ve.active_chunks[chunk]
		if found && record.state == .EMPTY {
			if request.block_id == 0 do continue // ar-em-ar: descartar
			ve_try_materialize_empty(ve, chunk)
		}
		append(&kept, request)
	}
	if len(kept) != len(ve.edit.queue) {
		delete(ve.edit.queue)
		ve.edit.queue = make([dynamic]VoxelEditRequest)
		clear(&ve.edit.lookup)
		for request in kept {
			append(&ve.edit.queue, request)
			ve.edit.lookup[request.world_voxel] = len(ve.edit.queue) - 1
		}
	}
}

ve_request_voxel_edits_in_box :: proc(ve: ^VoxelEngine, min_corner, max_corner: [3]i32, block_id: u32) {
	for x in min_corner.x ..= max_corner.x {
		for y in min_corner.y ..= max_corner.y {
			for z in min_corner.z ..= max_corner.z {
				ve_request_voxel_edit(ve, {x, y, z}, block_id)
			}
		}
	}
}




edit_ring_write :: proc(ve: ^VoxelEngine, frame_index: u32) -> u32 {
	frame_idx := int(frame_index % NUM_FRAMES_IN_FLIGHT)

	// Feedback do flush que usou este slot há NUM_FRAMES_IN_FLIGHT frames.
	// O buffer é HOST_ACCESS_RANDOM: invalida antes de ler (no-op em memória
	// coerente).
	vk_check(
		vma.InvalidateAllocation(
			app.vmaAllocator,
			voxel_gpu.edit_results.allocation,
			0,
			vk.DeviceSize(voxel_gpu.edit_results.size),
		),
	)
	previous := ve.edit.ring_counts[frame_idx]
	if previous.edit_count > 0 {
		// Log por flush (diagnóstico): contagem por código neste slot.
		applied, noop, rejected: u32
		for i in 0 ..< previous.edit_count {
			code := voxel_gpu.edit_results_mapped[frame_idx * MAX_EDITS_PER_FLUSH + int(i)]
			switch code {
			case EDIT_RESULT_APPLIED:
				applied += 1
			case EDIT_RESULT_NOOP:
				noop += 1
			case:
				rejected += 1
				// VS-04 (REQ-MIRROR-09): o mirror aplicou otimisticamente —
				// reconcilia a página mapeando a posição do ring de volta a
				// (chunk, voxel, bloco). Os rings de jobs/edições do slot
				// ainda estão intactos na colheita (só são regravados abaixo).
				mirror_reconcile_ring_position(ve, frame_idx, previous, i)
			}
		}
		log.infof(
			"DEBUG EDIT feedback: {} edições ({} jobs) — applied={} noop={} rejected={}",
			previous.edit_count,
			previous.job_count,
			applied,
			noop,
			rejected,
		)
		if previous.edit_count <= 128 {
			// TEMPORÁRIO (diagnóstico): par (edição packed, código) por posição.
			for i in 0 ..< previous.edit_count {
				packed := voxel_gpu.voxel_edits_mapped[frame_idx * MAX_EDITS_PER_FLUSH + int(i)]
				code := voxel_gpu.edit_results_mapped[frame_idx * MAX_EDITS_PER_FLUSH + int(i)]
				log.infof(
					"  edit[{}]: voxel={} block={} -> code={}",
					i,
					packed & 0x7FFF,
					packed >> 16,
					code,
				)
			}
		}
		ve.edit.stats_applied += u64(applied)
		ve.edit.stats_noop += u64(noop)
		ve.edit.stats_rejected += u64(rejected)
	}

	job_count := u32(len(ve.edit.staged_jobs))
	edit_count := u32(len(ve.edit.staged_edits))
	jobs_base := frame_idx * MAX_EDIT_JOBS_PER_FLUSH
	edits_base := frame_idx * MAX_EDITS_PER_FLUSH
	for job, i in ve.edit.staged_jobs {
		global_job := job
		global_job.first_edit += u32(edits_base) // índice global no ring (shader usa direto)
		voxel_gpu.edit_jobs_mapped[jobs_base + i] = global_job
	}
	for packed_edit, i in ve.edit.staged_edits {
		voxel_gpu.voxel_edits_mapped[edits_base + i] = packed_edit
	}

	ve.edit.ring_counts[frame_idx] = EditRingCounts{job_count, edit_count}
	// O staging vale por UMA cópia: sem limpar, frames seguintes re-copiam e
	// re-despacham o mesmo flush (vistos como no-ops redundantes no feedback).
	clear(&ve.edit.staged_jobs)
	clear(&ve.edit.staged_edits)
	return job_count
}

edit_update :: proc(ve: ^VoxelEngine) {
	if edit_flush_due(ve) do flush_voxel_edits(ve)
}

edit_log_stats :: proc(ve: ^VoxelEngine, prefix: string) {
	log.infof(
		"{} applied={} noop={} rejected={} deferred={} (fila={}, pendências={})",
		prefix,
		ve.edit.stats_applied,
		ve.edit.stats_noop,
		ve.edit.stats_rejected,
		ve.edit.stats_deferred,
		len(ve.edit.queue),
		len(ve.edit.pending),
	)
}



@(private)
voxel_chunk_and_index :: proc "contextless" (world_voxel: [3]i32) -> (chunk: ChunkCoordinate, voxel_index: u32) {
	chunk = ChunkCoordinate{
		floor_div_i32(world_voxel.x, CHUNK_SIZE),
		floor_div_i32(world_voxel.y, CHUNK_SIZE),
		floor_div_i32(world_voxel.z, CHUNK_SIZE),
	}
	local_x := world_voxel.x - chunk.x * CHUNK_SIZE
	local_y := world_voxel.y - chunk.y * CHUNK_SIZE
	local_z := world_voxel.z - chunk.z * CHUNK_SIZE
	voxel_index = u32(local_x) | (u32(local_z) << 5) | (u32(local_y) << 10)
	return
}

@(private)
ve_try_materialize_empty :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) -> bool {
	if len(ve.free_storage_slots) == 0 do return false
	slot := pop(&ve.free_storage_slots)
	ve.slot_generations[slot] += 1
	generation := ve.slot_generations[slot]
	chunk_record := &ve.active_chunks[coord]
	chunk_record.state = .GENERATING
	chunk_record.storage_slot_index = slot
	chunk_record.generation = generation
	ve.empty_chunks_active -= 1

	// Mirror: se o chunk está na bolha de simulação e a página não existe,
	// sintetiza zeros (conteúdo worldgen = ar conhecido) antes do journal.
	if coord in ve.mirror.pages {
		// página existente (zeros do ring ou já sintetizada): nada a fazer.
	} else {
		sim_radius2 := i64(config.radius_simulation) * i64(config.radius_simulation)
		if calculate_squared_distance(ve.last_camera_chunk, coord) <= sim_radius2 {
			if page := mirror_page_acquire(ve, coord); page != nil {
				mirror_page_fill_empty(ve, coord, page)
			}
		}
	}

	task := GenerationTask {
		coordinate         = coord,
		storage_slot_index = slot,
		generation         = generation,
		mirror_ring_slot   = -1,
	}
	sync.mutex_lock(&ve.queue_mutex)
	append(&ve.pending_tasks, task)
	sync.cond_signal(&ve.queue_condition)
	sync.mutex_unlock(&ve.queue_mutex)
	log.infof("VS-10: materializando chunk EMPTY {} (slot {}, geração {})", coord, slot, generation)
	return true
}

@(private)
edit_defer_to_pending :: proc(ve: ^VoxelEngine, chunk: ChunkCoordinate, request: VoxelEditRequest) {
	list := ve.edit.pending[chunk] // dynamic array compartilha o backing
	for &existing in list {
		if existing.world_voxel == request.world_voxel {
			existing.block_id = request.block_id // última escrita vence
			ve.edit.pending[chunk] = list
			return
		}
	}
	append(&list, request)
	ve.edit.pending[chunk] = list // append pode realocar: escreve de volta
	// Nota: pendências de chunks que nunca mais forem carregados ficam na
	// memória (capar por TTL/quantidade fica no backlog, junto ao save).
}

@(private)
edit_flush_due :: proc(ve: ^VoxelEngine) -> bool {
	if ve.edit.force_next_flush do return len(ve.edit.queue) > 0 || len(ve.edit.pending) > 0
	if len(ve.edit.queue) == 0 && len(ve.edit.pending) == 0 do return false
	if EDIT_FLUSH_INTERVAL_MS <= 0 do return true
	return time.duration_milliseconds(time.tick_since(ve.edit.last_flush)) >= EDIT_FLUSH_INTERVAL_MS
}

@(private)
flush_voxel_edits :: proc(ve: ^VoxelEngine) {
	clear(&ve.edit.staged_jobs)
	clear(&ve.edit.staged_edits)

	ready := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in ve.edit.pending {
		record, found := ve.active_chunks[coord]
		// VS-10: chunk EMPTY (sem slot) não está pronto — a edição só sai da
		// pendência quando a materialização concluir (CACHED/RENDERABLE).
		if found && (record.state == .CACHED || record.state == .RENDERABLE) {
			append(&ready, coord)
		}
	}
	for coord in ready {
		list := ve.edit.pending[coord]
		for request in list {
			ve_request_voxel_edit(ve, request.world_voxel, request.block_id) // dedup cuida de duplicatas
		}
		delete(list)
		delete_key(&ve.edit.pending, coord)
	}

	buckets := make(map[u32][dynamic]u32, context.temp_allocator) // slot -> packed edits
	total_staged := 0
	kept := make([dynamic]VoxelEditRequest, context.temp_allocator)

	for request in ve.edit.queue {
		chunk, voxel_index := voxel_chunk_and_index(request.world_voxel)
		record, found := ve.active_chunks[chunk]
		// VS-10: chunk EMPTY não tem slot — sem materialização não há para
		// onde despachar (a materialização é retentada por ve_retry_empty_edits).
		if !found || record.state == .GENERATING || record.state == .EMPTY {
			edit_defer_to_pending(ve, chunk, request)
			continue
		}
		if total_staged >= MAX_EDITS_PER_FLUSH {
			append(&kept, request)
			ve.edit.stats_deferred += 1
			continue
		}
		bucket, bucket_found := buckets[record.storage_slot_index]
		if !bucket_found {
			if len(buckets) >= MAX_EDIT_JOBS_PER_FLUSH {
				append(&kept, request)
				ve.edit.stats_deferred += 1
				continue
			}
			bucket = make([dynamic]u32, context.temp_allocator)
		}
		if len(bucket) >= MAX_EDITS_PER_CHUNK_PER_FLUSH {
			append(&kept, request)
			ve.edit.stats_deferred += 1
			continue
		}
		append(&bucket, pack_voxel_edit(voxel_index, request.block_id))
		buckets[record.storage_slot_index] = bucket
		total_staged += 1
		mirror_journal_apply(ve, chunk, request.world_voxel, request.block_id)
	}

	for slot, bucket in buckets {
		job := EditChunkJob {
			storage_slot_index = slot,
			first_edit         = u32(len(ve.edit.staged_edits)),
			edit_count         = u32(len(bucket)),
		}
		append(&ve.edit.staged_jobs, job)
		append(&ve.edit.staged_edits, ..bucket[:])
	}

	delete(ve.edit.queue)
	ve.edit.queue = make([dynamic]VoxelEditRequest)
	clear(&ve.edit.lookup)
	for request in kept {
		append(&ve.edit.queue, request)
		ve.edit.lookup[request.world_voxel] = len(ve.edit.queue) - 1
	}

	if len(ve.edit.staged_edits) > 0 {
		log.infof(
			"DEBUG EDIT flush: {} jobs, {} edições staged",
			len(ve.edit.staged_jobs),
			len(ve.edit.staged_edits),
		)
	}

	// O flush do journal (staging) é quem consome o intervalo/force;
	// edit_ring_write só copia o staging para o ring e não deve tocar aqui.
	ve.edit.last_flush = time.tick_now()
	ve.edit.force_next_flush = false
}

@(private)
mirror_reconcile_ring_position :: proc(ve: ^VoxelEngine, frame_idx: int, counts: EditRingCounts, index: u32) {
	// job que cobre a posição (edições contíguas por chunk)
	job: EditChunkJob
	found_job := false
	for j in 0 ..< counts.job_count {
		candidate := voxel_gpu.edit_jobs_mapped[frame_idx * MAX_EDIT_JOBS_PER_FLUSH + int(j)]
		if index >= candidate.first_edit && index < candidate.first_edit + candidate.edit_count {
			job, found_job = candidate, true
			break
		}
	}
	if !found_job do return

	// slot -> coordenada do chunk (busca reversa; caminho raro de rejeição)
	coord: ChunkCoordinate
	found_coord := false
	for c, record in ve.active_chunks {
		if record.storage_slot_index == job.storage_slot_index {
			coord, found_coord = c, true
			break
		}
	}
	if !found_coord do return

	packed_edit := voxel_gpu.voxel_edits_mapped[frame_idx * MAX_EDITS_PER_FLUSH + int(index)]
	voxel_index := packed_edit & 0x7FFF
	world_voxel := [3]i32 {
		coord.x * CHUNK_SIZE + i32(voxel_index & 31),
		coord.y * CHUNK_SIZE + i32(voxel_index >> 10),
		coord.z * CHUNK_SIZE + i32((voxel_index >> 5) & 31),
	}
	mirror_reconcile_rejection(ve, coord, VoxelEditRequest{world_voxel, packed_edit >> 16})
}

@(private)
edit_manager_init :: proc(ve: ^VoxelEngine) {
	ve.edit.queue = make([dynamic]VoxelEditRequest)
	ve.edit.lookup = make(map[[3]i32]int)
	ve.edit.pending = make(map[ChunkCoordinate][dynamic]VoxelEditRequest)
	ve.edit.staged_jobs = make([dynamic]EditChunkJob)
	ve.edit.staged_edits = make([dynamic]u32)
	ve.edit.last_flush = time.tick_now()
}

@(private)
edit_manager_destroy :: proc(ve: ^VoxelEngine) {
	for _, list in ve.edit.pending {
		delete(list)
	}
	delete(ve.edit.pending)
	delete(ve.edit.lookup)
	delete(ve.edit.queue)
	delete(ve.edit.staged_jobs)
	delete(ve.edit.staged_edits)
}
