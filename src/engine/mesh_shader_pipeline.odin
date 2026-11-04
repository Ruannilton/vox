package engine

import glm "core:math/linalg/glsl"
import vma "shared:vma"
import vk "vendor:vulkan"

VOXEL_GRID_SIZE :: 16
NUM_VOXELS :: VOXEL_GRID_SIZE * VOXEL_GRID_SIZE * VOXEL_GRID_SIZE
TASK_GROUP_SIZE :: 16
NUM_TASK_GROUPS :: NUM_VOXELS / TASK_GROUP_SIZE

// numthreads(16, 16, 4) do computeNoise
COMPUTE_GROUP_XY :: 16
COMPUTE_GROUP_Z :: 4

#assert(NUM_VOXELS % TASK_GROUP_SIZE == 0)
#assert(VOXEL_GRID_SIZE % COMPUTE_GROUP_XY == 0)
#assert(VOXEL_GRID_SIZE % COMPUTE_GROUP_Z == 0)

MeshShaderRenderSet :: struct {
	using parent:            RenderSet,
	compute_pipeline:           vk.Pipeline,
	voxel_buffer:            vk.Buffer,
	voxel_buffer_allocation: vma.Allocation,
	noise_buffer:            vk.Buffer,
	noise_buffer_allocation: vma.Allocation,
	descriptorSetLayout:     vk.DescriptorSetLayout,
	descriptorPool:          vk.DescriptorPool,
	descriptorSet:           vk.DescriptorSet,
}

VoxelValue :: struct {
	density: u32,
}

@(private = "file")
MeshShaderConstants :: struct {
	mvp:  glm.mat4,
	time: f32,
}

@(private = "file")
allocate_buffer  :: proc($T: typeid, num_elements: u32) -> (buffer: vk.Buffer, allocation: vma.Allocation) {
	chunk_buffer_info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = cast(vk.DeviceSize)(size_of(T) * num_elements),
		usage = {.STORAGE_BUFFER},
	}
	allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = {},
	}
	vk_check(
		vma.CreateBuffer(
			app.vmaAllocator,
			chunk_buffer_info,
			allocation_info,
			&buffer,
			&allocation,
			nil,
		),
	)
	return
}

create_mesh_shader_pipeline :: proc() -> (render_set: MeshShaderRenderSet) {

	voxel_buffer, voxel_buffer_allocation := allocate_buffer(VoxelValue, NUM_VOXELS)
	render_set.voxel_buffer = voxel_buffer
	render_set.voxel_buffer_allocation = voxel_buffer_allocation

	noise_buffer, noise_buffer_allocation := allocate_buffer(u32, NUM_VOXELS)
	render_set.noise_buffer = noise_buffer
	render_set.noise_buffer_allocation = noise_buffer_allocation

	shader_code := load_file("./cube.spv", context.temp_allocator)
	shader_module_create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code),
		pCode    = auto_cast (&shader_code[0]),
	}

	shader_module: vk.ShaderModule
	vk.CreateShaderModule(app.vkDevice, &shader_module_create_info, nil, &shader_module)
	defer vk.DestroyShaderModule(app.vkDevice, shader_module, nil)

	compute_pipeline_shader_stage_create_infos := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.COMPUTE},
			module = shader_module,
			pName = "computeNoise",
		},
	}

	graphic_pipeline_shader_stage_create_infos := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.TASK_EXT},
			module = shader_module,
			pName = "taskMain",
		},
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

	descriptor_set_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &vk.DescriptorSetLayoutBinding {
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE, .TASK_EXT, .MESH_EXT},
		},
	}

	render_set.descriptorSetLayout = vk.DescriptorSetLayout{}
	vk_check(
		vk.CreateDescriptorSetLayout(
			app.vkDevice,
			&descriptor_set_layout_info,
			nil,
			&render_set.descriptorSetLayout,
		),
	)

	// --- INÍCIO DA ALOCAÇÃO DO DESCRIPTOR SET ---
	pool_sizes := []vk.DescriptorPoolSize{
		{type = .STORAGE_BUFFER, descriptorCount = 2},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = cast(u32)len(pool_sizes),
		pPoolSizes    = raw_data(pool_sizes),
		maxSets       = 2,
	}

	vk_check(vk.CreateDescriptorPool(app.vkDevice, &pool_info, nil, &render_set.descriptorPool))

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = render_set.descriptorPool,
		descriptorSetCount = 2,
		pSetLayouts        = &render_set.descriptorSetLayout,
	}

	vk_check(vk.AllocateDescriptorSets(app.vkDevice, &alloc_info, &render_set.descriptorSet))

	buffer_info := []vk.DescriptorBufferInfo {
		{
			buffer = render_set.voxel_buffer,
			offset = 0,
			range  = cast(vk.DeviceSize)vk.WHOLE_SIZE,
		},
		{
			buffer = render_set.noise_buffer,
			offset = 0,
			range  = cast(vk.DeviceSize)vk.WHOLE_SIZE,
		},
	}

	write_descriptor := []vk.WriteDescriptorSet {
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = render_set.descriptorSet,
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo     = &buffer_info[0],
		},
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = render_set.descriptorSet,
			dstBinding      = 1,
			dstArrayElement = 0,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo     = &buffer_info[1],
		},
	}

	vk.UpdateDescriptorSets(app.vkDevice, cast(u32)len(write_descriptor), raw_data(write_descriptor), 0, nil)
	// --- FIM DA ALOCAÇÃO DO DESCRIPTOR SET ---

	pipeline_layout_create_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &render_set.descriptorSetLayout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &vk.PushConstantRange {
			stageFlags = {.TASK_EXT, .MESH_EXT},
			offset = 0,
			size = cast(u32)size_of(MeshShaderConstants),
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
		stageCount          = cast(u32)len(graphic_pipeline_shader_stage_create_infos),
		pStages             = raw_data(graphic_pipeline_shader_stage_create_infos),
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

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = compute_pipeline_shader_stage_create_infos[0],
		layout = render_set.pipelineLayout,
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
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&compute_pipeline_create_info,
			nil,
			&render_set.compute_pipeline,
		),
	)

	return
}

record_compute_shader_pipeline :: proc(
	renderSet: ^MeshShaderRenderSet,
	commandBuffer: vk.CommandBuffer,
	viewProjection: glm.mat4,
){
	constants := MeshShaderConstants {
		mvp  = viewProjection,
		time = f32(app.currentTime),
	}

	vk.CmdPushConstants(
		commandBuffer,
		renderSet.pipelineLayout,
		{.TASK_EXT, .MESH_EXT},
		0,
		cast(u32)size_of(MeshShaderConstants),
		&constants,
	)
	vk.CmdBindPipeline(commandBuffer, .COMPUTE, renderSet.compute_pipeline)


	vk.CmdBindDescriptorSets(
		commandBuffer,
		.COMPUTE,
		renderSet.pipelineLayout,
		0,
		1,
		&renderSet.descriptorSet,
		0,
		nil,
	)

	vk.CmdDispatch(commandBuffer, 1,1,4)
}

record_mesh_shader_pipeline :: proc(
	renderSet: ^MeshShaderRenderSet,
	commandBuffer: vk.CommandBuffer,
	viewProjection: glm.mat4,
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

	constants := MeshShaderConstants {
		mvp  = viewProjection,
		time = f32(app.currentTime),
	}

	vk.CmdPushConstants(
		commandBuffer,
		renderSet.pipelineLayout,
		{.TASK_EXT, .MESH_EXT},
		0,
		cast(u32)size_of(MeshShaderConstants),
		&constants,
	)

	vk.CmdBindPipeline(commandBuffer, .GRAPHICS, renderSet.graphicsPipeline)

	vk.CmdBindDescriptorSets(
		commandBuffer,
		.GRAPHICS,
		renderSet.pipelineLayout,
		0,
		1,
		&renderSet.descriptorSet,
		0,
		nil,
	)

	vk.CmdDrawMeshTasksEXT(commandBuffer, NUM_VOXELS/TASK_GROUP_SIZE, 1, 1)

}

destroy_mesh_shader_pipeline :: proc(render_set: ^MeshShaderRenderSet) {
	vk.DestroyPipelineLayout(app.vkDevice, render_set.pipelineLayout, nil)
	vk.DestroyPipeline(app.vkDevice, render_set.graphicsPipeline, nil)
	vk.DestroyPipeline(app.vkDevice, render_set.compute_pipeline, nil)

	vk.DestroyDescriptorPool(app.vkDevice, render_set.descriptorPool, nil)
	vk.DestroyDescriptorSetLayout(app.vkDevice, render_set.descriptorSetLayout, nil)

	vma.DestroyBuffer(
		app.vmaAllocator,
		render_set.voxel_buffer,
		render_set.voxel_buffer_allocation,
	)
}
