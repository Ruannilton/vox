package engine

// VS-04 (C2) — Mirror CPU-side (ADR-C2). A verdade do mundo é worldgen +
// journal E1; a GPU (packed) e a RAM (ChunkPage densa u16) são views
// materializadas do MESMO fluxo, na mesma ordem — convergência por
// construção. Sem paleta na RAM: o ID é direto (u16), o que elimina
// divergência de paleta e mantém chunks em PALETTE_OVERFLOW representáveis.
//
// Layout da página: y-contíguo (idx = y | z<<5 | x<<10 — uma coluna vertical
// = 64 B = 1 linha de cache). REGRA 7: nunca misturar com o denso
// x-contíguo do scratch GPU / das edições packed.
//
// Domínio: tudo roda na thread principal, EXCETO as seções que tomam
// queue_mutex (tarefas de geração/re-export são compartilhadas com a worker).

import "core:log"
import "core:sync"
import vma "shared:vma"
import vk "vendor:vulkan"

MirrorManager :: struct {
	// Pool fixo de páginas (endereços estáveis — o hash guarda ponteiros).
	pool:       []MirrorChunkPage,
	free_pages: [dynamic]u32,
	pages:      map[ChunkCoordinate]^MirrorChunkPage,
	ring:       [MIRROR_RING_SLOTS]MirrorRingEntry,
	// Diagnóstico.
	stats_pages_live:  int,
	stats_pool_misses: u64,
	stats_ring_misses: u64,
}

// Mundo -> (chunk, coordenada local). Mesmo floor-div do E1.
mirror_chunk_and_local :: proc "contextless" (world_voxel: [3]i32) -> (chunk: ChunkCoordinate, local: [3]i32) {
	chunk = ChunkCoordinate{
		floor_div_i32(world_voxel.x, CHUNK_SIZE),
		floor_div_i32(world_voxel.y, CHUNK_SIZE),
		floor_div_i32(world_voxel.z, CHUNK_SIZE),
	}
	local = [3]i32{
		world_voxel.x - chunk.x * CHUNK_SIZE,
		world_voxel.y - chunk.y * CHUNK_SIZE,
		world_voxel.z - chunk.z * CHUNK_SIZE,
	}
	return
}

// Índice do MIRROR (y-contíguo) — REGRA 7: nunca usar o índice denso
// x-contíguo do GPU/E1 aqui.
mirror_index_from_local :: proc "contextless" (local: [3]i32) -> u32 {
	return u32(local.y) | (u32(local.z) << 5) | (u32(local.x) << 10)
}

mirror_bit_test :: proc "contextless" (mask: []u32, index: u32) -> bool {
	return (mask[index >> 5] >> (index & 31)) & 1 != 0
}

mirror_bit_write :: proc "contextless" (mask: []u32, index: u32, value: bool) {
	bit := u32(1) << (index & 31)
	if value {
		mask[index >> 5] |= bit
	} else {
		mask[index >> 5] &= ~bit
	}
}

// --- Pool de páginas ---

mirror_page_acquire :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) -> ^MirrorChunkPage {
	if len(ve.mirror.free_pages) == 0 {
		ve.mirror.stats_pool_misses += 1
		return nil
	}
	pool_index := pop(&ve.mirror.free_pages)
	page := &ve.mirror.pool[pool_index]
	page.coord = coord
	page.edit_seq = 0
	page.state = .PENDING_READBACK
	page.ring_slot = -1
	page.pending = nil     // o backing da vida anterior foi liberado no release
	page.applied_log = nil // idem
	page.rejected_log = nil // idem
	// solid/ids não precisam de zero: a materialização sobrescreve tudo.
	ve.mirror.pages[coord] = page
	ve.mirror.stats_pages_live += 1
	return page
}

mirror_page_release :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) {
	page, found := ve.mirror.pages[coord]
	if !found do return
	delete(page.pending)
	delete(page.applied_log)
	delete(page.rejected_log)
	page.pending = nil
	page.applied_log = nil
	page.rejected_log = nil
	delete_key(&ve.mirror.pages, coord)
	pool_index := u32((uintptr(page) - uintptr(raw_data(ve.mirror.pool))) / size_of(MirrorChunkPage))
	append(&ve.mirror.free_pages, pool_index)
	ve.mirror.stats_pages_live -= 1
}

// --- Ring de export (regra 4: slot em voo só o handler de conclusão libera) ---

mirror_ring_try_reserve :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, generation: u32) -> i32 {
	for &entry, i in ve.mirror.ring {
		if !entry.used {
			entry.used = true
			entry.coord = coord
			entry.generation = generation
			return i32(i)
		}
	}
	ve.mirror.stats_ring_misses += 1
	return -1 // ring cheio: mirror_service_retries tenta nos próximos frames
}

// Só vale para exports AINDA NÃO submetidos (tarefas canceladas localmente).
// A checagem por (coord, geração) impede liberar uma entrada já reutilizada.
mirror_ring_release :: proc(ve: ^VoxelEngine, ring_slot: i32, coord: ChunkCoordinate, generation: u32) {
	entry := &ve.mirror.ring[ring_slot]
	if entry.used && entry.coord == coord && entry.generation == generation {
		entry.used = false
	}
}

// --- Agendamento de preenchimento ---

// Chunk ainda em GENERATING com a tarefa pendente: acopla um slot de ring a
// ela — o export sai de graça, junto com o próprio generate.
mirror_try_attach_to_generation :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord, page: ^MirrorChunkPage) -> bool {
	sync.mutex_lock(&ve.queue_mutex)
	defer sync.mutex_unlock(&ve.queue_mutex)
	for &task in ve.pending_tasks {
		if task_matches(task, coord, record) && !task.export_only {
			ring := mirror_ring_try_reserve(ve, coord, record.generation)
			if ring < 0 do return false
			task.mirror_ring_slot = ring
			page.ring_slot = ring
			return true
		}
	}
	return false
}

// Chunk já CACHED/RENDERABLE: agenda um RE-EXPORT (tarefa export_only — roda
// só o generate; o pack NÃO pode rodar de novo, pois reescreveria o packed a
// partir do worldgen e apagaria edições já aplicadas — AC-03). O scratch do
// slot é sobrescrito, mas é transitório por definição — ninguém mais o lê.
mirror_schedule_export :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord) -> bool {
	page, found := ve.mirror.pages[coord]
	if !found || page.state != .PENDING_READBACK || page.ring_slot >= 0 do return false
	ring := mirror_ring_try_reserve(ve, coord, record.generation)
	if ring < 0 do return false
	page.ring_slot = ring
	task := GenerationTask {
		coordinate         = coord,
		storage_slot_index = record.storage_slot_index,
		generation         = record.generation,
		mirror_ring_slot   = ring,
		export_only        = true,
	}
	sync.mutex_lock(&ve.queue_mutex)
	append(&ve.pending_export_tasks, task)
	sync.cond_signal(&ve.queue_condition)
	sync.mutex_unlock(&ve.queue_mutex)
	return true
}

// Páginas PENDING sem export agendado: (a) tarefa de geração ainda pendente
// -> acopla um slot de ring agora; (b) chunk já CACHED -> agenda o re-export.
// Chamada todo frame, depois do handler de conclusão (é quando slots de ring
// são liberados).
mirror_service_retries :: proc(ve: ^VoxelEngine) {
	for coord, page in ve.mirror.pages {
		if page.state != .PENDING_READBACK || page.ring_slot >= 0 do continue
		record, active := ve.active_chunks[coord]
		if !active do continue
		if record.state == .GENERATING {
			mirror_try_attach_to_generation(ve, coord, record, page)
		} else {
			mirror_schedule_export(ve, coord, record)
		}
	}
}

// Puxa a página de um chunk sob demanda (ex.: um sistema prestes a consultar
// um chunk fora da bolha de simulação). Não bloqueia: a página entra como
// PENDING_READBACK e abre quando o export concluir.
mirror_request_page :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord) {
	page := mirror_page_acquire(ve, coord)
	if page == nil do return // pool cheio: tenta no próximo frame/movimento
	if record.state == .GENERATING {
		mirror_try_attach_to_generation(ve, coord, record, page)
		// Se a tarefa já foi reivindicada (ou o ring está cheio), a página fica
		// PENDING sem slot: mirror_service_retries agenda o re-export quando o
		// chunk ficar CACHED.
	} else {
		mirror_schedule_export(ve, coord, record)
	}
}

mirror_request :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) {
	if coord in ve.mirror.pages do return
	record, found := ve.active_chunks[coord]
	if !found do return
	mirror_request_page(ve, coord, record)
}

// Descarte do espelho de um chunk (descarregado ou fora da bolha). A página é
// liberada; exports PENDENTES são desacoplados/cancelados e seus slots de
// ring voltam ao pool; exports EM VOO são descartados pelo handler de
// conclusão (página ausente / geração não bate -> entry liberada lá). A tarefa
// de GERAÇÃO em si nunca é cancelada aqui — o descarregamento de GENERATING
// já passou por retire_generating_slot, e um chunk fora da bolha continua
// renderizando.
mirror_forget_chunk :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, record: ChunkRecord) {
	sync.mutex_lock(&ve.queue_mutex)
	for i := len(ve.pending_export_tasks) - 1; i >= 0; i -= 1 {
		task := ve.pending_export_tasks[i]
		if task_matches(task, coord, record) {
			if task.mirror_ring_slot >= 0 {
				mirror_ring_release(ve, task.mirror_ring_slot, coord, record.generation)
			}
			unordered_remove(&ve.pending_export_tasks, i)
		}
	}
	for &task in ve.pending_tasks {
		if task_matches(task, coord, record) && task.mirror_ring_slot >= 0 {
			mirror_ring_release(ve, task.mirror_ring_slot, coord, record.generation)
			task.mirror_ring_slot = -1
		}
	}
	// Se NADA em voo referencia este (coord, geração), qualquer entrada de ring
	// residual pode ser liberada na hora — a GPU nunca a escreverá. Se há lote
	// em voo, quem libera é o handler de conclusão (regra 4).
	in_flight := false
	for batch in ve.submitted_batches {
		for i in 0 ..< batch.task_count {
			task := batch.tasks[i]
			if task_matches(task, coord, record) && task.mirror_ring_slot >= 0 {
				in_flight = true
			}
		}
	}
	if !in_flight {
		for &entry in ve.mirror.ring {
			if entry.used && entry.coord == coord && entry.generation == record.generation {
				entry.used = false
			}
		}
	}
	sync.mutex_unlock(&ve.queue_mutex)
	mirror_page_release(ve, coord)
}

// --- Aplicação de edições (dupla materialização, REQ-MIRROR-07) ---

// O MESMO pedido staged para a GPU alimenta o mirror — mesma ordem, mesmo
// dedup, mesmo teto de lote (chamada só no caminho "staged" do flush).
// Convergência por construção: os dois lados aplicam o mesmo journal.
mirror_journal_apply :: proc(ve: ^VoxelEngine, chunk: ChunkCoordinate, world_voxel: [3]i32, block_id: u32) {
	page, found := ve.mirror.pages[chunk]
	if !found do return // fora da bolha de simulação: só a GPU recebe o journal
	if page.state == .PENDING_READBACK {
		// O export em voo contém APENAS worldgen: retém a edição (dedup
		// "última escrita vence", mesma regra do E1) p/ replay na materialização.
		for &existing in page.pending {
			if existing.world_voxel == world_voxel {
				existing.block_id = block_id
				return
			}
		}
		append(&page.pending, VoxelEditRequest{world_voxel, block_id})
		return
	}
	mirror_page_apply(page, world_voxel, block_id)
	append(&page.applied_log, VoxelEditRequest{world_voxel, block_id})
	page.edit_seq += 1
}

// Reconciliação de uma rejeição reportada pelo feedback do E1 (2 frames
// depois). A GPU NÃO aplicou a edição; o mirror aplicou otimisticamente.
mirror_reconcile_rejection :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate, rejected: VoxelEditRequest) {
	page, found := ve.mirror.pages[coord]
	if !found do return // página evictada: a GPU não mudou, nada a reconciliar
	if page.state == .PENDING_READBACK && len(page.rejected_log) == 0 {
		// Primeiro preenchimento: a rejeitada ainda está retida — remove antes
		// do replay (não precisa de re-export).
		for i := len(page.pending) - 1; i >= 0; i -= 1 {
			if page.pending[i] == rejected {
				ordered_remove(&page.pending, i)
				break
			}
		}
		return
	}
	// MATERIALIZED (ou reconciliação já em voo): acumula no filtro e agenda
	// o re-export; a rematerialização faz o replay do applied_log sem ela.
	append(&page.rejected_log, rejected)
	page.state = .PENDING_READBACK
	if record, active := ve.active_chunks[coord]; active {
		mirror_schedule_export(ve, coord, record)
	}
}

// --- API pública do mirror (gameplay — thread principal, REQ-MIRROR-08) ---

// Consulta tri-state canônica ("qual o voxel em (x,y,z)?"): (amostra, true) =
// leitura válida; ({}, false) = DESCONHECIDO (chunk sem página ou página em
// PENDING_READBACK). A política do desconhecido — bloquear, chutar, aguardar —
// é do consumidor; mirror_request puxa a página sob demanda.
voxel_get :: proc(ve: ^VoxelEngine, world_voxel: [3]i32) -> (sample: VoxelSample, ok: bool) {
	chunk, local := mirror_chunk_and_local(world_voxel)
	page, found := ve.mirror.pages[chunk]
	if !found || page.state != .MATERIALIZED { return {}, false }
	index := mirror_index_from_local(local)
	return VoxelSample{page.ids[index], mirror_bit_test(page.solid[:], index)}, true
}

voxel_is_solid :: proc(ve: ^VoxelEngine, world_voxel: [3]i32) -> (solid: bool, ok: bool) {
	sample, valid := voxel_get(ve, world_voxel)
	return sample.solid, valid
}

// Varredura colunar: primeiro sólido indo de y_from para baixo (raycast de
// coluna — o layout y-contíguo faz a coluna inteira caber em 1 linha de cache
// por chunk). Cruza fronteiras de chunk; retorna ok=false se a varredura
// atingir uma página desconhecida (o chamador decide a política).
mirror_column_ground :: proc(ve: ^VoxelEngine, world_x, world_z, y_from: i32) -> (ground_y: i32, ok: bool) {
	y := y_from
	for {
		chunk := ChunkCoordinate{
			floor_div_i32(world_x, CHUNK_SIZE),
			floor_div_i32(y, CHUNK_SIZE),
			floor_div_i32(world_z, CHUNK_SIZE),
		}
		page, found := ve.mirror.pages[chunk]
		if !found || page.state != .MATERIALIZED { return 0, false }
		local_x := u32(world_x - chunk.x * CHUNK_SIZE)
		local_z := u32(world_z - chunk.z * CHUNK_SIZE)
		local_y := i32(y - chunk.y * CHUNK_SIZE)
		base := (local_x << 10) | (local_z << 5)
		for ly := local_y; ly >= 0; ly -= 1 {
			if mirror_bit_test(page.solid[:], base + u32(ly)) {
				return chunk.y * CHUNK_SIZE + ly, true
			}
		}
		y = chunk.y * CHUNK_SIZE - 1 // coluna toda de ar: desce p/ o chunk de baixo
	}
}

// --- Materialização (handler de conclusão de lote, thread principal) ---

// Aplica uma edição na página (ids + bitmask). Usada pelo replay da
// materialização, pelo dual-apply do journal e pela reconciliação.
mirror_page_apply :: proc(page: ^MirrorChunkPage, world_voxel: [3]i32, block_id: u32) {
	_, local := mirror_chunk_and_local(world_voxel)
	index := mirror_index_from_local(local)
	page.ids[index] = u16(block_id)
	mirror_bit_write(page.solid[:], index, block_id != 0)
}

// Copia o export do ring para a página (y-contíguo u16), reconstrói a
// bitmask de sólidos, faz o replay das edições retidas e abre a página.
mirror_materialize_from_ring :: proc(ve: ^VoxelEngine, task: GenerationTask, batch_timeline_value: u64) {
	ring_slot := task.mirror_ring_slot
	entry := &ve.mirror.ring[ring_slot]

	page, page_found := ve.mirror.pages[task.coordinate]
	record, active := ve.active_chunks[task.coordinate]
	// Mesma disciplina anti-ABA do B1: o conteúdo do ring só é válido para
	// exatamente o (coord, slot, geração) que pediu o export. Chunk recriado,
	// página evicta (saída da bolha) ou export vencido -> descarta e libera.
	valid := page_found && entry.used &&
		page.ring_slot == ring_slot &&
		entry.coord == task.coordinate && entry.generation == task.generation &&
		active && record.generation == task.generation &&
		record.storage_slot_index == task.storage_slot_index &&
		record.state != .GENERATING

	if !valid {
		entry.used = false
		return
	}

	// Acquire p/ o host: GetSemaphoreCounterValue NÃO é sincronização. Um
	// WaitSemaphores(0) sobre valor já alcançado retorna na hora e estabelece
	// a visibilidade das escritas do compute para a CPU (mesmo padrão do
	// readback de edit_results).
	semaphore := app.computeTimelineSemaphore
	value := batch_timeline_value
	vk_check(
		vk.WaitSemaphores(
			app.vkDevice,
			&vk.SemaphoreWaitInfo {
				sType          = .SEMAPHORE_WAIT_INFO,
				semaphoreCount = 1,
				pSemaphores    = &semaphore,
				pValues        = &value,
			},
			0,
		),
	)
	// O buffer é HOST_ACCESS_RANDOM: invalida antes de ler (no-op em memória
	// coerente) — somente o slot lido.
	vk_check(
		vma.InvalidateAllocation(
			app.vmaAllocator,
			voxel_gpu.mirror_export_ring.allocation,
			vk.DeviceSize(uint(ring_slot) * CHUNK_VOXEL_COUNT * size_of(u16)),
			vk.DeviceSize(CHUNK_VOXEL_COUNT * size_of(u16)),
		),
	)

	// ring -> página (y-contíguo u16) + reconstrução da bitmask de sólidos.
	base := int(ring_slot) * CHUNK_VOXEL_COUNT
	src := voxel_gpu.mirror_export_ring_mapped[base:base + CHUNK_VOXEL_COUNT]
	for id, i in src {
		page.ids[i] = id
		mirror_bit_write(page.solid[:], u32(i), id != 0)
	}
	if len(page.rejected_log) > 0 {
		// RECONCILIAÇÃO (REQ-MIRROR-09): o re-export trouxe só worldgen; o
		// journal aceito é reaplicado do applied_log SEM as edições rejeitadas
		// (remove a ocorrência mais recente de cada par — convergência exata).
		for rejected in page.rejected_log {
			for i := len(page.applied_log) - 1; i >= 0; i -= 1 {
				if page.applied_log[i] == rejected {
					ordered_remove(&page.applied_log, i)
					break
				}
			}
		}
		clear(&page.rejected_log)
		for edit in page.applied_log {
			mirror_page_apply(page, edit.world_voxel, edit.block_id)
		}
	}
	// Replay das edições staged p/ a GPU enquanto PENDING_READBACK: a edição
	// cai no packed DEPOIS do pack, então o export não a contém — sem o replay
	// os dois lados divergiriam.
	for edit in page.pending {
		mirror_page_apply(page, edit.world_voxel, edit.block_id)
		append(&page.applied_log, edit)
	}
	clear(&page.pending)
	page.state = .MATERIALIZED
	page.ring_slot = -1
	page.edit_seq += 1
	entry.used = false
}

// Gestão da bolha de simulação (raio 5, independente da bolha de render):
// evicta páginas cujo chunk saiu e pede páginas para os chunks presentes.
// Todo frame (barata), na thread principal.
mirror_update_bubble :: proc(ve: ^VoxelEngine, camera_chunk: ChunkCoordinate) {
	sim_radius2 := i64(RADIUS_SIMULATION) * RADIUS_SIMULATION
	to_forget := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in ve.mirror.pages {
		if calculate_squared_distance(camera_chunk, coord) > sim_radius2 {
			append(&to_forget, coord)
		}
	}
	for coord in to_forget {
		record, active := ve.active_chunks[coord]
		if active {
			mirror_forget_chunk(ve, coord, record)
		} else {
			mirror_page_release(ve, coord)
		}
	}
	for coord, record in ve.active_chunks {
		if calculate_squared_distance(camera_chunk, coord) > sim_radius2 do continue
		if coord in ve.mirror.pages do continue
		mirror_request_page(ve, coord, record)
	}
}

// Estatísticas do mirror (diagnóstico/evidência da VS-04).
mirror_log_stats :: proc(ve: ^VoxelEngine, prefix: string) {
	log.infof(
		"{} páginas vivas={} (pool {}), ring misses={}, pool misses={}",
		prefix,
		ve.mirror.stats_pages_live,
		MIRROR_PAGE_POOL_SIZE,
		ve.mirror.stats_ring_misses,
		ve.mirror.stats_pool_misses,
	)
}

@(private)
mirror_init :: proc(ve: ^VoxelEngine) {
	ve.mirror.pool = make([]MirrorChunkPage, MIRROR_PAGE_POOL_SIZE)
	ve.mirror.free_pages = make([dynamic]u32, 0, MIRROR_PAGE_POOL_SIZE)
	ve.mirror.pages = make(map[ChunkCoordinate]^MirrorChunkPage)
	for i in 0 ..< MIRROR_PAGE_POOL_SIZE {
		append(&ve.mirror.free_pages, u32(i))
	}
}

@(private)
mirror_destroy :: proc(ve: ^VoxelEngine) {
	for _, page in ve.mirror.pages {
		delete(page.pending)
		delete(page.applied_log)
		delete(page.rejected_log)
	}
	delete(ve.mirror.pages)
	delete(ve.mirror.free_pages)
	delete(ve.mirror.pool)
}
