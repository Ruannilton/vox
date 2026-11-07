package engine

// VS-08 (REQ-CFG-01..04, REQ-CFG-07): config via INI + provisionamento runtime.
// O Config global é carregado/validado ANTES de CreateEngine (sem janela em erro
// fatal); a validação de máquina (REQ-CFG-04) roda após create_vma_allocator.

import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import vma "shared:vma"
import vk "vendor:vulkan"

CONFIG_DEFAULT_PATH :: "vox.ini"

// Fator de folga do pool de páginas do mirror (REQ-CFG-02).
MIRROR_PAGE_FACTOR_NUM :: 3
MIRROR_PAGE_FACTOR_DEN :: 2

// Margem de segurança do budget device-local (REQ-CFG-04).
CONFIG_BUDGET_MARGIN_NUM :: 9
CONFIG_BUDGET_MARGIN_DEN :: 10

Config :: struct {
	// parâmetros (REQ-CFG-01)
	radius_vision:       u32,
	radius_generation:   u32,
	radius_unload:       u32,
	radius_simulation:   u32,
	chunks_per_batch:    u32,
	batches_in_flight:   u32,

	// capacidades derivadas (REQ-CFG-02)
	visible_capacity:      u32, // |esfera(vision)|
	resident_slots:        u32, // |esfera(generation)|
	scratch_chunks:        u32, // batches_in_flight × chunks_per_batch
	mirror_pages:          u32, // ⌈|esfera(simulation)| × 1,5⌉
	mirror_ring_slots:     u32, // max(64, próxima potência de 2 ≥ scratch_chunks)
	work_item_capacity:    u32, // visible_capacity × BRICKS_PER_CHUNK
	work_queue_slot_words: u32, // WORK_QUEUE_STATE_WORDS + work_item_capacity

	provisioned_device_bytes: u64, // bytes device somados na validação de máquina
}

config: Config
config_path: string // definido pelo parsing de flags da VS-07 (--config)

// Carga do INI + defaults + derivações + validação (REQ-CFG-01..03); erros
// fatais saem sem criar janela.
config_load :: proc() {
	path := config_path
	if path == "" {
		path = CONFIG_DEFAULT_PATH
	}

	cfg := Config {
		radius_vision     = 8,
		radius_generation = 9,
		radius_unload     = 10,
		radius_simulation = 5,
		chunks_per_batch  = 16,
		batches_in_flight = 3,
	}

	data, ferr := os.read_entire_file_from_path(path, context.temp_allocator)
	if ferr != nil {
		log.warnf(
			"Arquivo de configuração {} não encontrado; usando defaults (visão 8, geração 9, descarga 10, simulação 5, lote 16, lotes em voo 3)",
			path,
		)
	} else {
		config_parse_ini(string(data), path, &cfg)
	}

	config_derive_and_validate(&cfg)
	config = cfg
	config_log_effective()
}

// Validação de máquina (REQ-CFG-04): requerido × budget device-local × 0,9.
// Roda após create_vma_allocator e antes de qualquer provisionamento.
config_validate_machine :: proc() {
	config.provisioned_device_bytes = config_device_bytes_required()

	budgets: [vk.MAX_MEMORY_HEAPS]vma.Budget
	vma.GetHeapBudgets(app.vmaAllocator, &budgets[0])
	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(app.vkPhysicalDevice, &memory_properties)

	device_budget: u64 = 0
	for type_index in 0 ..< memory_properties.memoryTypeCount {
		if .DEVICE_LOCAL in memory_properties.memoryTypes[type_index].propertyFlags {
			heap := memory_properties.memoryTypes[type_index].heapIndex
			device_budget += u64(budgets[heap].budget)
		}
	}
	device_budget = (device_budget * CONFIG_BUDGET_MARGIN_NUM) / CONFIG_BUDGET_MARGIN_DEN

	if config.provisioned_device_bytes > device_budget {
		// sugestão: reduzir unload (que governa os slots residentes), piso em generation + 1
		suggestion := config.radius_unload
		for suggestion > config.radius_generation + 1 {
			slots := (sphere_count(suggestion - 1) * 105 + 99) / 100
			saved := (u64(config.resident_slots) - slots) * (
				u64(OCCUPANCY_WORDS_PER_CHUNK) * size_of(u32) +
				u64(MATERIAL_WORDS_PER_CHUNK) * size_of(u32) +
				size_of(ChunkHeader) +
				u64(SPECIAL_RECORDS_PER_CHUNK) * size_of(SpecialVoxelRecord)
			)
			if config.provisioned_device_bytes - saved <= device_budget {
				suggestion -= 1
				break
			}
			suggestion -= 1
		}
		floor_msg := ""
		if suggestion <= config.radius_generation + 1 {
			floor_msg = " (piso atingido: é preciso reduzir vision/generation manualmente)"
		}
		config_fatal(
			"Limite de máquina excedido (REQ-CFG-04): os recursos derivados da configuração requerem {} bytes na heap device-local, mas o budget disponível com margem de 10% é {} bytes. Sugestão: reduza streaming.unload para ≤ {}{} (ou diminua streaming.vision)",
			config.provisioned_device_bytes,
			device_budget,
			suggestion,
			floor_msg,
		)
	}

	log.infof(
		"VS-08: validação de máquina OK — {} bytes provisionados (device-local) de {} disponíveis (budget × 0,9)",
		config.provisioned_device_bytes,
		device_budget,
	)
}

@(private)
config_device_bytes_required :: proc() -> u64 {
	slots := u64(config.resident_slots)
	visible := u64(config.visible_capacity)
	scratch := u64(config.scratch_chunks)

	pools := slots * (
		u64(OCCUPANCY_WORDS_PER_CHUNK) * size_of(u32) +
		u64(MATERIAL_WORDS_PER_CHUNK) * size_of(u32) +
		size_of(ChunkHeader) +
		u64(SPECIAL_RECORDS_PER_CHUNK) * size_of(SpecialVoxelRecord)
	)
	work_queue := u64(NUM_FRAMES_IN_FLIGHT) * (u64(WORK_QUEUE_STATE_WORDS) + visible * BRICKS_PER_CHUNK) * size_of(u32)
	scratch_bytes := scratch * u64(CHUNK_VOXEL_COUNT) * size_of(u32)
	visible_chunks := u64(NUM_FRAMES_IN_FLIGHT) * visible * size_of(VisibleChunk)
	generation_jobs := scratch * size_of(ChunkGenerationJob)

	fixed := u64(BLOCK_REGISTRY_CAPACITY) * size_of(BlockDefinition) +
		u64(MESH_TEMPLATE_CAPACITY) * size_of(MeshTemplate) +
		1024 * 4 * size_of(f32) + // template_vertices
		1024 * size_of(u32) + // template_triangles
		1024 * 2 * size_of(f32) + // template_uvs (VS-11, binding 19)
		16 // dummy_buffer

	// VS-10 (REQ-VRT-05): feedback de flags do pack por slot (binding 18,
	// host-visible) — residual (4 B × slots).
	result_flags := slots * size_of(u32)

	return pools + work_queue + scratch_bytes + visible_chunks + generation_jobs + fixed + result_flags
}

@(private)
config_derive_and_validate :: proc(cfg: ^Config) {
	// REQ-CFG-03 (emendada VS-09, REQ-WID-02): visible_index de 16 bits —
	// visíveis ≤ 65535, logo vision ≤ 25 (esfera(25)=65.267; esfera(26)=73.525 estoura).
	if cfg.radius_vision < 1 || cfg.radius_vision > 25 {
		config_fatal(
			"streaming.vision = {} fora do intervalo válido 1..25 (limite de formato: visible_index tem 16 bits no item da fila de trabalho, no máximo 65535 visíveis; vision=26 daria {} > 65535)",
			cfg.radius_vision,
			sphere_count(26),
		)
	}
	if cfg.radius_simulation < 1 {
		config_fatal("streaming.simulation = {} deve ser ≥ 1", cfg.radius_simulation)
	}
	if cfg.radius_generation < cfg.radius_vision {
		config_fatal(
			"streaming.generation ({}) deve ser ≥ streaming.vision ({})",
			cfg.radius_generation,
			cfg.radius_vision,
		)
	}
	if cfg.radius_generation >= cfg.radius_unload {
		config_fatal(
			"streaming.unload ({}) deve ser > streaming.generation ({}) (histerese estrita)",
			cfg.radius_unload,
			cfg.radius_generation,
		)
	}
	if cfg.chunks_per_batch < 1 || cfg.chunks_per_batch > 64 {
		config_fatal("compute.chunks_per_batch = {} fora do intervalo válido 1..64", cfg.chunks_per_batch)
	}
	if cfg.batches_in_flight < 1 || cfg.batches_in_flight > 8 {
		config_fatal("compute.batches_in_flight = {} fora do intervalo válido 1..8", cfg.batches_in_flight)
	}

	visible := sphere_count(cfg.radius_vision)
	generation := sphere_count(cfg.radius_generation)
	// slots residentes: esfera de UNLOAD (retenção CAGED até unload + transitório
	// de aposentadoria B1) + margem de 5% — derivar de generation esgota o pool.
	resident := (sphere_count(cfg.radius_unload) * 105 + 99) / 100
	simulation := sphere_count(cfg.radius_simulation)
	scratch := u64(cfg.batches_in_flight) * u64(cfg.chunks_per_batch)

	if visible == 0 || visible > u64(max(u32)) ||
	   generation == 0 || generation > u64(max(u32)) ||
	   simulation == 0 || simulation > u64(max(u32)) ||
	   scratch == 0 || scratch > u64(max(u32)) {
		config_fatal("capacidade derivada excede u32 (overflow); reduza os parâmetros de streaming/compute")
	}
	if resident > 65535 {
		config_fatal(
			"streaming.unload = {} produz {} slots residentes, acima do limite de 65535",
			cfg.radius_unload,
			resident,
		)
	}
	if scratch > 256 {
		config_fatal(
			"scratch_chunks = batches_in_flight ({}) × chunks_per_batch ({}) = {} excede o limite de 256",
			cfg.batches_in_flight,
			cfg.chunks_per_batch,
			scratch,
		)
	}

	work_items := visible * BRICKS_PER_CHUNK
	if work_items > u64(max(u32)) {
		config_fatal("work_item_capacity derivada excede u32 (overflow); reduza streaming.vision")
	}

	pages := (simulation * MIRROR_PAGE_FACTOR_NUM + MIRROR_PAGE_FACTOR_DEN - 1) / MIRROR_PAGE_FACTOR_DEN
	ring := next_power_of_two(scratch)
	if ring < 64 do ring = 64

	cfg.visible_capacity = u32(visible)
	cfg.resident_slots = u32(resident)
	cfg.scratch_chunks = u32(scratch)
	cfg.mirror_pages = u32(pages)
	cfg.mirror_ring_slots = u32(ring)
	cfg.work_item_capacity = u32(work_items)
	cfg.work_queue_slot_words = u32(WORK_QUEUE_STATE_WORDS) + cfg.work_item_capacity
}

@(private)
config_fatal :: proc(format: string, args: ..any) -> ! {
	log.errorf(format, ..args)
	os.exit(1)
}

@(private)
config_log_effective :: proc() {
	log.infof(
		"Config efetiva: visão={} geração={} descarga={} simulação={} lote={} lotes_em_voo={} → visíveis={} slots={} scratch={} páginas_mirror={} ring_mirror={} itens_fila={}",
		config.radius_vision,
		config.radius_generation,
		config.radius_unload,
		config.radius_simulation,
		config.chunks_per_batch,
		config.batches_in_flight,
		config.visible_capacity,
		config.resident_slots,
		config.scratch_chunks,
		config.mirror_pages,
		config.mirror_ring_slots,
		config.work_item_capacity,
	)
}

@(private)
config_parse_ini :: proc(text, path: string, cfg: ^Config) {
	section := ""
	lines := strings.split(text, "\n", context.temp_allocator)
	for line_raw, line_no in lines {
		line := strings.trim_space(line_raw)
		// comentário: linha inteira ou inline com ';'
		if i := strings.index(line, ";"); i >= 0 {
			line = strings.trim_space(line[:i])
		}
		if line == "" do continue

		if line[0] == '[' {
			if len(line) < 2 || line[len(line) - 1] != ']' {
				config_fatal("{}:{}: seção malformada '{}' (esperado [nome])", path, line_no + 1, line)
			}
			section = line[1:len(line) - 1]
			if section != "streaming" && section != "compute" {
				log.warnf("{}:{}: seção desconhecida '[{}]'; chaves nela serão ignoradas", path, line_no + 1, section)
			}
			continue
		}

		eq := strings.index(line, "=")
		if eq < 0 {
			config_fatal("{}:{}: linha malformada '{}' (esperado chave=valor)", path, line_no + 1, line)
		}
		key := strings.trim_space(line[:eq])
		value_raw := strings.trim_space(line[eq + 1:])

		if section != "streaming" && section != "compute" {
			continue
		}

		known := true
		dst: ^u32
		full_key := strings.concatenate({section, ".", key}, context.temp_allocator)
		switch full_key {
		case "streaming.vision":
			dst = &cfg.radius_vision
		case "streaming.generation":
			dst = &cfg.radius_generation
		case "streaming.unload":
			dst = &cfg.radius_unload
		case "streaming.simulation":
			dst = &cfg.radius_simulation
		case "compute.chunks_per_batch":
			dst = &cfg.chunks_per_batch
		case "compute.batches_in_flight":
			dst = &cfg.batches_in_flight
		case:
			known = false
		}
		if !known {
			log.warnf("{}:{}: chave desconhecida '[{}] {}'; ignorada", path, line_no + 1, section, key)
			continue
		}

		value, ok := strconv.parse_u64(value_raw, 10)
		if !ok || value > u64(max(u32)) {
			config_fatal(
				"{}:{}: valor malformado '{}' para '{}' (esperado inteiro de 32 bits não negativo)",
				path, line_no + 1, value_raw, full_key,
			)
		}
		dst^ = u32(value)
	}
}

// Pontos inteiros com x²+y²+z² ≤ r² (REQ-CFG-02).
@(private)
sphere_count :: proc "contextless" (radius: u32) -> u64 {
	r := i64(radius)
	count: u64 = 0
	for x in -r ..= r {
		for y in -r ..= r {
			for z in -r ..= r {
				if x * x + y * y + z * z <= r * r {
					count += 1
				}
			}
		}
	}
	return count
}

@(private)
next_power_of_two :: proc "contextless" (v: u64) -> u64 {
	p: u64 = 1
	for p < v {
		p *= 2
	}
	return p
}
