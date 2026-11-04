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

[[vk::push_constant]] PushConstants push_constants;

// ----------------------------------------------------------------------------
// Bindings (VS-01: geração e pack; 6/8/9/13-16 são fatias seguintes)
// ----------------------------------------------------------------------------
[[vk::binding(0, 0)]] RWStructuredBuffer<uint>               temporary_dense_chunks;
[[vk::binding(1, 0)]] StructuredBuffer<ChunkGenerationJob>   generation_jobs;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint>               occupancy_pool;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint>               material_plane_pool;
[[vk::binding(4, 0)]] RWStructuredBuffer<ChunkHeader>        chunk_headers;
[[vk::binding(5, 0)]] RWStructuredBuffer<SpecialVoxelRecord> special_voxel_records;
[[vk::binding(7, 0)]] StructuredBuffer<BlockDefinition>      global_block_registry;
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
