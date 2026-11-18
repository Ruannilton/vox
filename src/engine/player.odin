package engine

import "core:log"
import glm "core:math/linalg/glsl"
import "vendor:glfw"

PLAYER_SIZE :: glm.vec3{0.6, 2, 0.6}
PLAYER_HALF_WIDTH :: f32(0.3)
PLAYER_EYE_HEIGHT :: f32(2)
PLAYER_WALK_SPEED :: f32(6.0)
PLAYER_SPRINT_FACTOR :: f32(2.0)
PLAYER_MOUSE_SENSITIVITY :: f32(0.07)

Player :: struct {
	camera:             Camera,
	physic_body_handle: PhysicsHandle,
	physics_body:       ^PhysicsBody,
	space_pressed:      bool,
	jump_tracking:      bool,
	jump_base_y:        f32,
	jump_apex_y:        f32,
}

player_create :: proc(ve: ^VoxelEngine, position: glm.vec3) -> Player {
	camera := camera_create(position, glm.vec3{-50, -90, 0}, 45.0)
	body_handle := physics_body_create(
		ve,
		camera.position - glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH},
		PLAYER_SIZE,
	)
	return Player {
		camera             = camera,
		physic_body_handle = body_handle,
		physics_body       = physics_body_get(ve, body_handle),
	}
}

player_destroy :: proc(ve: ^VoxelEngine, p: ^Player) {
	if p.physic_body_handle != PHYSICS_HANDLE_INVALID {
		physics_body_remove(ve, p.physic_body_handle)
		p.physic_body_handle = PHYSICS_HANDLE_INVALID
		p.physics_body       = nil
	}
}

// Teleporte: reposiciona o corpo (com guarda de handle) e ressincroniza a câmera.
player_set_position :: proc(p: ^Player, position: glm.vec3) {
	if p.physics_body != nil {
		p.physics_body.position = position - glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH}
		p.physics_body.velocity = {}
		player_sync_camera(p)
	}
}

player_get_position :: proc(p: ^Player) -> glm.vec3 {
	return p.physics_body.position + glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH}
}

// Movimento WASD + sprint: converte o input do bus de eventos em velocidade
// horizontal do corpo físico. Deve rodar antes de physics_tick no frame.
player_update :: proc(p: ^Player, delta_time: f32) {
	body := p.physics_body
	if body == nil do return
	speed: f32 = PLAYER_WALK_SPEED
	if events_is_pressed(glfw.KEY_LEFT_SHIFT) do speed *= PLAYER_SPRINT_FACTOR

	forward_input, right_input: f32
	if events_is_pressed(glfw.KEY_W) do forward_input += 1
	if events_is_pressed(glfw.KEY_S) do forward_input -= 1
	if events_is_pressed(glfw.KEY_D) do right_input += 1
	if events_is_pressed(glfw.KEY_A) do right_input -= 1

	// evita andar mais rápido na diagonal
	if forward_input != 0 && right_input != 0 {
		forward_input *= 0.70710678
		right_input *= 0.70710678
	}

	rad_yaw := glm.radians(p.camera.rotation.y)
	forward := glm.vec3{glm.cos(rad_yaw), 0, glm.sin(rad_yaw)}
	right := glm.vec3{-glm.sin(rad_yaw), 0, glm.cos(rad_yaw)}
	wish := forward * forward_input + right * right_input

	body.velocity.x = wish.x * speed
	body.velocity.z = wish.z * speed
}

// A câmera acompanha o corpo: posição do olho = topo do AABB (olho na altura EYE).
player_sync_camera :: proc(p: ^Player) {
	body := p.physics_body
	if body == nil do return

	p.camera.position = body.position + glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH}
	p.camera.target = p.camera.position + p.camera.direction
}


player_track_jump_apex :: proc(p: ^Player, ve: ^VoxelEngine) {
	body := p.physics_body
	if body == nil do return
	if !p.jump_tracking {
		if ve.gameplay.stats_jumps > 0 &&
		   ve.gameplay.stats_jumps != ve.gameplay.stats_jumps_logged &&
		   !body.grounded {
			p.jump_tracking = true
			p.jump_base_y = body.position.y
			p.jump_apex_y = body.position.y
			ve.gameplay.stats_jumps_logged = ve.gameplay.stats_jumps
		}
		return
	}
	p.jump_apex_y = max(p.jump_apex_y, body.position.y)
	if body.grounded {
		log.infof(
			"VS-20 PULO ápice: base={:.3f} apex={:.3f} delta={:.3f} voxels",
			p.jump_base_y, p.jump_apex_y, p.jump_apex_y - p.jump_base_y,
		)
		p.jump_tracking = false
	}
}

// Input de teclado do jogador: borda do SPACE dispara o pulo (com edge guard).
player_on_space :: proc(p: ^Player, ve: ^VoxelEngine, pressed: bool) {
	if pressed == p.space_pressed do return
	p.space_pressed = pressed
	if pressed {
		gameplay_jump(ve, p.physics_body)
	}
}

// Input de mouse: rotação da câmera (payload já traz deltas em pixels).
player_on_mouse_move :: proc(p: ^Player, dx, dy: f32) {
	camera_rotate(&p.camera, glm.vec3{dy * PLAYER_MOUSE_SENSITIVITY, dx * PLAYER_MOUSE_SENSITIVITY, 0})
}

// Input de mouse: construção/remoção de blocos no alvo atual (VS-20).
player_on_mouse_button :: proc(p: ^Player, ve: ^VoxelEngine, button: i32, pressed: bool) {
	if pressed {
		gameplay_mouse_press(ve, button, p.physics_body)
	}
}
