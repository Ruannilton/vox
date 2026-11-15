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


camera: Camera
voxel_engine: ^engine.VoxelEngine


player_body: engine.PhysicsHandle
space_pressed:     bool
jump_tracking:     bool
jump_base_y:       f32
jump_apex_y:       f32

debug_light_mode:  u32 = 0
torch_enabled:     bool = true
PLAYER_SIZE :: glm.vec3{0.6, 2, 0.6}
PLAYER_HALF_WIDTH :: f32(0.3)
PLAYER_EYE_HEIGHT :: f32(2)
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

	
	engine.events_init()
	defer engine.events_destroy()

	engine.config_load()
	engine.assets_load()
	
	engine.CreateEngine()
	defer engine.DestroyEngine()

	engine.TracingStartup()
	defer engine.TracingShutdown()

	voxel_engine = engine.voxel_engine_init()

	camera = camera_create(glm.vec3{32, 75, 60}, glm.vec3{-50, -90, 0}, 45.0)
	
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

	GL_TO_VK_CLIP :: matrix[4, 4]f32{
		1, 0, 0, 0,
		0, -1, 0, 0,
		0, 0, 0.5, 0.5,
		0, 0, 0, 1,
	}

	glfw.SetInputMode(engine.app.glfwWindow, glfw.CURSOR, glfw.CURSOR_DISABLED)
	
	engine.setup_glfw_callbacks()
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

	engine.events_reset_clock()

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
			
				engine.physics_tick(voxel_engine, frame_dt)
				player_track_jump_apex()
				player_sync_camera()
		
				engine.gameplay_update_target(voxel_engine, engine.app.frameIndex, camera.position, camera.direction)
				engine.light_update_globals(voxel_engine, engine.app.frameIndex, camera.position, debug_light_mode, torch_enabled)

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
				{
					engine.ZoneN("wait_timeline")
					signal_value = engine.WaitTimelineSemaphore()
					engine.telemetry_collect_graphics(engine.app.frameIndex)
					engine.tracing_gpu_collect_graphics()
					view := camera_view(&camera)
					vp = GL_TO_VK_CLIP * projection * view
				}

				{
					engine.ZoneN("acquire_image")
					frame_resource = engine.AcquireFrameResource()
					acquired: bool
					swapchain_frame, acquired = engine.AcquireNextImage()
					if !acquired {
						engine.CancelFrameReservation()
						continue
					}
				}

		
				{
					engine.ZoneN("publish_visible")
					visible_count = engine.voxel_engine_wait_published(voxel_engine, signal_value, engine.chunk_coordinate_from_world(camera.position))
					compute_wait_value = voxel_engine.published_compute_value
				}
				{
					engine.ZoneN("edit_flush")
					edit_job_count = engine.edit_ring_write(voxel_engine, engine.app.frameIndex)
				}

				
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

			engine.voxel_render_prepare(
				cmd,
				vp,
				camera.position,
				visible_count,
				engine.app.frameIndex,
				edit_job_count,
			)

			engine.voxel_render_record(cmd, vp, camera.position, visible_count, engine.app.frameIndex, swapchain_frame)

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

	rad_yaw := glm.radians(camera.rotation.y)
	forward := glm.vec3{glm.cos(rad_yaw), 0, glm.sin(rad_yaw)}
	right := glm.vec3{-glm.sin(rad_yaw), 0, glm.cos(rad_yaw)}
	wish := forward * forward_input + right * right_input

	body.velocity.x = wish.x * speed
	body.velocity.z = wish.z * speed
}


@(private)
player_track_jump_apex :: proc() {
	body := engine.physics_body_get(voxel_engine, player_body)
	if body == nil do return
	if !jump_tracking {
		if voxel_engine.gameplay.stats_jumps > 0 &&
		   voxel_engine.gameplay.stats_jumps != voxel_engine.gameplay.stats_jumps_logged &&
		   !body.grounded {
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
		switch p.key {
		case glfw.KEY_ESCAPE:
			engine.events_emit(.CloseRequested, struct {}{})
		case glfw.KEY_F8:
			engine.telemetry_toggle()
		case glfw.KEY_F9:
			engine.telemetry_snapshot()
		case glfw.KEY_F7:
			
			engine.debug_validate_run(voxel_engine)
			engine.debug_heights_parity(voxel_engine)
		case glfw.KEY_F5:
			
			debug_light_mode = (debug_light_mode + 1) % 4
			log.infof("VS-23 DEBUG modo {}", debug_light_mode)
		case glfw.KEY_F6:
			torch_enabled = !torch_enabled
			log.infof("VS-23 tocha dinâmica {}", "ON" if torch_enabled else "OFF")
		case glfw.KEY_SPACE:
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
		delta_rotation := glm.vec3{p.dy * sensitivity, p.dx * sensitivity, 0}
		camera_rotate(&camera, delta_rotation)
	case engine.MouseButtonPayload:
		if p.press {
			engine.gameplay_mouse_press(voxel_engine, p.button, engine.physics_body_get(voxel_engine, player_body))
		}
	}
}

@(private)
close_handler :: proc(e: engine.Event) {
	glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
}
