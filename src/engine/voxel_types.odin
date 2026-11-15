package engine

import "core:log"

CHUNK_SIZE :: 32
CHUNK_VOXEL_COUNT :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

BRICKS_PER_CHUNK :: 1024
VOXELS_PER_BRICK :: 32

COARSE_WORDS_PER_CHUNK :: 2
SUBDIVISION_WORDS_PER_CHUNK :: 64

OCCUPANCY_WORDS_PER_CHUNK :: 3 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK
SUBDIVISION_WORD_BASE :: BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK // 1026
SOLID_WORD_BASE :: SUBDIVISION_WORD_BASE + SUBDIVISION_WORDS_PER_CHUNK // 1090
OPAQUE_WORD_BASE :: SOLID_WORD_BASE + BRICKS_PER_CHUNK // 2114

MATERIAL_PLANE_COUNT_MAXIMUM :: 8
MATERIAL_WORDS_PER_CHUNK :: MATERIAL_PLANE_COUNT_MAXIMUM * BRICKS_PER_CHUNK
PALETTE_SIZE_MAXIMUM :: 256
SPECIAL_RECORDS_PER_CHUNK :: 256

CHUNK_FLAG_EMPTY :: 1
CHUNK_FLAG_PALETTE_OVERFLOW :: 2

MESH_VERTEX_MAXIMUM :: 256
MESH_TRIANGLE_MAXIMUM :: 192

MAX_TEMPLATE_VERTICES :: 32
MAX_TEMPLATE_TRIANGLES :: 24
TEMPLATE_FLAG_HAS_FLUSH_FACES :: 1
CULL_FACE_NEVER :: 7

BLOCK_DEFINITION_FLAG_TRANSPARENT :: 1
BLOCK_DEFINITION_FLAG_NON_SOLID :: 2

NEIGHBOR_SLOT_INVALID :: max(u32)
WORK_QUEUE_STATE_WORDS :: 8
WORK_QUEUE_APPEND_COUNT_WORD :: 0
WORK_QUEUE_OVERFLOW_WORD :: 1
WORK_QUEUE_INDIRECT_X_WORD :: 2


NEIGHBOR_OFFSETS :: [6]ChunkCoordinate{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}

// VS-10 (REQ-VRT-01): registro EMPTY não possui slot de GPU.
SLOT_INDEX_INVALID :: max(u32)

ALBEDO_PALETTE_LAYERS :: 256

ALBEDO_PALETTE_LAYER_SIZE :: 16

NO_TEMPLATE_UV_OFFSET :: 0xFFFFFFFF

EDIT_FLUSH_INTERVAL_MS :: 100.0 // intervalo entre flushes (0 = todo frame)
MAX_EDITS_PER_FLUSH :: 4096
MAX_EDIT_JOBS_PER_FLUSH :: 256
MAX_EDITS_PER_CHUNK_PER_FLUSH :: 1024

EDIT_RESULT_APPLIED :: 0
EDIT_RESULT_NOOP :: 1
EDIT_RESULT_REJECTED_PALETTE_FULL :: 2
EDIT_RESULT_REJECTED_OVERFLOW :: 3

ChunkCoordinate :: [3]i32

// 32 B (múltiplo de 16) — espelha o Slang.
ChunkGenerationJob :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	mirror_ring_slot:   i32,
	padding:            [3]u32,
}

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

BlockDefinition :: struct {
	mesh_template_index: u32,   // 0
	pbr_texture_index:   u32,   // 4
	flags:               u32,   // 8
	albedo_faces:        [6]u32, // 12..36 (FACE_NORMALS: +X,-X,+Y,-Y,+Z,-Z)
	rotation:            u32,   // 36
	padding_2:           u32,   // 40
	padding_3:           u32,   // 44
	emission_color:      [3]f32, // 48..60 (offset múltiplo de 16)
	base_roughness:      f32,   // 60
	base_metallic:       f32,   // 64
	padding_4:           u32,   // 68
	padding_5:           u32,   // 72
	padding_6:           u32,   // 76
}

MeshTemplate :: struct {
	vertex_offset:   u32,
	vertex_count:    u32,
	triangle_offset: u32,
	triangle_count:  u32,
	worst_case_tris: u32,
	flags:           u32,
	uv_offset:       u32,
	padding_1:       u32,
}

// 48 B — espelha o Slang
VisibleChunk :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	neighbor_slots:     [6]u32, // NEIGHBOR_SLOT_INVALID se ausente ou GENERATING
	padding:            [2]u32,
}

// 16 B — espelha o Slang (ring de jobs de edição, binding 13).
EditChunkJob :: struct {
	storage_slot_index: u32,
	first_edit:         u32, // índice global no ring de voxel_edits/edit_results
	edit_count:         u32, // <= MAX_EDITS_PER_CHUNK_PER_FLUSH
	padding:            u32,
}

// 16 B — espelha o Slang (VS-23, binding 28): chunk selecionado para relight.
LightJob :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
}

// 208 B — espelha o LightGlobals do common.slang (std140; só tipos 16 B).
LightGlobals :: struct {
	sun_direction:                 [4]f32,
	sun_color:                     [4]f32,
	sky_zenith:                    [4]f32,
	sky_horizon:                   [4]f32,
	grid_min_chunk:                [4]i32,
	grid_dim_chunks:               [4]i32,
	params:                        [4]f32, // x: shadow_max_distance, y: ao_strength, z: block_light_strength
	dynamic_light_position_radius: [2][4]f32,
	dynamic_light_color:           [2][4]f32,
	counts:                        [4]u32, // x: dynamic_light_count, y: debug_mode
}

#assert(size_of(LightGlobals) == 192)

// VS-23: dimensões do chunk_grid (64×16×64 ≈ 256 KB de u32).
LIGHT_GRID_DIM_X :: 64
LIGHT_GRID_DIM_Y :: 16
LIGHT_GRID_DIM_Z :: 64
LIGHT_GRID_CELL_COUNT :: LIGHT_GRID_DIM_X * LIGHT_GRID_DIM_Y * LIGHT_GRID_DIM_Z


MAX_LIGHT_JOBS_PER_FLUSH :: 1024
LIGHT_PROPAGATION_PASSES :: 15

MirrorPageState :: enum u8 {
	PENDING_READBACK,
	MATERIALIZED,
}


VoxelSample :: struct {
	block_id: u16,
	solid:    bool, // VS-14 emenda: derivado do registry (bit NON_SOLID)
}

MirrorChunkPage :: struct {
	coord:        ChunkCoordinate,
	edit_seq:     u32,
	state:        MirrorPageState,
	ring_slot:    i32,
	pending:      [dynamic]VoxelEditRequest,
	applied_log:  [dynamic]VoxelEditRequest,
	rejected_log: [dynamic]VoxelEditRequest,
	solid:        [CHUNK_VOXEL_COUNT / 32]u32,
	ids:          [CHUNK_VOXEL_COUNT]u16,
	heights:      [CHUNK_SIZE * CHUNK_SIZE]u16,
}

MirrorRingEntry :: struct {
	used:       bool,
	coord:      ChunkCoordinate,
	generation: u32,
}

VoxelPushConstants :: struct {
	view_projection_matrix: matrix[4, 4]f32,
	camera_position:        [3]f32,
	visible_chunk_offset:   u32,
	batch_job_offset:       u32,
	edit_job_offset:        u32,
	visible_chunk_capacity: u32,
}

#assert(size_of(MirrorChunkPage) == 71824)
#assert(size_of(ChunkGenerationJob) == 32)
#assert(size_of(ChunkHeader) == 2064)
#assert(size_of(BlockDefinition) == 80)
#assert(offset_of(BlockDefinition, albedo_faces) == 12)
#assert(offset_of(BlockDefinition, emission_color) == 48)
#assert(size_of(MeshTemplate) == 32)
#assert(size_of(VisibleChunk) == 48)
#assert(size_of(EditChunkJob) == 16)
#assert(size_of(VoxelPushConstants) == 92)
#assert(OPAQUE_WORD_BASE == 2114)
#assert(OCCUPANCY_WORDS_PER_CHUNK == 3138)

// Edição packed em u32: voxel_index (15 bits, layout denso x|z<<5|y<<10) | block_id<<16.
pack_voxel_edit :: proc "contextless" (voxel_index: u32, block_id: u32) -> u32 {
	return (voxel_index & 0x7FFF) | (block_id << 16)
}

// Triângulo packed em u32: bits [0..8) v0 | [8..16) v1 | [16..24) v2 | [24..27) face de culling.
pack_template_triangle :: proc "contextless" (v0, v1, v2, cull_face: u32) -> u32 {
	return (v0 & 0xFF) | ((v1 & 0xFF) << 8) | ((v2 & 0xFF) << 16) | ((cull_face & 7) << 24)
}


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

validate_template :: proc(vertices: [][3]f32, packed_triangles: []u32) -> bool {
	if len(vertices) > MAX_TEMPLATE_VERTICES do return false
	if compute_worst_case_tris(packed_triangles) > MAX_TEMPLATE_TRIANGLES do return false
	for v in vertices {
		if v.x < 0 || v.x > 1 || v.y < 0 || v.y > 1 || v.z < 0 || v.z > 1 do return false
	}
	return true
}


validate_template_uvs :: proc(template_index: int, uvs: [][2]f32) -> bool {
	for uv, i in uvs {
		if uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 {
			log.errorf(
				"template {}: UV do vértice {} fora de [0,1]²: ({}, {})",
				template_index, i, uv.x, uv.y,
			)
			return false
		}
	}
	return true
}
