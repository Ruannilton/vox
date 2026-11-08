package engine


import "core:log"
import "core:mem"
import vma "shared:vma"
import vk "vendor:vulkan"

BLOCK_REGISTRY_CAPACITY :: 256
MESH_TEMPLATE_CAPACITY :: 256
BUILTIN_CUBE_VERTICES :: [8][3]f32 {
	{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
	{0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1},
}

BUILTIN_CUBE_TRIANGLES :: [12][4]u32 {
	{1, 3, 7, 0}, {1, 7, 5, 0}, // +X
	{0, 4, 6, 1}, {0, 6, 2, 1}, // -X
	{2, 7, 3, 2}, {2, 6, 7, 2}, // +Y
	{0, 1, 5, 3}, {0, 5, 4, 3}, // -Y
	{4, 5, 7, 4}, {4, 7, 6, 4}, // +Z
	{0, 3, 1, 5}, {0, 2, 3, 5}, // -Z
}

BUILTIN_PLANT_VERTICES :: [8][3]f32 {
	{0, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 0}, // quad diagonal 1
	{1, 0, 0}, {0, 0, 1}, {0, 1, 1}, {1, 1, 0}, // quad diagonal 2
}

BUILTIN_PLANT_TRIANGLES :: [4][4]u32 {
	{0, 1, 2, CULL_FACE_NEVER}, {0, 2, 3, CULL_FACE_NEVER},
	{4, 5, 6, CULL_FACE_NEVER}, {4, 6, 7, CULL_FACE_NEVER},
}

VoxelGpu :: struct {
	scratch:                GpuBuffer,
	generation_jobs:        GpuBuffer,
	generation_jobs_mapped: [^]ChunkGenerationJob,
	occupancy_pool:         GpuBuffer,
	material_plane_pool:    GpuBuffer,
	chunk_headers:          GpuBuffer,
	special_voxel_records:  GpuBuffer,
	block_registry:         GpuBuffer,
	visible_chunks:         GpuBuffer,
	visible_chunks_mapped:  [^]VisibleChunk,
	mesh_templates:         GpuBuffer,
	template_vertices:      GpuBuffer,
	template_triangles:     GpuBuffer,
	// VS-11 (REQ-UV-02): pool de UVs dos templates (binding 19), paralelo a
	// template_vertices e indexado por MeshTemplate.uv_offset.
	template_uvs:           GpuBuffer,
	work_queue:             GpuBuffer,
	edit_jobs:              GpuBuffer,
	edit_jobs_mapped:       [^]EditChunkJob,
	voxel_edits:            GpuBuffer,
	voxel_edits_mapped:     [^]u32,
	edit_results:           GpuBuffer,
	edit_results_mapped:    [^]u32,
	mirror_export_ring:        GpuBuffer,
	mirror_export_ring_mapped: [^]u16,
	// VS-13 (REQ-MIR-01): ring paralelo do heightmap (binding 20) — mesmo
	// índice de slot do ring denso; 1.024 u16 por slot (2 KiB).
	mirror_heightmap_ring:        GpuBuffer,
	mirror_heightmap_ring_mapped: [^]u16,
	// VS-10 (REQ-VRT-02): flags do pack por slot (binding 18, host-visible).
	chunk_result_flags:        GpuBuffer,
	chunk_result_flags_mapped: [^]u32,
	target_highlight_ubo:        GpuBuffer,
	target_highlight_ubo_mapped: [^]u8,
	target_highlight_alignment:  vk.DeviceSize, // stride do slot (>= minUniformBufferOffsetAlignment)
	dummy_buffer:           GpuBuffer,
	albedo_palette_image:      vk.Image,
	albedo_palette_allocation: vma.Allocation,
	albedo_palette_view:       vk.ImageView,
	pbr_dummy_image:           vk.Image,
	pbr_dummy_allocation:      vma.Allocation,
	pbr_dummy_view:            vk.ImageView,
	texture_sampler:           vk.Sampler,

	descriptor_pool:        vk.DescriptorPool,
	descriptor_set:         vk.DescriptorSet,

	shader_module:          vk.ShaderModule,
	edit_shader_module:     vk.ShaderModule,
	render_shader_module:   vk.ShaderModule,
	generation_pipeline:    vk.Pipeline,
	packing_pipeline:       vk.Pipeline,

	build_work_queue_pipeline:    vk.Pipeline,
	finalize_work_queue_pipeline: vk.Pipeline,
	edit_pipeline:                vk.Pipeline,
	mesh_pipeline:          vk.Pipeline,

	compute_command_pool:    vk.CommandPool,
	compute_command_buffers: []vk.CommandBuffer, // [batches_in_flight] (VS-08)
}

voxel_gpu: VoxelGpu

voxel_gpu_init :: proc() {
	log.info("Inicializando recursos GPU do voxel engine")

	// VS-08 (REQ-CFG-05): command buffers dimensionados pelo Config.
	voxel_gpu.compute_command_buffers = make([]vk.CommandBuffer, config.batches_in_flight)

	vk_check(
		vk.CreateCommandPool(
			app.vkDevice,
			&vk.CommandPoolCreateInfo {
				sType            = .COMMAND_POOL_CREATE_INFO,
				queueFamilyIndex = app.queues[.Compute].familyIndex,
				flags            = {.TRANSIENT, .RESET_COMMAND_BUFFER},
			},
			nil,
			&voxel_gpu.compute_command_pool,
		),
	)
	vk_check(
		vk.AllocateCommandBuffers(
			app.vkDevice,
			&vk.CommandBufferAllocateInfo {
				sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool        = voxel_gpu.compute_command_pool,
				level              = .PRIMARY,
				commandBufferCount = u32(len(voxel_gpu.compute_command_buffers)),
			},
			&voxel_gpu.compute_command_buffers[0],
		),
	)

	// --- buffers (VS-08/REQ-CFG-05: tamanhos derivados do Config) ---
	voxel_gpu.scratch = gpu_buffer_create(
		vk.DeviceSize(config.scratch_chunks * CHUNK_VOXEL_COUNT * size_of(u32)),
		{.STORAGE_BUFFER},
	)
	mapped_jobs: rawptr
	voxel_gpu.generation_jobs, mapped_jobs = gpu_buffer_create_host(
		vk.DeviceSize(config.scratch_chunks * size_of(ChunkGenerationJob)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.generation_jobs_mapped = cast([^]ChunkGenerationJob)mapped_jobs

	voxel_gpu.occupancy_pool = gpu_buffer_create(
		vk.DeviceSize(config.resident_slots * OCCUPANCY_WORDS_PER_CHUNK * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
	)
	voxel_gpu.material_plane_pool = gpu_buffer_create(
		vk.DeviceSize(config.resident_slots * MATERIAL_WORDS_PER_CHUNK * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_SRC},
	)
	voxel_gpu.chunk_headers = gpu_buffer_create(
		vk.DeviceSize(config.resident_slots * size_of(ChunkHeader)),
		{.STORAGE_BUFFER, .TRANSFER_SRC},
	)
	voxel_gpu.special_voxel_records = gpu_buffer_create(
		vk.DeviceSize(config.resident_slots * SPECIAL_RECORDS_PER_CHUNK * size_of(SpecialVoxelRecord)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.block_registry = gpu_buffer_create(
		vk.DeviceSize(BLOCK_REGISTRY_CAPACITY * size_of(BlockDefinition)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)

	visible_mapped: rawptr
	voxel_gpu.visible_chunks, visible_mapped = gpu_buffer_create_host(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * config.visible_capacity * size_of(VisibleChunk)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.visible_chunks_mapped = cast([^]VisibleChunk)visible_mapped
	voxel_gpu.mesh_templates = gpu_buffer_create(
		vk.DeviceSize(MESH_TEMPLATE_CAPACITY * size_of(MeshTemplate)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	voxel_gpu.template_vertices = gpu_buffer_create(
		vk.DeviceSize(1024 * 4 * size_of(f32)), // stride 16 B (std430 float4)
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
	)
	voxel_gpu.template_triangles = gpu_buffer_create(
		vk.DeviceSize(1024 * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	// VS-11 (REQ-UV-02): 1 float2 por vértice de template (stride 8 B std430).
	voxel_gpu.template_uvs = gpu_buffer_create(
		vk.DeviceSize(1024 * 2 * size_of(f32)),
		// VS-12: TRANSFER_SRC para o readback de validação (debug_readback_validate)
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
	)

	voxel_gpu.work_queue = gpu_buffer_create(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * config.work_queue_slot_words * size_of(u32)),
		{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST, .TRANSFER_SRC},
	)

	mapped_edit_jobs: rawptr
	voxel_gpu.edit_jobs, mapped_edit_jobs = gpu_buffer_create_host(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * MAX_EDIT_JOBS_PER_FLUSH * size_of(EditChunkJob)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.edit_jobs_mapped = cast([^]EditChunkJob)mapped_edit_jobs
	mapped_voxel_edits: rawptr
	voxel_gpu.voxel_edits, mapped_voxel_edits = gpu_buffer_create_host(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * MAX_EDITS_PER_FLUSH * size_of(u32)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.voxel_edits_mapped = cast([^]u32)mapped_voxel_edits
	mapped_edit_results: rawptr
	voxel_gpu.edit_results, mapped_edit_results = gpu_buffer_create_host_flags(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * MAX_EDITS_PER_FLUSH * size_of(u32)),
		{.STORAGE_BUFFER},
		{.HOST_ACCESS_RANDOM, .MAPPED}, // CPU lê o feedback 2 frames depois
	)
	voxel_gpu.edit_results_mapped = cast([^]u32)mapped_edit_results

	mapped_mirror_ring: rawptr
	voxel_gpu.mirror_export_ring, mapped_mirror_ring = gpu_buffer_create_host_flags(
		vk.DeviceSize(config.mirror_ring_slots * CHUNK_VOXEL_COUNT * size_of(u16)),
		{.STORAGE_BUFFER},
		{.HOST_ACCESS_RANDOM, .MAPPED},
	)
	voxel_gpu.mirror_export_ring_mapped = cast([^]u16)mapped_mirror_ring
	mapped_heightmap_ring: rawptr
	voxel_gpu.mirror_heightmap_ring, mapped_heightmap_ring = gpu_buffer_create_host_flags(
		vk.DeviceSize(config.mirror_ring_slots * CHUNK_SIZE * CHUNK_SIZE * size_of(u16)),
		{.STORAGE_BUFFER},
		{.HOST_ACCESS_RANDOM, .MAPPED},
	)
	voxel_gpu.mirror_heightmap_ring_mapped = cast([^]u16)mapped_heightmap_ring
	mapped_result_flags: rawptr
	voxel_gpu.chunk_result_flags, mapped_result_flags = gpu_buffer_create_host_flags(
		vk.DeviceSize(config.resident_slots * size_of(u32)),
		{.STORAGE_BUFFER},
		{.HOST_ACCESS_RANDOM, .MAPPED}, // CPU lê após a timeline do lote (B1)
	)
	voxel_gpu.chunk_result_flags_mapped = cast([^]u32)mapped_result_flags
	// VS-20 (REQ-GPL-03): UBO do realce — NUM_FRAMES_IN_FLIGHT slots com
	// stride alinhado a minUniformBufferOffsetAlignment (offset dinâmico no
	// bind gráfico; sem corrida CPU/GPU por frame).
	alignment: vk.DeviceSize = 256
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(app.vkPhysicalDevice, &properties)
	alignment = max(alignment, vk.DeviceSize(properties.limits.minUniformBufferOffsetAlignment))
	voxel_gpu.target_highlight_alignment = alignment
	mapped_target: rawptr
	voxel_gpu.target_highlight_ubo, mapped_target = gpu_buffer_create_host_flags(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT) * alignment,
		{.UNIFORM_BUFFER},
		{.HOST_ACCESS_RANDOM, .MAPPED},
	)
	voxel_gpu.target_highlight_ubo_mapped = cast([^]u8)mapped_target
	voxel_gpu.dummy_buffer = gpu_buffer_create(vk.DeviceSize(16), {.STORAGE_BUFFER})

	// VS-12: assets data-driven substituem built-ins quando assets/blocks.json
	// existe (fallback = comportamento anterior, paridade total).
	if voxel_assets.loaded {
		upload_asset_templates()
		upload_asset_registry()
		upload_asset_textures()
	} else {
		upload_builtin_templates()
		upload_block_registry()
		upload_palette_textures()
	}

	// --- pipelines de compute (generate + pack) ---
	voxel_gpu.shader_module = load_shader_module("./voxel.spv")
	voxel_gpu.edit_shader_module = load_shader_module("./edit.spv")
	voxel_gpu.render_shader_module = load_shader_module("./render.spv")

	generation_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = voxel_gpu.shader_module,
		pName  = "generate_voxels",
	}
	packing_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = voxel_gpu.shader_module,
		pName  = "pack_chunk",
	}
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType  = .COMPUTE_PIPELINE_CREATE_INFO,
				stage  = generation_stage,
				layout = app.computePipelineLayout,
			},
			nil,
			&voxel_gpu.generation_pipeline,
		),
	)
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType  = .COMPUTE_PIPELINE_CREATE_INFO,
				stage  = packing_stage,
				layout = app.computePipelineLayout,
			},
			nil,
			&voxel_gpu.packing_pipeline,
		),
	)

	build_queue_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = voxel_gpu.render_shader_module,
		pName  = "build_work_queue",
	}
	finalize_queue_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = voxel_gpu.render_shader_module,
		pName  = "finalize_work_queue",
	}
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType  = .COMPUTE_PIPELINE_CREATE_INFO,
				stage  = build_queue_stage,
				layout = app.computePipelineLayout,
			},
			nil,
			&voxel_gpu.build_work_queue_pipeline,
		),
	)
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType  = .COMPUTE_PIPELINE_CREATE_INFO,
				stage  = finalize_queue_stage,
				layout = app.computePipelineLayout,
			},
			nil,
			&voxel_gpu.finalize_work_queue_pipeline,
		),
	)

	edit_stage := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = voxel_gpu.edit_shader_module,
		pName  = "main",
	}
	vk_check(
		vk.CreateComputePipelines(
			app.vkDevice,
			{},
			1,
			&vk.ComputePipelineCreateInfo {
				sType  = .COMPUTE_PIPELINE_CREATE_INFO,
				stage  = edit_stage,
				layout = app.computePipelineLayout,
			},
			nil,
			&voxel_gpu.edit_pipeline,
		),
	)
	voxel_render_pipeline_create()

	pool_sizes := [3]vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = DESCRIPTOR_SET_BINDING_COUNT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 2},
		// VS-20 (REQ-GPL-03): UBO dinâmico do realce (binding 21).
		{type = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 1},
	}
	vk_check(
		vk.CreateDescriptorPool(
			app.vkDevice,
			&vk.DescriptorPoolCreateInfo {
				sType         = .DESCRIPTOR_POOL_CREATE_INFO,
				poolSizeCount = len(pool_sizes),
				pPoolSizes    = &pool_sizes[0],
				maxSets       = 1,
			},
			nil,
			&voxel_gpu.descriptor_pool,
		),
	)
	layout := app.descriptorSetLayout
	vk_check(
		vk.AllocateDescriptorSets(
			app.vkDevice,
			&vk.DescriptorSetAllocateInfo {
				sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
				descriptorPool     = voxel_gpu.descriptor_pool,
				descriptorSetCount = 1,
				pSetLayouts        = &layout,
			},
			&voxel_gpu.descriptor_set,
		),
	)

	binding_buffers := [DESCRIPTOR_SET_BINDING_COUNT]vk.Buffer {
		0  = voxel_gpu.scratch.handle,
		1  = voxel_gpu.generation_jobs.handle,
		2  = voxel_gpu.occupancy_pool.handle,
		3  = voxel_gpu.material_plane_pool.handle,
		4  = voxel_gpu.chunk_headers.handle,
		5  = voxel_gpu.special_voxel_records.handle,
		6  = voxel_gpu.visible_chunks.handle,
		7  = voxel_gpu.block_registry.handle,
		// 8/9 = texturas (VS-02), escritas como COMBINED_IMAGE_SAMPLER abaixo
		10 = voxel_gpu.mesh_templates.handle,
		11 = voxel_gpu.template_vertices.handle,
		12 = voxel_gpu.template_triangles.handle,
		13 = voxel_gpu.edit_jobs.handle,
		14 = voxel_gpu.voxel_edits.handle,
		15 = voxel_gpu.edit_results.handle,
		16 = voxel_gpu.mirror_export_ring.handle,
		17 = voxel_gpu.work_queue.handle,
		18 = voxel_gpu.chunk_result_flags.handle,
		19 = voxel_gpu.template_uvs.handle,
		20 = voxel_gpu.mirror_heightmap_ring.handle,
		21 = voxel_gpu.target_highlight_ubo.handle,
	}
	buffer_infos: [DESCRIPTOR_SET_BINDING_COUNT]vk.DescriptorBufferInfo
	writes: [DESCRIPTOR_SET_BINDING_COUNT]vk.WriteDescriptorSet
	write_count := 0
	for buffer, i in binding_buffers {
		if i == 8 || i == 9 do continue // texturas, abaixo
		if i == 21 do continue // UBO dinâmico, write especial abaixo
		buffer_infos[i] = {buffer = buffer, offset = 0, range = vk.DeviceSize(vk.WHOLE_SIZE)}
		writes[write_count] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = voxel_gpu.descriptor_set,
			dstBinding      = u32(i),
			dstArrayElement = 0,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo     = &buffer_infos[i],
		}
		write_count += 1
	}

	image_infos := [2]vk.DescriptorImageInfo {
		{sampler = voxel_gpu.texture_sampler, imageView = voxel_gpu.albedo_palette_view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
		{sampler = voxel_gpu.texture_sampler, imageView = voxel_gpu.pbr_dummy_view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
	}
	// VS-20 (REQ-GPL-03): UBO dinâmico do realce (range inteiro; o offset do
	// slot vem do bind do command buffer por frame).
	buffer_infos[21] = {
		buffer = voxel_gpu.target_highlight_ubo.handle,
		offset = 0,
		range  = voxel_gpu.target_highlight_alignment, // stride do slot
	}
	writes[write_count] = {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = voxel_gpu.descriptor_set,
		dstBinding      = 21,
		dstArrayElement = 0,
		descriptorType  = .UNIFORM_BUFFER_DYNAMIC,
		descriptorCount = 1,
		pBufferInfo     = &buffer_infos[21],
	}
	write_count += 1
	for binding in 8 ..= 9 {
		writes[write_count] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = voxel_gpu.descriptor_set,
			dstBinding      = u32(binding),
			dstArrayElement = 0,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &image_infos[binding - 8],
		}
		write_count += 1
	}
	vk.UpdateDescriptorSets(app.vkDevice, u32(write_count), raw_data(&writes), 0, nil)

	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.scratch.handle, .BUFFER, "scratch_dense")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.occupancy_pool.handle, .BUFFER, "occupancy_pool")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.material_plane_pool.handle, .BUFFER, "material_plane_pool")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.chunk_headers.handle, .BUFFER, "chunk_headers")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.visible_chunks.handle, .BUFFER, "visible_chunks")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.work_queue.handle, .BUFFER, "work_queue")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.edit_jobs.handle, .BUFFER, "edit_jobs")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.voxel_edits.handle, .BUFFER, "voxel_edits")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.edit_results.handle, .BUFFER, "edit_results")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.mirror_export_ring.handle, .BUFFER, "mirror_export_ring")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.mirror_heightmap_ring.handle, .BUFFER, "mirror_heightmap_ring")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.chunk_result_flags.handle, .BUFFER, "chunk_result_flags")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.template_uvs.handle, .BUFFER, "template_uvs")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.target_highlight_ubo.handle, .BUFFER, "target_highlight_ubo")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.generation_pipeline, .PIPELINE, "pipeline_generate")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.packing_pipeline, .PIPELINE, "pipeline_pack")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.edit_pipeline, .PIPELINE, "pipeline_apply_voxel_edits")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.build_work_queue_pipeline, .PIPELINE, "pipeline_build_work_queue")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.finalize_work_queue_pipeline, .PIPELINE, "pipeline_finalize_work_queue")
	telemetry_name_object(cast(u64)cast(uintptr)voxel_gpu.mesh_pipeline, .PIPELINE, "pipeline_mesh_draw")

	log.info("Recursos GPU do voxel engine inicializados")
}

voxel_gpu_destroy :: proc() {
	log.info("Destruindo recursos GPU do voxel engine")
	vk.DestroyDescriptorPool(app.vkDevice, voxel_gpu.descriptor_pool, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.mesh_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.edit_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.finalize_work_queue_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.build_work_queue_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.packing_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.generation_pipeline, nil)
	vk.DestroyShaderModule(app.vkDevice, voxel_gpu.render_shader_module, nil)
	vk.DestroyShaderModule(app.vkDevice, voxel_gpu.edit_shader_module, nil)
	vk.DestroyShaderModule(app.vkDevice, voxel_gpu.shader_module, nil)
	vk.FreeCommandBuffers(
		app.vkDevice,
		voxel_gpu.compute_command_pool,
		u32(len(voxel_gpu.compute_command_buffers)),
		&voxel_gpu.compute_command_buffers[0],
	)
	vk.DestroyCommandPool(app.vkDevice, voxel_gpu.compute_command_pool, nil)

	vk.DestroySampler(app.vkDevice, voxel_gpu.texture_sampler, nil)
	vk.DestroyImageView(app.vkDevice, voxel_gpu.pbr_dummy_view, nil)
	vma.DestroyImage(app.vmaAllocator, voxel_gpu.pbr_dummy_image, voxel_gpu.pbr_dummy_allocation)
	vk.DestroyImageView(app.vkDevice, voxel_gpu.albedo_palette_view, nil)
	vma.DestroyImage(app.vmaAllocator, voxel_gpu.albedo_palette_image, voxel_gpu.albedo_palette_allocation)

	gpu_buffer_destroy(&voxel_gpu.target_highlight_ubo)
	gpu_buffer_destroy(&voxel_gpu.dummy_buffer)
	gpu_buffer_destroy(&voxel_gpu.chunk_result_flags)
	gpu_buffer_destroy(&voxel_gpu.mirror_heightmap_ring)
	gpu_buffer_destroy(&voxel_gpu.mirror_export_ring)
	gpu_buffer_destroy(&voxel_gpu.edit_results)
	gpu_buffer_destroy(&voxel_gpu.voxel_edits)
	gpu_buffer_destroy(&voxel_gpu.edit_jobs)
	gpu_buffer_destroy(&voxel_gpu.work_queue)
	gpu_buffer_destroy(&voxel_gpu.template_uvs)
	gpu_buffer_destroy(&voxel_gpu.template_triangles)
	gpu_buffer_destroy(&voxel_gpu.template_vertices)
	gpu_buffer_destroy(&voxel_gpu.mesh_templates)
	gpu_buffer_destroy(&voxel_gpu.visible_chunks)
	gpu_buffer_destroy(&voxel_gpu.block_registry)
	gpu_buffer_destroy(&voxel_gpu.special_voxel_records)
	gpu_buffer_destroy(&voxel_gpu.chunk_headers)
	gpu_buffer_destroy(&voxel_gpu.material_plane_pool)
	gpu_buffer_destroy(&voxel_gpu.occupancy_pool)
	gpu_buffer_destroy(&voxel_gpu.generation_jobs)
	gpu_buffer_destroy(&voxel_gpu.scratch)
	voxel_gpu = {}
}


@(private)
debug_readback_validate :: proc(ve: ^VoxelEngine) {
	coord: ChunkCoordinate
	record: ChunkRecord
	page: ^MirrorChunkPage
	found := false
	// Preferimos um chunk materializado no mirror (página MATERIALIZED): a
	// checagem de conteúdo compara o readback packed contra o grid denso u16
	// do mirror (mesmo scratch GPU, mesmo conteúdo — ver bloco abaixo).
	for c, r in ve.active_chunks {
		p, ok := ve.mirror.pages[c]
		if r.state != .GENERATING && ok && p.state == .MATERIALIZED && c.y * CHUNK_SIZE <= 1 && (c.y + 1) * CHUNK_SIZE > 0 {
			coord, record, page, found = c, r, p, true
			break
		}
	}
	if !found {
		for c, r in ve.active_chunks {
			p, ok := ve.mirror.pages[c]
			if r.state != .GENERATING && ok && p.state == .MATERIALIZED {
				coord, record, page, found = c, r, p, true
				break
			}
		}
	}
	if !found {
		for c, r in ve.active_chunks {
			if r.state != .GENERATING {
				coord, record, found = c, r, true
				break
			}
		}
	}
	if !found {
		log.warn("DEBUG READBACK: nenhum chunk concluído para inspecionar")
		return
	}
	slot := record.storage_slot_index

	{
		// VS-12: com assets carregados, o readback casa com os dados do JSON
		// (vértices + UVs); sem assets, mantém a regresso contra os built-ins.
		vertex_count := 16
		uv_count := 0
		if voxel_assets.loaded {
			vertex_count = len(voxel_assets.vertices)
			uv_count = len(voxel_assets.uvs)
		}
		vtx_size := vk.DeviceSize(vertex_count * 4 * size_of(f32))
		uv_size := vk.DeviceSize(uv_count * 2 * size_of(f32))
		rb_size := vtx_size + uv_size
		vtx_rb, vtx_mapped := gpu_buffer_create_host(rb_size, {.TRANSFER_DST})
		vk_check(vk.DeviceWaitIdle(app.vkDevice))
		cmd := voxel_gpu.compute_command_buffers[0]
		vk_check(vk.ResetCommandBuffer(cmd, {}))
		vk_check(
			vk.BeginCommandBuffer(
				cmd,
				&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
			),
		)
		vk.CmdCopyBuffer(cmd, voxel_gpu.template_vertices.handle, vtx_rb.handle, 1, &vk.BufferCopy{size = vtx_size})
		// buffer único de readback: copia UVs para depois dos vértices
		if uv_size > 0 {
			uv_copy := vk.BufferCopy{dstOffset = vtx_size, size = uv_size}
			vk.CmdCopyBuffer(cmd, voxel_gpu.template_uvs.handle, vtx_rb.handle, 1, &uv_copy)
		}
		vk_check(vk.EndCommandBuffer(cmd))
		vk_check(
			vk.QueueSubmit2(
				app.queues[.Compute].queue,
				1,
				&vk.SubmitInfo2 {
					sType                  = .SUBMIT_INFO_2,
					commandBufferInfoCount = 1,
					pCommandBufferInfos    = &vk.CommandBufferSubmitInfo {
						sType         = .COMMAND_BUFFER_SUBMIT_INFO,
						commandBuffer = cmd,
					},
				},
				{},
			),
		)
		vk_check(vk.DeviceWaitIdle(app.vkDevice))

		gpu_vertices := cast([^][4]f32)vtx_mapped
		vtx_errors := 0
		if voxel_assets.loaded {
			for v, i in voxel_assets.vertices {
				if gpu_vertices[i] != v { vtx_errors += 1 }
			}
		} else {
			for v, i in BUILTIN_CUBE_VERTICES {
				if gpu_vertices[i].xyz != v { vtx_errors += 1 }
			}
			for v, i in BUILTIN_PLANT_VERTICES {
				if gpu_vertices[8 + i].xyz != v { vtx_errors += 1 }
			}
		}
		if vtx_errors == 0 {
			if voxel_assets.loaded {
				log.infof("DEBUG READBACK OK: template_vertices ({} vértices, stride 16) == assets JSON", vertex_count)
			} else {
				log.info("DEBUG READBACK OK: template_vertices (16 vértices, stride 16) == built-ins")
			}
		} else {
			log.errorf("DEBUG READBACK FALHOU: template_vertices — {} vértices divergentes", vtx_errors)
		}

		if uv_size > 0 {
			gpu_uvs := cast([^][2]f32)mem.ptr_offset(cast(^u8)vtx_mapped, int(vtx_size))
			uv_errors := 0
			for uv, i in voxel_assets.uvs {
				if gpu_uvs[i] != uv { uv_errors += 1 }
			}
			if uv_errors == 0 {
				log.infof("DEBUG READBACK OK: template_uvs ({} UVs, stride 8) == assets JSON", uv_count)
			} else {
				log.errorf("DEBUG READBACK FALHOU: template_uvs — {} UVs divergentes", uv_errors)
			}
		}
		gpu_buffer_destroy(&vtx_rb)
	}

	header_size := vk.DeviceSize(size_of(ChunkHeader))
	occupancy_size := vk.DeviceSize(OCCUPANCY_WORDS_PER_CHUNK * size_of(u32))
	planes_size := vk.DeviceSize(MATERIAL_WORDS_PER_CHUNK * size_of(u32))
	total := header_size + occupancy_size + planes_size

	readback, readback_mapped := gpu_buffer_create_host(total, {.TRANSFER_DST})
	defer gpu_buffer_destroy(&readback)

	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	cmd := voxel_gpu.compute_command_buffers[0]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	copies := [3]vk.BufferCopy {
		{ // header
			srcOffset = vk.DeviceSize(slot) * header_size,
			dstOffset = 0,
			size      = header_size,
		},
		{ // ocupação
			srcOffset = vk.DeviceSize(slot) * occupancy_size,
			dstOffset = header_size,
			size      = occupancy_size,
		},
		{ // planos
			srcOffset = vk.DeviceSize(slot) * planes_size,
			dstOffset = header_size + occupancy_size,
			size      = planes_size,
		},
	}
	src_buffers := [3]vk.Buffer {
		voxel_gpu.chunk_headers.handle,
		voxel_gpu.occupancy_pool.handle,
		voxel_gpu.material_plane_pool.handle,
	}
	for i in 0 ..< 3 {
		vk.CmdCopyBuffer(cmd, src_buffers[i], readback.handle, 1, &copies[i])
	}
	vk_check(vk.EndCommandBuffer(cmd))
	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	vk_check(
		vk.QueueSubmit2(
			app.queues[.Compute].queue,
			1,
			&vk.SubmitInfo2 {
				sType                  = .SUBMIT_INFO_2,
				commandBufferInfoCount = 1,
				pCommandBufferInfos    = &cmd_info,
			},
			{},
		),
	)
	vk_check(vk.DeviceWaitIdle(app.vkDevice))

	header := cast(^ChunkHeader)readback_mapped
	occupancy := cast([^]u32)mem.ptr_offset(cast(^u8)readback_mapped, int(header_size))
	planes := cast([^]u32)mem.ptr_offset(cast(^u8)readback_mapped, int(header_size + occupancy_size))

	errors := 0
	solid := 0
	dense_checked := false
	if page != nil && page.state == .MATERIALIZED {
		// VS-04: a checagem de conteúdo NÃO compara contra um modelo de mundo
		// CPU (C2/Etapa 7 — a CPU não reproduz o worldgen GPU bit a bit). Em vez
		// disso, decodifica o readback packed (ocupação/paleta/planos) e compara
		// voxel a voxel com o grid denso u16 do mirror, ambos derivados do mesmo
		// scratch GPU. Esse decode é o mesmo espelhado bit a bit por
		// tools/sim/pack_sim.py offline.
		dense_checked = true
		for y in 0 ..< CHUNK_SIZE {
			for z in 0 ..< CHUNK_SIZE {
				for x in 0 ..< CHUNK_SIZE {
					brick_idx := x / 4 + 8 * (z / 4 + 8 * (y / 2))
					bit_idx := x % 4 + 4 * (z % 4 + 4 * (y % 2))
					palette_index: u32 = 0
					for plane in 0 ..< header.plane_count {
						word := planes[int(plane) * BRICKS_PER_CHUNK + brick_idx]
						palette_index |= ((word >> uint(bit_idx)) & 1) << plane
					}
					clamped := min(palette_index, max(header.palette_size, 1) - 1)
					decoded := header.palette[clamped]
					if decoded != 0 do solid += 1 // ocupados (sólidos + plantas)

					mi := u32(y) | (u32(z) << 5) | (u32(x) << 10) // índice y-contíguo do mirror
					if u32(page.ids[mi]) != decoded {
						errors += 1
					} else if mirror_bit_test(page.solid[:], mi) != block_is_solid(decoded) {
						// VS-14 emenda: solid do mirror exclui planta (NON_SOLID)
						errors += 1
					}
					solid_word := occupancy[SOLID_WORD_BASE + brick_idx]
					if ((solid_word >> uint(bit_idx)) & 1 != 0) != block_is_solid(decoded) {
						errors += 1
					}
				}
			}
		}
	} else {
		// Sem página MATERIALIZED (chunk fora da bolha de simulação): mantém
		// apenas os invariantes estruturais abaixo (decode×denso coberto por
		// tools/sim/pack_sim.py; CPU não reproduz worldgen — C2).
		log.info("DEBUG READBACK: chunk sem página MATERIALIZED no mirror — checagem denso pulada (invariantes estruturais mantidas)")
	}

	if header.palette[0] != 0 {
		errors += 1
		log.errorf("DEBUG READBACK: palette[0] = {} (invariante AR violada)", header.palette[0])
	}
	if dense_checked {
		if errors == 0 {
			log.infof(
				"DEBUG READBACK OK: chunk {} slot {} — packed == mirror denso ({} voxels, {} sólidos, paleta {}, planos {}, flags {})",
				coord, slot, CHUNK_VOXEL_COUNT, solid, header.palette_size, header.plane_count, header.flags,
			)
		} else {
			log.errorf("DEBUG READBACK FALHOU: chunk {} slot {} — {} divergências packed×denso", coord, slot, errors)
		}
	} else if errors == 0 {
		log.infof(
			"DEBUG READBACK OK: chunk {} slot {} — invariantes estruturais (paleta {}, planos {}, flags {})",
			coord, slot, header.palette_size, header.plane_count, header.flags,
		)
	} else {
		log.errorf("DEBUG READBACK FALHOU: chunk {} slot {} — {} divergências estruturais", coord, slot, errors)
	}
}

// VS-19 (AC-04): ponto de entrada público da validação packed×denso (a
// rotina em si é privada deste arquivo); usada pelo hook de debug F7.
debug_validate_run :: proc(ve: ^VoxelEngine) {
	debug_readback_validate(ve)
}

@(private)
debug_readback_decode_voxels :: proc(ve: ^VoxelEngine, chunk_coord: ChunkCoordinate, local_voxels: [][3]i32, tag: string) {
	record, found := ve.active_chunks[chunk_coord]
	if !found || record.state == .GENERATING || record.state == .EMPTY {
		log.infof("DEBUG VOXEL {}: chunk {} ausente/gerando/vazio", tag, chunk_coord)
		return
	}
	slot := record.storage_slot_index

	header_size := vk.DeviceSize(size_of(ChunkHeader))
	planes_size := vk.DeviceSize(MATERIAL_WORDS_PER_CHUNK * size_of(u32))
	total := header_size + planes_size
	readback, mapped := gpu_buffer_create_host(total, {.TRANSFER_DST})
	defer gpu_buffer_destroy(&readback)

	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	cmd := voxel_gpu.compute_command_buffers[0]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	copies := [2]vk.BufferCopy {
		{srcOffset = vk.DeviceSize(slot) * header_size, dstOffset = 0, size = header_size},
		{srcOffset = vk.DeviceSize(slot) * planes_size, dstOffset = header_size, size = planes_size},
	}
	vk.CmdCopyBuffer(cmd, voxel_gpu.chunk_headers.handle, readback.handle, 1, &copies[0])
	vk.CmdCopyBuffer(cmd, voxel_gpu.material_plane_pool.handle, readback.handle, 1, &copies[1])
	vk_check(vk.EndCommandBuffer(cmd))
	vk_check(
		vk.QueueSubmit2(
			app.queues[.Compute].queue,
			1,
			&vk.SubmitInfo2 {
				sType                  = .SUBMIT_INFO_2,
				commandBufferInfoCount = 1,
				pCommandBufferInfos    = &vk.CommandBufferSubmitInfo {
					sType         = .COMMAND_BUFFER_SUBMIT_INFO,
					commandBuffer = cmd,
				},
			},
			{},
		),
	)
	vk_check(vk.DeviceWaitIdle(app.vkDevice))

	header := cast(^ChunkHeader)mapped
	planes := cast([^]u32)mem.ptr_offset(cast(^u8)mapped, int(header_size))
	for lv in local_voxels {
		brick_idx := int(lv.x / 4 + 8 * (lv.z / 4 + 8 * (lv.y / 2)))
		bit_idx := int(lv.x % 4 + 4 * (lv.z % 4 + 4 * (lv.y % 2)))
		palette_index: u32 = 0
		for plane in 0 ..< header.plane_count {
			word := planes[int(plane) * BRICKS_PER_CHUNK + brick_idx]
			palette_index |= ((word >> uint(bit_idx)) & 1) << plane
		}
		clamped := min(palette_index, max(header.palette_size, 1) - 1)
		log.infof(
			"DEBUG VOXEL {}: chunk {} voxel {} -> id {} (palette_size={}, planes={}, flags={})",
			tag,
			chunk_coord,
			lv,
			header.palette[clamped],
			header.palette_size,
			header.plane_count,
			header.flags,
		)
	}
}


@(private)
debug_mirror_parity :: proc(ve: ^VoxelEngine, chunk_coord: ChunkCoordinate) {
	page, found := ve.mirror.pages[chunk_coord]
	if !found || page.state != .MATERIALIZED {
		log.warnf("DEBUG MIRROR PARITY: chunk {} sem página materializada", chunk_coord)
		return
	}
	record, active := ve.active_chunks[chunk_coord]
	if !active || record.state == .GENERATING || record.state == .EMPTY {
		log.warnf("DEBUG MIRROR PARITY: chunk {} ausente/gerando/vazio", chunk_coord)
		return
	}
	slot := record.storage_slot_index

	header_size := vk.DeviceSize(size_of(ChunkHeader))
	planes_size := vk.DeviceSize(MATERIAL_WORDS_PER_CHUNK * size_of(u32))
	total := header_size + planes_size
	readback, mapped := gpu_buffer_create_host(total, {.TRANSFER_DST})
	defer gpu_buffer_destroy(&readback)

	vk_check(vk.DeviceWaitIdle(app.vkDevice))
	cmd := voxel_gpu.compute_command_buffers[0]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	copies := [2]vk.BufferCopy {
		{srcOffset = vk.DeviceSize(slot) * header_size, dstOffset = 0, size = header_size},
		{srcOffset = vk.DeviceSize(slot) * planes_size, dstOffset = header_size, size = planes_size},
	}
	vk.CmdCopyBuffer(cmd, voxel_gpu.chunk_headers.handle, readback.handle, 1, &copies[0])
	vk.CmdCopyBuffer(cmd, voxel_gpu.material_plane_pool.handle, readback.handle, 1, &copies[1])
	vk_check(vk.EndCommandBuffer(cmd))
	vk_check(
		vk.QueueSubmit2(
			app.queues[.Compute].queue,
			1,
			&vk.SubmitInfo2 {
				sType                  = .SUBMIT_INFO_2,
				commandBufferInfoCount = 1,
				pCommandBufferInfos    = &vk.CommandBufferSubmitInfo {
					sType         = .COMMAND_BUFFER_SUBMIT_INFO,
					commandBuffer = cmd,
				},
			},
			{},
		),
	)
	vk_check(vk.DeviceWaitIdle(app.vkDevice))

	header := cast(^ChunkHeader)mapped
	planes := cast([^]u32)mem.ptr_offset(cast(^u8)mapped, int(header_size))
	divergences := 0
	for y in 0 ..< CHUNK_SIZE {
		for z in 0 ..< CHUNK_SIZE {
			for x in 0 ..< CHUNK_SIZE {
				brick_idx := x / 4 + 8 * (z / 4 + 8 * (y / 2))
				bit_idx := x % 4 + 4 * (z % 4 + 4 * (y % 2))
				palette_index: u32 = 0
				for plane in 0 ..< header.plane_count {
					word := planes[int(plane) * BRICKS_PER_CHUNK + brick_idx]
					palette_index |= ((word >> uint(bit_idx)) & 1) << plane
				}
				clamped := min(palette_index, max(header.palette_size, 1) - 1)
				gpu_id := header.palette[clamped]
				// Layout y-contíguo do mirror (regra 7).
				mirror_idx := u32(y) | (u32(z) << 5) | (u32(x) << 10)
				if u32(page.ids[mirror_idx]) != gpu_id {
					divergences += 1
				}
			}
		}
	}
	if divergences == 0 {
		log.infof(
			"DEBUG MIRROR PARITY OK: chunk {} — 32768 voxels GPU == mirror (edit_seq {})",
			chunk_coord,
			page.edit_seq,
		)
	} else {
		log.errorf("DEBUG MIRROR PARITY FALHOU: chunk {} — {} divergências", chunk_coord, divergences)
	}
}



@(private)
upload_asset_templates :: proc() {
	upload_to_device_buffer(
		raw_data(voxel_assets.templates),
		vk.DeviceSize(len(voxel_assets.templates) * size_of(MeshTemplate)),
		voxel_gpu.mesh_templates.handle,
	)
	upload_to_device_buffer(
		raw_data(voxel_assets.vertices),
		vk.DeviceSize(len(voxel_assets.vertices) * size_of([4]f32)),
		voxel_gpu.template_vertices.handle,
	)
	upload_to_device_buffer(
		raw_data(voxel_assets.triangles),
		vk.DeviceSize(len(voxel_assets.triangles) * size_of(u32)),
		voxel_gpu.template_triangles.handle,
	)
	upload_to_device_buffer(
		raw_data(voxel_assets.uvs),
		vk.DeviceSize(len(voxel_assets.uvs) * size_of([2]f32)),
		voxel_gpu.template_uvs.handle,
	)
}

@(private)
upload_asset_registry :: proc() {
	upload_to_device_buffer(
		&voxel_assets.registry,
		size_of(voxel_assets.registry),
		voxel_gpu.block_registry.handle,
	)
}

// VS-12 (REQ-AST-03/05): Texture2DArray de albedo com uma camada por textura
// (ordem de definição), no lugar da paleta procedural. Caminho de amostragem
// (índice de camada + UV) inalterado — zero mudança de shader.
@(private)
upload_asset_textures :: proc() {
	w := voxel_assets.texture_width
	h := voxel_assets.texture_height
	layers := voxel_assets.texture_layers

	voxel_gpu.albedo_palette_image, voxel_gpu.albedo_palette_allocation =
		gpu_image_2d_array_create(w, h, layers)
	voxel_gpu.albedo_palette_view = gpu_image_2d_array_view_create(voxel_gpu.albedo_palette_image, layers)

	voxel_gpu.pbr_dummy_image, voxel_gpu.pbr_dummy_allocation = gpu_image_2d_array_create(1, 1, 1)
	voxel_gpu.pbr_dummy_view = gpu_image_2d_array_view_create(voxel_gpu.pbr_dummy_image, 1)

	vk_check(
		vk.CreateSampler(
			app.vkDevice,
			&vk.SamplerCreateInfo {
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .LINEAR,
				minFilter = .LINEAR,
				addressModeU = .REPEAT,
				addressModeV = .REPEAT,
				addressModeW = .REPEAT,
				maxLod = 0.0,
			},
			nil,
			&voxel_gpu.texture_sampler,
		),
	)

	upload_to_device_image(
		raw_data(voxel_assets.texture_pixels),
		vk.DeviceSize(len(voxel_assets.texture_pixels)),
		voxel_gpu.albedo_palette_image,
		w, h, layers,
	)

	black := [4]u8{0, 0, 0, 255}
	upload_to_device_image(&black, vk.DeviceSize(4), voxel_gpu.pbr_dummy_image, 1, 1, 1)
}

@(private)
upload_builtin_templates :: proc() {
	cube_tris, plant_tris: [12]u32
	for t, i in BUILTIN_CUBE_TRIANGLES {
		cube_tris[i] = pack_template_triangle(t[0], t[1], t[2], t[3])
	}
	for t, i in BUILTIN_PLANT_TRIANGLES {
		plant_tris[i] = pack_template_triangle(t[0], t[1], t[2], t[3])
	}

	cube_verts := BUILTIN_CUBE_VERTICES
	plant_verts := BUILTIN_PLANT_VERTICES
	// VS-11 (REQ-UV-02): built-ins com UV — cubo: projeção planar (x,z) por
	// vértice (os 8 vértices são compartilhados entre 3 faces; unwrap por face
	// exigiria duplicar vértices — simplificação registrada na VS-11, questão
	// aberta de rotação/unwrap por face); planta: cada quad da cruz com [0,1]².
	cube_uvs: [8][2]f32
	for v, i in cube_verts do cube_uvs[i] = {v[0], v[2]}
	plant_uvs := [8][2]f32{{0, 0}, {1, 0}, {1, 1}, {0, 1}, {0, 0}, {1, 0}, {1, 1}, {0, 1}}
	log.assert(validate_template(cube_verts[:], cube_tris[:]), "template cubo inválido")
	log.assert(validate_template(plant_verts[:], plant_tris[:4]), "template planta inválido")
	log.assert(validate_template_uvs(1, cube_uvs[:]), "UVs do template cubo fora de [0,1]²")
	log.assert(validate_template_uvs(2, plant_uvs[:]), "UVs do template planta fora de [0,1]²")

	templates := [3]MeshTemplate {
		{uv_offset = NO_TEMPLATE_UV_OFFSET}, // 0 = ar: nada emite
		{ // 1 = cubo
			vertex_offset   = 0,
			vertex_count    = 8,
			triangle_offset = 0,
			triangle_count  = 12,
			worst_case_tris = compute_worst_case_tris(cube_tris[:]),
			flags           = TEMPLATE_FLAG_HAS_FLUSH_FACES,
			uv_offset       = 0,
		},
		{ // 2 = planta
			vertex_offset   = 8,
			vertex_count    = 8,
			triangle_offset = 12,
			triangle_count  = 4,
			worst_case_tris = compute_worst_case_tris(plant_tris[:4]),
			flags           = 0,
			uv_offset       = 8,
		},
	}

	vertices: [16][4]f32
	for v, i in cube_verts do vertices[i] = {v[0], v[1], v[2], 0}
	for v, i in plant_verts do vertices[8 + i] = {v[0], v[1], v[2], 0}
	triangles: [16]u32
	copy(triangles[0:12], cube_tris[:])
	copy(triangles[12:16], plant_tris[:4])
	uvs: [16][2]f32
	copy(uvs[0:8], cube_uvs[:])
	copy(uvs[8:16], plant_uvs[:])

	upload_to_device_buffer(&templates, size_of(templates), voxel_gpu.mesh_templates.handle)
	upload_to_device_buffer(&vertices, size_of(vertices), voxel_gpu.template_vertices.handle)
	upload_to_device_buffer(&triangles, size_of(triangles), voxel_gpu.template_triangles.handle)
	upload_to_device_buffer(&uvs, size_of(uvs), voxel_gpu.template_uvs.handle)
}


@(private)
upload_block_registry :: proc() {
	registry: [BLOCK_REGISTRY_CAPACITY]BlockDefinition
	for id in 1 ..= 3 {
		registry[id] = BlockDefinition{mesh_template_index = 1, albedo_texture_index = u32(id)}
	}
	// VS-14 (REQ-PLT-05): fallback sem assets — id 4 (planta) usa o template
	// cruz built-in (2) + camada 4 da paleta, com alpha-test (flags bit 0) e
	// NON_SOLID (flags bit 1 — emenda 2026-11-07).
	registry[4] = BlockDefinition{
		mesh_template_index = 2,
		albedo_texture_index = 4,
		flags = BLOCK_DEFINITION_FLAG_TRANSPARENT | BLOCK_DEFINITION_FLAG_NON_SOLID,
	}
	upload_to_device_buffer(&registry, size_of(registry), voxel_gpu.block_registry.handle)
}

@(private)
gpu_buffer_create_host :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (buffer: GpuBuffer, mapped: rawptr) {
	return gpu_buffer_create_host_flags(size, usage, {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED})
}

@(private)
load_shader_module :: proc(path: string) -> (module: vk.ShaderModule) {
	shader_code := load_file(path, context.temp_allocator)
	vk_check(
		vk.CreateShaderModule(
			app.vkDevice,
			&vk.ShaderModuleCreateInfo {
				sType    = .SHADER_MODULE_CREATE_INFO,
				codeSize = len(shader_code),
				pCode    = cast(^u32)raw_data(shader_code),
			},
			nil,
			&module,
		),
	)
	return
}

@(private)
gpu_buffer_create_host_flags :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	flags: vma.AllocationCreateFlags,
) -> (buffer: GpuBuffer, mapped: rawptr) {
	buffer.size = size
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = flags,
	}
	info: vma.AllocationInfo
	vk_check(
		vma.CreateBuffer(app.vmaAllocator, buffer_info, allocation_info, &buffer.handle, &buffer.allocation, &info),
	)
	mapped = info.pMappedData
	return
}

@(private)
upload_to_device_buffer :: proc(data: rawptr, size: vk.DeviceSize, dst: vk.Buffer) {
	staging, staging_mapped := gpu_buffer_create_host(size, {.TRANSFER_SRC})
	mem.copy(staging_mapped, data, int(size))
	defer gpu_buffer_destroy(&staging)

	cmd := voxel_gpu.compute_command_buffers[0]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))
	vk.CmdCopyBuffer(cmd, staging.handle, dst, 1, &vk.BufferCopy{size = size})
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit_info := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_info,
	}
	vk_check(vk.QueueSubmit2(app.queues[.Compute].queue, 1, &submit_info, {}))
	vk_check(vk.DeviceWaitIdle(app.vkDevice))
}

@(private)
gpu_image_2d_array_create :: proc(
	width, height, layers: u32,
) -> (
	image: vk.Image,
	allocation: vma.Allocation,
) {
	families := [2]u32{app.queues[.Graphics].familyIndex, app.queues[.Compute].familyIndex}
	image_info := vk.ImageCreateInfo {
		sType       = .IMAGE_CREATE_INFO,
		imageType   = .D2,
		format      = .R8G8B8A8_UNORM,
		extent      = {width = width, height = height, depth = 1},
		mipLevels   = 1,
		arrayLayers = layers,
		samples     = {._1},
		tiling      = .OPTIMAL,
		usage       = {.SAMPLED, .TRANSFER_DST},
	}
	if families[0] != families[1] {
		image_info.sharingMode = .CONCURRENT
		image_info.queueFamilyIndexCount = 2
		image_info.pQueueFamilyIndices = &families[0]
	}
	allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
	}
	vk_check(vma.CreateImage(app.vmaAllocator, image_info, allocation_info, &image, &allocation, nil))
	return
}

@(private)
gpu_image_2d_array_view_create :: proc(image: vk.Image, layers: u32) -> (view: vk.ImageView) {
	vk_check(
		vk.CreateImageView(
			app.vkDevice,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2_ARRAY,
				format = .R8G8B8A8_UNORM,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = layers},
			},
			nil,
			&view,
		),
	)
	return
}

@(private)
upload_to_device_image :: proc(pixels: rawptr, size: vk.DeviceSize, dst: vk.Image, width, height, layers: u32) {
	staging, staging_mapped := gpu_buffer_create_host(size, {.TRANSFER_SRC})
	mem.copy(staging_mapped, pixels, int(size))
	defer gpu_buffer_destroy(&staging)

	cmd := voxel_gpu.compute_command_buffers[0]
	vk_check(vk.ResetCommandBuffer(cmd, {}))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)

	to_transfer := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		image = dst,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = layers},
		oldLayout = .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcStageMask = {.COPY},
		dstStageMask = {.COPY},
		dstAccessMask = {.TRANSFER_WRITE},
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_transfer},
	)

	region := vk.BufferImageCopy {
		imageSubresource = {aspectMask = {.COLOR}, layerCount = layers},
		imageExtent      = {width = width, height = height, depth = 1},
	}
	vk.CmdCopyBufferToImage(cmd, staging.handle, dst, .TRANSFER_DST_OPTIMAL, 1, &region)

	to_read := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		image = dst,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = layers},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .SHADER_READ_ONLY_OPTIMAL,
		srcStageMask = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.COPY},
	}
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &to_read},
	)
	vk_check(vk.EndCommandBuffer(cmd))

	vk_check(
		vk.QueueSubmit2(
			app.queues[.Compute].queue,
			1,
			&vk.SubmitInfo2 {
				sType = .SUBMIT_INFO_2,
				commandBufferInfoCount = 1,
				pCommandBufferInfos = &vk.CommandBufferSubmitInfo {
					sType = .COMMAND_BUFFER_SUBMIT_INFO,
					commandBuffer = cmd,
				},
			},
			{},
		),
	)
	vk_check(vk.DeviceWaitIdle(app.vkDevice))
}

@(private)
upload_palette_textures :: proc() {
	LAYER :: ALBEDO_PALETTE_LAYER_SIZE
	LAYERS :: ALBEDO_PALETTE_LAYERS

	voxel_gpu.albedo_palette_image, voxel_gpu.albedo_palette_allocation =
		gpu_image_2d_array_create(LAYER, LAYER, LAYERS)
	voxel_gpu.albedo_palette_view = gpu_image_2d_array_view_create(voxel_gpu.albedo_palette_image, LAYERS)

	voxel_gpu.pbr_dummy_image, voxel_gpu.pbr_dummy_allocation = gpu_image_2d_array_create(1, 1, 1)
	voxel_gpu.pbr_dummy_view = gpu_image_2d_array_view_create(voxel_gpu.pbr_dummy_image, 1)

	vk_check(
		vk.CreateSampler(
			app.vkDevice,
			&vk.SamplerCreateInfo {
				sType = .SAMPLER_CREATE_INFO,
				magFilter = .LINEAR,
				minFilter = .LINEAR,
				addressModeU = .REPEAT,
				addressModeV = .REPEAT,
				addressModeW = .REPEAT,
				maxLod = 0.0,
			},
			nil,
			&voxel_gpu.texture_sampler,
		),
	)

	colors: [LAYERS][3]u8
	for &c in colors do c = {128, 128, 128}
	colors[0] = {0, 0, 0}
	colors[1] = {89, 191, 64} // grama: verde
	colors[2] = {128, 89, 51} // terra: marrom
	colors[3] = {140, 140, 148} // pedra: cinza
	colors[4] = {60, 160, 60} // VS-14: planta (fallback sem assets): verde folha

	pixels: [LAYERS * LAYER * LAYER][4]u8
	for layer in 0 ..< LAYERS {
		base := layer * LAYER * LAYER
		for texel in 0 ..< LAYER * LAYER {
			pixels[base + texel] = {colors[layer][0], colors[layer][1], colors[layer][2], 255}
		}
	}
	upload_to_device_image(
		&pixels[0],
		vk.DeviceSize(size_of(pixels)),
		voxel_gpu.albedo_palette_image,
		LAYER, LAYER, LAYERS,
	)

	black := [4]u8{0, 0, 0, 255}
	upload_to_device_image(&black, vk.DeviceSize(4), voxel_gpu.pbr_dummy_image, 1, 1, 1)
}

