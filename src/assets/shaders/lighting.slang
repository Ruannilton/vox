import common;


float exit_t(float3 ro, float3 inv_rd, float3 rd, int3 cell_min, int3 cell_size) {
    float3 bound = float3(cell_min) + float3(rd.x > 0 ? float(cell_size.x) : 0.0,
                                             rd.y > 0 ? float(cell_size.y) : 0.0,
                                             rd.z > 0 ? float(cell_size.z) : 0.0);
    float3 t = (bound - ro) * inv_rd;
    return min(t.x, min(t.y, t.z));
}


bool trace_occluded(float3 ro, float3 rd_in, float t_max, int3 ignore_voxel) {
    float3 rd = float3(abs(rd_in.x) < 1e-6 ? 1e-6 : rd_in.x,
                       abs(rd_in.y) < 1e-6 ? 1e-6 : rd_in.y,
                       abs(rd_in.z) < 1e-6 ? 1e-6 : rd_in.z);
    float3 inv_rd = 1.0 / rd;
    float t = 0.0;

    [loop] for (uint i = 0; i < 192 && t < t_max; i++) {
        float3 p  = ro + rd * (t + 1e-3);
        int3   w  = int3(floor(p));
        int3   cc = w >> 5; // CHUNK_SIZE = 32
        uint slot = chunk_slot_at(cc);

        int3 cell_min, cell_size;
        if (slot == NEIGHBOR_SLOT_INVALID ||
            (chunk_headers[slot].flags & CHUNK_FLAG_EMPTY) != 0u) {
            cell_min = cc << 5;
            cell_size = int3(32); // chunk ausente/vazio: aberto
        } else {
            int3 l    = w - (cc << 5);
            uint base = slot * OCCUPANCY_WORDS_PER_CHUNK;
            uint cell = uint(l.x >> 3) + 4u * (uint(l.z >> 3) + 4u * uint(l.y >> 3));
            if (((occupancy_pool[base + BRICKS_PER_CHUNK + (cell >> 5)] >> (cell & 31u)) & 1u) == 0u) {
                cell_min = (w >> 3) << 3;
                cell_size = int3(8); // célula grossa vazia
            } else {
                uint brick = brick_index_from_coordinate(l / BRICK_SIZE);
                uint word  = occupancy_pool[base + OPAQUE_WORD_BASE + brick];
                if (word == 0u) {
                    cell_min  = int3((w.x >> 2) << 2, (w.y >> 1) << 1, (w.z >> 2) << 2);
                    cell_size = BRICK_SIZE; // brick sem opaco
                } else {
                    uint bit = bit_index_from_local_coordinate(l % BRICK_SIZE);
                    if (((word >> bit) & 1u) != 0u && any(w != ignore_voxel)) return true;
                    cell_min = w;
                    cell_size = int3(1);
                }
            }
        }
        t = max(exit_t(ro, inv_rd, rd, cell_min, cell_size), t + 1e-4);
    }
    return false;
}

float corner_ao(bool side1, bool side2, bool corner) {
    if (side1 && side2) return 0.0;
    return (3.0 - float(side1) - float(side2) - float(corner)) / 3.0;
}


float voxel_ao(float3 world_pos, float3 normal) {
    float3 an = abs(normal);
    if (max(an.x, max(an.y, an.z)) < 0.99) return 1.0; // faces diagonais (plantas): sem AO

    int3 n  = int3(round(normal));
    int3 t1 = (an.x > 0.5) ? int3(0, 1, 0) : int3(1, 0, 0);

    int3 t2 = (an.z > 0.5) ? int3(1, 0, 0) : int3(0, 0, 1);

    int3   own = int3(floor(world_pos - normal * 0.01));
    int3   v   = own + n; // voxel à frente da face
    float3 fr  = world_pos - float3(own);
    float  u   = saturate(dot(fr, float3(t1)));
    float  w   = saturate(dot(fr, float3(t2)));

    bool e1 = opaque_at_world(v + t1), e2 = opaque_at_world(v - t1);
    bool f1 = opaque_at_world(v + t2), f2 = opaque_at_world(v - t2);
    float a00 = corner_ao(e2, f2, opaque_at_world(v - t1 - t2));
    float a10 = corner_ao(e1, f2, opaque_at_world(v + t1 - t2));
    float a01 = corner_ao(e2, f1, opaque_at_world(v - t1 + t2));
    float a11 = corner_ao(e1, f1, opaque_at_world(v + t1 + t2));
    return lerp(lerp(a00, a10, u), lerp(a01, a11, u), w);
}

// Amostragem trilinear simples do volume de block light RGB.
float3 sample_block_light(float3 world_pos, float3 normal) {
    float3 p    = world_pos + normal * 0.5;
    int3   base = int3(floor(p));
    float3 f    = saturate(p - float3(base));
    float3 c000 = float3(block_light_at_world(base));
    float3 c100 = float3(block_light_at_world(base + int3(1, 0, 0)));
    float3 c010 = float3(block_light_at_world(base + int3(0, 1, 0)));
    float3 c110 = float3(block_light_at_world(base + int3(1, 1, 0)));
    float3 c001 = float3(block_light_at_world(base + int3(0, 0, 1)));
    float3 c101 = float3(block_light_at_world(base + int3(1, 0, 1)));
    float3 c011 = float3(block_light_at_world(base + int3(0, 1, 1)));
    float3 c111 = float3(block_light_at_world(base + int3(1, 1, 1)));
    float3 cx00 = lerp(c000, c100, f.x);
    float3 cx10 = lerp(c010, c110, f.x);
    float3 cx01 = lerp(c001, c101, f.x);
    float3 cx11 = lerp(c011, c111, f.x);
    float3 cxy0 = lerp(cx00, cx10, f.y);
    float3 cxy1 = lerp(cx01, cx11, f.y);
    return lerp(cxy0, cxy1, f.z) / 15.0;
}

float3 shade_surface(float3 world_pos, float3 normal, float3 albedo, uint block_id) {
    float3 ray_origin = world_pos + normal * 0.01;
    int3   own_voxel  = int3(floor(world_pos - normal * 0.01));

    // Sol
    float3 L   = light_globals.sun_direction.xyz;
    float  ndl = max(dot(normal, L), 0.0);
    float  sun_visibility = 0.0;
    if (ndl > 0.0) {
        sun_visibility = trace_occluded(ray_origin, L, light_globals.params.x, own_voxel) ? 0.0 : 1.0;
    }
    if (light_globals.counts.y == 1u) return float3(sun_visibility);
    float3 sun = light_globals.sun_color.rgb * ndl * sun_visibility;

    // Ambiente: gradiente de céu pela normal, modulado pelo AO.
    float ao = lerp(1.0, voxel_ao(world_pos, normal), light_globals.params.y);
    if (light_globals.counts.y == 2u) return float3(ao);
    float3 ambient = lerp(light_globals.sky_horizon.rgb, light_globals.sky_zenith.rgb,
                          normal.y * 0.5 + 0.5) * ao;

    // Block light propagada (volume RGB).
    float3 block_light = sample_block_light(world_pos, normal) * light_globals.params.z;
    if (light_globals.counts.y == 3u) return block_light;

    // Luzes dinâmicas (no máximo counts.x ≤ 2): shadow ray direto por luz.
    float3 dynamic_light = float3(0.0);
    uint dynamic_count = min(light_globals.counts.x, 2u);
    for (uint i = 0; i < dynamic_count; i++) {
        float4 pr   = light_globals.dynamic_light_position_radius[i];
        float3 to_l = pr.xyz - world_pos;
        float  dist = length(to_l);
        if (dist >= pr.w) continue;
        float3 Ld = to_l / dist;
        float  nd = max(dot(normal, Ld), 0.0);
        if (nd <= 0.0) continue;
        if (trace_occluded(ray_origin, Ld, dist, own_voxel)) continue;
        float window = saturate(1.0 - pow(dist / pr.w, 4.0));
        dynamic_light += light_globals.dynamic_light_color[i].rgb * nd * window * window / (dist * dist + 1.0);
    }

    float3 emission = global_block_registry[block_id & 0x7FFFFFFFu].emission_color;
    return albedo * (sun + ambient + block_light + dynamic_light) + emission;
}
