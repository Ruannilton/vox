package engine

import "vendor:glfw"

last_x, last_y: f64
first_cursor_event: bool

setup_glfw_callbacks :: proc() {
    last_x, last_y = glfw.GetCursorPos(app.glfwWindow)
	first_cursor_event = true
 
	glfw.SetKeyCallback(
		app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
			switch action {
			case glfw.PRESS:
				events_push_now(.KeyPress, KeyPayload{key = key, scancode = scancode, duration = -1})
			case glfw.RELEASE:
				events_push_now(.KeyRelease, KeyPayload{key = key, scancode = scancode, duration = -1})
			}
		},
	)

	glfw.SetCursorPosCallback(
		app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
			if first_cursor_event {
				first_cursor_event = false
				last_x, last_y = xpos, ypos
				return
			}

			xoffset := f32(xpos - last_x)
			yoffset := f32(last_y - ypos) // Invertido, pois o eixo Y cresce para baixo
			last_x = xpos
			last_y = ypos
			events_push_now(.MouseMove, MouseMovePayload{dx = xoffset, dy = yoffset})
		},
	)

	glfw.SetMouseButtonCallback(
		app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
			switch action {
			case glfw.PRESS:
				events_push_now(.MouseButton, MouseButtonPayload{button = button, press = true})
			case glfw.RELEASE:
				events_push_now(.MouseButton, MouseButtonPayload{button = button, press = false})
			}
		},
	)

	glfw.SetWindowCloseCallback(
		app.glfwWindow,
		proc "c" (window: glfw.WindowHandle) {
			events_push_now(.CloseRequested, struct {}{})
		},
	)
}