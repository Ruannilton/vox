package engine

// =============================================================================
// CHUNK STREAMER
// =============================================================================
//
// VISÃO GERAL
// -----------
// Duas threads cooperam:
//
//   Thread de GERAÇÃO   decide quais chunks carregar e descarregar e manda a GPU
//                       gerar o terreno (compute shader) em lotes ("batches").
//   Thread de RENDER    desenha os chunks que já estão prontos.
//
// Elas se coordenam com dois contadores na GPU (timeline semaphores):
//
//   generation_timeline   sobe quando a GPU termina de gerar um batch.
//                         Avisa o render: "esses chunks já têm dados".
//
//   render_timeline       sobe quando a GPU termina de desenhar um frame.
//                         Avisa a geração: "esse slot pode ser reaproveitado".
//
// Um "slot" é um pedaço fixo do SSBO gigante de voxels. O slot N guarda os
// voxels de um chunk. Slots são reciclados quando o chunk fica longe.
//
// CICLO DE VIDA DE UM SLOT
// ------------------------
//
//   Free -> WaitingForBatch -> Generating -> Ready -> Unloading -> Retiring -> Free
//
//   Free             livre para uso.
//   WaitingForBatch  reservado para um chunk, esperando entrar em um batch.
//                    A GPU ainda não tocou nele.
//   Generating       o compute shader está escrevendo nele (batch em voo).
//   Ready            gerado. O render pode desenhar.
//   Unloading        a geração pediu a descarga; esperando o render soltar o slot.
//   Retiring         o render soltou o slot; esperando a GPU terminar o último
//                    frame que ainda podia lê-lo.
//
// QUEM MEXE EM QUÊ
// ----------------
//   Thread de geração: chunk_slots, free_slot_ids, slots_waiting_for_batch,
//                      slots_retiring, slot_id_by_chunk_coord, batch_ring
//   Thread de render:  visible_by_slot, latest_generation_value_seen,
//                      next_frame_value, events_scratch
//   Compartilhado:     events_to_render e releases_to_generation (com mutex),
//                      camera_chunk_packed e is_running (atômicos)
//
// Remova do código antigo: CHUNK_SIZE, CHUNK_SLOT_COUNT, VoxelEngine e ve_*.

import "core:log"
import "core:math"
import "core:sync"
import "core:thread"
import "core:time"
import vk "vendor:vulkan"

// =============================================================================
// 1. CONSTANTES E TIPOS BÁSICOS
// =============================================================================

CHUNK_SIZE       :: 16        // voxels por lado
CHUNK_SLOT_COUNT :: 8 * 8 * 8 // quantos chunks cabem no SSBO

LOAD_RADIUS_IN_CHUNKS   :: 4
UNLOAD_RADIUS_IN_CHUNKS :: LOAD_RADIUS_IN_CHUNKS + 1 // histerese: descarrega um pouco além

MAX_BATCHES_IN_FLIGHT :: 4  // batches que a GPU pode estar executando ao mesmo tempo
MAX_CHUNKS_PER_BATCH  :: 16

SlotId     :: u32
ChunkCoord :: [2]i32 // posição do chunk no grid (x, z), em unidades de chunk

// =============================================================================
// 2. STRUCTS COMPARTILHADOS COM A GPU
// =============================================================================
// Layout std430: 16 bytes cada. Só o layout importa; os nomes dos campos no
// Slang (origin, slot) podem ser diferentes.

ChunkGenerationJob :: struct {
    world_origin: [3]i32, // canto do chunk em coordenadas de voxel do mundo
    slot_id:      SlotId, // onde gravar no SSBO de voxels
}

VisibleChunk :: struct {
    world_origin: [3]i32,
    slot_id:      SlotId,
}

// =============================================================================
// 3. MENSAGENS ENTRE AS THREADS
// =============================================================================

// Caixa de mensagens simples protegida por mutex.
// Troque por uma fila SPSC lock-free se o profiler pedir.
Mailbox :: struct($Message: typeid) {
    mutex:    sync.Mutex,
    messages: [dynamic]Message,
}

mailbox_send :: proc(mailbox: ^Mailbox($Message), message: Message) {
    sync.mutex_lock(&mailbox.mutex)
    defer sync.mutex_unlock(&mailbox.mutex)
    append(&mailbox.messages, message)
}

mailbox_take_all :: proc(mailbox: ^Mailbox($Message), destination: ^[dynamic]Message) {
    sync.mutex_lock(&mailbox.mutex)
    defer sync.mutex_unlock(&mailbox.mutex)
    append(destination, ..mailbox.messages[:])
    clear(&mailbox.messages)
}

// Geração -> Render.
// "Ready" e "MustBeUnloaded" usam a MESMA caixa para preservar a ordem entre eles.
// Com duas caixas, o render poderia ler a descarga antes do aviso de pronto do
// mesmo slot e deixar um slot reciclado visível.
ChunkEventKind :: enum u8 {
    BecameReady,
    MustBeUnloaded,
}

ChunkEvent :: struct {
    kind:             ChunkEventKind,
    slot_id:          SlotId,
    chunk_coord:      ChunkCoord,
    generation_value: u64, // valor de generation_timeline que garante que os dados estão prontos
}

// Render -> Geração: "parei de usar esse slot".
SlotReleaseMessage :: struct {
    slot_id:               SlotId,
    last_frame_using_slot: u64, // valor de render_timeline do último frame que podia lê-lo
}

// =============================================================================
// 4. ESTADO DO STREAMER
// =============================================================================

SlotState :: enum u8 {
    Free,
    WaitingForBatch,
    Generating,
    Ready,
    Unloading,
    Retiring,
}

ChunkSlot :: struct {
    chunk_coord:           ChunkCoord,
    state:                 SlotState,
    last_frame_using_slot: u64, // só vale no estado Retiring
}

// Um batch é um conjunto de chunks gerados por um único vkCmdDispatch.
GenerationBatch :: struct {
    generation_value: u64, // valor sinalizado em generation_timeline quando terminar
    chunk_count:      int,
    slot_ids:         [MAX_CHUNKS_PER_BATCH]SlotId,
}

VisibleSlotEntry :: struct {
    is_visible:   bool,
    world_origin: [3]i32,
}

// Recursos Vulkan criados fora deste arquivo.
ChunkStreamerConfig :: struct {
    device:                  vk.Device,
    generation_queue:        vk.Queue, // usada SÓ pela thread de geração (se for a mesma do render, proteja com mutex)
    generation_queue_family: u32,
    generation_pipeline:     vk.Pipeline,       // o compute shader de geração
    generation_layout:       vk.PipelineLayout,

    // Um conjunto de recursos por posição do anel de batches (índice 0..MAX_BATCHES_IN_FLIGHT-1):
    //   descriptor set: binding 0 = SSBO de voxels, binding 1 = buffer de jobs daquela posição
    descriptor_set_per_batch: [MAX_BATCHES_IN_FLIGHT]vk.DescriptorSet,
    //   ponteiro do buffer de jobs (host-visible, mapeado de forma persistente)
    job_buffer_per_batch:     [MAX_BATCHES_IN_FLIGHT][^]ChunkGenerationJob,
}

ChunkStreamer :: struct {
    // ----- Vulkan (não muda depois do create) -----
    device:                   vk.Device,
    generation_queue:         vk.Queue,
    generation_pipeline:      vk.Pipeline,
    generation_layout:        vk.PipelineLayout,
    descriptor_set_per_batch: [MAX_BATCHES_IN_FLIGHT]vk.DescriptorSet,
    job_buffer_per_batch:     [MAX_BATCHES_IN_FLIGHT][^]ChunkGenerationJob,
    generation_command_pool:  vk.CommandPool, // pool exclusivo da thread de geração
    command_buffer_per_batch: [MAX_BATCHES_IN_FLIGHT]vk.CommandBuffer,
    generation_timeline:      vk.Semaphore,
    render_timeline:          vk.Semaphore,

    // ----- Thread de geração -----
    chunk_slots:             [CHUNK_SLOT_COUNT]ChunkSlot,
    free_slot_ids:           [dynamic]SlotId,
    slots_waiting_for_batch: [dynamic]SlotId,
    slots_retiring:          [dynamic]SlotId,
    slot_id_by_chunk_coord:  map[ChunkCoord]SlotId, // chunks Waiting, Generating ou Ready

    // Anel de batches em voo: os mais antigos primeiro.
    batch_ring:            [MAX_BATCHES_IN_FLIGHT]GenerationBatch,
    oldest_batch_index:    int,
    batches_in_flight:     int,
    next_generation_value: u64,

    // ----- Thread de render -----
    visible_by_slot:             [CHUNK_SLOT_COUNT]VisibleSlotEntry,
    latest_generation_value_seen: u64,
    next_frame_value:            u64,
    events_scratch:              [dynamic]ChunkEvent,

    // ----- Comunicação entre as threads -----
    events_to_render:       Mailbox(ChunkEvent),
    releases_to_generation: Mailbox(SlotReleaseMessage),
    camera_chunk_packed:    u64, // atômico: chunk onde está a câmera
    is_running:             u32, // atômico: 1 enquanto a thread de geração deve rodar

    generation_thread: ^thread.Thread,
}

// =============================================================================
// 5. FUNÇÕES AUXILIARES
// =============================================================================

vk_check :: proc(result: vk.Result, location := #caller_location) {
    if result != .SUCCESS {
        log.panicf("Vulkan error: %v", result, location = location)
    }
}

// Guarda um ChunkCoord em um u64 para poder usar atomic_store/atomic_load.
pack_chunk_coord :: proc(coord: ChunkCoord) -> u64 {
    return u64(u32(coord.x)) << 32 | u64(u32(coord.y))
}

unpack_chunk_coord :: proc(packed: u64) -> ChunkCoord {
    return {i32(u32(packed >> 32)), i32(u32(packed))}
}

world_position_to_chunk_coord :: proc(position: [3]f32) -> ChunkCoord {
    return {
        i32(math.floor(position.x / CHUNK_SIZE)),
        i32(math.floor(position.z / CHUNK_SIZE)),
    }
}

chunk_coord_to_world_origin :: proc(coord: ChunkCoord) -> [3]i32 {
    return {coord.x * CHUNK_SIZE, 0, coord.y * CHUNK_SIZE}
}

squared_distance_in_chunks :: proc(a, b: ChunkCoord) -> int {
    delta_x := int(a.x - b.x)
    delta_z := int(a.y - b.y)
    return delta_x * delta_x + delta_z * delta_z
}

create_timeline_semaphore :: proc(device: vk.Device) -> vk.Semaphore {
    timeline_info := vk.SemaphoreTypeCreateInfo{
        sType         = .SEMAPHORE_TYPE_CREATE_INFO,
        semaphoreType = .TIMELINE,
        initialValue  = 0,
    }
    create_info := vk.SemaphoreCreateInfo{
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = &timeline_info,
    }
    semaphore: vk.Semaphore
    vk_check(vk.CreateSemaphore(device, &create_info, nil, &semaphore))
    return semaphore
}

// Bloqueia a CPU até o contador do semáforo chegar em `target_value`.
wait_for_timeline_value :: proc(device: vk.Device, semaphore: vk.Semaphore, target_value: u64) {
    semaphore_to_wait := semaphore
    value_to_wait     := target_value
    wait_info := vk.SemaphoreWaitInfo{
        sType          = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = 1,
        pSemaphores    = &semaphore_to_wait,
        pValues        = &value_to_wait,
    }
    vk_check(vk.WaitSemaphores(device, &wait_info, max(u64)))
}

// Lê o contador atual SEM bloquear.
read_timeline_value :: proc(device: vk.Device, semaphore: vk.Semaphore) -> u64 {
    value: u64
    vk_check(vk.GetSemaphoreCounterValue(device, semaphore, &value))
    return value
}

// =============================================================================
// 6. CICLO DE VIDA
// =============================================================================

chunk_streamer_create :: proc(config: ChunkStreamerConfig) -> ^ChunkStreamer {
    streamer := new(ChunkStreamer)

    streamer.device                   = config.device
    streamer.generation_queue         = config.generation_queue
    streamer.generation_pipeline      = config.generation_pipeline
    streamer.generation_layout        = config.generation_layout
    streamer.descriptor_set_per_batch = config.descriptor_set_per_batch
    streamer.job_buffer_per_batch     = config.job_buffer_per_batch

    streamer.generation_timeline = create_timeline_semaphore(streamer.device)
    streamer.render_timeline     = create_timeline_semaphore(streamer.device)

    // Command pool próprio: pools não são thread-safe, então a thread de geração tem o seu.
    pool_info := vk.CommandPoolCreateInfo{
        sType            = .COMMAND_POOL_CREATE_INFO,
        flags            = {.RESET_COMMAND_BUFFER},
        queueFamilyIndex = config.generation_queue_family,
    }
    vk_check(vk.CreateCommandPool(streamer.device, &pool_info, nil, &streamer.generation_command_pool))

    allocate_info := vk.CommandBufferAllocateInfo{
        sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool        = streamer.generation_command_pool,
        level              = .PRIMARY,
        commandBufferCount = MAX_BATCHES_IN_FLIGHT,
    }
    vk_check(vk.AllocateCommandBuffers(streamer.device, &allocate_info, &streamer.command_buffer_per_batch[0]))

    streamer.slot_id_by_chunk_coord = make(map[ChunkCoord]SlotId)

    // Todos os slots começam livres (em ordem inversa para o pop entregar o slot 0 primeiro).
    for slot_index := CHUNK_SLOT_COUNT - 1; slot_index >= 0; slot_index -= 1 {
        append(&streamer.free_slot_ids, SlotId(slot_index))
    }

    // Valores de timeline começam em 1; o valor 0 significa "nada aconteceu ainda".
    streamer.next_generation_value = 1
    streamer.next_frame_value      = 1

    return streamer
}

chunk_streamer_start :: proc(streamer: ^ChunkStreamer) {
    sync.atomic_store(&streamer.is_running, 1)

    streamer.generation_thread = thread.create(generation_thread_main)
    streamer.generation_thread.data = streamer
    streamer.generation_thread.init_context = context // propaga logger e allocator
    thread.start(streamer.generation_thread)
}

chunk_streamer_stop :: proc(streamer: ^ChunkStreamer) {
    sync.atomic_store(&streamer.is_running, 0)
    thread.join(streamer.generation_thread)
    thread.destroy(streamer.generation_thread)
}

// Chame depois de chunk_streamer_stop e de vk.DeviceWaitIdle.
chunk_streamer_destroy :: proc(streamer: ^ChunkStreamer) {
    vk.DestroyCommandPool(streamer.device, streamer.generation_command_pool, nil)
    vk.DestroySemaphore(streamer.device, streamer.generation_timeline, nil)
    vk.DestroySemaphore(streamer.device, streamer.render_timeline, nil)

    delete(streamer.free_slot_ids)
    delete(streamer.slots_waiting_for_batch)
    delete(streamer.slots_retiring)
    delete(streamer.slot_id_by_chunk_coord)
    delete(streamer.events_scratch)
    delete(streamer.events_to_render.messages)
    delete(streamer.releases_to_generation.messages)

    free(streamer)
}

// =============================================================================
// 7. THREAD DE GERAÇÃO
// =============================================================================
// A cada volta do loop, executa 6 passos em ordem.

generation_thread_main :: proc(thread_handle: ^thread.Thread) {
    streamer := cast(^ChunkStreamer)thread_handle.data

    release_messages: [dynamic]SlotReleaseMessage
    defer delete(release_messages)

    for sync.atomic_load(&streamer.is_running) == 1 {
        step_1_collect_finished_batches(streamer)
        step_2_receive_released_slots(streamer, &release_messages)
        step_3_recycle_slots_gpu_is_done_with(streamer)
        step_4_unload_distant_chunks(streamer)
        step_5_reserve_slots_for_nearby_chunks(streamer)
        step_6_submit_next_batch(streamer)

        time.sleep(500 * time.Microsecond)
    }

    // Antes de sair, espera a GPU terminar os batches que ainda estão em voo.
    if streamer.batches_in_flight > 0 {
        newest_batch_index := (streamer.oldest_batch_index + streamer.batches_in_flight - 1) % MAX_BATCHES_IN_FLIGHT
        wait_for_timeline_value(streamer.device, streamer.generation_timeline, streamer.batch_ring[newest_batch_index].generation_value)
    }
}

// PASSO 1: a GPU terminou algum batch?
// Se sim, os chunks dele estão prontos e avisamos o render.
step_1_collect_finished_batches :: proc(streamer: ^ChunkStreamer) {
    gpu_finished_up_to := read_timeline_value(streamer.device, streamer.generation_timeline)

    for streamer.batches_in_flight > 0 {
        oldest_batch := &streamer.batch_ring[streamer.oldest_batch_index]
        if oldest_batch.generation_value > gpu_finished_up_to {
            break // o batch mais antigo ainda não terminou, os demais também não
        }

        for chunk_index in 0 ..< oldest_batch.chunk_count {
            slot_id := oldest_batch.slot_ids[chunk_index]
            streamer.chunk_slots[slot_id].state = .Ready

            mailbox_send(&streamer.events_to_render, ChunkEvent{
                kind             = .BecameReady,
                slot_id          = slot_id,
                chunk_coord      = streamer.chunk_slots[slot_id].chunk_coord,
                generation_value = oldest_batch.generation_value,
            })
        }

        streamer.oldest_batch_index = (streamer.oldest_batch_index + 1) % MAX_BATCHES_IN_FLIGHT
        streamer.batches_in_flight -= 1
    }
}

// PASSO 2: o render devolveu algum slot? Ele passa de Unloading para Retiring.
step_2_receive_released_slots :: proc(streamer: ^ChunkStreamer, release_messages: ^[dynamic]SlotReleaseMessage) {
    clear(release_messages)
    mailbox_take_all(&streamer.releases_to_generation, release_messages)

    for message in release_messages {
        chunk_slot := &streamer.chunk_slots[message.slot_id]
        chunk_slot.state                 = .Retiring
        chunk_slot.last_frame_using_slot = message.last_frame_using_slot
        append(&streamer.slots_retiring, message.slot_id)
    }
}

// PASSO 3: slots em Retiring só voltam a ficar livres quando a GPU já terminou
// o último frame que podia lê-los. Escrever antes disso corromperia o desenho.
step_3_recycle_slots_gpu_is_done_with :: proc(streamer: ^ChunkStreamer) {
    if len(streamer.slots_retiring) == 0 do return

    gpu_rendered_up_to := read_timeline_value(streamer.device, streamer.render_timeline)

    // De trás para frente, para remover elementos sem pular nenhum.
    for retiring_index := len(streamer.slots_retiring) - 1; retiring_index >= 0; retiring_index -= 1 {
        slot_id := streamer.slots_retiring[retiring_index]

        if streamer.chunk_slots[slot_id].last_frame_using_slot <= gpu_rendered_up_to {
            streamer.chunk_slots[slot_id].state = .Free
            append(&streamer.free_slot_ids, slot_id)
            unordered_remove(&streamer.slots_retiring, retiring_index)
        }
    }
}

// PASSO 4: descarrega chunks que ficaram longe da câmera.
step_4_unload_distant_chunks :: proc(streamer: ^ChunkStreamer) {
    camera_chunk := unpack_chunk_coord(sync.atomic_load(&streamer.camera_chunk_packed))
    unload_radius_squared :: UNLOAD_RADIUS_IN_CHUNKS * UNLOAD_RADIUS_IN_CHUNKS

    for &chunk_slot, slot_index in streamer.chunk_slots {
        if squared_distance_in_chunks(chunk_slot.chunk_coord, camera_chunk) <= unload_radius_squared {
            continue // ainda está perto, mantém
        }

        slot_id := SlotId(slot_index)

        #partial switch chunk_slot.state {
        case .WaitingForBatch:
            // A GPU nunca tocou nesse slot: pode liberar imediatamente.
            delete_key(&streamer.slot_id_by_chunk_coord, chunk_slot.chunk_coord)
            remove_from_waiting_list(streamer, slot_id)
            chunk_slot.state = .Free
            append(&streamer.free_slot_ids, slot_id)

        case .Ready:
            // O render pode estar desenhando esse chunk agora.
            // Pede para ele soltar o slot (handshake: passos 2 e 3 completam o ciclo).
            delete_key(&streamer.slot_id_by_chunk_coord, chunk_slot.chunk_coord)
            chunk_slot.state = .Unloading
            mailbox_send(&streamer.events_to_render, ChunkEvent{
                kind    = .MustBeUnloaded,
                slot_id = slot_id,
            })

        // Generating: deixa o batch terminar. Vira Ready e é descarregado no próximo ciclo.
        }
    }
}

remove_from_waiting_list :: proc(streamer: ^ChunkStreamer, slot_id: SlotId) {
    for waiting_index in 0 ..< len(streamer.slots_waiting_for_batch) {
        if streamer.slots_waiting_for_batch[waiting_index] == slot_id {
            ordered_remove(&streamer.slots_waiting_for_batch, waiting_index)
            return
        }
    }
}

// PASSO 5: para cada posição do grid dentro do raio de carga que ainda não tem
// chunk, reserva um slot livre. A geração em si acontece no passo 6.
step_5_reserve_slots_for_nearby_chunks :: proc(streamer: ^ChunkStreamer) {
    camera_chunk := unpack_chunk_coord(sync.atomic_load(&streamer.camera_chunk_packed))
    load_radius_squared :: LOAD_RADIUS_IN_CHUNKS * LOAD_RADIUS_IN_CHUNKS

    for offset_z in -LOAD_RADIUS_IN_CHUNKS ..= LOAD_RADIUS_IN_CHUNKS {
        for offset_x in -LOAD_RADIUS_IN_CHUNKS ..= LOAD_RADIUS_IN_CHUNKS {
            if offset_x * offset_x + offset_z * offset_z > load_radius_squared {
                continue // fora do círculo
            }

            chunk_coord := ChunkCoord{camera_chunk.x + i32(offset_x), camera_chunk.y + i32(offset_z)}
            if chunk_coord in streamer.slot_id_by_chunk_coord {
                continue // já existe
            }

            if len(streamer.free_slot_ids) == 0 {
                log.warn("Sem slots livres para novos chunks")
                return
            }

            slot_id := pop(&streamer.free_slot_ids)
            streamer.chunk_slots[slot_id] = ChunkSlot{chunk_coord = chunk_coord, state = .WaitingForBatch}
            streamer.slot_id_by_chunk_coord[chunk_coord] = slot_id
            append(&streamer.slots_waiting_for_batch, slot_id)
        }
    }
}

// Remove e devolve o slot em espera cujo chunk está mais perto da câmera.
take_nearest_waiting_slot :: proc(streamer: ^ChunkStreamer, camera_chunk: ChunkCoord) -> (slot_id: SlotId, found: bool) {
    if len(streamer.slots_waiting_for_batch) == 0 {
        return 0, false
    }

    nearest_list_index        := 0
    nearest_squared_distance  := max(int)

    for candidate_slot_id, list_index in streamer.slots_waiting_for_batch {
        squared_distance := squared_distance_in_chunks(streamer.chunk_slots[candidate_slot_id].chunk_coord, camera_chunk)
        if squared_distance < nearest_squared_distance {
            nearest_squared_distance = squared_distance
            nearest_list_index       = list_index
        }
    }

    slot_id = streamer.slots_waiting_for_batch[nearest_list_index]
    unordered_remove(&streamer.slots_waiting_for_batch, nearest_list_index)
    return slot_id, true
}

// PASSO 6: monta um batch com os chunks mais próximos e manda a GPU gerá-los.
step_6_submit_next_batch :: proc(streamer: ^ChunkStreamer) {
    no_work_to_do := len(streamer.slots_waiting_for_batch) == 0
    ring_is_full  := streamer.batches_in_flight == MAX_BATCHES_IN_FLIGHT
    if no_work_to_do || ring_is_full do return

    camera_chunk := unpack_chunk_coord(sync.atomic_load(&streamer.camera_chunk_packed))

    // Posição deste batch no anel. O buffer de jobs, o command buffer e o descriptor set
    // dessa posição só são reaproveitados depois que o batch anterior dela terminou
    // (garantido porque o passo 1 já liberou a posição).
    ring_index := (streamer.oldest_batch_index + streamer.batches_in_flight) % MAX_BATCHES_IN_FLIGHT
    batch      := &streamer.batch_ring[ring_index]
    batch^ = {}

    // --- 6a. Preenche o buffer de jobs com os chunks mais próximos ---
    for batch.chunk_count < MAX_CHUNKS_PER_BATCH {
        slot_id, found := take_nearest_waiting_slot(streamer, camera_chunk)
        if !found do break

        chunk_coord := streamer.chunk_slots[slot_id].chunk_coord

        streamer.job_buffer_per_batch[ring_index][batch.chunk_count] = ChunkGenerationJob{
            world_origin = chunk_coord_to_world_origin(chunk_coord),
            slot_id      = slot_id,
        }
        batch.slot_ids[batch.chunk_count] = slot_id
        batch.chunk_count += 1

        streamer.chunk_slots[slot_id].state = .Generating
    }
    // Se o buffer de jobs for não-coerente: chame vk.FlushMappedMemoryRanges aqui.

    // --- 6b. Grava o command buffer: um workgroup por chunk ---
    command_buffer := streamer.command_buffer_per_batch[ring_index]
    descriptor_set := streamer.descriptor_set_per_batch[ring_index]

    vk_check(vk.ResetCommandBuffer(command_buffer, {}))
    begin_info := vk.CommandBufferBeginInfo{
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }
    vk_check(vk.BeginCommandBuffer(command_buffer, &begin_info))
    vk.CmdBindPipeline(command_buffer, .COMPUTE, streamer.generation_pipeline)
    vk.CmdBindDescriptorSets(command_buffer, .COMPUTE, streamer.generation_layout, 0, 1, &descriptor_set, 0, nil)
    vk.CmdDispatch(command_buffer, u32(batch.chunk_count), 1, 1)
    vk_check(vk.EndCommandBuffer(command_buffer))

    // --- 6c. Submete e pede à GPU para sinalizar generation_timeline ao terminar ---
    batch.generation_value = streamer.next_generation_value
    streamer.next_generation_value += 1

    command_buffer_info := vk.CommandBufferSubmitInfo{
        sType         = .COMMAND_BUFFER_SUBMIT_INFO,
        commandBuffer = command_buffer,
    }
    signal_info := vk.SemaphoreSubmitInfo{
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = streamer.generation_timeline,
        value     = batch.generation_value,
        stageMask = {.COMPUTE_SHADER},
    }
    submit_info := vk.SubmitInfo2{
        sType                    = .SUBMIT_INFO_2,
        commandBufferInfoCount   = 1,
        pCommandBufferInfos      = &command_buffer_info,
        signalSemaphoreInfoCount = 1,
        pSignalSemaphoreInfos    = &signal_info,
    }
    vk_check(vk.QueueSubmit2(streamer.generation_queue, 1, &submit_info, 0))

    streamer.batches_in_flight += 1
}

// =============================================================================
// 8. LADO DO RENDER (chamar apenas da thread de render)
// =============================================================================

// O que o render precisa para montar o submit do frame.
FrameSyncInfo :: struct {
    visible_chunk_count:      u32,
    generation_value_to_wait: u64, // 0 = não precisa esperar generation_timeline
    render_value_to_signal:   u64, // valor a sinalizar em render_timeline neste frame
}

// Controle de frames em voo: espera a GPU terminar o frame (next_frame_value - frames_in_flight).
// Chame ANTES de chunk_streamer_begin_frame, pois o buffer `visible_chunks_out` daquele frame é reescrito.
chunk_streamer_wait_for_old_frames :: proc(streamer: ^ChunkStreamer, frames_in_flight: u64) {
    if streamer.next_frame_value <= frames_in_flight do return
    wait_for_timeline_value(streamer.device, streamer.render_timeline, streamer.next_frame_value - frames_in_flight)
}

// Chame uma vez por frame, antes de gravar os comandos. Faz três coisas:
//   1. Publica a posição da câmera para a thread de geração.
//   2. Aplica os eventos recebidos (chunk pronto, chunk descarregado).
//   3. Escreve em `visible_chunks_out` a lista de chunks a desenhar
//      (precisa ter capacidade para CHUNK_SLOT_COUNT entradas).
chunk_streamer_begin_frame :: proc(
    streamer:           ^ChunkStreamer,
    camera_position:    [3]f32,
    visible_chunks_out: [^]VisibleChunk,
) -> FrameSyncInfo {

    // 1. Câmera
    camera_chunk := world_position_to_chunk_coord(camera_position)
    sync.atomic_store(&streamer.camera_chunk_packed, pack_chunk_coord(camera_chunk))

    // 2. Eventos, na mesma ordem em que a geração os enviou
    clear(&streamer.events_scratch)
    mailbox_take_all(&streamer.events_to_render, &streamer.events_scratch)

    for event in streamer.events_scratch {
        switch event.kind {
        case .BecameReady:
            streamer.visible_by_slot[event.slot_id] = VisibleSlotEntry{
                is_visible   = true,
                world_origin = chunk_coord_to_world_origin(event.chunk_coord),
            }
            streamer.latest_generation_value_seen = max(streamer.latest_generation_value_seen, event.generation_value)

        case .MustBeUnloaded:
            // A partir deste frame o slot não é mais desenhado.
            // O último frame que ainda pode lê-lo é o anterior (next_frame_value - 1).
            streamer.visible_by_slot[event.slot_id].is_visible = false
            mailbox_send(&streamer.releases_to_generation, SlotReleaseMessage{
                slot_id               = event.slot_id,
                last_frame_using_slot = streamer.next_frame_value - 1,
            })
        }
    }

    // 3. Lista compacta de chunks visíveis
    visible_chunk_count: u32
    for entry, slot_index in streamer.visible_by_slot {
        if !entry.is_visible do continue

        visible_chunks_out[visible_chunk_count] = VisibleChunk{
            world_origin = entry.world_origin,
            slot_id      = SlotId(slot_index),
        }
        visible_chunk_count += 1
    }

    frame_sync := FrameSyncInfo{
        visible_chunk_count      = visible_chunk_count,
        generation_value_to_wait = streamer.latest_generation_value_seen,
        render_value_to_signal   = streamer.next_frame_value,
    }
    streamer.next_frame_value += 1
    return frame_sync
}

// Wait em generation_timeline para colocar no submit do frame.
// Não bloqueia (o valor já foi sinalizado), mas cria a dependência de memória
// que torna as escritas do compute visíveis para os task/mesh shaders.
chunk_streamer_make_generation_wait :: proc(streamer: ^ChunkStreamer, frame_sync: FrameSyncInfo) -> (wait_info: vk.SemaphoreSubmitInfo, needed: bool) {
    if frame_sync.generation_value_to_wait == 0 {
        return {}, false
    }
    return vk.SemaphoreSubmitInfo{
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = streamer.generation_timeline,
        value     = frame_sync.generation_value_to_wait,
        stageMask = {.TASK_SHADER_EXT, .MESH_SHADER_EXT},
    }, true
}

// Signal em render_timeline para colocar no submit do frame.
// TEM que ser sinalizado em todo frame submetido; senão a geração nunca libera slots.
chunk_streamer_make_render_signal :: proc(streamer: ^ChunkStreamer, frame_sync: FrameSyncInfo) -> vk.SemaphoreSubmitInfo {
    return vk.SemaphoreSubmitInfo{
        sType     = .SEMAPHORE_SUBMIT_INFO,
        semaphore = streamer.render_timeline,
        value     = frame_sync.render_value_to_signal,
        stageMask = {.ALL_COMMANDS},
    }
}

// =============================================================================
// 9. EXEMPLO DE USO NO LOOP DE RENDER
// =============================================================================
/*
    // Uma vez, na inicialização:
    streamer := chunk_streamer_create(config)
    chunk_streamer_start(streamer)

    // A cada frame:
    chunk_streamer_wait_for_old_frames(streamer, FRAMES_IN_FLIGHT)
    frame_sync := chunk_streamer_begin_frame(streamer, camera_position, visible_chunks_mapped[frame_index])

    // ... grava o command buffer, por exemplo:
    //     vk.CmdDrawMeshTasksEXT(command_buffer, frame_sync.visible_chunk_count, 1, 1)

    wait_infos: [2]vk.SemaphoreSubmitInfo
    wait_count: u32 = 1                       // [0] = semáforo binário do acquire da swapchain
    if generation_wait, needed := chunk_streamer_make_generation_wait(streamer, frame_sync); needed {
        wait_infos[wait_count] = generation_wait
        wait_count += 1
    }
    signal_infos := [2]vk.SemaphoreSubmitInfo{
        present_semaphore_info,                                  // binário, para o present
        chunk_streamer_make_render_signal(streamer, frame_sync), // timeline do streamer
    }
    // vk.QueueSubmit2 na fila de render com wait_infos[:wait_count] e signal_infos

    // No encerramento:
    chunk_streamer_stop(streamer)
    vk.DeviceWaitIdle(device)
    chunk_streamer_destroy(streamer)
*/
