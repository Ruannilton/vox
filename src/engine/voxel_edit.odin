package engine

// VS-03 (E1) — Journal de edição de voxels (ADR-E1). Toda alteração do mundo
// vira um VoxelEditRequest em coordenada de MUNDO via ve_request_voxel_edit,
// com dedup "última escrita vence" por voxel. O flush (temporal ou forçado)
// agrupa as edições por chunk (1 EditChunkJob = 1 workgroup no
// apply_voxel_edits) e grava jobs+edições no ring host-visible deste frame.
//
//   1. Pedidos cujo chunk está CACHED/RENDERABLE entram no lote; pedidos
//      cujo chunk está GENERATING ou ausente ficam em pending e reintegram
//      quando o chunk ficar pronto (a geração recomeça o terreno do zero —
//      a edição cai DEPOIS do pack).
//   2. O dispatch do compute roda NO COMMAND BUFFER DO FRAME, antes do
//      builder da fila de trabalho, com barreira COMPUTE->COMPUTE (ADR-B10)
//      — a malha do mesmo frame já nasce refletindo a edição.
//   3. O feedback (edit_results) é colhido no edit_ring_write do slot
//      seguinte (2 frames depois, protegido pela espera de frames em voo).
//
// Tetos do lote: MAX_EDITS_PER_FLUSH, MAX_EDIT_JOBS_PER_FLUSH e
// MAX_EDITS_PER_CHUNK_PER_FLUSH; o excedente permanece na fila para o
// próximo ciclo (backpressure natural, contabilizado em stats_deferred).
// Domínio: tudo aqui roda na thread principal.

import "core:log"
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
	// Fila ativa com dedup "última escrita vence" por voxel de mundo —
	// invariante que torna os refcounts exatos (1 edição por voxel por flush).
	queue:             [dynamic]VoxelEditRequest,
	lookup:            map[[3]i32]int,
	// Pedidos cujo chunk está GENERATING ou fora do raio: reaplicados quando
	// o chunk ficar pronto. (Sem persistência em disco — ver não-escopo.)
	pending:           map[ChunkCoordinate][dynamic]VoxelEditRequest,
	last_flush:        time.Tick,
	force_next_flush:  bool,
	// Staging do flush corrente: montado antes da espera de frames em voo e
	// copiado ao ring depois dela (mesma garantia do visible_chunks).
	staged_jobs:       [dynamic]EditChunkJob,
	staged_edits:      [dynamic]u32,
	// Contadores por slot do ring para o readback de edit_results.
	ring_counts:       [NUM_FRAMES_IN_FLIGHT]EditRingCounts,
	// Estatísticas acumuladas do feedback (diagnóstico/evidência).
	stats_applied:     u64,
	stats_noop:        u64,
	stats_rejected:    u64,
	stats_deferred:    u64, // ficaram para o próximo flush (tetos do lote)
}

// Mundo -> (chunk, índice denso do voxel). Layout denso igual ao Slang:
// x | z<<5 | y<<10.
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

// API pública: empilha (ou sobrescreve) um pedido de alteração. Deve ser
// chamada na thread principal (mesma do loop); se gameplay ganhar threads
// próprias, proteger queue+lookup com uma trava.
ve_request_voxel_edit :: proc(ve: ^VoxelEngine, world_voxel: [3]i32, block_id: u32) {
	if block_id > 65535 do return // fora do domínio de 16 bits do registro do lote
	if index, found := ve.edit.lookup[world_voxel]; found {
		ve.edit.queue[index].block_id = block_id // última escrita vence
		return
	}
	append(&ve.edit.queue, VoxelEditRequest{world_voxel, block_id})
	ve.edit.lookup[world_voxel] = len(ve.edit.queue) - 1
}

// Atalho para explosões/pincéis: mesma semântica, um voxel por chamada.
ve_request_voxel_edits_in_box :: proc(ve: ^VoxelEngine, min_corner, max_corner: [3]i32, block_id: u32) {
	for x in min_corner.x ..= max_corner.x {
		for y in min_corner.y ..= max_corner.y {
			for z in min_corner.z ..= max_corner.z {
				ve_request_voxel_edit(ve, {x, y, z}, block_id)
			}
		}
	}
}

// Move o pedido para a lista pendente do chunk (chunk gerando ou ausente),
// com dedup por voxel dentro da lista.
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

edit_flush_due :: proc(ve: ^VoxelEngine) -> bool {
	if ve.edit.force_next_flush do return len(ve.edit.queue) > 0 || len(ve.edit.pending) > 0
	if len(ve.edit.queue) == 0 && len(ve.edit.pending) == 0 do return false
	if EDIT_FLUSH_INTERVAL_MS <= 0 do return true
	return time.duration_milliseconds(time.tick_since(ve.edit.last_flush)) >= EDIT_FLUSH_INTERVAL_MS
}

// Monta o staging do flush: drena pendências prontas, converte mundo->slot,
// agrupa por chunk e aplica os tetos do lote. O que não couber permanece na
// fila para o próximo intervalo (backpressure natural).
flush_voxel_edits :: proc(ve: ^VoxelEngine) {
	clear(&ve.edit.staged_jobs)
	clear(&ve.edit.staged_edits)

	// 1. Reintegra pendências de chunks que ficaram prontos desde o último flush.
	ready := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in ve.edit.pending {
		record, found := ve.active_chunks[coord]
		if found && record.state != .GENERATING {
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

	// 2. Drena a fila ativa agrupando por slot (edições contíguas por job).
	buckets := make(map[u32][dynamic]u32, context.temp_allocator) // slot -> packed edits
	total_staged := 0
	kept := make([dynamic]VoxelEditRequest, context.temp_allocator)

	for request in ve.edit.queue {
		chunk, voxel_index := voxel_chunk_and_index(request.world_voxel)
		record, found := ve.active_chunks[chunk]
		if !found || record.state == .GENERATING {
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
	}

	// 3. Emite os jobs com as edições contíguas (first_edit local do staging;
	//    edit_ring_write soma a base do ring ao copiar).
	for slot, bucket in buckets {
		job := EditChunkJob {
			storage_slot_index = slot,
			first_edit         = u32(len(ve.edit.staged_edits)),
			edit_count         = u32(len(bucket)),
		}
		append(&ve.edit.staged_jobs, job)
		append(&ve.edit.staged_edits, ..bucket[:])
	}

	// 4. Recompacta a fila com o que ficou e reconstrói o lookup.
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
}

// Copia o staging para o slot do ring deste frame e colhe o feedback do uso
// anterior daquele slot (2 frames atrás — a espera de frames em voo já
// garantiu a conclusão). Chamada DEPOIS da espera, nunca antes.
// Retorna o job_count do frame (0 => nenhum dispatch de edição é gravado).
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
	ve.edit.last_flush = time.tick_now()
	ve.edit.force_next_flush = false
	// O staging vale por UMA cópia: sem limpar, frames seguintes re-copiam e
	// re-despacham o mesmo flush (vistos como no-ops redundantes no feedback).
	clear(&ve.edit.staged_jobs)
	clear(&ve.edit.staged_edits)
	return job_count
}

// Estatísticas do feedback (diagnóstico/evidência da VS-03).
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
