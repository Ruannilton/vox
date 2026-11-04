// ============================================================================
// voxel.slang — VS-01: generate_voxels + pack_chunk; VS-02: builder da fila de
// trabalho + mesh (mesh-only, sem payload) + fragment
// Constantes, layouts e bindings: common.slang (fonte única de verdade).
// Simulação bit-a-bit do pack: tools/sim/pack_sim.py (959 checks).
// Simulação da renderização: tools/sim/render_sim.py (210 checks).
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

// ----------------------------------------------------------------------------
// VS-02 ESTÁGIO 3: BUILDER DA FILA DE TRABALHO — seleção de grupos por chunk
// visível. Compute na fila gráfica: 1 workgroup (128 threads) por chunk
// visível anexa itens de 32 bits (visible_index | brick | parte | subdivisão)
// num buffer global; o draw é mesh-only indireto e cada workgroup lê o seu
// item por SV_GroupID. CORREÇÃO pós-validação: substitui o task shader + o
// payload (que chegava sempre zerado neste ambiente — ver render_sim.py e
// docs/obsidian/decisoes).
// ----------------------------------------------------------------------------
groupshared uint shared_item_offsets[BRICKS_PER_CHUNK]; // scan: offset do brick no lote do chunk
groupshared uint shared_chunk_item_total;
groupshared uint shared_chunk_item_base;

[shader("compute")]
[numthreads(128, 1, 1)]
void build_work_queue(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
    uint thread = local_id.x;
    uint visible_index = group_id.x;
    VisibleChunk chunk = visible_chunks[push_constants.visible_chunk_offset + visible_index];

    ChunkHeader header = chunk_headers[chunk.storage_slot_index];
    if ((header.flags & CHUNK_FLAG_EMPTY) != 0) {
        return; // chunk vazio não anexa nada (branch uniforme no workgroup)
    }

    uint occupancy_base = chunk.storage_slot_index * OCCUPANCY_WORDS_PER_CHUNK;
    uint queue_base = work_queue_base_words();
    uint step_count = BRICKS_PER_CHUNK / 128;

    // Fase 1: conta os itens (partes) de cada brick selecionado.
    for (uint step = 0; step < step_count; step++) {
        uint brick_index = thread + step * 128;
        uint occupancy_word = occupancy_pool[occupancy_base + brick_index];

        uint item_count = 0;
        // TODO: culling de frustum por brick (bounds do brick vs frustum).
        if (occupancy_word != 0 && !is_brick_occluded(chunk.storage_slot_index, occupancy_word,
                brick_coordinate_from_index(brick_index), chunk.neighbor_slots)) {
            // CAMINHO B: lê o nível de subdivisão decidido pelo pack.
            uint subd_word = occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
            item_count = 1u << ((subd_word >> ((brick_index & 15u) * 2u)) & 3u);
        }
        shared_item_offsets[brick_index] = item_count;
    }
    GroupMemoryBarrierWithGroupSync();

    // Scan exclusivo sequencial (1024 entradas, thread 0): offset de cada
    // brick dentro do lote do chunk + total do chunk.
    if (thread == 0) {
        uint running_total = 0;
        for (uint i = 0; i < BRICKS_PER_CHUNK; i++) {
            uint item_count = shared_item_offsets[i];
            shared_item_offsets[i] = running_total;
            running_total += item_count;
        }
        shared_chunk_item_total = running_total;
    }
    GroupMemoryBarrierWithGroupSync();

    // Reserva global: um InterlockedAdd por chunk. Overflow é sinalizado na
    // word de estado (nunca silencioso) e o finalize faz o clamp do draw.
    if (thread == 0) {
        uint chunk_base;
        InterlockedAdd(work_queue[queue_base + WORK_QUEUE_APPEND_COUNT_WORD], shared_chunk_item_total, chunk_base);
        shared_chunk_item_base = chunk_base;
        if (chunk_base + shared_chunk_item_total > WORK_ITEM_CAPACITY) {
            InterlockedOr(work_queue[queue_base + WORK_QUEUE_OVERFLOW_WORD], 1u);
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // Fase 2: rederiva a seleção (determinística) e escreve os itens.
    for (uint step = 0; step < step_count; step++) {
        uint brick_index = thread + step * 128;
        uint occupancy_word = occupancy_pool[occupancy_base + brick_index];

        if (occupancy_word == 0 || is_brick_occluded(chunk.storage_slot_index, occupancy_word,
                brick_coordinate_from_index(brick_index), chunk.neighbor_slots)) {
            continue;
        }
        uint subd_word = occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
        uint subdivision = (subd_word >> ((brick_index & 15u) * 2u)) & 3u;
        uint parts = 1u << subdivision;

        for (uint part = 0; part < parts; part++) {
            uint position = shared_chunk_item_base + shared_item_offsets[brick_index] + part;
            if (position < WORK_ITEM_CAPACITY) {
                work_queue[queue_base + WORK_QUEUE_STATE_WORDS + position] =
                    pack_work_item(visible_index, brick_index, part, subdivision);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// VS-02 ESTÁGIO 3b: FINALIZE — 1 thread fecha o x do draw indireto com o
// clamp do append_count na capacidade (y = z = 1).
// ----------------------------------------------------------------------------
[shader("compute")]
[numthreads(1, 1, 1)]
void finalize_work_queue() {
    uint queue_base = work_queue_base_words();
    uint append_count = work_queue[queue_base + WORK_QUEUE_APPEND_COUNT_WORD];
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD]     = min(append_count, WORK_ITEM_CAPACITY);
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD + 1] = 1u;
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD + 2] = 1u;
}

// ----------------------------------------------------------------------------
// VS-02 ESTÁGIO 4: MESH SHADER (mesh-only, sem task) — montagem da geometria
// a partir de templates. Cada workgroup lê o seu item da fila global por
// SV_GroupID e resolve o chunk via visible_chunks. 32 threads; orçamento
// 256v/192t garantido pela subdivisão do pack (regra 5).
// ----------------------------------------------------------------------------
groupshared uint shared_v_count[VOXELS_PER_BRICK];
groupshared uint shared_t_count[VOXELS_PER_BRICK];
groupshared uint shared_face_mask[VOXELS_PER_BRICK];
groupshared uint shared_total_v;
groupshared uint shared_total_t;

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)]
void build_brick_mesh(
    uint3 group_id : SV_GroupID,
    uint3 local_id : SV_GroupThreadID,
    out indices uint3 tris[MESH_TRIANGLE_MAXIMUM],
    out vertices MeshVertex verts[MESH_VERTEX_MAXIMUM]
) {
    // Item da fila global (escrito pelo build_work_queue):
    // visible_index (12b) | brick (10b) | parte (2b) | subdivisão (2b).
    uint item             = work_queue[work_queue_base_words() + WORK_QUEUE_STATE_WORDS + group_id.x];
    uint visible_index    = item & 0xFFFu;
    uint brick_idx        = (item >> 12u) & 1023u;
    uint part             = (item >> 22u) & 3u;
    uint subdivision_log2 = (item >> 24u) & 3u;

    VisibleChunk chunk = visible_chunks[push_constants.visible_chunk_offset + visible_index];
    uint slot = chunk.storage_slot_index;

    // CAMINHO B: decodifica o grupo (brick + parte, conforme subdivisão do pack).
    uint voxels_in_group  = VOXELS_PER_BRICK >> subdivision_log2;
    bool active           = local_id.x < voxels_in_group;
    uint voxel_slot       = part * voxels_in_group + min(local_id.x, voxels_in_group - 1u);
    int3 voxel_coord      = brick_coordinate_from_index(brick_idx) * BRICK_SIZE + local_coordinate_from_bit_index(voxel_slot);

    uint v_cnt = 0u;
    uint t_cnt = 0u;
    uint face_mask = 0u;
    MeshTemplate tmpl = {};
    BlockDefinition def = {};
    uint block_id = 0u;

    if (active) {
        ChunkHeader header = chunk_headers[slot];
        block_id = read_block_identifier(slot, header, voxel_coord);
        def = global_block_registry[block_id];
        tmpl = mesh_templates[def.mesh_template_index];

        if (tmpl.triangle_count > 0u) {
            // Culling de faces só é necessário para templates com triângulos
            // colados em faces do voxel (bit HAS_FLUSH_FACES).
            if ((tmpl.flags & TEMPLATE_FLAG_HAS_FLUSH_FACES) != 0u) {
                face_mask = compute_visible_face_mask(slot, voxel_coord,
                    chunk.chunk_world_origin, push_constants.camera_position,
                    chunk.neighbor_slots);
            }

            for (uint t = 0; t < tmpl.triangle_count; t++) {
                uint packed_tri = template_triangles[tmpl.triangle_offset + t];
                if (triangle_survives_culling(packed_tri, def.rotation, face_mask)) {
                    t_cnt++;
                }
            }
            // Sem triângulos sobreviventes: nenhum vértice é emitido.
            if (t_cnt > 0u) v_cnt = tmpl.vertex_count;
        }
    }

    shared_v_count[local_id.x] = v_cnt;
    shared_t_count[local_id.x] = t_cnt;
    shared_face_mask[local_id.x] = face_mask;
    GroupMemoryBarrierWithGroupSync();

    // Prefixo exclusivo sequencial (32 elementos; threads inativas contribuem 0).
    // Totais vão para escalares dedicados para não destruir o prefixo do voxel 0.
    if (local_id.x == 0) {
        uint v_acc = 0u, t_acc = 0u;
        for (uint i = 0; i < VOXELS_PER_BRICK; i++) {
            uint vc = shared_v_count[i], tc = shared_t_count[i];
            shared_v_count[i] = v_acc; shared_t_count[i] = t_acc;
            v_acc += vc; t_acc += tc;
        }
        shared_total_v = v_acc;
        shared_total_t = t_acc;
    }
    GroupMemoryBarrierWithGroupSync();

    uint first_v = shared_v_count[local_id.x];
    uint first_t = shared_t_count[local_id.x];

    SetMeshOutputCounts(shared_total_v, shared_total_t);

    if (!active || v_cnt == 0u) return;

    // ------------------------- Emissão de vértices -------------------------
    float3 voxel_min_world = float3(chunk.chunk_world_origin + voxel_coord);
    for (uint i = 0; i < tmpl.vertex_count; i++) {
        float3 local_pos = template_vertices[tmpl.vertex_offset + i].xyz;
        local_pos = rotate_vertex_yaw(local_pos, def.rotation);

        MeshVertex v;
        v.world_position = voxel_min_world + local_pos;
        v.clip_position = mul(push_constants.view_projection_matrix, float4(v.world_position, 1.0));
        v.block_id = block_id;
        verts[first_v + i] = v;
    }

    // ------------------------- Emissão de triângulos ------------------------
    uint mask = shared_face_mask[local_id.x];
    uint t_cur = first_t;
    for (uint t = 0; t < tmpl.triangle_count; t++) {
        uint packed_tri = template_triangles[tmpl.triangle_offset + t];
        if (!triangle_survives_culling(packed_tri, def.rotation, mask)) continue;

        uint3 tri = uint3(packed_tri & 0xFFu, (packed_tri >> 8u) & 0xFFu, (packed_tri >> 16u) & 0xFFu);
        tris[t_cur++] = tri + first_v;
    }
}

// ----------------------------------------------------------------------------
// VS-02 ESTÁGIO 5: FRAGMENT — Lambert + emissão, triplanar, normais por
// derivadas (ADR-B7: sem PBR). Albedo = paleta procedural de cores sólidas
// (binding 8); binding 9 existe mas não é amostrado nesta fatia.
// ----------------------------------------------------------------------------
float3 sample_triplanar_albedo(float3 world_pos, float3 world_normal, uint texture_index) {
    float3 blend_weights = abs(world_normal);
    blend_weights = blend_weights / (blend_weights.x + blend_weights.y + blend_weights.z);

    float3 x_projection = block_albedo_textures.Sample(float3(world_pos.zy, float(texture_index))).rgb;
    float3 y_projection = block_albedo_textures.Sample(float3(world_pos.xz, float(texture_index))).rgb;
    float3 z_projection = block_albedo_textures.Sample(float3(world_pos.xy, float(texture_index))).rgb;

    return x_projection * blend_weights.x + y_projection * blend_weights.y + z_projection * blend_weights.z;
}

[shader("fragment")]
float4 shade_voxel(MeshVertex input) : SV_Target {
    BlockDefinition def = global_block_registry[input.block_id];

    float3 normal_x = ddx(input.world_position);
    float3 normal_y = ddy(input.world_position);
    float3 normal = normalize(cross(normal_x, normal_y));

    float3 albedo = sample_triplanar_albedo(input.world_position, normal, def.albedo_texture_index);

    // ADR-B7: Lambert + emissão; Cook-Torrance e SSAO ficam no backlog.
    float3 light_dir = normalize(float3(0.5, 0.8, 0.3));
    float diffuse = max(dot(normal, light_dir), 0.0);
    float3 ambient = float3(0.2);
    float3 final_color = albedo * (ambient + diffuse) + def.emission_color;

    return float4(final_color, 1.0);
}
