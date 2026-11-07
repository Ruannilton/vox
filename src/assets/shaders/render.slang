import common;

groupshared uint shared_item_offsets[BRICKS_PER_CHUNK]; // scan: offset do brick no lote do chunk
groupshared uint shared_chunk_item_total;
groupshared uint shared_chunk_item_base;

[shader("compute")]
[numthreads(128, 1, 1)]
void build_work_queue(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
    uint thread = local_id.x;
    uint visible_index = group_id.x;
    VisibleChunk chunk = visible_chunks[push_constants.visible_chunk_offset + visible_index];

    // VS-06 (REQ-CULL-02): early-out de chunk antes de ler header/ocupação —
    // o teste é uniforme no workgroup, sem divergência.
    float4 frustum_planes[6] = frustum_planes_from_vp(push_constants.view_projection_matrix);
    float3 chunk_min = float3(chunk.chunk_world_origin);
    if (aabb_outside_frustum(chunk_min, chunk_min + float3(CHUNK_SIZE), frustum_planes)) {
        return;
    }

    ChunkHeader header = chunk_headers[chunk.storage_slot_index];
    if ((header.flags & CHUNK_FLAG_EMPTY) != 0) {
        return;
    }

    uint occupancy_base = chunk.storage_slot_index * OCCUPANCY_WORDS_PER_CHUNK;
    uint queue_base = work_queue_base_words();
    uint step_count = BRICKS_PER_CHUNK / 128;

    for (uint step = 0; step < step_count; step++) {
        uint brick_index = thread + step * 128;
        uint occupancy_word = occupancy_pool[occupancy_base + brick_index];

        uint item_count = 0;
        // VS-06 (REQ-CULL-03): ordem vazio → frustum → oclusão.
        int3 brick_coord = brick_coordinate_from_index(brick_index);
        float3 brick_min = float3(chunk.chunk_world_origin + brick_coord * BRICK_SIZE);
        if (occupancy_word != 0 && !aabb_outside_frustum(brick_min, brick_min + float3(BRICK_SIZE),
                frustum_planes) && !is_brick_occluded(chunk.storage_slot_index, occupancy_word,
                brick_coord, chunk.neighbor_slots)) {
            uint subd_word = occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
            item_count = 1u << ((subd_word >> ((brick_index & 15u) * 2u)) & 3u);
        }
        shared_item_offsets[brick_index] = item_count;
    }
    GroupMemoryBarrierWithGroupSync();

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

    if (thread == 0) {
        uint chunk_base;
        InterlockedAdd(work_queue[queue_base + WORK_QUEUE_APPEND_COUNT_WORD], shared_chunk_item_total, chunk_base);
        shared_chunk_item_base = chunk_base;
        if (chunk_base + shared_chunk_item_total > push_constants.visible_chunk_capacity * BRICKS_PER_CHUNK) {
            InterlockedOr(work_queue[queue_base + WORK_QUEUE_OVERFLOW_WORD], 1u);
        }
    }
    GroupMemoryBarrierWithGroupSync();

    for (uint step = 0; step < step_count; step++) {
        uint brick_index = thread + step * 128;
        uint occupancy_word = occupancy_pool[occupancy_base + brick_index];

        int3 brick_coord = brick_coordinate_from_index(brick_index);
        float3 brick_min = float3(chunk.chunk_world_origin + brick_coord * BRICK_SIZE);
        if (occupancy_word == 0 || aabb_outside_frustum(brick_min, brick_min + float3(BRICK_SIZE),
                frustum_planes) || is_brick_occluded(chunk.storage_slot_index, occupancy_word,
                brick_coord, chunk.neighbor_slots)) {
            continue;
        }
        uint subd_word = occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
        uint subdivision = (subd_word >> ((brick_index & 15u) * 2u)) & 3u;
        uint parts = 1u << subdivision;

        for (uint part = 0; part < parts; part++) {
            uint position = shared_chunk_item_base + shared_item_offsets[brick_index] + part;
            if (position < push_constants.visible_chunk_capacity * BRICKS_PER_CHUNK) {
                work_queue[queue_base + WORK_QUEUE_STATE_WORDS + position] =
                    pack_work_item(visible_index, brick_index, part, subdivision);
            }
        }
    }
}

[shader("compute")]
[numthreads(1, 1, 1)]
void finalize_work_queue() {
    uint queue_base = work_queue_base_words();
    uint append_count = work_queue[queue_base + WORK_QUEUE_APPEND_COUNT_WORD];
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD]     = min(append_count, push_constants.visible_chunk_capacity * BRICKS_PER_CHUNK);
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD + 1] = 1u;
    work_queue[queue_base + WORK_QUEUE_INDIRECT_X_WORD + 2] = 1u;
}

groupshared uint shared_v_count[VOXELS_PER_BRICK];
groupshared uint shared_t_count[VOXELS_PER_BRICK];
groupshared uint shared_face_mask[VOXELS_PER_BRICK];
groupshared uint shared_total_v;
groupshared uint shared_total_t;

float4 sample_triplanar_albedo(float3 world_pos, float3 world_normal, uint texture_index) {
    float3 blend_weights = abs(world_normal);
    blend_weights = blend_weights / (blend_weights.x + blend_weights.y + blend_weights.z);

    float4 x_projection = block_albedo_textures.Sample(float3(world_pos.zy, float(texture_index)));
    float4 y_projection = block_albedo_textures.Sample(float3(world_pos.xz, float(texture_index)));
    float4 z_projection = block_albedo_textures.Sample(float3(world_pos.xy, float(texture_index)));

    return x_projection * blend_weights.x + y_projection * blend_weights.y + z_projection * blend_weights.z;
}

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)]
void build_brick_mesh(
    uint3 group_id : SV_GroupID,
    uint3 local_id : SV_GroupThreadID,
    out indices uint3 tris[MESH_TRIANGLE_MAXIMUM],
    out vertices MeshVertex verts[MESH_VERTEX_MAXIMUM]
) {

    // VS-09 (REQ-WID-01): visible_index 16 bits — layout 16|10|2|2
    uint item             = work_queue[work_queue_base_words() + WORK_QUEUE_STATE_WORDS + group_id.x];
    uint visible_index    = item & 0xFFFFu;
    uint brick_idx        = (item >> 16u) & 1023u;
    uint part             = (item >> 26u) & 3u;
    uint subdivision_log2 = (item >> 28u) & 3u;

    VisibleChunk chunk = visible_chunks[push_constants.visible_chunk_offset + visible_index];
    uint slot = chunk.storage_slot_index;

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
            if ((tmpl.flags & TEMPLATE_FLAG_HAS_FLUSH_FACES) != 0u) {
                face_mask = compute_visible_face_mask(slot, header, voxel_coord,
                    chunk.chunk_world_origin, push_constants.camera_position,
                    chunk.neighbor_slots);
            }

            for (uint t = 0; t < tmpl.triangle_count; t++) {
                uint packed_tri = template_triangles[tmpl.triangle_offset + t];
                if (triangle_survives_culling(packed_tri, def.rotation, face_mask)) {
                    t_cnt++;
                }
            }

            if (t_cnt > 0u) v_cnt = tmpl.vertex_count;
        }
    }

    shared_v_count[local_id.x] = v_cnt;
    shared_t_count[local_id.x] = t_cnt;
    shared_face_mask[local_id.x] = face_mask;
    GroupMemoryBarrierWithGroupSync();

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
    // VS-11 (REQ-UV-02): template com pool de UVs emite a UV do pool; sem
    // pool (uv_offset == NO_TEMPLATE_UV_OFFSET) emite a sentinela (-1,-1) —
    // o fragment cai no triplanar (fallback para mods procedurais).
    bool has_uvs = tmpl.uv_offset != NO_TEMPLATE_UV_OFFSET;
    float3 voxel_min_world = float3(chunk.chunk_world_origin + voxel_coord);
    for (uint i = 0; i < tmpl.vertex_count; i++) {
        float3 local_pos = template_vertices[tmpl.vertex_offset + i].xyz;
        local_pos = rotate_vertex_yaw(local_pos, def.rotation);

        MeshVertex v;
        v.world_position = voxel_min_world + local_pos;
        v.clip_position = mul(push_constants.view_projection_matrix, float4(v.world_position, 1.0));
        v.block_id = block_id;
        v.uv = has_uvs ? template_uvs[tmpl.uv_offset + i] : float2(-1.0, -1.0);
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

[shader("fragment")]
float4 shade_voxel(MeshVertex input) : SV_Target {
    BlockDefinition def = global_block_registry[input.block_id];

    float3 normal_x = ddx(input.world_position);
    float3 normal_y = ddy(input.world_position);
    float3 normal = normalize(cross(normal_x, normal_y));

    // VS-11 (REQ-UV-03): com UV (uv.x >= 0) amostra a camada de albedo por
    // UV; com a sentinela cai no triplanar (fallback inalterado da VS-02).
    // Na paleta de cores sólidas as duas rotas são idênticas por construção.
    float4 albedo = input.uv.x >= 0.0
        ? block_albedo_textures.Sample(float3(input.uv, float(def.albedo_texture_index)))
        : sample_triplanar_albedo(input.world_position, normal, def.albedo_texture_index);

    // VS-14 (REQ-PLT-01, ADR-P1 Opção A): alpha-test cutout — blocos com
    // flags bit 0 (transparente) descartam fragmentos com albedo.a < 0.5
    // (limiar constante). Cutout opaco: sem blending, CULL_MODE_NONE permanece.
    if ((def.flags & BLOCK_DEFINITION_FLAG_TRANSPARENT) != 0u && albedo.a < 0.5) {
        discard;
    }

    float3 light_dir = normalize(float3(0.5, 0.8, 0.3));
    float diffuse = max(dot(normal, light_dir), 0.0);
    float3 ambient = float3(0.2);
    float3 final_color = albedo.rgb * (ambient + diffuse) + def.emission_color;

    return float4(final_color, 1.0);
}
