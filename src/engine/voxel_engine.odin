package engine

import "core:log"
import "core:math"
import glm "core:math/linalg/glsl"

CHUNK_SIZE :: 16
CHUNK_SLOT_COUNT :: 8 * 8 * 8
CHUNK_DISTANCE_THRESHOLD :: 4 * CHUNK_SIZE

void :: struct {}

ChunkSlot :: struct {
	id:       u64,
	position: glm.vec3,
}

VoxelEngine :: struct {
	free_slots:       [dynamic]ChunkSlot,
	using_slots:      [dynamic]ChunkSlot,
	pending_slots:    [dynamic]u64,
	lookup_positions: map[glm.vec3]void,
}

ve_init :: proc() -> VoxelEngine {
	ve := VoxelEngine {
		free_slots       = make([dynamic]ChunkSlot, 0, CHUNK_SLOT_COUNT),
		using_slots      = make([dynamic]ChunkSlot, 0, CHUNK_SLOT_COUNT),
		pending_slots    = make([dynamic]u64, 0, CHUNK_SLOT_COUNT),
		lookup_positions = make(map[glm.vec3]void),
	}

	for i: u64 = 0; i < CHUNK_SLOT_COUNT; i += 1 {
		append(&ve.free_slots, ChunkSlot{id = i})
	}

	return ve
}

ve_update :: proc(ve: ^VoxelEngine, pivot: glm.vec3) {
	pos := vec_to_grid(pivot)

	// De trás pra frente: seguro com unordered_remove
	for i := len(ve.using_slots) - 1; i >= 0; i -= 1 {
		slot := ve.using_slots[i]
		if dist_xz(pos, slot.position) > CHUNK_DISTANCE_THRESHOLD {
			delete_key(&ve.lookup_positions, slot.position)
			unordered_remove(&ve.using_slots, i)
			append(&ve.free_slots, slot)

			// Tira do pending se ainda não foi despachado
			for j := len(ve.pending_slots) - 1; j >= 0; j -= 1 {
				if ve.pending_slots[j] == slot.id {
					unordered_remove(&ve.pending_slots, j)
				}
			}
			log.infof("Recycled slot %v at position %v", slot.id, slot.position)
		}
	}

	for x := -CHUNK_DISTANCE_THRESHOLD; x <= CHUNK_DISTANCE_THRESHOLD; x += CHUNK_SIZE {
		for z := -CHUNK_DISTANCE_THRESHOLD; z <= CHUNK_DISTANCE_THRESHOLD; z += CHUNK_SIZE {
			chunk_pos := glm.vec3{f32(x) + pos.x, 0, f32(z) + pos.z}

			if chunk_pos in ve.lookup_positions do continue
			if dist_xz(pos, chunk_pos) > CHUNK_DISTANCE_THRESHOLD do continue

			if len(ve.free_slots) == 0 {
				log.warn("No free chunk slots")
				return
			}

			slot := pop(&ve.free_slots)
			slot.position = chunk_pos
			append(&ve.using_slots, slot)
			append(&ve.pending_slots, slot.id)
			ve.lookup_positions[chunk_pos] = void{}
			log.infof("Allocated slot %v at position %v", slot.id, slot.position)
		}
	}
}

ve_dispatch :: proc(ve: ^VoxelEngine) {
	count := len(ve.pending_slots)
	if count == 0 do return
	log.infof("Dispatching %v pending slots", count)
	clear(&ve.pending_slots)
}

ve_destroy :: proc(ve: ^VoxelEngine) {
	delete(ve.free_slots)
	delete(ve.using_slots)
	delete(ve.pending_slots)
	delete(ve.lookup_positions)
}

@(private)
dist_xz :: proc(a, b: glm.vec3) -> f32 {
	return glm.length(glm.vec2{a.x - b.x, a.z - b.z})
}

@(private)
vec_to_grid :: proc(v: glm.vec3) -> glm.vec3 {
	return {
		math.floor(v.x / CHUNK_SIZE) * CHUNK_SIZE,
		0,
		math.floor(v.z / CHUNK_SIZE) * CHUNK_SIZE,
	}
}
