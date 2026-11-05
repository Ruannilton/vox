// ============================================================================
// voxel.slang — VS-01: generate_voxels + pack_chunk
// Constantes, layouts e bindings: common.slang (fonte única de verdade).
// Simulação bit-a-bit do pack: tools/sim/pack_sim.py (959 checks).
// ============================================================================
import common;

// ----------------------------------------------------------------------------
// ESTÁGIO 1: GENERATE — scratch denso (1 u32 por voxel)
// B9: [numthreads(8,8,8)], dispatch (4, 4, 4·N), job = thread_id.z / 32.
// ----------------------------------------------------------------------------
[shader("compute")]
[numthreads(8, 8, 8)]
void generate_voxels(uint3 thread_id : SV_DispatchThreadID) {
    uint chunk_in_batch = thread_id.z / CHUNK_SIZE;
    uint local_z        = thread_id.z % CHUNK_SIZE;

    ChunkGenerationJob job = generation_jobs[push_constants.batch_job_offset + chunk_in_batch];

    int3 coord = int3(int(thread_id.x), int(thread_id.y), int(local_z));
    int3 voxel_world_position = job.chunk_world_origin + coord;

    // Worldgen da referência (determinístico).
    uint block_id = 0;
    if (voxel_world_position.y < 0) {
        block_id = 3; // pedra profunda
    } else if (voxel_world_position.y == 0) {
        block_id = 2; // terra
    } else if (voxel_world_position.y == 1) {
        block_id = 1; // grama
    }

    temporary_dense_chunks[(push_constants.batch_job_offset + chunk_in_batch) * CHUNK_VOXEL_COUNT + dense_index_from_coordinate(coord)] = block_id;
}

// ----------------------------------------------------------------------------
// ESTÁGIO 2: PACK — 128 threads/chunk, 4 fases (B3 completo)
// INVARIANTE: slot 0 da paleta = AR; índice no plano = rank + 1.
// ----------------------------------------------------------------------------
groupshared uint shared_block_presence[BLOCK_PRESENCE_WORDS];
groupshared uint shared_presence_prefix[BLOCK_PRESENCE_WORDS];
groupshared uint shared_block_partials[PACK_THREADS];
groupshared uint shared_palette_blocks[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_palette_size;
groupshared uint shared_refcount[PALETTE_SIZE_MAXIMUM];

uint palette_rank_of_block(uint block_id) {
    uint word_index = block_id >> 5u;
    uint bit_index = block_id & 31u;
    uint word = shared_block_presence[word_index];
    return shared_presence_prefix[word_index] + countbits(word & ((1u << bit_index) - 1u));
}

[shader("compute")]
[numthreads(128, 1, 1)]
void pack_chunk(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
    uint thread = local_id.x;
    uint slot = generation_jobs[push_constants.batch_job_offset + group_id.x].storage_slot_index;

    // O scratch é um ring de 3×16 chunks indexado pela posição no lote
    // (batch_job_offset), não pelo slot — o slot identifica só o destino packed.
    uint dense_base = (push_constants.batch_job_offset + group_id.x) * CHUNK_VOXEL_COUNT;
    uint occupancy_base = slot * OCCUPANCY_WORDS_PER_CHUNK;
    uint plane_base = slot * MATERIAL_WORDS_PER_CHUNK;

    // ----------------------------------------------------------
    // Fase 0: zera contadores compartilhados e região [coarse|subdivisão]
    // ----------------------------------------------------------
    if (thread < 32u) {
        shared_block_partials[thread] = 0u;
    }
    if (thread == 0u) {
        shared_palette_size = 0u;
    }
    for (uint i = thread; i < BLOCK_PRESENCE_WORDS; i += PACK_THREADS) {
        shared_block_presence[i] = 0u;
    }
    for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += PACK_THREADS) {
        shared_refcount[i] = 0u;
    }
    for (uint i = thread; i < COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK; i += PACK_THREADS) {
        occupancy_pool[occupancy_base + BRICKS_PER_CHUNK + i] = 0u;
    }
    GroupMemoryBarrierWithGroupSync();

    // ----------------------------------------------------------
    // Fase A: ocupação + presença + custo geométrico por brick
    // ----------------------------------------------------------
    uint step_count = BRICKS_PER_CHUNK / PACK_THREADS;
    for (uint step = 0; step < step_count; step++) {
        uint brick_idx = thread + step * PACK_THREADS;
        int3 brick_coord = brick_coordinate_from_index(brick_idx);

        uint occupancy = 0;
        uint part_verts[4] = { 0u, 0u, 0u, 0u };
        uint part_tris[4]  = { 0u, 0u, 0u, 0u };

        for (uint bit_idx = 0; bit_idx < VOXELS_PER_BRICK; bit_idx++) {
            int3 local_coord = local_coordinate_from_bit_index(bit_idx);
            int3 coord = brick_coord * BRICK_SIZE + local_coord;
            uint block_id = temporary_dense_chunks[dense_base + dense_index_from_coordinate(coord)];

            if (block_id != 0u) {
                occupancy |= 1u << bit_idx;
                InterlockedOr(shared_block_presence[block_id >> 5u], 1u << (block_id & 31u));

                BlockDefinition def = global_block_registry[block_id];
                MeshTemplate tmpl = mesh_templates[def.mesh_template_index];
                if (tmpl.triangle_count > 0u) {
                    uint part = bit_idx >> 3u;
                    part_verts[part] += tmpl.vertex_count;
                    part_tris[part]  += tmpl.worst_case_tris;
                }
            }
        }

        occupancy_pool[occupancy_base + brick_idx] = occupancy;

        // CAMINHO B: menor subdivisão cuja pior parte cabe no orçamento (256v/192t).
        uint half_verts  = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3]);
        uint half_tris   = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3]);
        uint total_verts = part_verts[0] + part_verts[1] + part_verts[2] + part_verts[3];
        uint total_tris  = part_tris[0] + part_tris[1] + part_tris[2] + part_tris[3];

        uint subdivision = 0u;
        if (total_verts > MESH_VERTEX_MAXIMUM || total_tris > MESH_TRIANGLE_MAXIMUM) {
            subdivision = 1u;
            if (half_verts > MESH_VERTEX_MAXIMUM || half_tris > MESH_TRIANGLE_MAXIMUM) {
                subdivision = 2u;
            }
        }
        if (subdivision != 0u) {
            InterlockedOr(occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_idx >> 4u)],
                          subdivision << ((brick_idx & 15u) * 2u));
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // ----------------------------------------------------------
    // Fase B1: coarse cells
    // ----------------------------------------------------------
    for (uint step = 0; step < step_count; step++) {
        uint brick_idx = thread + step * PACK_THREADS;
        uint occupancy = occupancy_pool[occupancy_base + brick_idx];

        if (occupancy != 0) {
            uint cell_index = coarse_cell_index_from_brick_coordinate(brick_coordinate_from_index(brick_idx));
            InterlockedOr(occupancy_pool[occupancy_base + BRICKS_PER_CHUNK + (cell_index >> 5u)], 1u << (cell_index & 31u));
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // ----------------------------------------------------------
    // Fase B2: scan de prefixo popcount (ranking da paleta)
    // ----------------------------------------------------------
    uint thread_partial = 0;
    for (uint i = 0; i < PRESENCE_WORDS_PER_THREAD; i++) {
        uint word_index = thread + i * PACK_THREADS;
        thread_partial += countbits(shared_block_presence[word_index]);
    }
    shared_block_partials[thread] = thread_partial;
    GroupMemoryBarrierWithGroupSync();

    if (thread == 0u) {
        uint running_total = 0;
        for (uint i = 0; i < PACK_THREADS; i++) {
            uint current = shared_block_partials[i];
            shared_block_partials[i] = running_total;
            running_total += current;
        }
        shared_palette_size = running_total;
    }
    GroupMemoryBarrierWithGroupSync();

    uint running_prefix = shared_block_partials[thread];
    for (uint i = 0; i < PRESENCE_WORDS_PER_THREAD; i++) {
        uint word_index = thread + i * PACK_THREADS;
        shared_presence_prefix[word_index] = running_prefix;
        running_prefix += countbits(shared_block_presence[word_index]);
    }
    GroupMemoryBarrierWithGroupSync();

    uint distinct_count = shared_palette_size;
    bool palette_overflow = distinct_count > (PALETTE_SIZE_MAXIMUM - 1u);

    // ----------------------------------------------------------
    // Fase B3: paleta + ChunkHeader (slot 0 = AR)
    // ----------------------------------------------------------
    if (thread == 0u) {
        uint palette_count = min(distinct_count, PALETTE_SIZE_MAXIMUM - 1u) + 1u;
        uint plane_count = 1u;
        while ((1u << plane_count) < palette_count) plane_count++;

        shared_palette_blocks[0] = 0u;

        ChunkHeader header;
        header.palette_size = palette_count;
        header.plane_count = plane_count;
        header.special_voxel_count = 0;
        header.flags = (distinct_count == 0u) ? CHUNK_FLAG_EMPTY : 0u;
        if (palette_overflow) {
            header.flags |= CHUNK_FLAG_PALETTE_OVERFLOW;
        }

        chunk_headers[slot] = header;
    }
    GroupMemoryBarrierWithGroupSync();

    // Upload cooperativo da paleta (ids presentes em ordem crescente)
    for (uint i = thread; i < BLOCK_PRESENCE_WORDS; i += PACK_THREADS) {
        uint word = shared_block_presence[i];
        while (word != 0u) {
            uint bit = firstbitlow(word);
            word &= word - 1u;
            uint block_id = (i << 5u) + bit;
            uint rank = palette_rank_of_block(block_id);
            if (rank < PALETTE_SIZE_MAXIMUM - 1u) {
                shared_palette_blocks[rank + 1u] = block_id;
            }
        }
    }
    GroupMemoryBarrierWithGroupSync();

    uint palette_count = chunk_headers[slot].palette_size;
    for (uint i = thread; i < palette_count; i += PACK_THREADS) {
        chunk_headers[slot].palette[i] = shared_palette_blocks[i];
    }
    GroupMemoryBarrierWithGroupSync();

    // ----------------------------------------------------------
    // Fase C: planos de material (rank + 1) + special records + refcounts
    // ----------------------------------------------------------
    uint plane_count = chunk_headers[slot].plane_count;
    uint total_plane_words = plane_count * BRICKS_PER_CHUNK;
    for (uint i = thread; i < total_plane_words; i += PACK_THREADS) {
        material_plane_pool[plane_base + i] = 0u;
    }
    GroupMemoryBarrierWithGroupSync();

    uint voxel_steps = CHUNK_VOXEL_COUNT / PACK_THREADS;
    for (uint step = 0; step < voxel_steps; step++) {
        uint dense_idx = thread + step * PACK_THREADS;
        uint block_id = temporary_dense_chunks[dense_base + dense_idx];

        if (block_id == 0u) continue;

        uint rank = palette_rank_of_block(block_id);
        uint palette_index = rank + 1u;

        if (palette_index >= palette_count) {
            uint write_idx;
            InterlockedAdd(chunk_headers[slot].special_voxel_count, 1u, write_idx);
            if (write_idx < SPECIAL_RECORDS_PER_CHUNK) {
                SpecialVoxelRecord record;
                record.voxel_index = dense_idx;
                record.shape_and_orientation = 0u;
                record.block_identifier = block_id;
                special_voxel_records[slot * SPECIAL_RECORDS_PER_CHUNK + write_idx] = record;
            }
            continue; // degrada para ar na renderização (seguro por construção)
        }

        InterlockedAdd(shared_refcount[palette_index], 1u);

        int3 coord = int3(int(dense_idx & 31u), int(dense_idx >> 10u), int((dense_idx >> 5u) & 31u));
        uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
        uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);

        for (uint plane = 0; plane < plane_count; plane++) {
            if (((palette_index >> plane) & 1u) != 0u) {
                InterlockedOr(material_plane_pool[plane_base + plane * BRICKS_PER_CHUNK + brick_idx], 1u << bit_idx);
            }
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // Fecha os refcounts: slot 0 (AR) conta os não-sólidos; as 256 entradas
    // sobem (slots além da paleta = 0 = livres para a edição, VS-03).
    if (thread == 0u) {
        uint solid_total = 0;
        for (uint i = 1u; i < palette_count; i++) { solid_total += shared_refcount[i]; }
        shared_refcount[0] = CHUNK_VOXEL_COUNT - solid_total;
    }
    GroupMemoryBarrierWithGroupSync();
    for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += PACK_THREADS) {
        chunk_headers[slot].refcount[i] = shared_refcount[i];
    }
}
