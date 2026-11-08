package engine

// VS-20 (REQ-GPL-01..08; ADR-G2): mira central por frame com realce no
// fragment (UBO binding 21), construção com clique esquerdo (pedra id 3 em
// hit+normal), remoção com direito (ar no hit) via intake E1, e pulo de
// 1,5 bloco com SPACE. Regras espelhadas por tools/sim/render_sim.py.

import "core:log"
import "core:math"

TARGET_HIGHLIGHT_TINT :: 1.4 // fator constante de clareamento (REQ-GPL-02)
GAMEPLAY_REACH :: f32(12.0)  // alcance do DDA central (REQ-GPL-01)
GAMEPLAY_BLOCK_PLACE_ID :: u32(3) // pedra
JUMP_HEIGHT_VOXELS :: f32(1.5)

// 16 B — espelha TargetHighlight do common.slang (REQ-GPL-02).
TargetHighlight :: struct {
	target_voxel: [3]i32,
	target_valid: u32,
}

#assert(size_of(TargetHighlight) == 16)

GameplayManager :: struct {
	target:              PhysicsRayHit, // snapshot da mira central (1×/frame)
	stats_target_hit:    u64,
	stats_target_miss:   u64,
	stats_target_unknown: u64,
	stats_edits:         u64, // edições solicitadas (place + remove)
	stats_noop:          u64, // ações rejeitadas pelas guardas
	stats_jumps:         u64,
	stats_jumps_rejected: u64,
	stats_jumps_logged:  u64,
}

gameplay_init :: proc(ve: ^VoxelEngine) {
	ve.gameplay = GameplayManager{}
}

gameplay_destroy :: proc(ve: ^VoxelEngine) {}

// Publica o alvo do frame no UBO do slot do frame (REQ-GPL-01/07): chamado
// na main após physics_tick + player_sync_camera, antes do submit.
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

// Teleporte invalida o alvo até o próximo DDA (REQ-GPL-07).
gameplay_clear_target :: proc(ve: ^VoxelEngine) {
	ve.gameplay.target = {}
}

// Clique: 0 = esquerdo (colocar pedra), 1 = direito (remover). Consome o
// snapshot do frame — o mesmo exibido pelo realce (REQ-GPL-04/05/07).
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
		// a pedra resultante não pode intersectar a AABB do jogador
		if player != nil && gameplay_aabb_intersects_voxel(player.position, player.size, destination) {
			ve.gameplay.stats_noop += 1
			return
		}
		log.infof("VS-20 CONSTRUÇÃO place: voxel={} normal={} dest={} id={}", hit.voxel, hit.normal, destination, GAMEPLAY_BLOCK_PLACE_ID)
		ve_request_voxel_edit(ve, destination, GAMEPLAY_BLOCK_PLACE_ID)
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

// Pulo de 1,5 bloco (REQ-GPL-06): impulso único no press, só grounded e não
// congelado; release/hold/auto-repeat não pulam (a main dedup auto-repeat).
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
