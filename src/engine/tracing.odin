// VS-15 (REQ-TRC-02): wrapper opt-in do Tracy. Único módulo que importa o
// package tracy (vendored em vendor/tracy/). Com TRACY_ENABLE=false (padrão
// do run.bat) nada é importado e toda a API compila para no-op inline;
// ligado (-define:TRACY_ENABLE=true, run_tracy.bat), delega ao wrapper do
// odin-tracy.

package engine

import "core:sync"

import tracy "../../vendor/tracy"

// Odin não permite import em when: o package entra sempre, mas com
// TRACY_ENABLE=false a API dele no-opa e o foreign import vira kernel32.

TRACY_ENABLE :: #config(TRACY_ENABLE, false)

when TRACY_ENABLE {
	ZoneCtx :: tracy.ZoneCtx
} else {
	ZoneCtx :: struct {}
}

zone_end :: #force_inline proc(ctx: ZoneCtx) {
	when TRACY_ENABLE {
		tracy.ZoneEnd(ctx)
	}
}

when TRACY_ENABLE {
	// Chama ZoneBegin (sem defer) e é o ÚNICO dono do par deferido: as
	// procs ZoneN/Zone do odin-tracy já têm @(deferred_out=ZoneEnd), então
	// delegar a elas com defer próprio emitia dois ZoneEnd por ZoneBegin
	// ("zone ended twice" na UI/capture Tracy). Depth vem de TRACY_CALLSTACK
	// (REQ-CPU-02: run_tracy.bat passa 10).
	@(deferred_out=zone_end)
	ZoneN :: #force_inline proc(name: string, active := true, loc := #caller_location) -> (ctx: ZoneCtx) {
		return tracy.ZoneBegin(active, tracy.TRACY_CALLSTACK, name, 0, loc)
	}

	@(deferred_out=zone_end)
	Zone :: #force_inline proc(name: string = "", active := true, loc := #caller_location) -> (ctx: ZoneCtx) {
		return tracy.ZoneBegin(active, tracy.TRACY_CALLSTACK, name, 0, loc)
	}
} else {
	@(deferred_out=zone_end)
	ZoneN :: #force_inline proc(name: string, active := true) -> (ctx: ZoneCtx) {
		return
	}

	@(deferred_out=zone_end)
	Zone :: #force_inline proc(name: string = "", active := true) -> (ctx: ZoneCtx) {
		return
	}
}

FrameMark :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy.FrameMark()
	}
}

PlotInt :: #force_inline proc(name: cstring, value: i64) {
	when TRACY_ENABLE {
		tracy.PlotI(name, value)
	}
}

SetThreadName :: #force_inline proc(name: cstring) {
	when TRACY_ENABLE {
		tracy.SetThreadName(name)
	}
}

Message :: #force_inline proc(text: string) {
	when TRACY_ENABLE {
		tracy.MessageS(text)
	}
}

AppInfo :: #force_inline proc(text: string) {
	when TRACY_ENABLE {
		tracy.AppInfo(text)
	}
}

TracingIsConnected :: #force_inline proc() -> bool {
	when TRACY_ENABLE {
		return tracy.IsConnected()
	} else {
		return false
	}
}

// VS-15 (BLK-37): com a lib em TRACY_MANUAL_LIFETIME + TRACY_DELAYED_INIT o
// profiler nasce só aqui — depois do init Vulkan/GLFW, que conflitava com o
// client Tracy ativo desde o CRT init (hang em vkCreateComputePipelines).
// Só chamar com TRACY_ENABLE ligado e fora do intervalo nenhuma API Tracy
// pode ser usada (GetProfiler asserta com o profiler não iniciado).
// VS-16: o startup também sobe os contextos GPU (tracing_gpu_init) e
// anuncia os locks rastreados; só o teardown completo coleta as zonas GPU
// restantes antes de descer o profiler.
TracingStartup :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy.StartupProfiler()
		tracing_gpu_init()
		tracing_locks_init()
	}
}

TracingShutdown :: #force_inline proc(full_teardown := true) {
	when TRACY_ENABLE {
		if full_teardown do tracing_gpu_shutdown()
		tracy.ShutdownProfiler()
	}
}

// VS-16 (REQ-CPU-03): lock tracking nos mutexes principais. Anúncio único
// no startup; os wrappers emitem before/after lock ao redor do sync.Mutex.
// Os srclocs precisam de storage estático: o protocolo envia o ponteiro
// bruto ao servidor (lockAnnounce.lckloc = srcloc).
when TRACY_ENABLE {
	TracingLock :: struct {
		ctx:       ^tracy.LockCtx,
		announced: bool,
	}

	@(private)
	queue_lock_srcloc := tracy.SourceLocationData {
		name     = "queue_mutex",
		function = "queue_mutex",
		file     = "src/engine/voxel_engine.odin",
		line     = 0,
		color    = 0,
	}

	@(private)
	results_lock_srcloc := tracy.SourceLocationData {
		name     = "results_mutex",
		function = "results_mutex",
		file     = "src/engine/telemetry.odin",
		line     = 0,
		color    = 0,
	}
} else {
	TracingLock :: struct {}
}

tracing_queue_lock: TracingLock
tracing_results_lock: TracingLock

tracing_locks_init :: proc() {
	when TRACY_ENABLE {
		tracing_queue_lock.ctx = tracy.LockAnnounce(&queue_lock_srcloc)
		tracing_results_lock.ctx = tracy.LockAnnounce(&results_lock_srcloc)
		tracing_queue_lock.announced = true
		tracing_results_lock.announced = true
	}
}

tracing_mutex_lock :: proc(m: ^sync.Mutex, lock: ^TracingLock) {
	when TRACY_ENABLE {
		if lock.announced do tracy.LockBefore(lock.ctx)
	}
	sync.mutex_lock(m)
	when TRACY_ENABLE {
		if lock.announced do tracy.LockAfter(lock.ctx)
	}
}

tracing_mutex_unlock :: proc(m: ^sync.Mutex, lock: ^TracingLock) {
	sync.mutex_unlock(m)
	when TRACY_ENABLE {
		if lock.announced do tracy.LockAfterUnlock(lock.ctx)
	}
}
