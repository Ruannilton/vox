package engine

import glm "core:math/linalg/glsl"
import vk "vendor:vulkan"

create_mesh_shader_pipeline :: proc() -> (render_set: RenderSet) {
	shader_code := load_file("./cube.spv", context.temp_allocator)
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code),
		pCode    = auto_cast (&shader_code[0]),
	}

    shader_module: vk.ShaderModule
    vk.CreateShaderModule(app.vkDevice, &shader_module_create_info, nil, &shader_module)
    defer vk.DestroyShaderModule(app.vkDevice, shader_module, nil)

    pipeline_shader_stage_create_infos := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.MESH_EXT},
			module = shader_module,
			pName = "meshMain",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
			pName = "fragmentMain",
		},
	}

    pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &vk.PushConstantRange {
			stageFlags = {.MESH_EXT},
			offset = 0,
			size = cast(u32)size_of(glm.mat4),
		},
	}
	vk_check(
		vk.CreatePipelineLayout(
			app.vkDevice,
			&pipeline_layout_create_info,
			nil,
			&render_set.pipelineLayout,
		),
	)
    
    dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_create_infos := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = cast(u32)len(dynamic_states),
		pDynamicStates    = raw_data(dynamic_states),
	}
	rasterization_state_create_info := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {.BACK},
		frontFace   = .CLOCKWISE,
		lineWidth   = 1.0,
	}

	color_blending_state_create_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
			blendEnable = false,
		},
	}

	view_port_state_create_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	multisample_state_create_info := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}


	pipeline_rendering_create_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &app.presentation.format,
		depthAttachmentFormat   = app.depthBuffer.format,
	}

    depth_stencil_state_create_info := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		depthBoundsTestEnable = false,
		stencilTestEnable     = false,
	}

	graphics_pipeline_create_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = cast(u32)len(pipeline_shader_stage_create_infos),
		pStages             = raw_data(pipeline_shader_stage_create_infos),
		pViewportState      = &view_port_state_create_info,
		pRasterizationState = &rasterization_state_create_info,
		pMultisampleState   = &multisample_state_create_info,
		pColorBlendState    = &color_blending_state_create_info,
		pDynamicState       = &dynamic_state_create_infos,
		layout              = render_set.pipelineLayout,
		pNext               = &pipeline_rendering_create_info,
		pVertexInputState   = nil,
		pInputAssemblyState = nil,
		pDepthStencilState  = &depth_stencil_state_create_info,
		renderPass          = {},
	}

	vk_check(
		vk.CreateGraphicsPipelines(
			app.vkDevice,
			{},
			1,
			&graphics_pipeline_create_info,
			nil,
			&render_set.graphicsPipeline,
		),
	)

	return
}

record_mesh_shader_pipeline :: proc(
	renderSet: ^RenderSet,
	commandBuffer: vk.CommandBuffer,
	viewProjection: ^glm.mat4,
) {

	view_port := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(app.presentation.width),
		height   = f32(app.presentation.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(commandBuffer, 0, 1, &view_port)

	scissor := vk.Rect2D {
		offset = {0, 0},
		extent = {app.presentation.width, app.presentation.height},
	}
	vk.CmdSetScissor(commandBuffer, 0, 1, &scissor)

	// draw
	vk.CmdPushConstants(
		commandBuffer,
		renderSet.pipelineLayout,
		{.MESH_EXT},
		0,
		cast(u32)size_of(glm.mat4),
		raw_data(viewProjection),
	)
	vk.CmdBindPipeline(commandBuffer, .GRAPHICS, renderSet.graphicsPipeline)
	vk.CmdDrawMeshTasksEXT(commandBuffer, 1, 1, 1)

}

destroy_mesh_shader_pipeline :: proc(render_set: ^RenderSet) {
	vk.DestroyPipelineLayout(app.vkDevice, render_set.pipelineLayout, nil)
	vk.DestroyPipeline(app.vkDevice, render_set.graphicsPipeline, nil)
}