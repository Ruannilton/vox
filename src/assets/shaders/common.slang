// ============================================================================
// common.slang — FONTE ÚNICA DE VERDADE (constantes e layouts Odin↔Slang)
// VS-01 — Streaming, generate e pack.
// Qualquer mudança aqui exige revisão das specs afetadas (AGENTS.md).
// ============================================================================

// ----------------------------------------------------------------------------
// Constantes globais
// ----------------------------------------------------------------------------
static const int  CHUNK_SIZE        = 32;
static const uint CHUNK_VOXEL_COUNT = 32 * 32 * 32;

static const int3 BRICK_SIZE            = int3(4, 2, 4);
static const uint VOXELS_PER_BRICK      = 32;
static const int3 BRICKS_PER_CHUNK_AXIS = int3(8, 16, 8);
static const uint BRICKS_PER_CHUNK      = 1024;

static const int3 BRICKS_PER_COARSE_CELL = int3(2, 4, 2);
static const uint COARSE_WORDS_PER_CHUNK = 2;
// CAMINHO B: 2 bits de subdivisão por brick = 64 words por chunk.
static const uint SUBDIVISION_WORDS_PER_CHUNK = 64;
// Layout do pool de ocupação por chunk:
//   [0..1024)    = 1 word de ocupação por brick
//   [1024..1026) = 64 bits de coarse cells
//   [1026..1090) = 2 bits de subdivisão por brick (caminho B)
static const uint OCCUPANCY_WORDS_PER_CHUNK = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK;
static const uint SUBDIVISION_WORD_BASE     = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK; // 1026

// Paleta: 8 planos, 256 entradas — slot 0 é SEMPRE ar (invariante do B3).
static const uint MATERIAL_PLANE_COUNT_MAXIMUM = 8;
static const uint MATERIAL_WORDS_PER_CHUNK     = MATERIAL_PLANE_COUNT_MAXIMUM * BRICKS_PER_CHUNK;
static const uint PALETTE_SIZE_MAXIMUM         = 256;
static const uint BLOCK_PRESENCE_WORDS         = 2048;
static const uint PACK_THREADS                 = 128;
static const uint PRESENCE_WORDS_PER_THREAD    = BLOCK_PRESENCE_WORDS / PACK_THREADS;
static const uint SPECIAL_RECORDS_PER_CHUNK    = 256;

static const uint CHUNK_FLAG_EMPTY            = 1;
static const uint CHUNK_FLAG_PALETTE_OVERFLOW = 2;

static const uint MESH_VERTEX_MAXIMUM   = 256;
static const uint MESH_TRIANGLE_MAXIMUM = 192;

// CAMINHO B: limites do contrato de carga de templates.
static const uint MAX_TEMPLATE_VERTICES  = 32; // por voxel; subdivisão x4 => 8*32 = 256
static const uint MAX_TEMPLATE_TRIANGLES = 24; // pior-caso por voxel; x4 => 8*24 = 192
static const uint TEMPLATE_FLAG_HAS_FLUSH_FACES = 1;
static const uint CULL_FACE_NEVER = 7; // triângulo nunca culpado (interior/diagonal)

// VS-02: publicação de visíveis e payload do task shader.
static const uint NEIGHBOR_SLOT_INVALID       = 0xFFFFFFFFu;
static const uint MAXIMUM_VISIBLE_CHUNKS      = 4096;
// Payload: 2 entradas de 14 bits (brick 10b | parte 2b | subdivisão 2b) por
// word — 2048 words ≈ 8,2 KiB < 16 KiB, capacidade 4096 entradas = pior caso
// exato (1024 bricks × 4 partes). Não usa tipos de 16 bits (shaderInt16 não
// é habilitado).
static const uint TASK_PAYLOAD_WORDS          = 2048;
static const uint TASK_PAYLOAD_BRICK_CAPACITY = 4096;

// ----------------------------------------------------------------------------
// Estruturas (espelhadas em src/engine — std430)
// ----------------------------------------------------------------------------
struct ChunkGenerationJob {
    int3 chunk_world_origin;
    uint storage_slot_index;
    // C2 (VS-04): >= 0 = exporta o denso u16 p/ este slot do ring do mirror;
    // -1 = sem export. Sempre -1 nesta fatia.
    int  mirror_ring_slot;
    uint _padding[3]; // 32 B totais (múltiplo de 16) — casar com o Odin
};

struct ChunkHeader {
    uint palette_size;
    uint plane_count;
    uint special_voxel_count;
    uint flags;
    uint palette[PALETTE_SIZE_MAXIMUM];
    // E1 (VS-03): refcount por entrada da paleta. Mantido pelo pack na
    // geração; slot 0 conta os não-sólidos e nunca é reciclado.
    uint refcount[PALETTE_SIZE_MAXIMUM];
};

struct SpecialVoxelRecord {
    uint voxel_index; // dense_index_from_coordinate (15 bits)
    uint shape_and_orientation;
    uint block_identifier;
};

struct BlockDefinition {
    uint   mesh_template_index; // CAMINHO B: índice na tabela de templates (0 = ar)
    uint   albedo_texture_index;
    uint   pbr_texture_index;
    uint   flags;               // bit 0 = transparente
    float3 emission_color;
    float  base_roughness;
    float  base_metallic;
    uint   rotation;            // yaw em passos de 90° (0..3)
    uint   padding_2;
    uint   padding_3;
};

// CAMINHO B: template de micro-mesh. Vértices em [0,1]^3 (regra da engine:
// voxel de tamanho único). Triângulos packed em uint:
// bits [0..8) v0, [8..16) v1, [16..24) v2, [24..27) face de culling.
struct MeshTemplate {
    uint vertex_offset;   // no pool template_vertices
    uint vertex_count;    // <= MAX_TEMPLATE_VERTICES
    uint triangle_offset; // no pool template_triangles
    uint triangle_count;
    uint worst_case_tris; // pré-computado no load
    uint flags;           // bit 0: HAS_FLUSH_FACES
    uint padding_0;
    uint padding_1;
};

struct PushConstants {
    column_major float4x4 view_projection_matrix;
    float3 camera_position;
    uint   visible_chunk_offset;
    uint   batch_job_offset;
    uint   edit_job_offset; // E1 (VS-03). 88 B totais — casar com a VS-00.
};

// VS-02 (B2): entrada do ring de visíveis (binding 6), 48 B.
struct VisibleChunk {
    int3 chunk_world_origin;
    uint storage_slot_index;
    uint neighbor_slots[6]; // ordem: +X,-X,+Y,-Y,+Z,-Z (mesma de FACE_NORMALS)
    uint _padding[2];
};

// VS-02: payload task→mesh. Cada word carrega 2 entradas de 14 bits:
// brick (10 bits) | parte<<10 | subdivisão<<12; entrada i está na metade
// (i&1)*14 da word i>>1. Words não escritas permanecem zeradas (o task
// shader zera antes de selecionar).
struct TaskPayload {
    uint storage_slot_index;
    int3 chunk_world_origin;
    uint neighbor_slots[6];
    uint brick_indices[TASK_PAYLOAD_WORDS];
};

// VS-02: saída do mesh shader.
struct MeshVertex {
    float4 clip_position  : SV_Position;
    float3 world_position : WORLD_POSITION;
    uint   block_id       : BLENDINDICES;
};

[[vk::push_constant]] PushConstants push_constants;

// ----------------------------------------------------------------------------
// Bindings (0–5, 7, 10–12 = VS-01; 6, 8, 9 = VS-02; 13–16 = VS-03/VS-04)
// ----------------------------------------------------------------------------
[[vk::binding(0, 0)]] RWStructuredBuffer<uint>               temporary_dense_chunks;
[[vk::binding(1, 0)]] StructuredBuffer<ChunkGenerationJob>   generation_jobs;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint>               occupancy_pool;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint>               material_plane_pool;
[[vk::binding(4, 0)]] RWStructuredBuffer<ChunkHeader>        chunk_headers;
[[vk::binding(5, 0)]] RWStructuredBuffer<SpecialVoxelRecord> special_voxel_records;
[[vk::binding(6, 0)]] StructuredBuffer<VisibleChunk>         visible_chunks;
[[vk::binding(7, 0)]] StructuredBuffer<BlockDefinition>      global_block_registry;
[[vk::binding(8, 0)]] Sampler2DArray                         block_albedo_textures;
[[vk::binding(9, 0)]] Sampler2DArray                         block_pbr_textures; // dummy nesta fatia (ADR-B7)
// CAMINHO B: tabela de templates + pools de geometria (escritos no load pela CPU)
[[vk::binding(10, 0)]] StructuredBuffer<MeshTemplate>        mesh_templates;
[[vk::binding(11, 0)]] StructuredBuffer<float3>              template_vertices;
[[vk::binding(12, 0)]] StructuredBuffer<uint>                template_triangles;

// ----------------------------------------------------------------------------
// Funções auxiliares de coordenadas
// ----------------------------------------------------------------------------
uint brick_index_from_coordinate(int3 coord) { return uint(coord.x) + 8u * (uint(coord.z) + 8u * uint(coord.y)); }
int3 brick_coordinate_from_index(uint index) { return int3(int(index & 7u), int(index >> 6u), int((index >> 3u) & 7u)); }
uint bit_index_from_local_coordinate(int3 coord) { return uint(coord.x) + 4u * (uint(coord.z) + 4u * uint(coord.y)); }
int3 local_coordinate_from_bit_index(uint index) { return int3(int(index & 3u), int(index >> 4u), int((index >> 2u) & 3u)); }
uint dense_index_from_coordinate(int3 coord) { return uint(coord.x) | (uint(coord.z) << 5u) | (uint(coord.y) << 10u); }
int3 coordinate_from_dense_index(uint index) { return int3(int(index & 31u), int(index >> 10u), int((index >> 5u) & 31u)); }
uint coarse_cell_index_from_brick_coordinate(int3 coord) { int3 cell = coord / BRICKS_PER_COARSE_CELL; return uint(cell.x) + 4u * (uint(cell.z) + 4u * uint(cell.y)); }

// ----------------------------------------------------------------------------
// VS-02: helpers de renderização (B2, culling de faces, rotação yaw)
// ----------------------------------------------------------------------------
static const int3 FACE_NORMALS[6] = { int3(1,0,0), int3(-1,0,0), int3(0,1,0), int3(0,-1,0), int3(0,0,1), int3(0,0,-1) };

// CAMINHO B: para onde aponta cada face após a rotação yaw (ordem de FACE_NORMALS).
static const uint ROTATED_FACE[24] = {
    0, 1, 2, 3, 4, 5,  // r=0: identidade
    5, 4, 2, 3, 0, 1,  // r=1: +X->-Z, -X->+Z, +Z->+X, -Z->-X
    1, 0, 2, 3, 5, 4,  // r=2: 180°
    4, 5, 2, 3, 1, 0,  // r=3
};

uint read_brick_occupancy(uint slot, int3 coord) {
    if (any(coord < 0) || any(coord >= BRICKS_PER_CHUNK_AXIS)) return 0;
    return occupancy_pool[slot * OCCUPANCY_WORDS_PER_CHUNK + brick_index_from_coordinate(coord)];
}

bool is_voxel_solid_local(uint slot, int3 coord) {
    uint occupancy = read_brick_occupancy(slot, coord / BRICK_SIZE);
    return ((occupancy >> bit_index_from_local_coordinate(coord % BRICK_SIZE)) & 1u) != 0;
}

// VS-02: word de ocupação de um brick VIZINHO com redirecionamento B2 entre
// chunks (mesma ordem de FACE_NORMALS). Vizinho inválido => 0 (conservador:
// tratado como não-cheio, nunca contribui para culling de oclusão).
uint read_brick_occupancy_b2(uint slot, int3 brick_coord, uint neighbor_slots[6]) {
    if (all(brick_coord >= 0) && all(brick_coord < BRICKS_PER_CHUNK_AXIS)) {
        return read_brick_occupancy(slot, brick_coord);
    }
    uint neighbor_slot = NEIGHBOR_SLOT_INVALID;
    int3 local = brick_coord;
    if (brick_coord.x < 0)                              { neighbor_slot = neighbor_slots[1]; local.x += BRICKS_PER_CHUNK_AXIS.x; }
    else if (brick_coord.x >= BRICKS_PER_CHUNK_AXIS.x)  { neighbor_slot = neighbor_slots[0]; local.x -= BRICKS_PER_CHUNK_AXIS.x; }
    else if (brick_coord.y < 0)                         { neighbor_slot = neighbor_slots[3]; local.y += BRICKS_PER_CHUNK_AXIS.y; }
    else if (brick_coord.y >= BRICKS_PER_CHUNK_AXIS.y)  { neighbor_slot = neighbor_slots[2]; local.y -= BRICKS_PER_CHUNK_AXIS.y; }
    else if (brick_coord.z < 0)                         { neighbor_slot = neighbor_slots[5]; local.z += BRICKS_PER_CHUNK_AXIS.z; }
    else                                                { neighbor_slot = neighbor_slots[4]; local.z -= BRICKS_PER_CHUNK_AXIS.z; }
    if (neighbor_slot == NEIGHBOR_SLOT_INVALID) return 0;
    return read_brick_occupancy(neighbor_slot, local);
}

// Brick ocluso = cheio (32/32 voxels sólidos) com os 6 bricks vizinhos cheios:
// nenhum voxel tem face exposta (independente da câmera), então o grupo não
// emitiria geometria. Simulação: tools/sim/render_sim.py (cenário de oclusão).
bool is_brick_occluded(uint slot, uint occupancy_word, int3 brick_coord, uint neighbor_slots[6]) {
    if (occupancy_word != 0xFFFFFFFFu) return false;
    [unroll]
    for (uint face = 0; face < 6; face++) {
        int3 neighbor_coord = brick_coord + FACE_NORMALS[face];
        if (read_brick_occupancy_b2(slot, neighbor_coord, neighbor_slots) != 0xFFFFFFFFu) {
            return false;
        }
    }
    return true;
}

// CORREÇÃO B2: leitura fora do chunk é redirecionada à ocupação do vizinho
// (NEIGHBOR_SLOT_INVALID = ar; a geometria se corrige no frame da conclusão).
bool is_voxel_solid(uint slot, int3 coord, uint neighbor_slots[6]) {
    if (all(coord >= 0) && all(coord < CHUNK_SIZE)) {
        return is_voxel_solid_local(slot, coord);
    }
    uint neighbor_slot = NEIGHBOR_SLOT_INVALID;
    int3 local = coord;
    if (coord.x < 0)                  { neighbor_slot = neighbor_slots[1]; local.x += CHUNK_SIZE; }
    else if (coord.x >= CHUNK_SIZE)   { neighbor_slot = neighbor_slots[0]; local.x -= CHUNK_SIZE; }
    else if (coord.y < 0)             { neighbor_slot = neighbor_slots[3]; local.y += CHUNK_SIZE; }
    else if (coord.y >= CHUNK_SIZE)   { neighbor_slot = neighbor_slots[2]; local.y -= CHUNK_SIZE; }
    else if (coord.z < 0)             { neighbor_slot = neighbor_slots[5]; local.z += CHUNK_SIZE; }
    else                              { neighbor_slot = neighbor_slots[4]; local.z -= CHUNK_SIZE; }
    if (neighbor_slot == NEIGHBOR_SLOT_INVALID) return false;
    if (any(local < 0) || any(local >= CHUNK_SIZE)) return false;
    return is_voxel_solid_local(neighbor_slot, local);
}

// Máscara de faces: bit F setado se a face F do voxel pode ser visível
// (vizinho não-sólido E câmera do lado de fora do plano). Uso: culling de
// triângulos colados em faces do voxel (tags 0..5) nos templates.
uint compute_visible_face_mask(uint slot, int3 coord, int3 chunk_world_origin, float3 camera_position, uint neighbor_slots[6]) {
    float3 voxel_min_world = float3(chunk_world_origin + coord);
    uint face_mask = 0;

    [unroll]
    for (uint face_index = 0; face_index < 6; face_index++) {
        int3 neighbor_coord = coord + FACE_NORMALS[face_index];
        if (is_voxel_solid(slot, neighbor_coord, neighbor_slots)) continue;

        uint axis_index = face_index >> 1;
        bool is_positive_face = (face_index & 1) == 0;
        float plane_position = voxel_min_world[axis_index] + (is_positive_face ? 1.0 : 0.0);
        bool camera_sees_face = is_positive_face ? (camera_position[axis_index] > plane_position) : (camera_position[axis_index] < plane_position);

        if (camera_sees_face) {
            face_mask |= 1u << face_index;
        }
    }
    return face_mask;
}

// CAMINHO B: rotação yaw do template (passos de 90°, centrada no voxel).
// Convenção r=1: (x,z) -> (z, 1-x).
float3 rotate_vertex_yaw(float3 p, uint r) {
    switch (r & 3u) {
    case 1:  return float3(p.z, p.y, 1.0 - p.x);
    case 2:  return float3(1.0 - p.x, p.y, 1.0 - p.z);
    case 3:  return float3(1.0 - p.z, p.y, p.x);
    default: return p;
    }
}

// CAMINHO B: um triângulo de template sobrevive ao culling?
bool triangle_survives_culling(uint packed_tri, uint rotation, uint face_mask) {
    uint cull_face = (packed_tri >> 24u) & 7u;
    if (cull_face == CULL_FACE_NEVER) return true;
    uint rotated_face = ROTATED_FACE[(rotation & 3u) * 6u + cull_face];
    return (face_mask & (1u << rotated_face)) != 0u;
}

// VS-02: block id de um voxel via paleta/planos (o decode já foi validado
// bit-a-bit contra o denso em tools/sim/pack_sim.py).
uint read_block_identifier(uint slot, ChunkHeader header, int3 coord) {
    uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
    uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);

    uint palette_index = 0;
    for (uint plane = 0; plane < header.plane_count; plane++) {
        uint plane_word = material_plane_pool[slot * MATERIAL_WORDS_PER_CHUNK + plane * BRICKS_PER_CHUNK + brick_idx];
        palette_index |= ((plane_word >> bit_idx) & 1u) << plane;
    }
    return header.palette[min(palette_index, max(header.palette_size, 1u) - 1u)];
}
