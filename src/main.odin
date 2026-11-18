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



voxel_engine: ^engine.VoxelEngine

// Referência global do jogador por ora (refatoração de ownership fica para
// depois): o estado do player (câmera + corpo físico) mora em engine.player.
player: engine.Player

debug_light_mode:  u32 = 0
torch_enabled:     bool = true

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
	player = engine.player_create(voxel_engine, glm.vec3{32, 75, 60})

	
	

	
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
					engine.player_set_position(&player, p.v)
					engine.gameplay_clear_target(voxel_engine)
				} else {
					engine.camera_look_at(&player.camera, p.v)
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
	engine.voxel_engine_set_view_camera(voxel_engine, &player.camera)
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
				engine.player_update(&player, frame_dt)

				engine.physics_tick(voxel_engine, frame_dt)
				engine.player_track_jump_apex(&player, voxel_engine)
				engine.player_sync_camera(&player)

				engine.gameplay_upate()
				engine.gameplay_update_target(voxel_engine, engine.app.frameIndex, player.camera.position, player.camera.direction)
				engine.light_update_globals(voxel_engine, engine.app.frameIndex, player.camera.position, debug_light_mode, torch_enabled)

				engine.voxel_engine_request_frame(voxel_engine, engine.app.currentTimelineValue, engine.app.frameIndex, engine.chunk_coordinate_from_world(player.camera.position))
			}

			signal_value: u64
			visible_count: u32
			edit_job_count: u32
			compute_wait_value: u64
			frame_resource: ^engine.FrameResource
			swapchain_frame: engine.SwapChainFrameData
			
			cmd: vk.CommandBuffer
			{
				engine.ZoneN("frame_wait")
				{
					engine.ZoneN("wait_timeline")
					signal_value = engine.WaitTimelineSemaphore()
					engine.telemetry_collect_graphics(engine.app.frameIndex)
					engine.tracing_gpu_collect_graphics()
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
					visible_count = engine.voxel_engine_wait_published(voxel_engine, signal_value, engine.chunk_coordinate_from_world(player.camera.position))
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
				player.camera.position,
				visible_count,
				engine.app.frameIndex,
				edit_job_count,
			)

			engine.voxel_render_record(cmd,  player.camera.position, visible_count, engine.app.frameIndex, swapchain_frame)

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
		player.camera.position.x, player.camera.position.y, player.camera.position.z,
		player.camera.target.x, player.camera.target.y, player.camera.target.z,
	)
	engine.edit_log_stats(voxel_engine, "FINAL edits:")
	log.info("Exiting application")
	if !engine.full_teardown {
		engine.TracingShutdown(false)
		log.info("fast-exit: teardown Vulkan pulado (SO reclaim; use --full-teardown para teardown completo)")
		os.exit(0)
	}

	engine.player_destroy(voxel_engine, &player)
	engine.voxel_engine_destroy(voxel_engine)
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
			engine.player_on_space(&player, voxel_engine, true)
		}
	case .KeyRelease:
		if p.key == glfw.KEY_SPACE {
			engine.player_on_space(&player, voxel_engine, false)
		}
	}
}

@(private)
mouse_handler :: proc(e: engine.Event) {
	#partial switch p in e.payload {
	case engine.MouseMovePayload:
		engine.player_on_mouse_move(&player, p.dx, p.dy)
	case engine.MouseButtonPayload:
		engine.player_on_mouse_button(&player, voxel_engine, p.button, p.press)
	}
}

@(private)
close_handler :: proc(e: engine.Event) {
	glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
}
