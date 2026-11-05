package engine

// VS-02-IMPL-06 — Pipeline gráfica mesh/fragment (mesh-only) e gravação do
// draw. CORREÇÃO pós-validação: o payload task→mesh chegava sempre zerado
// neste ambiente (driver NVIDIA 1.4.351), então a seleção de grupos roda num
// builder compute na fila gráfica (voxel_render_prepare, ANTES do render
// pass) que anexa itens de 32 bits numa fila global; o draw é indireto
// (vkCmdDrawMeshTasksIndirectEXT, um comando com x = contagem de itens) e
// cada workgroup lê o seu item por
// SV_GroupID. Layout da VS-00 (graphicsPipelineLayout, push constants de
// 88 B); dynamic rendering com os formatos da swapchain/depth; viewport/
// scissor dinâmicos (REQ-PIPE-04); cullMode NONE — o culling direcional
// acontece no shader por tags (a correção visual de plantas é a ADR-B6,
// adiada).

import "core:log"
import vk "vendor:vulkan"

PUSH_CONSTANT_STAGES_GRAPHICS :: vk.ShaderStageFlags{.MESH_EXT, .FRAGMENT}

voxel_render_pipeline_create :: proc() {
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.MESH_EXT}, module = voxel_gpu.render_shader_module, pName = "build_brick_mesh"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = voxel_gpu.render_shader_module, pName = "shade_voxel"},
	}

	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &app.presentation.format,
		depthAttachmentFormat   = app.depthBuffer.format,
	}

	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {}, // NONE: culling direcional por tags no mesh shader
		lineWidth   = 1.0,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
	}
	blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {.R, .G, .B, .A},
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &blend_attachment,
	}

	vk_check(
		vk.CreateGraphicsPipelines(
			app.vkDevice,
			{},
			1,
			&vk.GraphicsPipelineCreateInfo {
				sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
				pNext               = &rendering_info,
				stageCount          = len(stages),
				pStages             = &stages[0],
				pViewportState      = &viewport_state,
				pRasterizationState = &rasterization,
				pMultisampleState   = &multisample,
				pDepthStencilState  = &depth_stencil,
				pColorBlendState    = &color_blend,
				pDynamicState       = &dynamic_state,
				layout              = app.graphicsPipelineLayout,
			},
			nil,
			&voxel_gpu.mesh_pipeline,
		),
	)
	log.info("Pipeline mesh (mesh-only/fragment) criada")
}

// VS-02 (correção): grava o builder da fila de trabalho ANTES do render pass.
// Sequência por frame no slot do ring: zera o estado (fill de 32 B) →
// barrier transfer→compute → dispatch build_work_queue (1 workgroup por chunk
// visível) → barrier compute→compute → dispatch finalize_work_queue (1
// thread: fecha o x do draw indireto com clamp) → barrier compute→mesh/
// indirect. A reutilização do slot (2 frames atrás) já foi ordenada pela
// espera da timeline gráfica no host — mesma garantia do ring de visíveis.
// VS-03 (E1): o dispatch do apply_voxel_edits (se houver jobs) precede tudo,
// com barreira COMPUTE(write)→COMPUTE(read) — a ocupação/planos/header já
// refletem a edição quando o builder e o mesh leem (mesmo frame).
voxel_render_prepare :: proc(
	cmd: vk.CommandBuffer,
	vp: matrix[4, 4]f32,
	camera_position: [3]f32,
	visible_count: u32,
	frame_index: u32,
	edit_job_count: u32,
) {
	if visible_count == 0 && edit_job_count == 0 do return

	push_constants := VoxelPushConstants {
		view_projection_matrix = vp,
		camera_position        = camera_position,
		visible_chunk_offset   = frame_index * MAXIMUM_VISIBLE_CHUNKS,
		edit_job_offset        = frame_index * MAX_EDIT_JOBS_PER_FLUSH,
	}
	vk.CmdBindDescriptorSets(cmd, .COMPUTE, app.computePipelineLayout, 0, 1, &voxel_gpu.descriptor_set, 0, nil)
	vk.CmdPushConstants(cmd, app.computePipelineLayout, {.COMPUTE}, 0, PUSH_CONSTANTS_SIZE, &push_constants)

	// VS-03 (E1): aplica as edições do flush antes de qualquer leitura da
	// ocupação/planos neste frame.
	if edit_job_count > 0 {
		vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.edit_pipeline)
		vk.CmdDispatch(cmd, edit_job_count, 1, 1)

		edit_barrier := vk.MemoryBarrier2 {
			sType         = .MEMORY_BARRIER_2,
			srcStageMask  = {.COMPUTE_SHADER},
			srcAccessMask = {.SHADER_WRITE},
			dstStageMask  = {.COMPUTE_SHADER},
			dstAccessMask = {.SHADER_READ},
		}
		vk.CmdPipelineBarrier2(
			cmd,
			&vk.DependencyInfo {
				sType               = .DEPENDENCY_INFO,
				memoryBarrierCount  = 1,
				pMemoryBarriers     = &edit_barrier,
			},
		)
	}

	if visible_count == 0 do return

	state_offset := vk.DeviceSize(frame_index * WORK_QUEUE_SLOT_WORDS * size_of(u32))
	vk.CmdFillBuffer(cmd, voxel_gpu.work_queue.handle, state_offset, WORK_QUEUE_STATE_WORDS * 4, 0)

	fill_barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.CLEAR},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.COMPUTE_SHADER},
		dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
		buffer        = voxel_gpu.work_queue.handle,
		offset        = state_offset,
		size          = WORK_QUEUE_STATE_WORDS * 4,
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType                    = .DEPENDENCY_INFO,
			bufferMemoryBarrierCount = 1,
			pBufferMemoryBarriers    = &fill_barrier,
		},
	)

	vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.build_work_queue_pipeline)
	vk.CmdDispatch(cmd, visible_count, 1, 1)

	// builder → finalize: o append_count escrito pelo builder precisa estar
	// visível para a leitura do finalize.
	builder_barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.COMPUTE_SHADER},
		dstAccessMask = {.SHADER_READ},
		buffer        = voxel_gpu.work_queue.handle,
		offset        = state_offset,
		size          = vk.DeviceSize(WORK_QUEUE_SLOT_WORDS * size_of(u32)),
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType                    = .DEPENDENCY_INFO,
			bufferMemoryBarrierCount = 1,
			pBufferMemoryBarriers    = &builder_barrier,
		},
	)

	vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.finalize_work_queue_pipeline)
	vk.CmdDispatch(cmd, 1, 1, 1)

	// finalize/builder → draw: o estado (x,y,z) vira INDIRECT_COMMAND_READ e
	// os itens viram SHADER_READ no estágio mesh.
	draw_barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.DRAW_INDIRECT, .MESH_SHADER_EXT},
		dstAccessMask = {.INDIRECT_COMMAND_READ, .SHADER_READ},
		buffer        = voxel_gpu.work_queue.handle,
		offset        = state_offset,
		size          = vk.DeviceSize(WORK_QUEUE_SLOT_WORDS * size_of(u32)),
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType                    = .DEPENDENCY_INFO,
			bufferMemoryBarrierCount = 1,
			pBufferMemoryBarriers    = &draw_barrier,
		},
	)
}

// Grava o draw indireto dos visíveis dentro do render pass do frame
// (REQ-PIPE-03): UM comando VkDrawMeshTasksIndirectCommandEXT com x =
// min(append_count, capacidade), y = z = 1, produzido pelo finalize (fila
// vazia ⇒ x = 0, no-op). NÃO usar a variante IndirectCount: ela executaria
// `count` comandos de 12 B lidos da região de itens (TDR garantido).
voxel_render_record :: proc(
	cmd: vk.CommandBuffer,
	vp: matrix[4, 4]f32,
	camera_position: [3]f32,
	visible_count: u32,
	frame_index: u32,
) {
	if visible_count == 0 do return

	viewport := vk.Viewport {
		width    = f32(app.presentation.width),
		height   = f32(app.presentation.height),
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	scissor := vk.Rect2D{extent = {app.presentation.width, app.presentation.height}}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

	vk.CmdBindPipeline(cmd, .GRAPHICS, voxel_gpu.mesh_pipeline)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, app.graphicsPipelineLayout, 0, 1, &voxel_gpu.descriptor_set, 0, nil)

	push_constants := VoxelPushConstants {
		view_projection_matrix = vp,
		camera_position        = camera_position,
		visible_chunk_offset   = frame_index * MAXIMUM_VISIBLE_CHUNKS,
	}
	vk.CmdPushConstants(
		cmd,
		app.graphicsPipelineLayout,
		PUSH_CONSTANT_STAGES_GRAPHICS,
		0,
		PUSH_CONSTANTS_SIZE,
		&push_constants,
	)
	state_offset := vk.DeviceSize(frame_index * WORK_QUEUE_SLOT_WORDS * size_of(u32))
	vk.CmdDrawMeshTasksIndirectEXT(
		cmd,
		voxel_gpu.work_queue.handle,
		state_offset + WORK_QUEUE_INDIRECT_X_WORD * 4,
		1,  // um único comando (x = contagem de itens, com clamp do finalize)
		12, // stride = size_of(VkDrawMeshTasksIndirectCommandEXT) = 3 u32
	)
}
