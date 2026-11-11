// VS-16 (REQ-GPU-01/02/03): zonas GPU do Tracy sobre query pools dedicadas.
// Dois contextos (gráfica = 0, compute = 1), ring de slots de timestamp com
// coleta nos pontos de espera existentes. Com TRACY_ENABLE=false tudo é
// no-op e nenhuma query pool é criada (VS-05 intacta e independente).

package engine

import "core:log"
import vk "vendor:vulkan"

import tracy "../../vendor/tracy"

TRACING_GPU_CONTEXT_GRAPHICS :: 0
TRACING_GPU_CONTEXT_COMPUTE  :: 1
TRACING_GPU_CONTEXT_COUNT    :: 2

// Ring por contexto: cada zona usa 2 slots (begin/end) alocados em par;
// o slot 0 é reservado para a calibração inicial e o último para o
// gpu_time_sync periódico.
TRACING_GPU_RING_SIZE       :: 4096
TRACING_GPU_ZONE_SLOT_FIRST :: 2
TRACING_GPU_ZONE_SLOT_LIMIT :: TRACING_GPU_RING_SIZE - 1
TRACING_GPU_RING_MARGIN     :: 64
TRACING_GPU_SYNC_INTERVAL   :: 60

TRACING_GPU_CALIB_SLOT :: 0
TRACING_GPU_SYNC_SLOT  :: TRACING_GPU_RING_SIZE - 1

GpuTracingContext :: struct {
	query_pool:        vk.QueryPool,
	period_ns:         f32, // timestampPeriod do device (ns por tick)
	record_pos:        u64, // próximo slot absoluto a alocar
	collect_pos:       u64, // próximo slot absoluto a coletar
	reset_pos:         u64, // faixa [reset_pos, collect_pos) aguardando reset
	frames_since_sync: u32,
	sync_pending:      bool,
	omitted_logged:    bool,
}

@(private)
gpu_tracing: struct {
	active:   bool,
	contexts: [TRACING_GPU_CONTEXT_COUNT]GpuTracingContext,
}


tracing_gpu_init :: proc() {
	when TRACY_ENABLE {
		create_context :: proc(ctx_index: int, queue: vk.Queue, family: u32) {
			ctx := &gpu_tracing.contexts[ctx_index]
			vk_check(
				vk.CreateQueryPool(
					app.vkDevice,
					&vk.QueryPoolCreateInfo {
						sType = .QUERY_POOL_CREATE_INFO,
						queryType = .TIMESTAMP,
						queryCount = TRACING_GPU_RING_SIZE,
					},
					nil,
					&ctx.query_pool,
				),
			)

			props: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(app.vkPhysicalDevice, &props)
			ctx.period_ns = props.limits.timestampPeriod

			// Reset inicial + calibração: um único submit bloqueante por
			// contexto, só aqui no startup (padrão TracyVkContext).
			cmd_pool: vk.CommandPool
			vk_check(
				vk.CreateCommandPool(
					app.vkDevice,
					&vk.CommandPoolCreateInfo {
						sType = .COMMAND_POOL_CREATE_INFO,
						queueFamilyIndex = family,
						flags = {.TRANSIENT},
					},
					nil,
					&cmd_pool,
				),
			)
			defer vk.DestroyCommandPool(app.vkDevice, cmd_pool, nil)

			cmd := alloc_setup_command_buffer(cmd_pool)
			begin_setup_command_buffer(cmd)
			vk.CmdResetQueryPool(cmd, ctx.query_pool, 0, TRACING_GPU_RING_SIZE)
			vk.CmdWriteTimestamp2(cmd, {.TOP_OF_PIPE}, ctx.query_pool, TRACING_GPU_CALIB_SLOT)
			vk_check(vk.EndCommandBuffer(cmd))

			fence := create_setup_fence()
			defer vk.DestroyFence(app.vkDevice, fence, nil)
			submit_and_wait(queue, cmd, fence)

			calibration_value := read_calibration_value(ctx.query_pool)
			context_id := u8(ctx_index)
			tracy.GpuNewContext(calibration_value, ctx.period_ns, context_id)
			tracy.GpuContextName(
				context_id == TRACING_GPU_CONTEXT_GRAPHICS ? "graphics" : "compute",
				context_id,
			)

			ctx.record_pos = TRACING_GPU_ZONE_SLOT_FIRST
			ctx.collect_pos = TRACING_GPU_ZONE_SLOT_FIRST
			ctx.reset_pos = TRACING_GPU_ZONE_SLOT_FIRST
		}

		create_context(TRACING_GPU_CONTEXT_GRAPHICS, app.queues[.Graphics].queue, app.queues[.Graphics].familyIndex)
		create_context(TRACING_GPU_CONTEXT_COMPUTE, app.queues[.Compute].queue, app.queues[.Compute].familyIndex)

		gpu_tracing.active = true
	}
}

tracing_gpu_shutdown :: proc() {
	when TRACY_ENABLE {
		if !gpu_tracing.active do return
		// Coleta final com a GPU ociosa (worker encerrado e DeviceWaitIdle
		// no corpo de main) — drena o restante antes de descer o profiler.
		vk_check(vk.DeviceWaitIdle(app.vkDevice))
		for i in 0 ..< TRACING_GPU_CONTEXT_COUNT {
			collect_range(u8(i), true)
		}
		gpu_tracing.active = false
		for &ctx in gpu_tracing.contexts {
			vk.DestroyQueryPool(app.vkDevice, ctx.query_pool, nil)
			ctx.query_pool = {}
		}
	}
}

// Uma vez por command buffer que grava zonas do contexto: aplica os resets
// pendentes de faixas já coletadas e, a cada TRACING_GPU_SYNC_INTERVAL
// frames, grava o timestamp de re-sync.
tracing_gpu_record_context :: proc(cmd: vk.CommandBuffer, context_index: u8) {
	when TRACY_ENABLE {
		if !gpu_tracing.active do return
		ctx := &gpu_tracing.contexts[context_index]

		reset_from := ctx.reset_pos
		for reset_from < ctx.collect_pos {
			slot := u32(reset_from % TRACING_GPU_RING_SIZE)
			count := u32(min(ctx.collect_pos - reset_from, u64(TRACING_GPU_RING_SIZE) - u64(slot)))
			vk.CmdResetQueryPool(cmd, ctx.query_pool, slot, count)
			reset_from += u64(count)
		}
		ctx.reset_pos = reset_from

		if ctx.frames_since_sync >= TRACING_GPU_SYNC_INTERVAL && !ctx.sync_pending {
			vk.CmdResetQueryPool(cmd, ctx.query_pool, TRACING_GPU_SYNC_SLOT, 1)
			vk.CmdWriteTimestamp2(cmd, {.TOP_OF_PIPE}, ctx.query_pool, TRACING_GPU_SYNC_SLOT)
			ctx.sync_pending = true
			ctx.frames_since_sync = 0
		}
	}
}

// Aloca o par de slots e emite gpu_zone_begin. Retorna o queryId (slot de
// begin) ou max(u16) quando a zona foi omitida (ring sob pressão).
tracing_gpu_zone_begin :: proc(
	cmd: vk.CommandBuffer,
	context_index: u8,
	name: string,
	loc := #caller_location,
) -> u16 {
	when TRACY_ENABLE {
		if !gpu_tracing.active do return max(u16)
		ctx := &gpu_tracing.contexts[context_index]

		if ctx.record_pos - ctx.collect_pos >= u64(TRACING_GPU_ZONE_SLOT_LIMIT - TRACING_GPU_RING_MARGIN) {
			if !ctx.omitted_logged {
				log.warnf(
					"VS-16: zonas GPU omitidas no contexto {} (ring sob pressão)",
					context_index,
				)
				ctx.omitted_logged = true
			}
			return max(u16)
		}

		slot := ctx.record_pos
		// o par nunca cruza o fim do ring nem toca o slot de sync
		if slot % TRACING_GPU_RING_SIZE >= TRACING_GPU_ZONE_SLOT_LIMIT - 1 {
			slot = (slot / TRACING_GPU_RING_SIZE + 1) * TRACING_GPU_RING_SIZE + TRACING_GPU_ZONE_SLOT_FIRST
		}
		ctx.record_pos = slot + 2

		query_id := u16(slot % TRACING_GPU_RING_SIZE)
		vk.CmdWriteTimestamp2(cmd, {.TOP_OF_PIPE}, ctx.query_pool, u32(query_id))
		srcloc := tracy.AllocSrclocName(u32(loc.line), loc.file_path, loc.procedure, name)
		tracy.GpuZoneBegin(srcloc, query_id, context_index)
		return query_id
	} else {
		return max(u16)
	}
}

tracing_gpu_zone_end :: proc(cmd: vk.CommandBuffer, context_index: u8, query_id: u16) {
	when TRACY_ENABLE {
		if !gpu_tracing.active || query_id == max(u16) do return
		ctx := &gpu_tracing.contexts[context_index]
		vk.CmdWriteTimestamp2(cmd, {.BOTTOM_OF_PIPE}, ctx.query_pool, u32(query_id) + 1)
		tracy.GpuZoneEnd(query_id + 1, context_index)
	}
}

tracing_gpu_collect_graphics :: proc() {
	when TRACY_ENABLE {
		if !gpu_tracing.active do return
		gpu_tracing.contexts[TRACING_GPU_CONTEXT_GRAPHICS].frames_since_sync += 1
		collect_range(TRACING_GPU_CONTEXT_GRAPHICS, false)
	}
}

tracing_gpu_collect_compute :: proc() {
	when TRACY_ENABLE {
		if !gpu_tracing.active do return
		gpu_tracing.contexts[TRACING_GPU_CONTEXT_COMPUTE].frames_since_sync += 1
		collect_range(TRACING_GPU_CONTEXT_COMPUTE, false)
	}
}

@(private)
collect_range :: proc(context_index: u8, drain: bool) {
	when TRACY_ENABLE {
	ctx := &gpu_tracing.contexts[context_index]

	// Zonas pendentes: leitura com disponibilidade, em blocos que não
	// cruzam o fim do ring; emite gpu_time para os pares completos.
	for ctx.collect_pos + 1 < ctx.record_pos {
		slot := u32(ctx.collect_pos % TRACING_GPU_RING_SIZE)
		pairs_here := min(
			(ctx.record_pos - ctx.collect_pos) / 2,
			u64(TRACING_GPU_RING_SIZE-slot) / 2,
		)
		if pairs_here == 0 do break
		queries := u32(min(pairs_here * 2, 256))

		values: [512]u64
		res := vk.GetQueryPoolResults(
			app.vkDevice,
			ctx.query_pool,
			slot,
			queries,
			size_of(values),
			raw_data(&values),
			16,
			{._64, .WITH_AVAILABILITY},
		)
		if res != .SUCCESS do return

		completed: u32 = 0
		for i := u32(0); i + 1 < queries; i += 2 {
			if values[i * 2 + 1] == 0 || values[(i + 1) * 2 + 1] == 0 do break
			query_id := u16((slot + i) % TRACING_GPU_RING_SIZE)
			tracy.GpuTime(i64(values[i * 2]), query_id, context_index)
			tracy.GpuTime(i64(values[(i + 1) * 2]), query_id + 1, context_index)
			completed += 2
		}
		ctx.collect_pos += u64(completed)
		if completed < queries do break // restante ainda em voo
	}

	// Slot de re-sync: quando disponível, emite gpu_time_sync.
	if ctx.sync_pending {
		value: [2]u64
		res := vk.GetQueryPoolResults(
			app.vkDevice,
			ctx.query_pool,
			TRACING_GPU_SYNC_SLOT,
			1,
			size_of(value),
			raw_data(&value),
			16,
			{._64, .WITH_AVAILABILITY},
		)
		if res == .SUCCESS && value[1] != 0 {
			tracy.GpuTimeSync(i64(value[0]), context_index)
			ctx.sync_pending = false
		}
	}
	}
}

@(private)
alloc_setup_command_buffer :: proc(cmd_pool: vk.CommandPool) -> vk.CommandBuffer {
	cmd: vk.CommandBuffer
	vk_check(
		vk.AllocateCommandBuffers(
			app.vkDevice,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = cmd_pool,
				level = .PRIMARY,
				commandBufferCount = 1,
			},
			&cmd,
		),
	)
	return cmd
}

@(private)
begin_setup_command_buffer :: proc(cmd: vk.CommandBuffer) {
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo {
				sType = .COMMAND_BUFFER_BEGIN_INFO,
				flags = {.ONE_TIME_SUBMIT},
			},
		),
	)
}

@(private)
create_setup_fence :: proc() -> vk.Fence {
	fence: vk.Fence
	vk_check(
		vk.CreateFence(
			app.vkDevice,
			&vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO},
			nil,
			&fence,
		),
	)
	return fence
}

@(private)
submit_and_wait :: proc(queue: vk.Queue, cmd: vk.CommandBuffer, fence: vk.Fence) {
	fence_handle := fence
	vk_check(
		vk.QueueSubmit2(
			queue,
			1,
			&vk.SubmitInfo2 {
				sType = .SUBMIT_INFO_2,
				commandBufferInfoCount = 1,
				pCommandBufferInfos = &vk.CommandBufferSubmitInfo {
					sType = .COMMAND_BUFFER_SUBMIT_INFO,
					commandBuffer = cmd,
				},
			},
			fence_handle,
		),
	)
	vk_check(vk.WaitForFences(app.vkDevice, 1, &fence_handle, true, max(u64)))
}

@(private)
read_calibration_value :: proc(pool: vk.QueryPool) -> i64 {
	value: [2]u64
	vk_check(
		vk.GetQueryPoolResults(
			app.vkDevice,
			pool,
			TRACING_GPU_CALIB_SLOT,
			1,
			size_of(value),
			raw_data(&value),
			16,
			{._64},
		),
	)
	return i64(value[0])
}
