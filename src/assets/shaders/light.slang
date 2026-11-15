import common;


[shader("compute")]
[numthreads(8, 8, 8)]
void light_seed(uint3 thread_id : SV_DispatchThreadID) {
    uint job_index = thread_id.z / CHUNK_SIZE;
    LightJob job   = light_jobs[push_constants.batch_job_offset + job_index];
    int3 l         = int3(int(thread_id.x), int(thread_id.y), int(thread_id.z % CHUNK_SIZE));
    uint slot      = job.storage_slot_index;

    uint3 level = uint3(0);
    if ((chunk_headers[slot].flags & CHUNK_FLAG_EMPTY) == 0u) {
        uint block_id = read_block_identifier_fast(slot, l);
        if (block_id != 0u) {
            level = uint3(round(saturate(global_block_registry[block_id].emission_color) * 15.0));
        }
    }
    // Sempre escreve: limpa o volume reprocessado (fontes apagadas somem).
    light_pool[light_index(slot, l)] = uint16_t(pack_block_light(level));
}

[shader("compute")]
[numthreads(8, 8, 8)]
void light_propagate(uint3 thread_id : SV_DispatchThreadID) {
    uint job_index = thread_id.z / CHUNK_SIZE;
    LightJob job   = light_jobs[push_constants.batch_job_offset + job_index];
    int3 l         = int3(int(thread_id.x), int(thread_id.y), int(thread_id.z % CHUNK_SIZE));
    int3 w         = job.chunk_world_origin + l;
    uint slot      = job.storage_slot_index;

    if (opaque_at_world(w)) return; // opaco só mantém a própria emissão

    uint3 best = uint3(0);
    best = max(best, block_light_at_world(w + int3( 1, 0, 0)));
    best = max(best, block_light_at_world(w + int3(-1, 0, 0)));
    best = max(best, block_light_at_world(w + int3( 0, 1, 0)));
    best = max(best, block_light_at_world(w + int3( 0,-1, 0)));
    best = max(best, block_light_at_world(w + int3( 0, 0, 1)));
    best = max(best, block_light_at_world(w + int3( 0, 0,-1)));

    uint3 cur  = unpack_block_light(uint(light_pool[light_index(slot, l)]));
    uint3 next = max(cur, max(best, uint3(1)) - 1u);
    light_pool[light_index(slot, l)] = uint16_t(pack_block_light(next));
}
