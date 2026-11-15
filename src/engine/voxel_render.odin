package engine

import "core:log"
import vk "vendor:vulkan"

PUSH_CONSTANT_STAGES_GRAPHICS :: vk.ShaderStageFlags{.MESH_EXT, .FRAGMENT}

voxel_render_pipeline_create :: proc() {
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.MESH_EXT}, module = voxel_gpu.render_shader_module, pName = "build_brick_mesh"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = voxel_gpu.render_shader_module, pName = "shade_voxel"},
	}
	prepass_stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.MESH_EXT}, module = voxel_gpu.render_shader_module, pName = "build_brick_mesh"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = voxel_gpu.render_shader_module, pName = "depth_prepass"},
	}

	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &app.presentation.format,
		depthAttachmentFormat   = app.depthBuffer.format,
	}
	// VS-23/T1.3: pre-pass de profundidade sem color attachment.
	prepass_rendering_info := vk.PipelineRenderingCreateInfo {
		sType                 = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount  = 0,
		pColorAttachmentFormats = nil,
		depthAttachmentFormat = app.depthBuffer.format,
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

	prepass_depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = true,
		depthCompareOp   = .LESS,
	}
	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = true,
		depthWriteEnable = false,
		depthCompareOp   = .LESS_OR_EQUAL,
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
				pNext               = &prepass_rendering_info,
				stageCount          = len(prepass_stages),
				pStages             = &prepass_stages[0],
				pViewportState      = &viewport_state,
				pRasterizationState = &rasterization,
				pMultisampleState   = &multisample,
				pDepthStencilState  = &prepass_depth_stencil,
				pColorBlendState    = nil,
				pDynamicState       = &dynamic_state,
				layout              = app.graphicsPipelineLayout,
			},
			nil,
			&voxel_gpu.mesh_prepass_pipeline,
		),
	)
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
	log.info("Pipelines mesh criadas (depth pre-pass + pass principal)")
}

voxel_render_prepare :: proc(
	cmd: vk.CommandBuffer,
	vp: matrix[4, 4]f32,
	camera_position: [3]f32,
	visible_count: u32,
	frame_index: u32,
	edit_job_count: u32,
) {

	light_job_count := active_ve.light_job_counts[int(frame_index % config.frames_in_flight)]
	if visible_count == 0 && edit_job_count == 0 && light_job_count == 0 do return

	push_constants := VoxelPushConstants {
		view_projection_matrix = vp,
		camera_position        = camera_position,
		visible_chunk_offset   = frame_index * config.visible_capacity,
		edit_job_offset        = frame_index * MAX_EDIT_JOBS_PER_FLUSH,
		visible_chunk_capacity = config.visible_capacity,
	}

	dynamic_offsets := [2]u32{0, 0}
	vk.CmdBindDescriptorSets(cmd, .COMPUTE, app.computePipelineLayout, 0, 1, &voxel_gpu.descriptor_set, 2, &dynamic_offsets[0])
	vk.CmdPushConstants(cmd, app.computePipelineLayout, {.COMPUTE}, 0, PUSH_CONSTANTS_SIZE, &push_constants)

	if edit_job_count > 0 {
		tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_GRAPHICS)

		gfx_pool := telemetry.gfx_pools[frame_index]
		telemetry_timestamp_begin(cmd, gfx_pool, 2)
		telemetry_begin_label(cmd, "apply_voxel_edits")
		ZoneN("apply_edits_record")
		apply_edits_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "apply_edits")
		vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.edit_pipeline)
		vk.CmdDispatch(cmd, edit_job_count, 1, 1)
		tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, apply_edits_query)
		telemetry_end_label(cmd)
		telemetry_timestamp_end(cmd, gfx_pool, 3)
	}

	if light_job_count > 0 {

		ZoneN("light.relight_record")
		tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_GRAPHICS)
		vk.CmdPushConstants(
			cmd,
			app.computePipelineLayout,
			{.COMPUTE},
			0,
			PUSH_CONSTANTS_SIZE,
			&VoxelPushConstants {
				batch_job_offset       = u32(int(frame_index % config.frames_in_flight) * MAX_LIGHT_JOBS_PER_FLUSH),
				visible_chunk_capacity = config.visible_capacity,
			},
		)
		seed_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "light.seed")
		vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.light_seed_pipeline)
		vk.CmdDispatch(cmd, 4, 4, 4 * light_job_count)
		tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, seed_query)
		light_barrier := vk.MemoryBarrier2 {
			sType         = .MEMORY_BARRIER_2,
			srcStageMask  = {.COMPUTE_SHADER},
			srcAccessMask = {.SHADER_WRITE},
			dstStageMask  = {.COMPUTE_SHADER},
			dstAccessMask = {.SHADER_READ, .SHADER_WRITE},
		}
		vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo{sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &light_barrier})
		for pass in 0 ..< LIGHT_PROPAGATION_PASSES {
			propagate_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "light.propagate")
			vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.light_propagate_pipeline)
			vk.CmdDispatch(cmd, 4, 4, 4 * light_job_count)
			tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, propagate_query)
			if pass < LIGHT_PROPAGATION_PASSES - 1 {
				vk.CmdPipelineBarrier2(cmd, &vk.DependencyInfo{sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &light_barrier})
			}
		}

		vk.CmdPushConstants(cmd, app.computePipelineLayout, {.COMPUTE}, 0, PUSH_CONSTANTS_SIZE, &push_constants)
	}

	if edit_job_count > 0 || light_job_count > 0 {

		tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_GRAPHICS)
		edit_barrier := vk.MemoryBarrier2 {
			sType         = .MEMORY_BARRIER_2,
			srcStageMask  = {.COMPUTE_SHADER},
			srcAccessMask = {.SHADER_WRITE},
			dstStageMask  = {.COMPUTE_SHADER, .FRAGMENT_SHADER},
			dstAccessMask = {.SHADER_READ},
		}
		ZoneN("barriers_record")
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

	if edit_job_count == 0 && light_job_count == 0 {
		tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_GRAPHICS)
	}

	state_offset := vk.DeviceSize(frame_index * config.work_queue_slot_words * size_of(u32))
	vk.CmdFillBuffer(cmd, voxel_gpu.work_queue.handle, state_offset, WORK_QUEUE_STATE_WORDS * 4, 0)

	ZoneN("barriers_record")
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

	telemetry_timestamp_begin(cmd, telemetry.gfx_pools[frame_index], 4)
	telemetry_begin_label(cmd, "build_work_queue")
	ZoneN("builder_record")
	builder_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "build_work_queue")
	vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.build_work_queue_pipeline)
	vk.CmdDispatch(cmd, visible_count, 1, 1)
	tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, builder_query)
	telemetry_end_label(cmd)
	telemetry_timestamp_end(cmd, telemetry.gfx_pools[frame_index], 5)

	builder_barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.COMPUTE_SHADER},
		dstAccessMask = {.SHADER_READ},
		buffer        = voxel_gpu.work_queue.handle,
		offset        = state_offset,
		size          = vk.DeviceSize(config.work_queue_slot_words * size_of(u32)),
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType                    = .DEPENDENCY_INFO,
			bufferMemoryBarrierCount = 1,
			pBufferMemoryBarriers    = &builder_barrier,
		},
	)

	telemetry_timestamp_begin(cmd, telemetry.gfx_pools[frame_index], 6)
	telemetry_begin_label(cmd, "finalize_work_queue")
	ZoneN("finalize_record")
	finalize_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "finalize_work_queue")
	vk.CmdBindPipeline(cmd, .COMPUTE, voxel_gpu.finalize_work_queue_pipeline)
	vk.CmdDispatch(cmd, 1, 1, 1)
	tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, finalize_query)
	telemetry_end_label(cmd)
	telemetry_timestamp_end(cmd, telemetry.gfx_pools[frame_index], 7)

	draw_barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.DRAW_INDIRECT, .MESH_SHADER_EXT},
		dstAccessMask = {.INDIRECT_COMMAND_READ, .SHADER_READ},
		buffer        = voxel_gpu.work_queue.handle,
		offset        = state_offset,
		size          = vk.DeviceSize(config.work_queue_slot_words * size_of(u32)),
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


voxel_render_record :: proc(
	cmd: vk.CommandBuffer,
	vp: matrix[4, 4]f32,
	camera_position: [3]f32,
	visible_count: u32,
	frame_index: u32,
	swapchain_frame: SwapChainFrameData,
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

	// VS-20/VS-23: offsets dinâmicos dos UBOs (21 realce, 25 luz) do frame.
	highlight_offset := u32(voxel_gpu.target_highlight_alignment) * frame_index
	light_offset := u32(voxel_gpu.light_globals_alignment) * frame_index
	dynamic_offsets := [2]u32{highlight_offset, light_offset}
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, app.graphicsPipelineLayout, 0, 1, &voxel_gpu.descriptor_set, 2, &dynamic_offsets[0])

	push_constants := VoxelPushConstants {
		view_projection_matrix = vp,
		camera_position        = camera_position,
		visible_chunk_offset   = frame_index * config.visible_capacity,
		visible_chunk_capacity = config.visible_capacity,
	}
	vk.CmdPushConstants(
		cmd,
		app.graphicsPipelineLayout,
		PUSH_CONSTANT_STAGES_GRAPHICS,
		0,
		PUSH_CONSTANTS_SIZE,
		&push_constants,
	)
	state_offset := vk.DeviceSize(frame_index * config.work_queue_slot_words * size_of(u32))

	telemetry_timestamp_begin(cmd, telemetry.gfx_pools[frame_index], 8)
	// ---- depth pre-pass: mesmo mesh shader, sem color attachment ----
	prepass_depth_attachment := vk.RenderingAttachmentInfo {
		sType              = .RENDERING_ATTACHMENT_INFO,
		imageView          = app.depthBuffer.vkImageView,
		imageLayout        = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp             = .CLEAR,
		storeOp              = .STORE,
		clearValue         = {depthStencil = {depth = 1, stencil = 0}},
	}
	prepass_info := vk.RenderingInfo {
		sType              = .RENDERING_INFO,
		renderArea         = {offset = {0, 0}, extent = {app.presentation.width, app.presentation.height}},
		layerCount         = 1,
		colorAttachmentCount = 0,
		pColorAttachments  = nil,
		pDepthAttachment   = &prepass_depth_attachment,
	}
	vk.CmdBeginRendering(cmd, &prepass_info)
	telemetry_begin_label(cmd, "depth_prepass")
	prepass_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "depth_prepass")
	vk.CmdBindPipeline(cmd, .GRAPHICS, voxel_gpu.mesh_prepass_pipeline)
	vk.CmdDrawMeshTasksIndirectEXT(
		cmd,
		voxel_gpu.work_queue.handle,
		state_offset + WORK_QUEUE_INDIRECT_X_WORD * 4,
		1,
		12,
	)
	tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, prepass_query)
	telemetry_end_label(cmd)
	vk.CmdEndRendering(cmd)

	// ---- pass principal: cor + profundidade do pre-pass (load, <=) ----
	color_attachment := vk.RenderingAttachmentInfo {
		sType              = .RENDERING_ATTACHMENT_INFO,
		imageView          = swapchain_frame.image_view,
		imageLayout        = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp             = .CLEAR,
		storeOp              = .STORE,
		clearValue         = {color = {float32 = {0, 0.2, 0.8, 1}}},
	}
	depth_attachment := vk.RenderingAttachmentInfo {
		sType              = .RENDERING_ATTACHMENT_INFO,
		imageView          = app.depthBuffer.vkImageView,
		imageLayout        = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp             = .LOAD,
		storeOp              = .DONT_CARE,
	}
	rendering_info := vk.RenderingInfo {
		sType              = .RENDERING_INFO,
		renderArea         = {offset = {0, 0}, extent = {app.presentation.width, app.presentation.height}},
		layerCount         = 1,
		colorAttachmentCount = 1,
		pColorAttachments  = &color_attachment,
		pDepthAttachment   = &depth_attachment,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)
	telemetry_begin_label(cmd, "render_pass")
	ZoneN("mesh_draw_record")
	draw_query := tracing_gpu_zone_begin(cmd, TRACING_GPU_CONTEXT_GRAPHICS, "draw_mesh")
	vk.CmdBindPipeline(cmd, .GRAPHICS, voxel_gpu.mesh_pipeline)
	vk.CmdDrawMeshTasksIndirectEXT(
		cmd,
		voxel_gpu.work_queue.handle,
		state_offset + WORK_QUEUE_INDIRECT_X_WORD * 4,
		1,
		12,
	)
	tracing_gpu_zone_end(cmd, TRACING_GPU_CONTEXT_GRAPHICS, draw_query)
	telemetry_end_label(cmd)
	vk.CmdEndRendering(cmd)
	telemetry_timestamp_end(cmd, telemetry.gfx_pools[frame_index], 9)
}
