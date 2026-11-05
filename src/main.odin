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

	voxel_engine := engine.ve_init()
	defer engine.ve_destroy(voxel_engine)
	camera = camera_create(glm.vec3{32, 75, 60}, glm.vec3{-50, -90, 0}, 45.0)
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

	glfw.SetKeyCallback(
		engine.app.glfwWindow,
		proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
			context = engine.app.runtimeContext

			if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
				glfw.SetWindowShouldClose(engine.app.glfwWindow, true)
				return
			}
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
			delta_rotation := glm.vec3{yoffset * sensitivity, xoffset * sensitivity, 0}

			camera_rotate(&camera, delta_rotation)
		},
	)

	//mesh_pipeline := engine.create_mesh_shader_pipeline()
	//defer engine.destroy_mesh_shader_pipeline(&mesh_pipeline)

	log.info("Starting main loop")
	for !glfw.WindowShouldClose(engine.app.glfwWindow) {
		free_all(context.temp_allocator)
		glfw.PollEvents()

		engine.Update()
		update_camera_movement(min(f32(engine.app.deltaTime), 0.1))

		engine.ve_update(voxel_engine, camera.position)
		if engine.app.tick == 299 || engine.app.tick == 305 {
			// TEMPORÁRIO (diagnóstico VS-03): decodifica voxels do cenário
			// roteirizado antes (299) e depois (305) do flush do tick 300 —
			// mundo (30,35,30) está dentro da caixa esculpida; (31,53,31) e
			// (33,55,33) dentro do bloco de pedra flutuante.
			locals_c010 := [][3]i32{{30, 3, 30}, {31, 21, 31}}
			engine.debug_readback_decode_voxels(voxel_engine, {0, 1, 0}, locals_c010, "cenario-c010")
			locals_c111 := [][3]i32{{1, 23, 1}}
			engine.debug_readback_decode_voxels(voxel_engine, {1, 1, 1}, locals_c111, "cenario-c111")
		}
		if engine.app.tick == 300 {
			// VS-03 AC-01 (debug): esculpe um cubo de ar cortando a superfície
			// do terreno de ruído (altura 32..47) e ergue um bloco de pedra
			// flutuante acima dele, com flush forçado — a geometria do mesmo
			// frame já reflete a edição.
			engine.ve_request_voxel_edits_in_box(voxel_engine, {26, 28, 26}, {38, 44, 38}, 0)
			engine.ve_request_voxel_edits_in_box(voxel_engine, {30, 52, 30}, {33, 55, 33}, 3)
			voxel_engine.edit.force_next_flush = true
		}
		if engine.app.tick == 310 {
			engine.edit_log_stats(voxel_engine, "DEBUG EDIT (pós-flush):")
		}
		if engine.app.tick == 5 {
			// VS-04 AC-05 (debug): consulta antes da materialização — esperado
			// ok=false (página PENDING/ausente), nunca bloco inventado.
			_, ok_early := engine.voxel_get(voxel_engine, {30, 35, 30})
			log.infof("DEBUG MIRROR (early): voxel_get((30,35,30)) ok={} (esperado: false)", ok_early)
		}
		if engine.app.tick == 305 {
			// VS-04 AC-04/AC-05 (debug): evidências do mirror após a
			// materialização e o flush roteirizado do tick 300 (VS-03).
			engine.mirror_log_stats(voxel_engine, "DEBUG MIRROR:")
			sample_air, ok_air := engine.voxel_get(voxel_engine, {30, 35, 30})
			log.infof(
				"DEBUG MIRROR: voxel (30,35,30) [caixa esculpida] -> id={} solid={} ok={} (esperado: ar)",
				sample_air.block_id,
				sample_air.solid,
				ok_air,
			)
			sample_pillar, ok_pillar := engine.voxel_get(voxel_engine, {31, 53, 31})
			log.infof(
				"DEBUG MIRROR: voxel (31,53,31) [pilar] -> id={} solid={} ok={} (esperado: 3=pedra)",
				sample_pillar.block_id,
				sample_pillar.solid,
				ok_pillar,
			)
			_, ok_far := engine.voxel_get(voxel_engine, {9999, 10, 9999})
			log.infof("DEBUG MIRROR: voxel (9999,10,9999) [fora da bolha] -> ok={} (esperado: false)", ok_far)
			ground, ok_ground := engine.mirror_column_ground(voxel_engine, 32, 32, 70)
			log.infof("DEBUG MIRROR: column_ground(32,32) de y=70 -> y={} ok={}", ground, ok_ground)
			engine.debug_mirror_parity(voxel_engine, {0, 1, 0})
			engine.debug_mirror_parity(voxel_engine, {1, 1, 1})
		}
		if engine.app.tick == 600 {
			engine.mirror_log_stats(voxel_engine, "DEBUG MIRROR (tick 600):")
		}
		if engine.edit_flush_due(voxel_engine) {
			// VS-03 (E1): monta o staging do flush (drena pendências, agrupa
			// por chunk, tetos) antes da espera de frames em voo.
			engine.flush_voxel_edits(voxel_engine)
		}
		if engine.app.tick == 240 {
			// AC-01: readback de debug — decodifica um chunk real e compara
			// com a verdade do worldgen (uma única vez). Tick 240: o streaming
			// já concluiu — no tick 120 a worker podia estar usando o command
			// buffer de compute compartilhado (corrida do harness de debug).
			engine.debug_readback_validate(voxel_engine)
		}

		signal_value := engine.WaitTimelineSemaphore()
		view := camera_view(&camera)
		vp := GL_TO_VK_CLIP * projection * view

		frame_resource := engine.AcquireFrameResource()
		swapchain_frame, acquired := engine.AcquireNextImage()
		if !acquired {
			// Janela minimizada ou swapchain recriada/fora de data: pula o frame
			// e desfaz a reserva da timeline para não abrir lacuna na sequência.
			engine.CancelFrameReservation()
			continue
		}

		// VS-02: reconstrói os visíveis desta posição do ring (o slot já foi
		// liberado pela espera da timeline gráfica acima).
		visible_count := engine.ve_publish_visible(voxel_engine, engine.app.frameIndex)
		// VS-03 (E1): colhe o feedback do slot do ring (2 frames atrás) e
		// copia o staging do flush para o ring deste frame.
		edit_job_count := engine.edit_ring_write(voxel_engine, engine.app.frameIndex)
		if engine.app.tick == 240 {
			// VS-02 AC-04: evidência de que o draw está emitindo trabalho.
			log.infof(
				"DEBUG RENDER: {} chunks visíveis, timeline de compute em {}",
				visible_count,
				voxel_engine.highest_completed_compute_value,
			)
		}


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
	//	engine.record_compute_shader_pipeline(&mesh_pipeline, cmd, vp)
		
		// VS-02 (correção): builder da fila de trabalho roda na fila gráfica ANTES
	// do render pass — o draw indireto consome os resultados via barreiras.
	engine.voxel_render_prepare(cmd, vp, camera.position, visible_count, engine.app.frameIndex, edit_job_count)

	vk.CmdBeginRendering(cmd, &rendering_info)

		engine.voxel_render_record(cmd, vp, camera.position, visible_count, engine.app.frameIndex)

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
		// VS-02 (REQ-VIS-03): o builder (compute na fila gráfica) e o mesh só
		// leem a ocupação após os lotes de compute concluídos sinalizarem a
		// timeline.
		compute_wait_info := vk.SemaphoreSubmitInfo {
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = engine.app.computeTimelineSemaphore,
			value     = voxel_engine.highest_completed_compute_value,
			stageMask = {.COMPUTE_SHADER, .MESH_SHADER_EXT},
		}
		wait_infos := [2]vk.SemaphoreSubmitInfo{acquire_wait_info, compute_wait_info}
		wait_count: u32 = voxel_engine.highest_completed_compute_value > 0 ? 2 : 1
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

		engine.Present()
	}

	vk_check(vk.DeviceWaitIdle(engine.app.vkDevice))
	log.info("Exiting application")
}

update_camera_movement :: proc(dt: f32) {
	window := engine.app.glfwWindow

	speed: f32 = 10.0 // unidades por segundo
	if glfw.GetKey(window, glfw.KEY_LEFT_SHIFT) == glfw.PRESS do speed *= 4

	forward, right: f32
	if glfw.GetKey(window, glfw.KEY_W) == glfw.PRESS do forward += 1
	if glfw.GetKey(window, glfw.KEY_S) == glfw.PRESS do forward -= 1
	if glfw.GetKey(window, glfw.KEY_D) == glfw.PRESS do right += 1
	if glfw.GetKey(window, glfw.KEY_A) == glfw.PRESS do right -= 1

	if forward == 0 && right == 0 do return

	// evita andar mais rápido na diagonal
	if forward != 0 && right != 0 {
		forward *= 0.70710678
		right *= 0.70710678
	}

	camera_move(&camera, forward * speed * dt, right * speed * dt)
}