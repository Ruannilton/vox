package engine

import "core:log"
import glm "core:math/linalg/glsl"

GL_TO_VK_CLIP :: matrix[4, 4]f32{
		1, 0, 0, 0,
		0, -1, 0, 0,
		0, 0, 0.5, 0.5,
		0, 0, 0, 1,
	}

Camera :: struct {
	position:  glm.vec3,
	rotation:  glm.vec3, // x: pitch, y: yaw, z: roll
	fov:       f32,
	target:    glm.vec3,
	direction: glm.vec3,
	up:        glm.vec3,
	right:     glm.vec3,
	projection: glm.mat4,
}

camera_create :: proc(position, rotation: glm.vec3, fov: f32) -> Camera {
	projection := glm.mat4Perspective(
		glm.radians(fov),
		f32(app.presentation.width) / f32(app.presentation.height),
		0.5,
		500.0,
	)
	log.infof("Camera projection matrix: {},{}", app.presentation.width, app.presentation.height)
	c := Camera {
		position = position,
		rotation = rotation,
		fov      = fov,
		projection = projection,
	}
	camera_rotate(&c, {0, 0, 0})
	return c
}

camera_view :: proc(c: ^Camera) -> glm.mat4 {
	return glm.mat4LookAt(c.position, c.target, c.up)
}

camera_move :: proc(c: ^Camera, forward_amount, right_amount: f32) {
	c.position += c.direction * forward_amount
	c.position += c.right * right_amount
	c.target = c.position + c.direction
}

camera_look_at :: proc(c: ^Camera, target: glm.vec3) {
	c.target = target
	c.direction = glm.normalize(c.target - c.position)
	c.right = glm.normalize(glm.cross(c.direction, glm.vec3{0, 1, 0}))
	c.up = glm.cross(c.right, c.direction)
}

camera_rotate :: proc(c: ^Camera, delta: glm.vec3) {
	c.rotation += delta

	if c.rotation.x > 89.0 {
		c.rotation.x = 89.0
	} else if c.rotation.x < -89.0 {
		c.rotation.x = -89.0
	}

	rad_pitch := glm.radians(c.rotation.x)
	rad_yaw := glm.radians(c.rotation.y)

	c.direction = glm.normalize(
		glm.vec3 {
			glm.cos(rad_yaw) * glm.cos(rad_pitch),
			glm.sin(rad_pitch),
			glm.sin(rad_yaw) * glm.cos(rad_pitch),
		},
	)

	c.target = c.position + c.direction
	c.right = glm.normalize(glm.cross(c.direction, glm.vec3{0, 1, 0}))
	c.up = glm.cross(c.right, c.direction)
}

camera_get_view_projection :: proc(c: ^Camera) -> glm.mat4 {
	return GL_TO_VK_CLIP * c.projection * camera_view(c)
}
