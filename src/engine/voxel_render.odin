package engine

// VS-02-IMPL-06 — Pipeline gráfica task/mesh/fragment e gravação do draw.
// Layout da VS-00 (graphicsPipelineLayout, push constants de 88 B); dynamic
// rendering com os formatos da swapchain/depth; viewport/scissor dinâmicos
// (REQ-PIPE-04); cullMode NONE — o culling direcional acontece no shader por
// tags (a correção visual de plantas é a ADR-B6, adiada).

import "core:log"
import vk "vendor:vulkan"

PUSH_CONSTANT_STAGES_GRAPHICS :: vk.ShaderStageFlags{.TASK_EXT, .MESH_EXT, .FRAGMENT}

voxel_render_pipeline_create :: proc() {
	stages := [3]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.TASK_EXT}, module = voxel_gpu.shader_module, pName = "select_bricks"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.MESH_EXT}, module = voxel_gpu.shader_module, pName = "build_brick_mesh"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = voxel_gpu.shader_module, pName = "shade_voxel"},
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
	log.info("Pipeline mesh (task/mesh/fragment) criada")
}

// Grava o draw dos visíveis dentro do render pass do frame (REQ-PIPE-03).
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
	vk.CmdDrawMeshTasksEXT(cmd, visible_count, 1, 1)
}
