package engine

// VS-01-IMPL-07 — Buffers GPU, tabelas do Caminho B, pipelines de compute e
// descriptor set da fundação de voxels. Layouts e tamanhos: common.slang
// (fonte única de verdade) e voxel_types.odin.

import "core:log"
import "core:mem"
import vma "shared:vma"
import vk "vendor:vulkan"

SCRATCH_CHUNK_COUNT :: MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT * MAXIMUM_CHUNKS_PER_BATCH
GENERATION_JOB_COUNT :: SCRATCH_CHUNK_COUNT

BLOCK_REGISTRY_CAPACITY :: 256
MESH_TEMPLATE_CAPACITY  :: 256

VoxelGpu :: struct {
	scratch:                GpuBuffer, // ring 3×16 chunks × 128 KiB (device-local)
	generation_jobs:        GpuBuffer, // ring 3×16 jobs (host-visible)
	generation_jobs_mapped: [^]ChunkGenerationJob,
	occupancy_pool:         GpuBuffer,
	material_plane_pool:    GpuBuffer,
	chunk_headers:          GpuBuffer,
	special_voxel_records:  GpuBuffer,
	block_registry:         GpuBuffer,
	visible_chunks:         GpuBuffer, // ring 2×4096 × 48 B (host-visible, VS-02)
	visible_chunks_mapped:  [^]VisibleChunk,
	mesh_templates:         GpuBuffer,
	template_vertices:      GpuBuffer,
	template_triangles:     GpuBuffer,
	// VS-02 (correção): fila de trabalho global — ring 2×(estado + itens);
	// builder compute anexa, draw mesh-only indireto consome (device-local).
	work_queue:             GpuBuffer,
	// VS-03 (E1): rings de edição host-visible (2 slots de frame).
	edit_jobs:              GpuBuffer,
	edit_jobs_mapped:       [^]EditChunkJob,
	voxel_edits:            GpuBuffer,
	voxel_edits_mapped:     [^]u32,
	edit_results:           GpuBuffer, // HOST_ACCESS_RANDOM: CPU lê o feedback
	edit_results_mapped:    [^]u32,
	dummy_buffer:           GpuBuffer, // binding ainda não usado (16)

	// VS-02: texturas (bindings 8/9) — paleta procedural de cores sólidas +
	// dummy PBR (ADR-B7).
	albedo_palette_image:      vk.Image,
	albedo_palette_allocation: vma.Allocation,
	albedo_palette_view:       vk.ImageView,
	pbr_dummy_image:           vk.Image,
	pbr_dummy_allocation:      vma.Allocation,
	pbr_dummy_view:            vk.ImageView,
	texture_sampler:           vk.Sampler,

	descriptor_pool:        vk.DescriptorPool,
	descriptor_set:         vk.DescriptorSet,
	// Módulos separados por família de estágio: `groupshared` global no Slang
	// é a UNIÃO do módulo inteiro — num módulo único, o mesh shader herdava a
	// shared memory do pack+edição (37,9 KiB > maxMeshSharedMemorySize).
	shader_module:          vk.ShaderModule, // voxel.spv: generate + pack
	edit_shader_module:     vk.ShaderModule, // edit.spv: apply_voxel_edits
	render_shader_module:   vk.ShaderModule, // render.spv: builder + finalize + mesh + fragment
	generation_pipeline:    vk.Pipeline,
	packing_pipeline:       vk.Pipeline,
	// VS-02 (correção): builder + finalize da fila de trabalho (compute
	// despachado na fila gráfica, antes do render pass).
	build_work_queue_pipeline:    vk.Pipeline,
	finalize_work_queue_pipeline: vk.Pipeline,
	edit_pipeline:                vk.Pipeline, // VS-03: apply_voxel_edits (compute na fila gráfica)
	mesh_pipeline:          vk.Pipeline, // VS-02: mesh/fragment (mesh-only)

	compute_command_pool:    vk.CommandPool,
	compute_command_buffers: [MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT]vk.CommandBuffer,
}

voxel_gpu: VoxelGpu

@(private)
gpu_buffer_create_host :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (buffer: GpuBuffer, mapped: rawptr) {
	return gpu_buffer_create_host_flags(size, usage, {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED})
}

// Carrega um .spv do diretório de trabalho (bin/) e cria o shader module.
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

// HOST_ACCESS_RANDOM para buffers lidos pela CPU (ex.: edit_results); nesse
// caso chamar vma.InvalidateAllocation antes da leitura se a memória não for
// coerente.
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

// Upload via staging: copia para buffer host-visible temporário e grava no
// device-local com um submit único na fila de compute (chamado só no init,
// antes da worker começar).
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

// VS-02 (REQ-SHADE-03): cria uma imagem 2D array RGBA8 compartilhada entre as
// filas de compute (upload no init) e gráfica (amostragem no fragment).
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

// Upload de pixels RGBA8 para uma imagem 2D array via staging, com as duas
// transições de layout, num submit único na fila de compute (só no init).
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

	// A família de compute não aceita estágios gráficos; a transição de layout
	// não exige dstStage de leitura — o DeviceWaitIdle do init ordena o uso
	// posterior pela fila gráfica.
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

// VS-02: paleta de cores sólidas por entrada de albedo (sem arquivos de
// asset) + dummy PBR do mesmo tipo para validar o binding 9 (ADR-B7).
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

	// Cores: fallback cinza; 0 = ar (nunca amostrado); 1 = grama; 2 = terra;
	// 3 = pedra. O índice do bloco no dicionário aponta para a camada.
	colors: [LAYERS][3]u8
	for &c in colors do c = {128, 128, 128}
	colors[0] = {0, 0, 0}
	colors[1] = {89, 191, 64} // grama: verde
	colors[2] = {128, 89, 51} // terra: marrom
	colors[3] = {140, 140, 148} // pedra: cinza

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

voxel_gpu_init :: proc() {
	log.info("Inicializando recursos GPU do voxel engine")

	// --- command pool/buffers de compute (ring de 3 lotes em voo) ---
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
				commandBufferCount = len(voxel_gpu.compute_command_buffers),
			},
			&voxel_gpu.compute_command_buffers[0],
		),
	)

	// --- buffers ---
	voxel_gpu.scratch = gpu_buffer_create(
		vk.DeviceSize(SCRATCH_CHUNK_COUNT * CHUNK_VOXEL_COUNT * size_of(u32)),
		{.STORAGE_BUFFER},
	)
	mapped_jobs: rawptr
	voxel_gpu.generation_jobs, mapped_jobs = gpu_buffer_create_host(
		vk.DeviceSize(GENERATION_JOB_COUNT * size_of(ChunkGenerationJob)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.generation_jobs_mapped = cast([^]ChunkGenerationJob)mapped_jobs

	voxel_gpu.occupancy_pool = gpu_buffer_create(
		vk.DeviceSize(MAXIMUM_RESIDENT_CHUNKS * OCCUPANCY_WORDS_PER_CHUNK * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
	)
	voxel_gpu.material_plane_pool = gpu_buffer_create(
		vk.DeviceSize(MAXIMUM_RESIDENT_CHUNKS * MATERIAL_WORDS_PER_CHUNK * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_SRC},
	)
	voxel_gpu.chunk_headers = gpu_buffer_create(
		vk.DeviceSize(MAXIMUM_RESIDENT_CHUNKS * size_of(ChunkHeader)),
		{.STORAGE_BUFFER, .TRANSFER_SRC},
	)
	voxel_gpu.special_voxel_records = gpu_buffer_create(
		vk.DeviceSize(MAXIMUM_RESIDENT_CHUNKS * SPECIAL_RECORDS_PER_CHUNK * size_of(SpecialVoxelRecord)),
		{.STORAGE_BUFFER},
	)
	voxel_gpu.block_registry = gpu_buffer_create(
		vk.DeviceSize(BLOCK_REGISTRY_CAPACITY * size_of(BlockDefinition)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	// VS-02 (REQ-VIS-01): ring de visíveis, reconstruído pela CPU a cada frame.
	visible_mapped: rawptr
	voxel_gpu.visible_chunks, visible_mapped = gpu_buffer_create_host(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * MAXIMUM_VISIBLE_CHUNKS * size_of(VisibleChunk)),
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
	// VS-02 (correção): fila de trabalho global — INDIRECT para o
	// CmdDrawMeshTasksIndirectEXT, TRANSFER_DST para o fill do estado,
	// TRANSFER_SRC para readbacks de debug.
	voxel_gpu.work_queue = gpu_buffer_create(
		vk.DeviceSize(NUM_FRAMES_IN_FLIGHT * WORK_QUEUE_SLOT_WORDS * size_of(u32)),
		{.STORAGE_BUFFER, .INDIRECT_BUFFER, .TRANSFER_DST, .TRANSFER_SRC},
	)
	// VS-03 (E1): rings de edição host-visible (2 slots de frame; mesma
	// garantia de reescrita do visible_chunks — slot só regravado após a
	// espera de frames em voo).
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
	voxel_gpu.dummy_buffer = gpu_buffer_create(vk.DeviceSize(16), {.STORAGE_BUFFER})

	upload_builtin_templates()
	upload_block_registry()
	upload_palette_textures()

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

	// VS-02 (correção): pipelines compute do builder/finalize da fila de
	// trabalho (módulo render.spv) + gráfica mesh-only (mesh/fragment).
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
	// VS-03 (E1): pipeline do apply_voxel_edits (compute na fila gráfica,
	// antes do builder da fila de trabalho — mesma layout de compute).
	// O edit.spv tem UMA entry point, então o slangc a emite como "main".
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

	// --- descriptor set (layout da VS-00, com 8/9 revisados pela VS-02) ---
	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = DESCRIPTOR_SET_BINDING_COUNT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 2},
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
		13 = voxel_gpu.edit_jobs.handle,    // ring de jobs de edição (VS-03)
		14 = voxel_gpu.voxel_edits.handle,  // ring de edições packed (VS-03)
		15 = voxel_gpu.edit_results.handle, // ring de resultados (VS-03)
		16 = voxel_gpu.dummy_buffer.handle, // mirror_export_ring (VS-04)
		17 = voxel_gpu.work_queue.handle,   // fila de trabalho (VS-02)
	}
	buffer_infos: [DESCRIPTOR_SET_BINDING_COUNT]vk.DescriptorBufferInfo
	writes: [DESCRIPTOR_SET_BINDING_COUNT]vk.WriteDescriptorSet
	write_count := 0
	for buffer, i in binding_buffers {
		if i == 8 || i == 9 do continue // texturas, abaixo
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
	// VS-02 (REQ-PIPE-02): bindings 8/9 são COMBINED_IMAGE_SAMPLER.
	image_infos := [2]vk.DescriptorImageInfo {
		{sampler = voxel_gpu.texture_sampler, imageView = voxel_gpu.albedo_palette_view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
		{sampler = voxel_gpu.texture_sampler, imageView = voxel_gpu.pbr_dummy_view, imageLayout = .SHADER_READ_ONLY_OPTIMAL},
	}
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
		len(voxel_gpu.compute_command_buffers),
		&voxel_gpu.compute_command_buffers[0],
	)
	vk.DestroyCommandPool(app.vkDevice, voxel_gpu.compute_command_pool, nil)

	vk.DestroySampler(app.vkDevice, voxel_gpu.texture_sampler, nil)
	vk.DestroyImageView(app.vkDevice, voxel_gpu.pbr_dummy_view, nil)
	vma.DestroyImage(app.vmaAllocator, voxel_gpu.pbr_dummy_image, voxel_gpu.pbr_dummy_allocation)
	vk.DestroyImageView(app.vkDevice, voxel_gpu.albedo_palette_view, nil)
	vma.DestroyImage(app.vmaAllocator, voxel_gpu.albedo_palette_image, voxel_gpu.albedo_palette_allocation)

	gpu_buffer_destroy(&voxel_gpu.dummy_buffer)
	gpu_buffer_destroy(&voxel_gpu.edit_results)
	gpu_buffer_destroy(&voxel_gpu.voxel_edits)
	gpu_buffer_destroy(&voxel_gpu.edit_jobs)
	gpu_buffer_destroy(&voxel_gpu.work_queue)
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

// --- Readback de debug (AC-01): decodifica um chunk real na CPU e compara ---
// com a verdade do worldgen (determinístico). Só roda em diagnóstico, sob
// demanda, com a GPU idle.

debug_readback_validate :: proc(ve: ^VoxelEngine) {
	// Escolhe o primeiro chunk concluído que contenha camadas sólidas do
	// worldgen (y ≤ 1); fallback para qualquer chunk concluído.
	coord: ChunkCoordinate
	record: ChunkRecord
	found := false
	for c, r in ve.active_chunks {
		if r.state != .GENERATING && c.y * CHUNK_SIZE <= 1 && (c.y + 1) * CHUNK_SIZE > 0 {
			coord, record, found = c, r, true
			break
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

	// Regressão (VS-02): o shader lê template_vertices como float4 (stride
	// 16 B, std430). Compara o conteúdo do buffer com os built-ins —
	// historicamente o upload usava stride 12 e o shader lia vértices
	// desalinhados (faces malformadas).
	{
		vtx_size := vk.DeviceSize(16 * 4 * size_of(f32))
		vtx_rb, vtx_mapped := gpu_buffer_create_host(vtx_size, {.TRANSFER_DST})
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
		for v, i in BUILTIN_CUBE_VERTICES {
			if gpu_vertices[i].xyz != v { vtx_errors += 1 }
		}
		for v, i in BUILTIN_PLANT_VERTICES {
			if gpu_vertices[8 + i].xyz != v { vtx_errors += 1 }
		}
		if vtx_errors == 0 {
			log.info("DEBUG READBACK OK: template_vertices (16 vértices, stride 16) == built-ins")
		} else {
			log.errorf("DEBUG READBACK FALHOU: template_vertices — {} vértices divergentes", vtx_errors)
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

	// Decodifica na CPU espelhando read_block_identifier do common.slang.
	header := cast(^ChunkHeader)readback_mapped
	occupancy := cast([^]u32)mem.ptr_offset(cast(^u8)readback_mapped, int(header_size))
	planes := cast([^]u32)mem.ptr_offset(cast(^u8)readback_mapped, int(header_size + occupancy_size))

	errors := 0
	solid := 0
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

				// Verdade do worldgen da referência.
				world_y := coord.y * CHUNK_SIZE + i32(y)
				truth: u32 = 0
				if world_y < 0 do truth = 3
				else if world_y == 0 do truth = 2
				else if world_y == 1 do truth = 1

				if decoded != truth {
					errors += 1
				}
				if decoded != 0 do solid += 1
			}
		}
	}

	if header.palette[0] != 0 {
		errors += 1
		log.errorf("DEBUG READBACK: palette[0] = {} (invariante AR violada)", header.palette[0])
	}
	if errors == 0 {
		log.infof(
			"DEBUG READBACK OK: chunk {} slot {} — {} voxels decodificados == worldgen ({} sólidos, paleta {}, planos {}, flags {})",
			coord, slot, CHUNK_VOXEL_COUNT, solid, header.palette_size, header.plane_count, header.flags,
		)
	} else {
		log.errorf("DEBUG READBACK FALHOU: chunk {} slot {} — {} divergências", coord, slot, errors)
	}
}


// TEMPORÁRIO (diagnóstico VS-03): decodifica voxels específicos de um chunk
// via readback (header + planos), para inspecionar o cenário roteirizado.
debug_readback_decode_voxels :: proc(ve: ^VoxelEngine, chunk_coord: ChunkCoordinate, local_voxels: [][3]i32, tag: string) {
	record, found := ve.active_chunks[chunk_coord]
	if !found || record.state == .GENERATING {
		log.infof("DEBUG VOXEL {}: chunk {} ausente/gerando", tag, chunk_coord)
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


// --- Caminho B: templates built-in (0 = ar, 1 = cubo, 2 = planta) ---

BUILTIN_CUBE_VERTICES :: [8][3]f32 {
	{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
	{0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1},
}

// (v0, v1, v2, face) — winding CCW visto de fora; face 0..5 = +X,-X,+Y,-Y,+Z,-Z
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
	log.assert(validate_template(cube_verts[:], cube_tris[:]), "template cubo inválido")
	log.assert(validate_template(plant_verts[:], plant_tris[:4]), "template planta inválido")

	templates := [3]MeshTemplate {
		{}, // 0 = ar: nada emite
		{ // 1 = cubo
			vertex_offset   = 0,
			vertex_count    = 8,
			triangle_offset = 0,
			triangle_count  = 12,
			worst_case_tris = compute_worst_case_tris(cube_tris[:]),
			flags           = TEMPLATE_FLAG_HAS_FLUSH_FACES,
		},
		{ // 2 = planta
			vertex_offset   = 8,
			vertex_count    = 8,
			triangle_offset = 12,
			triangle_count  = 4,
			worst_case_tris = compute_worst_case_tris(plant_tris[:4]),
			flags           = 0,
		},
	}

	// std430: o shader lê float4 (stride 16 B) — upload com w=0 de padding.
	vertices: [16][4]f32
	for v, i in cube_verts do vertices[i] = {v[0], v[1], v[2], 0}
	for v, i in plant_verts do vertices[8 + i] = {v[0], v[1], v[2], 0}
	triangles: [16]u32
	copy(triangles[0:12], cube_tris[:])
	copy(triangles[12:16], plant_tris[:4])

	upload_to_device_buffer(&templates, size_of(templates), voxel_gpu.mesh_templates.handle)
	upload_to_device_buffer(&vertices, size_of(vertices), voxel_gpu.template_vertices.handle)
	upload_to_device_buffer(&triangles, size_of(triangles), voxel_gpu.template_triangles.handle)
}

// Dicionário mínimo do worldgen da referência: 1 = grama, 2 = terra,
// 3 = pedra (todos com o template cubo). 0 = ar (não é registrado).
// VS-02 (REQ-SHADE-03): albedo_texture_index aponta para a camada de cor
// sólida da paleta procedural (1 = verde, 2 = marrom, 3 = cinza).
@(private)
upload_block_registry :: proc() {
	registry: [BLOCK_REGISTRY_CAPACITY]BlockDefinition
	for id in 1 ..= 3 {
		registry[id] = BlockDefinition{mesh_template_index = 1, albedo_texture_index = u32(id)}
	}
	upload_to_device_buffer(&registry, size_of(registry), voxel_gpu.block_registry.handle)
}
