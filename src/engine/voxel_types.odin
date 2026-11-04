package engine

// Constantes e layouts compartilhados com src/assets/shaders/common.slang —
// o .slang é a fonte única de verdade (AGENTS.md); mudanças devem ser
// espelhadas nos dois lados.

CHUNK_SIZE         :: 32
CHUNK_VOXEL_COUNT  :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

BRICKS_PER_CHUNK   :: 1024
VOXELS_PER_BRICK   :: 32

COARSE_WORDS_PER_CHUNK      :: 2
SUBDIVISION_WORDS_PER_CHUNK :: 64
OCCUPANCY_WORDS_PER_CHUNK   :: BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK
SUBDIVISION_WORD_BASE       :: BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK // 1026

MATERIAL_PLANE_COUNT_MAXIMUM :: 8
MATERIAL_WORDS_PER_CHUNK     :: MATERIAL_PLANE_COUNT_MAXIMUM * BRICKS_PER_CHUNK
PALETTE_SIZE_MAXIMUM         :: 256
SPECIAL_RECORDS_PER_CHUNK    :: 256

CHUNK_FLAG_EMPTY            :: 1
CHUNK_FLAG_PALETTE_OVERFLOW :: 2

MESH_VERTEX_MAXIMUM   :: 256
MESH_TRIANGLE_MAXIMUM :: 192

MAX_TEMPLATE_VERTICES  :: 32
MAX_TEMPLATE_TRIANGLES :: 24
TEMPLATE_FLAG_HAS_FLUSH_FACES :: 1
CULL_FACE_NEVER        :: 7

// --- Renderização (VS-02) ---
NEIGHBOR_SLOT_INVALID       :: max(u32)
MAXIMUM_VISIBLE_CHUNKS      :: 4096
TASK_PAYLOAD_BRICK_CAPACITY :: 2048

// Ordem igual a FACE_NORMALS no common.slang (+X,-X,+Y,-Y,+Z,-Z).
NEIGHBOR_OFFSETS :: [6]ChunkCoordinate{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

// --- Textura de paleta procedural (VS-02, REQ-SHADE-03) ---
// Uma camada por entrada de albedo; cada camada é uma cor sólida.
ALBEDO_PALETTE_LAYERS     :: 256
ALBEDO_PALETTE_LAYER_SIZE :: 4

// --- Streaming (ADR-B5) ---
RADIUS_VISION     :: 8
RADIUS_GENERATION :: 8
RADIUS_UNLOAD     :: 16

MAXIMUM_RESIDENT_CHUNKS       :: 4096
MAXIMUM_CHUNKS_PER_BATCH      :: 16
MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT :: 3

ChunkCoordinate :: [3]i32

// 32 B (múltiplo de 16) — espelha o Slang.
ChunkGenerationJob :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	mirror_ring_slot:   i32, // C2 (VS-04): sempre -1 nesta fatia
	padding:            [3]u32,
}

// 2.064 B — espelha o Slang (16 B escalares + 1 KiB paleta + 1 KiB refcounts).
ChunkHeader :: struct {
	palette_size:        u32,
	plane_count:         u32,
	special_voxel_count: u32,
	flags:               u32,
	palette:             [PALETTE_SIZE_MAXIMUM]u32,
	refcount:            [PALETTE_SIZE_MAXIMUM]u32,
}

SpecialVoxelRecord :: struct {
	voxel_index:           u32,
	shape_and_orientation: u32,
	block_identifier:      u32,
}

// 48 B std430 — espelha o Slang.
BlockDefinition :: struct {
	mesh_template_index:  u32,
	albedo_texture_index: u32,
	pbr_texture_index:    u32,
	flags:                u32,
	emission_color:       [3]f32,
	base_roughness:       f32,
	base_metallic:        f32,
	rotation:             u32,
	padding_2:            u32,
	padding_3:            u32,
}

// 32 B std430 — espelha o Slang.
MeshTemplate :: struct {
	vertex_offset:   u32,
	vertex_count:    u32,
	triangle_offset: u32,
	triangle_count:  u32,
	worst_case_tris: u32,
	flags:           u32,
	padding_0:       u32,
	padding_1:       u32,
}

// 48 B — espelha o Slang (B2: ring de visíveis, binding 6).
VisibleChunk :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	neighbor_slots:     [6]u32, // NEIGHBOR_SLOT_INVALID se ausente ou GENERATING
	padding:            [2]u32,
}

// 88 B — casar com o pipeline layout da VS-00.
VoxelPushConstants :: struct {
	view_projection_matrix: matrix[4, 4]f32,
	camera_position:        [3]f32,
	visible_chunk_offset:   u32,
	batch_job_offset:       u32,
	edit_job_offset:        u32,
}

// Triângulo packed em u32: bits [0..8) v0 | [8..16) v1 | [16..24) v2 | [24..27) face de culling.
pack_template_triangle :: proc "contextless" (v0, v1, v2, cull_face: u32) -> u32 {
	return (v0 & 0xFF) | ((v1 & 0xFF) << 8) | ((v2 & 0xFF) << 16) | ((cull_face & 7) << 24)
}

// Pior-caso de triângulos para qualquer direção de câmera: nunca culpados +,
// por eixo, max(tris na face+, tris na face-).
compute_worst_case_tris :: proc(packed_triangles: []u32) -> u32 {
	never_culled: u32
	face_count: [6]u32
	for tri in packed_triangles {
		face := (tri >> 24) & 7
		if face == CULL_FACE_NEVER {
			never_culled += 1
		} else {
			face_count[face] += 1
		}
	}
	return never_culled +
		max(face_count[0], face_count[1]) +
		max(face_count[2], face_count[3]) +
		max(face_count[4], face_count[5])
}

// Contrato de carga (ADR-CAMINHO-B): vértices em [0,1]³, limites por template.
validate_template :: proc(vertices: [][3]f32, packed_triangles: []u32) -> bool {
	if len(vertices) > MAX_TEMPLATE_VERTICES do return false
	if compute_worst_case_tris(packed_triangles) > MAX_TEMPLATE_TRIANGLES do return false
	for v in vertices {
		if v.x < 0 || v.x > 1 || v.y < 0 || v.y > 1 || v.z < 0 || v.z > 1 do return false
	}
	return true
}

#assert(size_of(ChunkGenerationJob) == 32)
#assert(size_of(ChunkHeader) == 2064)
#assert(size_of(BlockDefinition) == 48)
#assert(size_of(MeshTemplate) == 32)
#assert(size_of(VisibleChunk) == 48)
#assert(size_of(VoxelPushConstants) == 88)
