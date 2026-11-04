package vox

import glm "core:math/linalg/glsl"
import "core:math"

CHUNK_SIZE :: 32
GRID_SIZE :: 16
GRID_COUNT :: GRID_SIZE * GRID_SIZE * GRID_SIZE
LOAD_DISTANCE :: 8
UNLOAD_DISTANCE :: 12

/*
    24 bits -> X
    24 bits -> Z
    16 bits -> Y
*/
ChunkPackedPosition :: u64
ChunkId :: u32
ivec3_to_chunk_position :: proc(v: glm.ivec3) -> ChunkPackedPosition {
    return ChunkPackedPosition((v.x & 0xFFFFFF) << 40 | (v.y & 0xFFFF) << 24 | (v.z & 0xFFFFFF))
}

chunk_position_to_ivec3 :: proc(p: ChunkPackedPosition) -> glm.ivec3 {
    res := glm.ivec3{}
    res.x = i32((p >> 40) & 0xFFFFFF)
    res.y = i32((p >> 24) & 0xFFFF)
    res.z = i32(p & 0xFFFFFF)
    return res
}

chunk_position_distance :: proc(a, b: ChunkPackedPosition) -> i32 {
    a_pos := chunk_position_to_ivec3(a)
    b_pos := chunk_position_to_ivec3(b)
    dx := f64(a_pos.x - b_pos.x)
    dy := f64(a_pos.y - b_pos.y)
    dz := f64(a_pos.z - b_pos.z)
    return i32(math.sqrt(dx*dx + dy*dy + dz*dz))
}

ivec3_to_grid_position :: proc(v: glm.vec3) -> (result: glm.ivec3) {
   result.x = i32(v.x / CHUNK_SIZE)
   result.y = i32(v.y / CHUNK_SIZE)
   result.z = i32(v.z / CHUNK_SIZE)
   return
}

grid_position_distance :: proc(a, b: glm.ivec3) -> i32 {
    dx := f64(a.x - b.x)
    dy := f64(a.y - b.y)
    dz := f64(a.z - b.z)
    return i32(math.sqrt(dx*dx + dy*dy + dz*dz))
}


ChunkState :: enum {
    Free,
    WaitingToGenerate,
    Generating,
    Ready,
    UnloadRequested,
    WaitingToRelease
}

ChunkSlot :: struct {
    id: ChunkId,
    state: ChunkState,
    grid_position: glm.ivec3
}

VoxelGridManager :: struct {
    chunks: [GRID_COUNT]ChunkSlot,
    chunks_free: [dynamic]ChunkId,
    chunks_to_unload: [dynamic]ChunkId,
    world_chunks: map[glm.ivec3]ChunkId
}

VoxelGridManager_init :: proc() -> VoxelGridManager {
    vgm := VoxelGridManager{
        chunks_free = make([dynamic]ChunkId),
        chunks_to_unload = make([dynamic]ChunkId)
    }
     for i:=GRID_COUNT-1 ; i  >= 0 ; i-= 1 {
        vgm.chunks[i] = ChunkSlot{
            id = ChunkId(i),
            state = ChunkState.Free
        }
        append(&vgm.chunks_free, ChunkId(i))
    }
    return vgm
}

VoxelGridManager_list_chunks_to_unload :: proc(vgm: ^VoxelGridManager) {
    grid_reference := glm.ivec3{}

    for &chunk_slot in vgm.chunks {
        distance := grid_position_distance(chunk_slot.grid_position, grid_reference)
        if distance < UNLOAD_DISTANCE {
            continue
        }
         #partial switch chunk_slot.state {
            case ChunkState.WaitingToGenerate:
                chunk_slot.state = .Free
                append(&vgm.chunks_free, chunk_slot.id)
                continue
            case ChunkState.Ready:
                chunk_slot.state = .UnloadRequested
                append(&vgm.chunks_to_unload, chunk_slot.id)
                continue
        }
    }
}
