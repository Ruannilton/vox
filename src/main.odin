package main

import "base:runtime"
import "core:log"
import glm "core:math/linalg/glsl"
import "core:os"
import "core:slice"
import "engine"
import vma "shared:vma"
import "vendor:glfw"
import vk "vendor:vulkan"

NUM_FRAMES_IN_FLIGHT :: 2
NUM_SWAP_CHAIN_IMAGES :: NUM_FRAMES_IN_FLIGHT + 1


Globals :: struct {
	global_context:    runtime.Context,
	window:            glfw.WindowHandle,
	vkInstance:        vk.Instance,
	vkDebugMessenger:  vk.DebugUtilsMessengerEXT,
	vkSurface:         vk.SurfaceKHR,
	vkPhysicalDevice:  vk.PhysicalDevice,
	vkDevice:          vk.Device,
	vkQueue:           vk.Queue,
	vkFamilyIndex:     u32,
	frameIndex:        u32,
	vmaAllocator:      vma.Allocator,
	triangleShader:    vk.ShaderModule,
	pipelineLayout:    vk.PipelineLayout,
	graphicsPipeline:  vk.Pipeline,
	timelineSemaphore: vk.Semaphore,
	nextSignalValue:   u64,
	deltaTime:         f32,
}

last_x, last_y: f64
camera: Camera
main :: proc() {
	file_logger, err := os.create("log.txt")
	defer os.close(file_logger)
	if err != nil {
		log.error("Failed to create log file: {}", err)
		return
	}
	file_log := log.create_file_logger(file_logger)
	context.logger = log.create_multi_logger(log.create_console_logger(), file_log)

	engine.CreateEngine()
	defer engine.DestroyEngine()


	camera = camera_create(glm.vec3{0, 0, 30}, glm.vec3{0, -90, 0}, 45.0)
	camera_look_at(&camera, glm.vec3{0, 0, -1})
	projection := glm.mat4Perspective(
		glm.radians(camera.fov),
		f32(engine.app.presentation.width) / f32(engine.app.presentation.height),
		0.1,
		100.0,
	)

	glfw.SetInputMode(engine.app.glfwWindow, glfw.CURSOR, glfw.CURSOR_DISABLED)
	last_x, last_y = glfw.GetCursorPos(engine.app.glfwWindow)

	glfw.SetKeyCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
			context = engine.app.runtimeContext
			speed := f32(1000.0 * engine.app.deltaTime)
			if key == glfw.KEY_W && (action == glfw.PRESS || action == glfw.REPEAT) {
				camera_move(&camera, speed, 0.0)
			} else if key == glfw.KEY_S && (action == glfw.PRESS || action == glfw.REPEAT) {
				camera_move(&camera, -speed, 0.0)
			} else if key == glfw.KEY_A && (action == glfw.PRESS || action == glfw.REPEAT) {
				camera_move(&camera, 0.0, -speed)
			} else if key == glfw.KEY_D && (action == glfw.PRESS || action == glfw.REPEAT) {
				camera_move(&camera, 0.0, speed)
			} else if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
				glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
			}
			log.info("Camera position: {}", camera.position)
		},
	)

	glfw.SetCursorPosCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
			context = engine.app.runtimeContext

			xoffset := f32(xpos - last_x)
			yoffset := f32(last_y - ypos) // Invertido, pois o eixo Y cresce para baixo

			last_x = xpos
			last_y = ypos

			sensitivity: f32 = 0.07
			// A struct Camera define rotation como x: pitch, y: yaw, z: roll
			delta_rotation := glm.vec3{-yoffset * sensitivity, xoffset * sensitivity, 0}

			camera_rotate(&camera, delta_rotation)
		},
	)

	triangle_pipeline := engine.create_triangle_pipeline()
	defer engine.destroy_triangle_pipeline(&triangle_pipeline)

	log.info("Starting main loop")
	for !glfw.WindowShouldClose(engine.app.glfwWindow) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		engine.Update()
		signal_value := engine.WaitTimelineSemaphore()
		view := camera_view(&camera)
		vp := projection * view

		frame_resource := engine.AcquireFrameResource()
		swapchain_frame := engine.AcquireNextImage()


		vk_check(vk.ResetCommandPool(engine.app.vkDevice, frame_resource.vkCommandPool, {}))

		begin_command_info := vk.CommandBufferBeginInfo {
			sType = .COMMAND_BUFFER_BEGIN_INFO,
			flags = {.ONE_TIME_SUBMIT},
		}
		cmd := frame_resource.vkCommandBuffer
		vk_check(vk.BeginCommandBuffer(cmd, &begin_command_info))

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
				srcStageMask = {.ALL_COMMANDS},
				srcAccessMask = {.MEMORY_READ},
				dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
				dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
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
		vk.CmdBeginRendering(cmd, &rendering_info)


		engine.record_triangle_pipeline(&triangle_pipeline, cmd, &vp)

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
		vk_check(vk.EndCommandBuffer(cmd))


		acquire_wait_info := vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = frame_resource.vkAcquireSemaphore,
			stageMask = {.COLOR_ATTACHMENT_OUTPUT},
		}
		semaphore_signals := []vk.SemaphoreSubmitInfo {
			{
				sType = .SEMAPHORE_SUBMIT_INFO,
				semaphore = swapchain_frame.vkPresentSemaphore,
				stageMask = {.ALL_GRAPHICS},
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
			waitSemaphoreInfoCount   = 1,
			pWaitSemaphoreInfos      = &acquire_wait_info,
			signalSemaphoreInfoCount = cast(u32)len(semaphore_signals),
			pSignalSemaphoreInfos    = raw_data(semaphore_signals),
		}
		vk_check(vk.QueueSubmit2(engine.app.queues[.Graphics].queue, 1, &submit_info, {}))

		engine.Present()
	}

	vk_check(vk.DeviceWaitIdle(engine.app.vkDevice))
	log.info("Exiting application")
}
