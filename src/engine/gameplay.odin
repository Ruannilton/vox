package engine


import "core:log"
import "core:math"
import "vendor:glfw"

TARGET_HIGHLIGHT_TINT :: 1.4 
GAMEPLAY_REACH :: f32(12.0)  
JUMP_HEIGHT_VOXELS :: f32(1.5)

TargetHighlight :: struct {
	target_voxel: [3]i32,
	target_valid: u32,
}

#assert(size_of(TargetHighlight) == 16)

GameplayManager :: struct {
	target:              PhysicsRayHit, 
	stats_target_hit:    u64,
	stats_target_miss:   u64,
	stats_target_unknown: u64,
	stats_edits:         u64, 
	stats_noop:          u64,
	stats_jumps:         u64,
	stats_jumps_rejected: u64,
	stats_jumps_logged:  u64,
}

selected_block :u32= 12

gameplay_init :: proc(ve: ^VoxelEngine) {
	ve.gameplay = GameplayManager{}
}

gameplay_destroy :: proc(ve: ^VoxelEngine) {}

gameplay_update_target :: proc(ve: ^VoxelEngine, frame_index: u32, origin, direction: [3]f32) {
	ZoneN("gameplay_target_update")
	ve.gameplay.target = physics_raycast(ve, origin, direction, GAMEPLAY_REACH)
	slot := voxel_gpu.target_highlight_ubo_mapped[frame_index * u32(voxel_gpu.target_highlight_alignment):]
	slot_ptr := cast(^TargetHighlight)&slot[0]
	highlight: TargetHighlight
	switch ve.gameplay.target.result {
	case .HIT:
		highlight.target_voxel = ve.gameplay.target.voxel
		highlight.target_valid = 1
		ve.gameplay.stats_target_hit += 1
	case .MISS:
		ve.gameplay.stats_target_miss += 1
	case .UNKNOWN:
		ve.gameplay.stats_target_unknown += 1
	}
	slot_ptr^ = highlight
}

gameplay_upate :: proc(){
	if events_is_pressed(glfw.KEY_TAB) do selected_block = (selected_block + 1) % 13
}

gameplay_clear_target :: proc(ve: ^VoxelEngine) {
	ve.gameplay.target = {}
}


gameplay_mouse_press :: proc(ve: ^VoxelEngine, button: i32, player: ^PhysicsBody) {
	if button == 0 {
		ZoneN("gameplay_place_block")
		hit := ve.gameplay.target
		zero_normal := hit.normal == [3]i32{0, 0, 0}
	if hit.result != .HIT || zero_normal {
			ve.gameplay.stats_noop += 1
			return
		}
		unit_axes := 0
		for component in hit.normal do if component != 0 do unit_axes += 1
		if unit_axes != 1 {
			ve.gameplay.stats_noop += 1
			return
		}
		destination := hit.voxel + hit.normal
		sample, known := voxel_get(ve, destination)
		if !known || block_is_blocking(u32(sample.block_id)) {
			ve.gameplay.stats_noop += 1
			return
		}

		if player != nil && gameplay_aabb_intersects_voxel(player.position, player.size, destination) {
			ve.gameplay.stats_noop += 1
			return
		}
		log.infof("VS-20 CONSTRUÇÃO place: voxel={} normal={} dest={} id={}", hit.voxel, hit.normal, destination, selected_block)
		ve_request_voxel_edit(ve, destination, selected_block)
		ve.gameplay.stats_edits += 1
	} else if button == 1 {
		ZoneN("gameplay_remove_block")
		hit := ve.gameplay.target
		if hit.result != .HIT {
			ve.gameplay.stats_noop += 1
			return
		}
		log.infof("VS-20 CONSTRUÇÃO remove: voxel={}", hit.voxel)
		ve_request_voxel_edit(ve, hit.voxel, 0)
		ve.gameplay.stats_edits += 1
	}
}

gameplay_jump :: proc(ve: ^VoxelEngine, player: ^PhysicsBody) {
	ZoneN("gameplay_jump")
	if player == nil || !player.grounded || player.frozen {
		ve.gameplay.stats_jumps_rejected += 1
		log.info("VS-20 PULO rejeitado (no ar/congelado)")
		return
	}
	player.velocity.y = math.sqrt_f32(2.0 * math.abs(PHYSICS_GRAVITY) * JUMP_HEIGHT_VOXELS)
	ve.gameplay.stats_jumps += 1
	log.infof("VS-20 PULO: impulso v0={:.3f} u/s em y={:.2f}", player.velocity.y, player.position.y)
}

gameplay_aabb_intersects_voxel :: proc "contextless" (body_min, body_size: [3]f32, voxel: [3]i32) -> bool {
	for axis in 0 ..= 2 {
		if body_min[axis] + body_size[axis] <= f32(voxel[axis]) do return false
		if f32(voxel[axis]) + 1.0 <= body_min[axis] do return false
	}
	return true
}
