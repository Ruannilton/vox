import common;

groupshared uint shared_edit_palette[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_edit_refcount[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_edit_hash_key[EDIT_HASH_CAPACITY];  // block_id | EMPTY | TOMBSTONE
groupshared uint shared_edit_hash_slot[EDIT_HASH_CAPACITY]; // slot | EMPTY (pendente) | REJECTED
groupshared uint shared_edit_new_slot[MAX_EDITS_PER_CHUNK_PER_FLUSH];
groupshared uint shared_edit_old_index[MAX_EDITS_PER_CHUNK_PER_FLUSH];
groupshared uint shared_edit_dirty_bricks[BRICKS_PER_CHUNK / 32];
groupshared uint shared_edit_palette_size;
groupshared uint shared_edit_plane_count;
groupshared uint shared_edit_flags;
groupshared uint shared_edit_nonempty;

uint edit_hash_bucket(uint block_id) {
    return ((block_id * 0x9E3779B1u) >> 23u) & (EDIT_HASH_CAPACITY - 1u);
}

void edit_hash_reserve(uint block_id, out uint bucket, out bool owned) {
    uint h = edit_hash_bucket(block_id);
    owned = false;
    bucket = EDIT_HASH_EMPTY;
    for (uint probe = 0u; probe < EDIT_HASH_CAPACITY; probe++) {
        uint idx = (h + probe) & (EDIT_HASH_CAPACITY - 1u);
        uint key;
        InterlockedAdd(shared_edit_hash_key[idx], 0u, key); // leitura atômica
        if (key == block_id) { bucket = idx; return; }
        if (key == EDIT_HASH_TOMBSTONE) { continue; }
        uint original;
        InterlockedCompareExchange(shared_edit_hash_key[idx], EDIT_HASH_EMPTY, block_id, original);
        if (original == EDIT_HASH_EMPTY) { owned = true; bucket = idx; return; }
        if (original == block_id) { bucket = idx; return; }
        // Outra chave recém-reservada: segue o probing.
    }
}

void edit_hash_tombstone(uint block_id) {
    uint h = edit_hash_bucket(block_id);
    for (uint probe = 0u; probe < EDIT_HASH_CAPACITY; probe++) {
        uint idx = (h + probe) & (EDIT_HASH_CAPACITY - 1u);
        uint key;
        InterlockedAdd(shared_edit_hash_key[idx], 0u, key);
        if (key == EDIT_HASH_EMPTY) { return; }
        if (key == block_id) {
            uint original;
            InterlockedCompareExchange(shared_edit_hash_key[idx], block_id, EDIT_HASH_TOMBSTONE, original);
            return;
        }
    }
}

uint edit_hash_wait_slot(uint bucket) {
    for (uint spin = 0u; spin < 4096u; spin++) {
        uint value;
        InterlockedAdd(shared_edit_hash_slot[bucket], 0u, value);
        if (value != EDIT_HASH_EMPTY) { return value; }
    }
    return EDIT_SLOT_REJECTED; // defensivo: timeout
}

uint edit_alloc_slot(uint slot, uint block_id, uint bucket) {
    for (uint s = 1u; s < PALETTE_SIZE_MAXIMUM; s++) {
        uint rc;
        InterlockedAdd(shared_edit_refcount[s], 0u, rc);
        if (rc != 0u) { continue; }
        uint original;
        InterlockedCompareExchange(shared_edit_refcount[s], 0u, EDIT_REFCLAIMED, original);
        if (original != 0u) { continue; }
        uint old_id = shared_edit_palette[s];
        if (old_id != 0u && old_id != block_id) { edit_hash_tombstone(old_id); }
        shared_edit_palette[s] = block_id;
        chunk_headers[slot].palette[s] = block_id;
        InterlockedMax(shared_edit_palette_size, s + 1u);
        InterlockedExchange(shared_edit_hash_slot[bucket], s, original); // publica
        InterlockedExchange(shared_edit_refcount[s], 1u, original);      // libera o claim
        return s;
    }
    uint original;
    InterlockedExchange(shared_edit_hash_slot[bucket], EDIT_SLOT_REJECTED, original); // acorda waiters
    return EDIT_SLOT_REJECTED;
}

uint edit_claim_slot(uint slot_idx, uint block_id, out bool counted) {
    counted = false;
    for (uint attempt = 0u; attempt < 64u; attempt++) {
        uint rc;
        InterlockedAdd(shared_edit_refcount[slot_idx], 0u, rc);
        if (rc == EDIT_REFCLAIMED) { continue; } // alocação em fluxo: gira
        if (rc != 0u) {
            if (shared_edit_palette[slot_idx] == block_id) { return slot_idx; }
            return EDIT_HASH_EMPTY; // conteúdo mudou: re-resolve pelo hash
        }
        uint original;
        InterlockedCompareExchange(shared_edit_refcount[slot_idx], 0u, 1u, original);
        if (original != 0u) { continue; }
        if (shared_edit_palette[slot_idx] == block_id) { counted = true; return slot_idx; }
        InterlockedAdd(shared_edit_refcount[slot_idx], 0xFFFFFFFFu); // desfaz (-1) e re-resolve
        return EDIT_HASH_EMPTY;
    }
    return EDIT_HASH_EMPTY; // defensivo: contenção patológica
}

uint edit_resolve_slot(uint slot, uint block_id, out bool counted) {
    counted = false;
    for (uint attempt = 0u; attempt < 32u; attempt++) {
        uint bucket; bool owned;
        edit_hash_reserve(block_id, bucket, owned);
        if (bucket == EDIT_HASH_EMPTY) { return EDIT_SLOT_REJECTED; }
        if (owned) {
            uint s = edit_alloc_slot(slot, block_id, bucket);
            counted = (s != EDIT_SLOT_REJECTED);
            return s;
        }
        uint s = edit_hash_wait_slot(bucket);
        if (s == EDIT_SLOT_REJECTED) { return EDIT_SLOT_REJECTED; }
        bool c;
        uint claimed = edit_claim_slot(s, block_id, c);
        if (claimed != EDIT_HASH_EMPTY) { counted = c; return claimed; }
    }
    return EDIT_SLOT_REJECTED; // defensivo
}

[shader("compute")]
[numthreads(128, 1, 1)]
void apply_voxel_edits(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
    uint thread = local_id.x;
    EditChunkJob job = edit_jobs[push_constants.edit_job_offset + group_id.x];
    uint slot = job.storage_slot_index;
    uint occupancy_base = slot * OCCUPANCY_WORDS_PER_CHUNK;
    uint plane_base = slot * MATERIAL_WORDS_PER_CHUNK;

    // ------------------------- Fase 0: cache do header -------------------------
    uint h_palette_size = chunk_headers[slot].palette_size;
    uint h_flags = chunk_headers[slot].flags;
    for (uint i = thread; i < EDIT_HASH_CAPACITY; i += 128u) {
        shared_edit_hash_key[i] = EDIT_HASH_EMPTY;
        shared_edit_hash_slot[i] = EDIT_HASH_EMPTY;
    }
    for (uint i = thread; i < BRICKS_PER_CHUNK / 32u; i += 128u) {
        shared_edit_dirty_bricks[i] = 0u;
    }
    if (thread == 0u) {
        shared_edit_palette_size = h_palette_size;
        shared_edit_plane_count = chunk_headers[slot].plane_count;
        shared_edit_flags = h_flags;
        shared_edit_nonempty = 0u;
    }
    for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += 128u) {
        // Slots além da paleta são normalizados (o buffer pode conter lixo).
        bool live = i < h_palette_size;
        shared_edit_palette[i] = live ? chunk_headers[slot].palette[i] : 0u;
        shared_edit_refcount[i] = live ? chunk_headers[slot].refcount[i] : 0u;
    }
    GroupMemoryBarrierWithGroupSync();

    if ((h_flags & CHUNK_FLAG_PALETTE_OVERFLOW) != 0u) {
        for (uint i = thread; i < job.edit_count; i += 128u) {
            edit_results[job.first_edit + i] = EDIT_RESULT_REJECTED_OVERFLOW;
        }
        return;
    }

    for (uint i = thread; i < h_palette_size; i += 128u) {
        if (i == 0u || shared_edit_refcount[i] > 0u) {
            uint bucket; bool owned;
            edit_hash_reserve(shared_edit_palette[i], bucket, owned);
            if (owned) { uint original; InterlockedExchange(shared_edit_hash_slot[bucket], i, original); }
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // ------------------------- Fase 1: resolve slots -------------------------
    for (uint i = thread; i < job.edit_count; i += 128u) {
        uint packed_edit = voxel_edits[job.first_edit + i];
        uint voxel_index = packed_edit & 0x7FFFu;
        uint new_block = packed_edit >> 16u;
        int3 coord = coordinate_from_dense_index(voxel_index);

        uint old_index = read_palette_index_at(slot, shared_edit_plane_count, coord);
        old_index = min(old_index, shared_edit_palette_size - 1u); // clamp defensivo
        uint old_block = shared_edit_palette[old_index];

        shared_edit_old_index[i] = old_index;
        if (old_block == new_block) {
            shared_edit_new_slot[i] = EDIT_SLOT_NOOP;
            continue;
        }
        bool counted;
        uint s = edit_resolve_slot(slot, new_block, counted);
        shared_edit_new_slot[i] = (s == EDIT_SLOT_REJECTED)
            ? EDIT_SLOT_REJECTED
            : (s | (counted ? EDIT_COUNTED_FLAG : 0u));
    }
    GroupMemoryBarrierWithGroupSync();

    uint old_planes = shared_edit_plane_count;
    uint required_planes = old_planes;
    while ((1u << required_planes) < max(shared_edit_palette_size, 1u)) { required_planes++; }
    if (required_planes > old_planes) {
        uint first_new_word = old_planes * BRICKS_PER_CHUNK;
        uint new_word_count = (required_planes - old_planes) * BRICKS_PER_CHUNK;
        for (uint i = thread; i < new_word_count; i += 128u) {
            material_plane_pool[plane_base + first_new_word + i] = 0u;
        }
        if (thread == 0u) { shared_edit_plane_count = required_planes; }
    }
    GroupMemoryBarrierWithGroupSync();

    // ------------------------- Fase 2: aplica as edições -------------------------
    for (uint i = thread; i < job.edit_count; i += 128u) {
        uint packed_slot = shared_edit_new_slot[i];
        if (packed_slot == EDIT_SLOT_NOOP) { edit_results[job.first_edit + i] = EDIT_RESULT_NOOP; continue; }
        if (packed_slot == EDIT_SLOT_REJECTED) { edit_results[job.first_edit + i] = EDIT_RESULT_REJECTED_PALETTE_FULL; continue; }

        uint new_index = packed_slot & 0x7FFFFFFFu;
        bool counted = (packed_slot & EDIT_COUNTED_FLAG) != 0u;
        uint old_index = shared_edit_old_index[i];

        uint packed_edit = voxel_edits[job.first_edit + i];
        uint voxel_index = packed_edit & 0x7FFFu;
        uint new_block = packed_edit >> 16u;
        int3 coord = coordinate_from_dense_index(voxel_index);
        uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
        uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);
        uint mask = 1u << bit_idx;

        for (uint plane = 0u; plane < shared_edit_plane_count; plane++) {
            bool old_bit = ((old_index >> plane) & 1u) != 0u;
            bool new_bit = ((new_index >> plane) & 1u) != 0u;
            if (old_bit == new_bit) { continue; }
            uint addr = plane_base + plane * BRICKS_PER_CHUNK + brick_idx;
            if (new_bit) { InterlockedOr(material_plane_pool[addr], mask); }
            else { InterlockedAnd(material_plane_pool[addr], ~mask); }
        }

        uint occupancy_addr = occupancy_base + brick_idx;
        if (new_block != 0u) { InterlockedOr(occupancy_pool[occupancy_addr], mask); }
        else { InterlockedAnd(occupancy_pool[occupancy_addr], ~mask); }
        uint solidity_addr = occupancy_base + SOLID_WORD_BASE + brick_idx;
        if (block_is_solid(new_block)) { InterlockedOr(occupancy_pool[solidity_addr], mask); }
        else { InterlockedAnd(occupancy_pool[solidity_addr], ~mask); }
        InterlockedOr(shared_edit_dirty_bricks[brick_idx >> 5u], 1u << (brick_idx & 31u));

        if (!counted) { InterlockedAdd(shared_edit_refcount[new_index], 1u); }
        InterlockedAdd(shared_edit_refcount[old_index], 0xFFFFFFFFu); // -1

        edit_results[job.first_edit + i] = EDIT_RESULT_APPLIED;
    }
    GroupMemoryBarrierWithGroupSync();

    uint local_or = 0u;
    for (uint i = thread; i < BRICKS_PER_CHUNK; i += 128u) {
        local_or |= occupancy_pool[occupancy_base + i];
    }
    if (local_or != 0u) { InterlockedOr(shared_edit_nonempty, 1u); }

    if (thread < COARSE_CELLS_PER_CHUNK) {
        int3 cell = int3(int(thread & 3u), int(thread >> 4u), int((thread >> 2u) & 3u));
        int3 base_brick = cell * BRICKS_PER_COARSE_CELL;
        bool any_solid = false;
        for (uint b = 0u; b < 16u && !any_solid; b++) {
            int3 brick_coord = base_brick + int3(int(b & 1u), int(b >> 2u), int((b >> 1u) & 1u));
            any_solid = occupancy_pool[occupancy_base + brick_index_from_coordinate(brick_coord)] != 0u;
        }
        uint cell_addr = occupancy_base + BRICKS_PER_CHUNK + (thread >> 5u);
        uint cell_mask = 1u << (thread & 31u);
        if (any_solid) { InterlockedOr(occupancy_pool[cell_addr], cell_mask); }
        else { InterlockedAnd(occupancy_pool[cell_addr], ~cell_mask); }
    }

    for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += 128u) {
        uint rc = shared_edit_refcount[i];
        if (rc == EDIT_REFCLAIMED) { rc = 0u; } // defensivo: claim interrompido
        chunk_headers[slot].refcount[i] = rc;
    }
    GroupMemoryBarrierWithGroupSync();

    if (thread == 0u) {
        uint flags = shared_edit_flags;
        if (shared_edit_nonempty != 0u) { flags &= ~CHUNK_FLAG_EMPTY; } else { flags |= CHUNK_FLAG_EMPTY; }
        chunk_headers[slot].flags = flags;
        chunk_headers[slot].palette_size = shared_edit_palette_size;
        chunk_headers[slot].plane_count = shared_edit_plane_count;
    }

    for (uint brick_idx = thread; brick_idx < BRICKS_PER_CHUNK; brick_idx += 128u) {
        if (((shared_edit_dirty_bricks[brick_idx >> 5u] >> (brick_idx & 31u)) & 1u) == 0u) { continue; }
        int3 brick_coord = brick_coordinate_from_index(brick_idx);
        uint part_verts[4] = { 0u, 0u, 0u, 0u };
        uint part_tris[4]  = { 0u, 0u, 0u, 0u };
        for (uint bit_idx = 0u; bit_idx < VOXELS_PER_BRICK; bit_idx++) {
            int3 coord = brick_coord * BRICK_SIZE + local_coordinate_from_bit_index(bit_idx);
            uint palette_index = read_palette_index_at(slot, shared_edit_plane_count, coord);
            palette_index = min(palette_index, shared_edit_palette_size - 1u);
            uint block_id = shared_edit_palette[palette_index];
            if (block_id == 0u) { continue; }
            BlockDefinition def = global_block_registry[block_id];
            MeshTemplate tmpl = mesh_templates[def.mesh_template_index];
            if (tmpl.triangle_count > 0u) {
                uint part = bit_idx >> 3u;
                part_verts[part] += tmpl.vertex_count;
                part_tris[part]  += tmpl.worst_case_tris;
            }
        }
        uint half_verts  = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3]);
        uint half_tris   = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3]);
        uint total_verts = part_verts[0] + part_verts[1] + part_verts[2] + part_verts[3];
        uint total_tris  = part_tris[0] + part_tris[1] + part_tris[2] + part_tris[3];
        uint subdivision = 0u;
        if (total_verts > MESH_VERTEX_MAXIMUM || total_tris > MESH_TRIANGLE_MAXIMUM) {
            subdivision = 1u;
            if (half_verts > MESH_VERTEX_MAXIMUM || half_tris > MESH_TRIANGLE_MAXIMUM) { subdivision = 2u; }
        }

        uint addr = occupancy_base + SUBDIVISION_WORD_BASE + (brick_idx >> 4u);
        uint shift = (brick_idx & 15u) * 2u;
        InterlockedAnd(occupancy_pool[addr], ~(3u << shift));
        if (subdivision != 0u) { InterlockedOr(occupancy_pool[addr], subdivision << shift); }
    }
}
