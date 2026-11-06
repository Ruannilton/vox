package engine


import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import vma "shared:vma"
import vk "vendor:vulkan"

TELEMETRY_DEFAULT_ENABLED :: true

TelemetryOperation :: enum {
	Generate,
	Pack,
	ApplyEdits,
	BuildWorkQueue,
	FinalizeWorkQueue,
	MeshDraw,
	FrameTotal,
}
TELEMETRY_OPERATION_COUNT :: 7

TELEMETRY_GFX_QUERY_COUNT     :: 16 // 5 operações + frame total (pares) = 12 ≤ 16
TELEMETRY_COMPUTE_QUERY_COUNT :: 8  // generate + pack (pares) = 4 ≤ 8


TelemetryHeapSample :: struct {
	used_bytes:       u64,
	budget_bytes:     u64,
	block_bytes:      u64,
	allocation_bytes: u64,
	block_count:      u32,
	allocation_count: u32,
}

Telemetry :: struct {
	enabled:             bool,
	times_available:     bool,
	timestamp_period_ns: f64,
	gfx_pools:           [NUM_FRAMES_IN_FLIGHT]vk.QueryPool,
	compute_pools:       [MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT]vk.QueryPool,
	results_mutex:       sync.Mutex,
	last_times_us:       [TELEMETRY_OPERATION_COUNT]f64,
	heap_count:          u32,
	heaps:               [vk.MAX_MEMORY_HEAPS]TelemetryHeapSample,
	csv_file:            ^os.File,
	last_csv_tick:       time.Tick,
}

TELEMETRY_CSV_INTERVAL_MS :: 500.0 // intervalo da série temporal (0 = desligada)
TELEMETRY_DIR :: "telemetry" // relativo ao cwd (bin/)

@(private)
telemetry_timestamp_string :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec := time.clock(now)
	return fmt.tprintf("%04d%02d%02d_%02d%02d%02d", year, int(month), day, hour, min, sec)
}

telemetry: Telemetry

telemetry_init :: proc() {
	telemetry.enabled = TELEMETRY_DEFAULT_ENABLED
	if !telemetry.enabled do return

	memory_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(app.vkPhysicalDevice, &memory_properties)
	telemetry.heap_count = memory_properties.memoryHeapCount

	telemetry_csv_open()

	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(app.vkPhysicalDevice, &properties)
	telemetry.timestamp_period_ns = f64(properties.limits.timestampPeriod)

	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(app.vkPhysicalDevice, &queue_family_count, nil)
	queue_families := make([]vk.QueueFamilyProperties, queue_family_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(app.vkPhysicalDevice, &queue_family_count, raw_data(queue_families))

	gfx_bits := queue_families[app.queues[.Graphics].familyIndex].timestampValidBits
	cmp_bits := queue_families[app.queues[.Compute].familyIndex].timestampValidBits
	telemetry.times_available =
		telemetry.timestamp_period_ns > 0 &&
		bool(properties.limits.timestampComputeAndGraphics) &&
		gfx_bits > 0 && cmp_bits > 0

	if !telemetry.times_available {
		return
	}
	gfx_pool_info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = TELEMETRY_GFX_QUERY_COUNT,
	}
	for &pool in telemetry.gfx_pools {
		vk_check(vk.CreateQueryPool(app.vkDevice, &gfx_pool_info, nil, &pool))
	}
	compute_pool_info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = TELEMETRY_COMPUTE_QUERY_COUNT,
	}
	for &pool in telemetry.compute_pools {
		vk_check(vk.CreateQueryPool(app.vkDevice, &compute_pool_info, nil, &pool))
	}
}

telemetry_destroy :: proc() {
	for pool in telemetry.gfx_pools {
		if pool != 0 do vk.DestroyQueryPool(app.vkDevice, pool, nil)
	}
	for pool in telemetry.compute_pools {
		if pool != 0 do vk.DestroyQueryPool(app.vkDevice, pool, nil)
	}
	if telemetry.csv_file != nil {
		os.close(telemetry.csv_file)
	}
}

telemetry_toggle :: proc() {
	telemetry.enabled = !telemetry.enabled
}

// --- Regiões nomeadas (EXT_debug_utils; carregadas com o instance) ---

telemetry_begin_label :: proc(cmd: vk.CommandBuffer, name: cstring) {
	if !telemetry.enabled do return
	vk.CmdBeginDebugUtilsLabelEXT(
		cmd,
		&vk.DebugUtilsLabelEXT {
			sType      = .DEBUG_UTILS_LABEL_EXT,
			pLabelName = name,
		},
	)
}

telemetry_end_label :: proc(cmd: vk.CommandBuffer) {
	if !telemetry.enabled do return
	vk.CmdEndDebugUtilsLabelEXT(cmd)
}

// Nomeia um objeto Vulkan para as capturas (buffers, pipelines, pools).
telemetry_name_object :: proc(object: u64, type: vk.ObjectType, name: cstring) {
	if !telemetry.enabled do return
	vk.SetDebugUtilsObjectNameEXT(
		app.vkDevice,
		&vk.DebugUtilsObjectNameInfoEXT {
			sType        = .DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
			objectType   = type,
			objectHandle = object,
			pObjectName  = name,
		},
	)
}

// --- Timestamps GPU (REQ-PROF-02) ---

telemetry_timestamp_begin :: proc(cmd: vk.CommandBuffer, pool: vk.QueryPool, query: u32) {
	if !telemetry.enabled || !telemetry.times_available do return
	vk.CmdWriteTimestamp2(cmd, {.TOP_OF_PIPE}, pool, query)
}

telemetry_timestamp_end :: proc(cmd: vk.CommandBuffer, pool: vk.QueryPool, query: u32) {
	if !telemetry.enabled || !telemetry.times_available do return
	vk.CmdWriteTimestamp2(cmd, {.BOTTOM_OF_PIPE}, pool, query)
}

telemetry_reset_pool :: proc(cmd: vk.CommandBuffer, pool: vk.QueryPool, query_count: u32) {
	if !telemetry.enabled || !telemetry.times_available do return
	vk.CmdResetQueryPool(cmd, pool, 0, query_count)
}

@(private)
telemetry_publish_pair :: proc(op: TelemetryOperation, values: []u64) {
	begin_value, begin_ok := values[0], values[1]
	end_value, end_ok := values[2], values[3]
	if begin_ok == 0 || end_ok == 0 do return
	if end_value <= begin_value do return
	sync.mutex_lock(&telemetry.results_mutex)
	telemetry.last_times_us[op] = f64(end_value - begin_value) * telemetry.timestamp_period_ns / 1000.0
	sync.mutex_unlock(&telemetry.results_mutex)
}

telemetry_collect_graphics :: proc(frame_index: u32) {
	if !telemetry.enabled || !telemetry.times_available do return
	pool := telemetry.gfx_pools[frame_index]
	if pool == 0 do return

	OpQuery :: struct {
		op:    TelemetryOperation,
		first: u32,
	}
	gfx_ops := [?]OpQuery {
		{.FrameTotal, 0},
		{.ApplyEdits, 2},
		{.BuildWorkQueue, 4},
		{.FinalizeWorkQueue, 6},
		{.MeshDraw, 8},
	}
	for entry in gfx_ops {
		values: [4]u64 // (valor, disponibilidade) × 2 queries
		res := vk.GetQueryPoolResults(
			app.vkDevice,
			pool,
			entry.first,
			2,
			size_of(values),
			raw_data(&values),
			16,
			{._64, .WITH_AVAILABILITY},
		)
		if res != .SUCCESS do continue
		telemetry_publish_pair(entry.op, values[:])
	}
}

telemetry_collect_compute :: proc(ring_index: int) {
	if !telemetry.enabled || !telemetry.times_available do return
	pool := telemetry.compute_pools[ring_index]
	if pool == 0 do return

	QUERY_COUNT :: 4
	values: [QUERY_COUNT * 2]u64
	res := vk.GetQueryPoolResults(
		app.vkDevice,
		pool,
		0,
		QUERY_COUNT,
		size_of(values),
		raw_data(&values),
		16, // (valor u64, disponibilidade u64) por query
		{._64, .WITH_AVAILABILITY},
	)
	if res != .SUCCESS do return

	telemetry_publish_pair(.Generate, values[0:4])
	telemetry_publish_pair(.Pack, values[4:8])
}

// --- VRAM (REQ-PROF-03) ---

telemetry_collect_vram :: proc() {
	if !telemetry.enabled do return

	budgets: [vk.MAX_MEMORY_HEAPS]vma.Budget
	vma.GetHeapBudgets(app.vmaAllocator, &budgets[0])
	stats: vma.TotalStatistics
	vma.CalculateStatistics(app.vmaAllocator, &stats)

	for heap in 0 ..< telemetry.heap_count {
		budget := budgets[heap]
		heap_stats := stats.memoryHeap[heap].statistics
		telemetry.heaps[heap] = TelemetryHeapSample {
			used_bytes       = u64(budget.usage),
			budget_bytes     = u64(budget.budget),
			block_bytes      = u64(heap_stats.blockBytes),
			allocation_bytes = u64(heap_stats.allocationBytes),
			block_count      = heap_stats.blockCount,
			allocation_count = heap_stats.allocationCount,
		}
	}
}

// --- Export para arquivo (REQ-PROF-04) ---

@(private)
telemetry_csv_open :: proc() {
	if TELEMETRY_CSV_INTERVAL_MS <= 0 do return
	os.make_directory(TELEMETRY_DIR)
	path := fmt.tprintf("%s/telemetry_%s.csv", TELEMETRY_DIR, telemetry_timestamp_string())
	handle, err := os.open(path, os.O_CREATE | os.O_WRONLY | os.O_APPEND)
	if err != nil {
		log.warnf("VS-05: não foi possível abrir o CSV de telemetria em {}: {}", path, err)
		return
	}
	telemetry.csv_file = handle
	telemetry.last_csv_tick = time.tick_now()

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "timestamp_ms,tick,generate_us,pack_us,apply_edits_us,build_work_queue_us,finalize_work_queue_us,mesh_draw_us,frame_total_us")
	for heap in 0 ..< telemetry.heap_count {
		fmt.sbprintf(&sb, ",heap%d_used_mib,heap%d_budget_mib", heap, heap)
	}
	fmt.sbprintln(&sb)
	os.write_string(handle, strings.to_string(sb))
	log.infof("VS-05: série temporal de telemetria em {}", path)
}

telemetry_service :: proc() {
	if !telemetry.enabled || telemetry.csv_file == nil do return
	if time.duration_milliseconds(time.tick_since(telemetry.last_csv_tick)) < TELEMETRY_CSV_INTERVAL_MS do return
	telemetry.last_csv_tick = time.tick_now()

	telemetry_collect_vram()

	sync.mutex_lock(&telemetry.results_mutex)
	times := telemetry.last_times_us
	sync.mutex_unlock(&telemetry.results_mutex)

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%d,%d", i64(time.duration_milliseconds(time.tick_since(session_start_tick))), app.tick)
	for op in TelemetryOperation {
		fmt.sbprintf(&sb, ",%.2f", times[op])
	}
	for heap in 0 ..< telemetry.heap_count {
		sample := telemetry.heaps[heap]
		fmt.sbprintf(&sb, ",%.1f,%.1f", f64(sample.used_bytes) / 1048576.0, f64(sample.budget_bytes) / 1048576.0)
	}
	fmt.sbprintln(&sb)
	os.write_string(telemetry.csv_file, strings.to_string(sb))
}

session_start_tick := time.tick_now()

telemetry_snapshot :: proc() {
	if !telemetry.enabled do return

	telemetry_collect_vram()
	stats_string: cstring
	vma.BuildStatsString(app.vmaAllocator, &stats_string, true)
	defer vma.FreeStatsString(app.vmaAllocator, stats_string)

	sync.mutex_lock(&telemetry.results_mutex)
	times := telemetry.last_times_us
	sync.mutex_unlock(&telemetry.results_mutex)

	sb := strings.builder_make(context.temp_allocator)

	strings.write_string(&sb, "{\n")
	fmt.sbprintf(&sb, "  \"captured_at\": \"%s\",\n", telemetry_timestamp_string())
	fmt.sbprintf(&sb, "  \"tick\": %d,\n", app.tick)
	fmt.sbprintf(&sb, "  \"times_available\": %t,\n", telemetry.times_available)
	strings.write_string(&sb, "  \"times_us\": {")
	for op, i in TelemetryOperation {
		if i > 0 do fmt.sbprintf(&sb, ", ")
		fmt.sbprintf(&sb, "\"%s\": %.2f", fmt.tprint(op), times[op])
	}
	strings.write_string(&sb, "},\n")
	strings.write_string(&sb, "  \"heaps\": [\n")
	for heap in 0 ..< telemetry.heap_count {
		sample := telemetry.heaps[heap]
		strings.write_string(&sb, "    {\"heap\": ")
		fmt.sbprintf(&sb, "%d, \"used_mib\": %.1f, \"budget_mib\": %.1f, \"block_mib\": %.1f, \"allocation_mib\": %.1f, \"blocks\": %d, \"allocations\": %d",
			heap,
			f64(sample.used_bytes) / 1048576.0,
			f64(sample.budget_bytes) / 1048576.0,
			f64(sample.block_bytes) / 1048576.0,
			f64(sample.allocation_bytes) / 1048576.0,
			sample.block_count,
			sample.allocation_count,
		)
		if heap + 1 < telemetry.heap_count {
			strings.write_string(&sb, "},\n")
		} else {
			strings.write_string(&sb, "}\n")
		}
	}
	strings.write_string(&sb, "  ],\n")
	fmt.sbprintf(&sb, "  \"vma_detailed_map\": %s\n", stats_string)
	strings.write_string(&sb, "}\n")

	os.make_directory(TELEMETRY_DIR)
	path := fmt.tprintf("%s/telemetry_%s_snapshot.json", TELEMETRY_DIR, telemetry_timestamp_string())
	handle, err := os.open(path, os.O_CREATE | os.O_WRONLY | os.O_TRUNC)
	if err != nil {
		log.warnf("VS-05: não foi possível abrir o snapshot em {}: {}", path, err)
		return
	}
	os.write_string(handle, strings.to_string(sb))
	os.close(handle)
	log.infof("VS-05: snapshot de telemetria em {}", path)
}
