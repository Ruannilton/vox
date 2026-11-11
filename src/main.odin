package main

import "base:runtime"
import "core:fmt"
import "core:log"
import glm "core:math/linalg/glsl"
import "core:os"
import "core:sync"
import "engine"
import "vendor:glfw"
import vk "vendor:vulkan"

last_x, last_y: f64
first_cursor_event: bool
camera: Camera
voxel_engine: ^engine.VoxelEngine

// VS-19 (REQ-PHY-10): jogador como corpo AABB do solver; a câmera segue o
// corpo (olhos na altura PLAYER_EYE_HEIGHT) — input/eventos/render inalterados.
player_body: engine.PhysicsHandle
space_pressed:     bool  // dedup de auto-repeat do SPACE (REQ-GPL-06)
jump_tracking:     bool  // amostragem do ápice do pulo (AC-04)
jump_base_y:       f32
jump_apex_y:       f32
PLAYER_SIZE :: glm.vec3{0.6, 1.8, 0.6}
PLAYER_HALF_WIDTH :: f32(0.3)
PLAYER_EYE_HEIGHT :: f32(1.62)
PLAYER_WALK_SPEED :: f32(6.0)
PLAYER_SPRINT_FACTOR :: f32(2.0)

main :: proc() {
	engine.debug_paths_init(VERSION_STRING)
	file_logger, err := os.create(engine.debug_log_path)
	defer os.close(file_logger)
	if err != nil {
		log.error("Failed to create log file: {}", err)
		return
	}
	file_log := log.create_file_logger(file_logger)
	context.logger = log.create_multi_logger(log.create_console_logger(), file_log)
	log.infof("Vox Engine {}", VERSION_STRING)

	// parsing de flags + validação fatal do replay/config antes de criar a janela
	engine.events_init()
	defer engine.events_destroy()
	engine.config_load()
	// VS-12 (REQ-AST-06): parse + validação de assets antes de criar a janela;
	// ausente → warning + fallback built-ins/paleta no init do voxel engine.
	engine.assets_load()

	engine.CreateEngine()
	defer engine.DestroyEngine()

	// VS-15 (BLK-37): profiler Tracy só inicia após o init Vulkan/GLFW;
	// o defer fica antes do destroy do voxel engine porque o worker (que
	// emite zones) é encerrado dentro dele.
	engine.TracingStartup()
	defer engine.TracingShutdown()

	voxel_engine = engine.voxel_engine_init()

	camera = camera_create(glm.vec3{32, 75, 60}, glm.vec3{-50, -90, 0}, 45.0)
	// corpo do jogador: pés sob a câmera; cai e pousa na superfície
	player_body = engine.physics_body_create(
		voxel_engine,
		camera.position - glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH},
		PLAYER_SIZE,
	)
	projection := glm.mat4Perspective(
		glm.radians(camera.fov),
		f32(engine.app.presentation.width) / f32(engine.app.presentation.height),
		0.5,
		500.0,
	)
	// glm produz clip space OpenGL (y para cima, z em [-1,1]); Vulkan quer y
	// para baixo e z em [0,1]. Aplicado por último: vp_final = FIX * vp.
	GL_TO_VK_CLIP :: matrix[4, 4]f32{
		1, 0, 0, 0,
		0, -1, 0, 0,
		0, 0, 0.5, 0.5,
		0, 0, 0, 1,
	}

	glfw.SetInputMode(engine.app.glfwWindow, glfw.CURSOR, glfw.CURSOR_DISABLED)
	last_x, last_y = glfw.GetCursorPos(engine.app.glfwWindow)
	// recentering do CURSOR_DISABLED dispara evento com posição defasada; o
	// primeiro só ressincroniza last_x/last_y, sem aplicar delta
	first_cursor_event = true

	// callbacks são produtores puros (sem context/efeitos); o dreno grava e despacha
	glfw.SetKeyCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
			switch action {
			case glfw.PRESS:
				engine.events_push_now(.KeyPress, engine.KeyPayload{key = key, scancode = scancode, duration = -1})
			case glfw.RELEASE:
				engine.events_push_now(.KeyRelease, engine.KeyPayload{key = key, scancode = scancode, duration = -1})
			}
		},
	)

	glfw.SetCursorPosCallback(
		engine.app.glfwWindow,
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
			engine.events_push_now(.MouseMove, engine.MouseMovePayload{dx = xoffset, dy = yoffset})
		},
	)

	glfw.SetMouseButtonCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
			switch action {
			case glfw.PRESS:
				engine.events_push_now(.MouseButton, engine.MouseButtonPayload{button = button, press = true})
			case glfw.RELEASE:
				engine.events_push_now(.MouseButton, engine.MouseButtonPayload{button = button, press = false})
			}
		},
	)

	glfw.SetWindowCloseCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle) {
			engine.events_push_now(.CloseRequested, struct {}{})
		},
	)

	engine.events_register({.KeyPress, .KeyRelease}, key_handler)
	engine.events_register({.MouseMove}, mouse_handler)
	engine.events_register({.MouseButton}, mouse_handler)
	engine.events_register({.CloseRequested}, close_handler)
	engine.events_register(
		{.TeleportTo, .LookAt, .AddBlock, .RemoveBlock, .ToggleTelemetry, .TelemetrySnapshot},
		proc(e: engine.Event) {
			#partial switch p in e.payload {
			case engine.Vec3fPayload:
				if e.type == .TeleportTo {
					camera.position = p.v
					camera.target = camera.position + camera.direction
					// VS-19: teletransporta também o corpo do jogador
					if body := engine.physics_body_get(voxel_engine, player_body); body != nil {
						body.position = p.v - glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH}
						body.velocity = {}
					}
					engine.gameplay_clear_target(voxel_engine)
				} else {
					camera_look_at(&camera, p.v)
				}
			case engine.Vec3iPayload:
				block_id := e.type == .AddBlock ? p.block_id : u32(0)
				engine.ve_request_voxel_edit(voxel_engine, p.v, block_id)
			case struct {}:
				if e.type == .ToggleTelemetry {
					engine.telemetry_toggle()
				} else {
					engine.telemetry_snapshot()
				}
			}
		},
	)

	// t0 é fixado no fim da inicialização, antes do primeiro PollEvents
	engine.events_set_t0()

	engine.SetThreadName("main")
	engine.AppInfo(fmt.tprintf("version={} | {}", VERSION_STRING, engine.ConfigSummary()))
	log.infof("Tracy IsConnected()={}", engine.TracingIsConnected())

	log.info("Starting main loop")
	for !glfw.WindowShouldClose(engine.app.glfwWindow) {
		{
			engine.ZoneN("frame")
			free_all(context.temp_allocator)
			glfw.PollEvents()

			{
				engine.ZoneN("events_drain")
				engine.events_replay_feed(engine.events_time_now())
				engine.events_drain()
				if engine.events_should_exit_after_replay() {
					glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
				}
			}

			{
				engine.ZoneN("engine_update")
				engine.Update()
				engine.telemetry_service()
				frame_dt := min(f32(engine.app.deltaTime), 0.1)
				update_camera_movement(frame_dt)
				// VS-19: passos fixos de física na main; a câmera segue o corpo
				engine.physics_tick(voxel_engine, frame_dt)
				player_track_jump_apex()
				player_sync_camera()
				// VS-20 (REQ-GPL-01): DDA central 1×/frame após física/câmera
				engine.gameplay_update_target(voxel_engine, engine.app.frameIndex, camera.position, camera.direction)

				engine.voxel_engine_request_frame(voxel_engine, engine.app.currentTimelineValue, engine.app.frameIndex, engine.chunk_coordinate_from_world(camera.position))
			}

			signal_value: u64
			visible_count: u32
			edit_job_count: u32
			compute_wait_value: u64
			frame_resource: ^engine.FrameResource
			swapchain_frame: engine.SwapChainFrameData
			vp: glm.mat4
			cmd: vk.CommandBuffer
			{
				engine.ZoneN("frame_wait")
				signal_value = engine.WaitTimelineSemaphore()
				engine.telemetry_collect_graphics(engine.app.frameIndex)
				// VS-16 (REQ-GPU-03): coleta das zonas GPU do contexto
				// gráfica no mesmo ponto de espera (leitura com
				// disponibilidade, nunca bloqueante).
				engine.tracing_gpu_collect_graphics()
				view := camera_view(&camera)
				vp = GL_TO_VK_CLIP * projection * view

				frame_resource = engine.AcquireFrameResource()
				acquired: bool
				swapchain_frame, acquired = engine.AcquireNextImage()
				if !acquired {
					engine.CancelFrameReservation()
					continue
				}

				// VS-16 (REQ-CPU-01)
				{
					engine.ZoneN("publish_visible")
					visible_count = engine.voxel_engine_wait_published(voxel_engine, signal_value, engine.chunk_coordinate_from_world(camera.position))
					compute_wait_value = voxel_engine.published_compute_value
				}
				{
					engine.ZoneN("edit_flush")
					edit_job_count = engine.edit_ring_write(voxel_engine, engine.app.frameIndex)
				}

				// VS-15 (REQ-TRC-04): plots por frame, coletados só quando a
				// UI Tracy está conectada.
				if engine.TracingIsConnected() {
					engine.PlotInt("visible_chunks", i64(visible_count))
					engine.PlotInt("work_items", i64(voxel_engine.update_appended_tasks))
					engine.PlotInt("empty_chunks", i64(voxel_engine.empty_chunks_active))
				}
			}

		{
			engine.ZoneN("render_record")
			vk_check(vk.ResetCommandPool(engine.app.vkDevice, frame_resource.vkCommandPool, {}))

			begin_command_info := vk.CommandBufferBeginInfo {
				sType = .COMMAND_BUFFER_BEGIN_INFO,
				flags = {.ONE_TIME_SUBMIT},
			}
			cmd = frame_resource.vkCommandBuffer
			vk_check(vk.BeginCommandBuffer(cmd, &begin_command_info))

			gfx_pool := engine.telemetry.gfx_pools[engine.app.frameIndex]
			engine.telemetry_reset_pool(cmd, gfx_pool, engine.TELEMETRY_GFX_QUERY_COUNT)
			engine.telemetry_timestamp_begin(cmd, gfx_pool, 0)

			transition_rendering_barrier := [2]vk.ImageMemoryBarrier2 {
				{
					sType = .IMAGE_MEMORY_BARRIER_2,
					image = swapchain_frame.image,
					subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
					oldLayout = .UNDEFINED,
					newLayout = .COLOR_ATTACHMENT_OPTIMAL,
					srcStageMask = {.ALL_COMMANDS},
					srcAccessMask = {.MEMORY_READ},
					dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
					dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
				},
				{
					sType = .IMAGE_MEMORY_BARRIER_2,
					image = engine.app.depthBuffer.vkImage,
					subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
					oldLayout = .UNDEFINED,
					newLayout = .DEPTH_ATTACHMENT_OPTIMAL,
					srcStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
					srcAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
					dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
					dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_READ, .DEPTH_STENCIL_ATTACHMENT_WRITE},
				},
			}
			vk.CmdPipelineBarrier2(
				cmd,
				&vk.DependencyInfo {
					sType = .DEPENDENCY_INFO,
					imageMemoryBarrierCount = len(transition_rendering_barrier),
					pImageMemoryBarriers = raw_data(&transition_rendering_barrier),
				},
			)

			color_attachment := vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = swapchain_frame.image_view,
				imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .STORE,
				clearValue = {color = {float32 = {0, 0.2, 0.8, 1}}},
			}
			depth_attachment := vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = engine.app.depthBuffer.vkImageView,
				imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .DONT_CARE,
				clearValue = {depthStencil = {depth = 1, stencil = 0}},
			}
			rendering_info := vk.RenderingInfo {
				sType = .RENDERING_INFO,
				renderArea = {
					offset = {0, 0},
					extent = {engine.app.presentation.width, engine.app.presentation.height},
				},
				layerCount = 1,
				colorAttachmentCount = 1,
				pColorAttachments = &color_attachment,
				pDepthAttachment = &depth_attachment,
			}

			engine.voxel_render_prepare(
				cmd,
				vp,
				camera.position,
				visible_count,
				engine.app.frameIndex,
				edit_job_count,
			)

			vk.CmdBeginRendering(cmd, &rendering_info)
			engine.telemetry_begin_label(cmd, "render_pass")

			engine.voxel_render_record(cmd, vp, camera.position, visible_count, engine.app.frameIndex)

			engine.telemetry_end_label(cmd)
			vk.CmdEndRendering(cmd)

			transition_present_barrier := vk.ImageMemoryBarrier2 {
				sType = .IMAGE_MEMORY_BARRIER_2,
				image = swapchain_frame.image,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
				oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
				newLayout = .PRESENT_SRC_KHR,
				srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
				dstStageMask = {},
				dstAccessMask = {},
			}
			vk.CmdPipelineBarrier2(
				cmd,
				&vk.DependencyInfo {
					sType = .DEPENDENCY_INFO,
					imageMemoryBarrierCount = 1,
					pImageMemoryBarriers = &transition_present_barrier,
				},
			)
			engine.telemetry_timestamp_end(cmd, gfx_pool, 1)
			vk_check(vk.EndCommandBuffer(cmd))
		}


			acquire_wait_info := vk.SemaphoreSubmitInfo {
				sType     = .SEMAPHORE_SUBMIT_INFO,
				semaphore = frame_resource.vkAcquireSemaphore,
				stageMask = {.COLOR_ATTACHMENT_OUTPUT},
			}

			compute_wait_info := vk.SemaphoreSubmitInfo {
				sType     = .SEMAPHORE_SUBMIT_INFO,
				semaphore = engine.app.computeTimelineSemaphore,
				value     = compute_wait_value,
				stageMask = {.COMPUTE_SHADER, .MESH_SHADER_EXT},
			}
			wait_infos := [2]vk.SemaphoreSubmitInfo{acquire_wait_info, compute_wait_info}
			wait_count: u32 = compute_wait_value > 0 ? 2 : 1
			semaphore_signals := []vk.SemaphoreSubmitInfo {
				{
					sType = .SEMAPHORE_SUBMIT_INFO,
					semaphore = swapchain_frame.vkPresentSemaphore,
					stageMask = {.ALL_COMMANDS},
				},
				{
					sType = .SEMAPHORE_SUBMIT_INFO,
					semaphore = engine.app.timelineSemaphore,
					value = signal_value,
					stageMask = {.ALL_COMMANDS},
				},
			}
			command_submit_info := vk.CommandBufferSubmitInfo {
				sType         = .COMMAND_BUFFER_SUBMIT_INFO,
				commandBuffer = cmd,
			}
			submit_info := vk.SubmitInfo2 {
				sType                    = .SUBMIT_INFO_2,
				commandBufferInfoCount   = 1,
				pCommandBufferInfos      = &command_submit_info,
				waitSemaphoreInfoCount   = wait_count,
				pWaitSemaphoreInfos      = &wait_infos[0],
				signalSemaphoreInfoCount = cast(u32)len(semaphore_signals),
				pSignalSemaphoreInfos    = raw_data(semaphore_signals),
			}
			vk_check(vk.QueueSubmit2(engine.app.queues[.Graphics].queue, 1, &submit_info, {}))
			sync.mutex_unlock(&voxel_engine.frame_mutex)
			engine.telemetry.gfx_slot_submitted[engine.app.frameIndex] = true
		{
			engine.ZoneN("present")
			engine.Present()
		}
		engine.FrameMark()
	}
	}

	// estado final observável para validação de replay (pose e efeitos E1)
	log.infof(
		"FINAL pose: position=[{}, {}, {}] target=[{}, {}, {}]",
		camera.position.x, camera.position.y, camera.position.z,
		camera.target.x, camera.target.y, camera.target.z,
	)
	engine.edit_log_stats(voxel_engine, "FINAL edits:")
	log.info("Exiting application")
	if !engine.full_teardown {
		engine.TracingShutdown(false)
		log.info("fast-exit: teardown Vulkan pulado (SO reclaim; use --full-teardown para teardown completo)")
		os.exit(0)
	}
	// BLK-28: para e junta a worker antes do DeviceWaitIdle interno;
	// os defers seguintes fazem a coleta Tracy e destroem o device já ocioso.
	engine.voxel_engine_destroy(voxel_engine)
}

@(private)
update_camera_movement :: proc(delta_time: f32) {
	body := engine.physics_body_get(voxel_engine, player_body)
	if body == nil do return
	speed: f32 = PLAYER_WALK_SPEED
	if engine.events_is_pressed(glfw.KEY_LEFT_SHIFT) do speed *= PLAYER_SPRINT_FACTOR

	forward_input, right_input: f32
	if engine.events_is_pressed(glfw.KEY_W) do forward_input += 1
	if engine.events_is_pressed(glfw.KEY_S) do forward_input -= 1
	if engine.events_is_pressed(glfw.KEY_D) do right_input += 1
	if engine.events_is_pressed(glfw.KEY_A) do right_input -= 1

	// evita andar mais rápido na diagonal
	if forward_input != 0 && right_input != 0 {
		forward_input *= 0.70710678
		right_input *= 0.70710678
	}

	// direção horizontal do yaw da câmera (graus)
	rad_yaw := glm.radians(camera.rotation.y)
	forward := glm.vec3{glm.cos(rad_yaw), 0, glm.sin(rad_yaw)}
	right := glm.vec3{-glm.sin(rad_yaw), 0, glm.cos(rad_yaw)}
	wish := forward * forward_input + right * right_input
	// input-driven: a velocidade horizontal é imposta a cada passo; o solver
	// (gravidade, sweep, fricção de contato) integra o resto
	body.velocity.x = wish.x * speed
	body.velocity.z = wish.z * speed
}

// VS-20 (AC-04): amostra o ápice entre o impulso e o novo pouso.
@(private)
player_track_jump_apex :: proc() {
	body := engine.physics_body_get(voxel_engine, player_body)
	if body == nil do return
	if !jump_tracking {
		if voxel_engine.gameplay.stats_jumps > 0 &&
		   voxel_engine.gameplay.stats_jumps != voxel_engine.gameplay.stats_jumps_logged &&
		   !body.grounded {
			// só abre a janela quando o corpo de fato deixou o chão
			jump_tracking = true
			jump_base_y = body.position.y
			jump_apex_y = body.position.y
			voxel_engine.gameplay.stats_jumps_logged = voxel_engine.gameplay.stats_jumps
		}
		return
	}
	jump_apex_y = max(jump_apex_y, body.position.y)
	if body.grounded {
		log.infof("VS-20 PULO ápice: base={:.3f} apex={:.3f} delta={:.3f} voxels", jump_base_y, jump_apex_y, jump_apex_y - jump_base_y)
		jump_tracking = false
	}
}

@(private)
player_sync_camera :: proc() {
	body := engine.physics_body_get(voxel_engine, player_body)
	if body == nil do return
	camera.position = body.position + glm.vec3{PLAYER_HALF_WIDTH, PLAYER_EYE_HEIGHT, PLAYER_HALF_WIDTH}
	camera.target = camera.position + camera.direction
}

@(private)
key_handler :: proc(e: engine.Event) {
	p, _ := e.payload.(engine.KeyPayload)
	#partial switch e.type {
	case .KeyPress:
		// teclas de ação são instantâneas; ESC vira CloseRequested para registrar o fechamento
		switch p.key {
		case glfw.KEY_ESCAPE:
			engine.events_emit(.CloseRequested, struct {}{})
		case glfw.KEY_F8:
			engine.telemetry_toggle()
		case glfw.KEY_F9:
			engine.telemetry_snapshot()
		case glfw.KEY_F7:
			// VS-19 (AC-04): validação sob demanda — packed×denso e heights
			// derivado do bitmask.
			engine.debug_validate_run(voxel_engine)
			engine.debug_heights_parity(voxel_engine)
		case glfw.KEY_SPACE:
			// VS-20 (REQ-GPL-06): um pulo por press — GLFW auto-repeat gera
			// KeyPress sem KeyRelease entre eles; o dedup ignora.
			if !space_pressed {
				space_pressed = true
				engine.gameplay_jump(voxel_engine, engine.physics_body_get(voxel_engine, player_body))
			}
		}
	case .KeyRelease:
		if p.key == glfw.KEY_SPACE do space_pressed = false
	}
}

@(private)
mouse_handler :: proc(e: engine.Event) {
	#partial switch p in e.payload {
	case engine.MouseMovePayload:
		sensitivity: f32 = 0.07
		// Camera.rotation: x: pitch, y: yaw, z: roll
		delta_rotation := glm.vec3{p.dy * sensitivity, p.dx * sensitivity, 0}
		camera_rotate(&camera, delta_rotation)
	case engine.MouseButtonPayload:
		// VS-20 (REQ-GPL-04/05): press esquerdo coloca pedra, direito remove;
		// release não edita. Consome o snapshot da mira central do frame.
		if p.press {
			engine.gameplay_mouse_press(voxel_engine, p.button, engine.physics_body_get(voxel_engine, player_body))
		}
	}
}

@(private)
close_handler :: proc(e: engine.Event) {
	glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
}
