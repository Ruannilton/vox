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
	mesh_templates:         GpuBuffer,
	template_vertices:      GpuBuffer,
	template_triangles:     GpuBuffer,
	dummy_buffer:           GpuBuffer, // bindings ainda não usados (6, 8, 9, 13-16)

	descriptor_pool:        vk.DescriptorPool,
	descriptor_set:         vk.DescriptorSet,
	shader_module:          vk.ShaderModule,
	generation_pipeline:    vk.Pipeline,
	packing_pipeline:       vk.Pipeline,

	compute_command_pool:    vk.CommandPool,
	compute_command_buffers: [MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT]vk.CommandBuffer,
}

voxel_gpu: VoxelGpu

@(private)
gpu_buffer_create_host :: proc(size: vk.DeviceSize, usage: vk.BufferUsageFlags) -> (buffer: GpuBuffer, mapped: rawptr) {
	buffer.size = size
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}
	allocation_info := vma.AllocationCreateInfo {
		usage = .AUTO,
		flags = {.HOST_ACCESS_SEQUENTIAL_WRITE, .MAPPED},
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
	voxel_gpu.mesh_templates = gpu_buffer_create(
		vk.DeviceSize(MESH_TEMPLATE_CAPACITY * size_of(MeshTemplate)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	voxel_gpu.template_vertices = gpu_buffer_create(
		vk.DeviceSize(1024 * 3 * size_of(f32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	voxel_gpu.template_triangles = gpu_buffer_create(
		vk.DeviceSize(1024 * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	voxel_gpu.dummy_buffer = gpu_buffer_create(vk.DeviceSize(16), {.STORAGE_BUFFER})

	upload_builtin_templates()
	upload_block_registry()

	// --- pipelines de compute (generate + pack) ---
	shader_code := load_file("./voxel.spv", context.temp_allocator)
	vk_check(
		vk.CreateShaderModule(
			app.vkDevice,
			&vk.ShaderModuleCreateInfo {
				sType    = .SHADER_MODULE_CREATE_INFO,
				codeSize = len(shader_code),
				pCode    = cast(^u32)raw_data(shader_code),
			},
			nil,
			&voxel_gpu.shader_module,
		),
	)

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

	// --- descriptor set (layout da VS-00: 17 bindings storage buffer) ---
	pool_size := vk.DescriptorPoolSize {
		type            = .STORAGE_BUFFER,
		descriptorCount = DESCRIPTOR_SET_BINDING_COUNT,
	}
	vk_check(
		vk.CreateDescriptorPool(
			app.vkDevice,
			&vk.DescriptorPoolCreateInfo {
				sType         = .DESCRIPTOR_POOL_CREATE_INFO,
				poolSizeCount = 1,
				pPoolSizes    = &pool_size,
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
		6  = voxel_gpu.dummy_buffer.handle, // visible_chunks (VS-02)
		7  = voxel_gpu.block_registry.handle,
		8  = voxel_gpu.dummy_buffer.handle, // texturas albedo (VS-02)
		9  = voxel_gpu.dummy_buffer.handle, // texturas PBR (VS-02)
		10 = voxel_gpu.mesh_templates.handle,
		11 = voxel_gpu.template_vertices.handle,
		12 = voxel_gpu.template_triangles.handle,
		13 = voxel_gpu.dummy_buffer.handle, // edit_jobs (VS-03)
		14 = voxel_gpu.dummy_buffer.handle, // voxel_edits (VS-03)
		15 = voxel_gpu.dummy_buffer.handle, // edit_results (VS-03)
		16 = voxel_gpu.dummy_buffer.handle, // mirror_export_ring (VS-04)
	}
	buffer_infos: [DESCRIPTOR_SET_BINDING_COUNT]vk.DescriptorBufferInfo
	writes: [DESCRIPTOR_SET_BINDING_COUNT]vk.WriteDescriptorSet
	for buffer, i in binding_buffers {
		buffer_infos[i] = {buffer = buffer, offset = 0, range = vk.DeviceSize(vk.WHOLE_SIZE)}
		writes[i] = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = voxel_gpu.descriptor_set,
			dstBinding      = u32(i),
			dstArrayElement = 0,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1,
			pBufferInfo     = &buffer_infos[i],
		}
	}
	vk.UpdateDescriptorSets(app.vkDevice, len(writes), raw_data(&writes), 0, nil)

	log.info("Recursos GPU do voxel engine inicializados")
}

voxel_gpu_destroy :: proc() {
	log.info("Destruindo recursos GPU do voxel engine")
	vk.DestroyDescriptorPool(app.vkDevice, voxel_gpu.descriptor_pool, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.packing_pipeline, nil)
	vk.DestroyPipeline(app.vkDevice, voxel_gpu.generation_pipeline, nil)
	vk.DestroyShaderModule(app.vkDevice, voxel_gpu.shader_module, nil)
	vk.FreeCommandBuffers(
		app.vkDevice,
		voxel_gpu.compute_command_pool,
		len(voxel_gpu.compute_command_buffers),
		&voxel_gpu.compute_command_buffers[0],
	)
	vk.DestroyCommandPool(app.vkDevice, voxel_gpu.compute_command_pool, nil)

	gpu_buffer_destroy(&voxel_gpu.dummy_buffer)
	gpu_buffer_destroy(&voxel_gpu.template_triangles)
	gpu_buffer_destroy(&voxel_gpu.template_vertices)
	gpu_buffer_destroy(&voxel_gpu.mesh_templates)
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

	vertices: [16][3]f32
	copy(vertices[0:8], cube_verts[:])
	copy(vertices[8:16], plant_verts[:])
	triangles: [16]u32
	copy(triangles[0:12], cube_tris[:])
	copy(triangles[12:16], plant_tris[:4])

	upload_to_device_buffer(&templates, size_of(templates), voxel_gpu.mesh_templates.handle)
	upload_to_device_buffer(&vertices, size_of(vertices), voxel_gpu.template_vertices.handle)
	upload_to_device_buffer(&triangles, size_of(triangles), voxel_gpu.template_triangles.handle)
}

// Dicionário mínimo do worldgen da referência: 1 = grama, 2 = terra,
// 3 = pedra (todos com o template cubo). 0 = ar (não é registrado).
@(private)
upload_block_registry :: proc() {
	registry: [BLOCK_REGISTRY_CAPACITY]BlockDefinition
	for id in 1 ..= 3 {
		registry[id] = BlockDefinition{mesh_template_index = 1}
	}
	upload_to_device_buffer(&registry, size_of(registry), voxel_gpu.block_registry.handle)
}
