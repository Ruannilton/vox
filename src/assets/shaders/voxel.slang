import common;
#include "./lib/FastNoiseLite.slang"


groupshared uint16_t heights_gs[8][8];
groupshared uint biome_gs[8][8];


uint wang_hash(uint a) {
    a = (a ^ 61u) ^ (a >> 16);
    a = a + (a << 3);
    a = a ^ (a >> 4);
    a = a * 0x27d4eb2du;
    a = a ^ (a >> 15);
    return a;
}

bool plant_spawns(int world_x, int world_z) {
    uint h = wang_hash(wang_hash(uint(world_x)) ^ uint(world_z));
    return h % 1000u < 100u; // 10% das colunas
}


static const uint BIOME_FLAG_PERMITE_PLANTAS = 1u;


uint biome_seed_warp_x(uint semente)   { return semente ^ 0x9E3779B9u; }
uint biome_seed_warp_z(uint semente)   { return semente ^ 0x85EBCA6Bu; }
uint biome_seed_temperatura(uint semente) { return semente + 101u; }
uint biome_seed_umidade(uint semente)  { return semente + 202u; }
uint biome_seed_camada(uint semente, uint bioma, uint camada) {
    return semente ^ ((bioma + 1u) * 0x27D4EB2Du) ^ ((camada + 1u) * 0x165667B1u);
}


float smoothstep_transicao(float limiar, float x) {
    float t = clamp((x - limiar) / (0.0 - limiar), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}


int biome_noise_type(uint tipo) {
    switch (tipo) {
    case 1u:  return FNL_NOISE_PERLIN;
    case 2u:  return FNL_NOISE_CELLULAR;
    default:  return FNL_NOISE_OPENSIMPLEX2;
    }
}


float biome_altura(BiomeDefinition def, uint bioma_index, uint semente, float2 pos) {
    float altura = def.altura_base;
    for (uint l = 0; l < def.layer_count; l++) {
        uint camada_global = def.layer_start + l;
        BiomeNoiseLayer camada = biome_noise_layers[camada_global];
        fnl_state fnl = fnlCreateState(int(biome_seed_camada(semente, bioma_index, camada_global)));
        fnl.noise_type = biome_noise_type(camada.tipo);
        fnl.frequency = camada.frequencia;
        fnl.octaves = int(camada.oitavas);
        float valor = fnlGetNoise2D(fnl, pos.x, pos.y) * camada.amplitude;
        altura += (camada.operacao == 1u) ? -valor : valor;
    }
    return altura;
}

[shader("compute")]
[numthreads(8, 8, 8)]
void generate_voxels(uint3 thread_id : SV_DispatchThreadID, uint3 local_id : SV_GroupThreadID) {
    uint chunk_in_batch = thread_id.z / CHUNK_SIZE;
    uint local_z        = thread_id.z % CHUNK_SIZE;

    ChunkGenerationJob job = generation_jobs[push_constants.batch_job_offset + chunk_in_batch];

    int3 coord = int3(int(thread_id.x), int(thread_id.y), int(local_z));
    int3 voxel_world_position = job.chunk_world_origin + coord;

    uint height = 0;
    if (local_id.y == 0) {

        BiomeGlobals g = biome_globals[0];

        
        float2 pos = float2(float(voxel_world_position.x), float(voxel_world_position.z))
                   + g.offset_mundial;

        fnl_state warp_x = fnlCreateState(int(biome_seed_warp_x(g.semente)));
        warp_x.noise_type = FNL_NOISE_OPENSIMPLEX2;
        fnl_state warp_z = fnlCreateState(int(biome_seed_warp_z(g.semente)));
        warp_z.noise_type = FNL_NOISE_OPENSIMPLEX2;
        pos += float2(fnlGetNoise2D(warp_x, pos.x, pos.y),
                      fnlGetNoise2D(warp_z, pos.x, pos.y)) * g.forca_distorcao;

        // 3. clima: temperatura e umidade em baixíssima frequência.
        fnl_state fnl_t = fnlCreateState(int(biome_seed_temperatura(g.semente)));
        fnl_t.noise_type = FNL_NOISE_OPENSIMPLEX2;
        fnl_t.frequency = g.frequencia_temperatura;
        fnl_state fnl_h = fnlCreateState(int(biome_seed_umidade(g.semente)));
        fnl_h.noise_type = FNL_NOISE_OPENSIMPLEX2;
        fnl_h.frequency = g.frequencia_umidade;
        float2 clima = float2(fnlGetNoise2D(fnl_t, pos.x, pos.y),
                              fnlGetNoise2D(fnl_h, pos.x, pos.y));

        uint prim = 0u;
        float dist_prim = 1e30;
        for (uint i = 0; i < g.num_biomas; i++) {
            float d = distance(clima, biome_definitions[i].centro_climatico);
            if (d < dist_prim) { dist_prim = d; prim = i; }
        }

        float altura_acc = 0.0;
        float peso_acc = 0.0;
        for (uint i = 0; i < g.num_biomas; i++) {
            float s = smoothstep_transicao(g.limiar_transicao, distance(clima, biome_definitions[i].centro_climatico) - dist_prim);
            if (s > 0.0) {
                altura_acc += s * biome_altura(biome_definitions[i], i, g.semente, pos);
                peso_acc += s;
            }
        }
        float altura_f = altura_acc / peso_acc;

        height = uint(clamp(floor(altura_f + 0.5), 1.0, 32767.0));

        heights_gs[local_id.x][local_id.z] = uint16_t(height);
        biome_gs[local_id.x][local_id.z] = prim;

        if (job.mirror_ring_slot >= 0) {
            int top_local = min(int(height) - job.chunk_world_origin.y, CHUNK_SIZE - 1);
            uint16_t top = top_local < 0 ? uint16_t(0xFFFF) : uint16_t(top_local);
            mirror_heightmap_ring[uint(job.mirror_ring_slot) * 1024 + uint(thread_id.x) | (uint(local_z) << 5)] = top;
        }
    }
    GroupMemoryBarrierWithGroupSync();
    height = uint(heights_gs[local_id.x][local_id.z]);

    uint block_id = 0;

    BiomeDefinition biome = biome_definitions[biome_gs[local_id.x][local_id.z]];
    int profundidade = int(min(biome.profundidade_subsuperficie, 65536u));
    int y = voxel_world_position.y;
    if (y > int(height)) {
       
        if (y == int(height) + 1
            && (biome.flags & BIOME_FLAG_PERMITE_PLANTAS) != 0u
            && plant_spawns(voxel_world_position.x, voxel_world_position.z)) {
            block_id = 4; // planta
        } else {
            block_id = 0; // ar
        }
    } else if (y <= int(height) - profundidade) {
        block_id = biome.bloco_profundo;
    } else if (y < int(height)) {
        block_id = biome.bloco_subsuperficie;
    } else {
        block_id = biome.bloco_superficie;
    }

    temporary_dense_chunks[(push_constants.batch_job_offset + chunk_in_batch) * CHUNK_VOXEL_COUNT + dense_index_from_coordinate(coord)] = block_id;

    if (job.mirror_ring_slot >= 0) {
        mirror_export_ring[uint(job.mirror_ring_slot) * CHUNK_VOXEL_COUNT + mirror_index_from_coordinate(coord)] = uint16_t(block_id);
    }
}

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

    uint dense_base = (push_constants.batch_job_offset + group_id.x) * CHUNK_VOXEL_COUNT;
    uint occupancy_base = slot * OCCUPANCY_WORDS_PER_CHUNK;
    uint plane_base = slot * MATERIAL_WORDS_PER_CHUNK;

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

    uint step_count = BRICKS_PER_CHUNK / PACK_THREADS;
    for (uint step = 0; step < step_count; step++) {
        uint brick_idx = thread + step * PACK_THREADS;
        int3 brick_coord = brick_coordinate_from_index(brick_idx);

        uint occupancy = 0;
        uint solidity = 0;
        uint opacity = 0; // VS-23/T0.1: máscara de opacidade por brick
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
                if ((def.flags & BLOCK_DEFINITION_FLAG_NON_SOLID) == 0u) solidity |= 1u << bit_idx;
                if ((def.flags & (BLOCK_DEFINITION_FLAG_NON_SOLID | BLOCK_DEFINITION_FLAG_TRANSPARENT)) == 0u) opacity |= 1u << bit_idx;
                MeshTemplate tmpl = mesh_templates[def.mesh_template_index];
                if (tmpl.triangle_count > 0u) {
                    uint part = bit_idx >> 3u;
                    part_verts[part] += tmpl.vertex_count;
                    part_tris[part]  += tmpl.worst_case_tris;
                }
            }
        }

        occupancy_pool[occupancy_base + brick_idx] = occupancy;
        occupancy_pool[occupancy_base + SOLID_WORD_BASE + brick_idx] = solidity;
        occupancy_pool[occupancy_base + OPAQUE_WORD_BASE + brick_idx] = opacity;

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

    for (uint step = 0; step < step_count; step++) {
        uint brick_idx = thread + step * PACK_THREADS;
        uint occupancy = occupancy_pool[occupancy_base + brick_idx];

        if (occupancy != 0) {
            uint cell_index = coarse_cell_index_from_brick_coordinate(brick_coordinate_from_index(brick_idx));
            InterlockedOr(occupancy_pool[occupancy_base + BRICKS_PER_CHUNK + (cell_index >> 5u)], 1u << (cell_index & 31u));
        }
    }
    GroupMemoryBarrierWithGroupSync();

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
        chunk_result_flags[slot] = header.flags;
    }
    GroupMemoryBarrierWithGroupSync();

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
            continue;
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
