
package engine

import "core:sync"

import tracy "../../vendor/tracy"



TRACY_ENABLE :: #config(TRACY_ENABLE, false)

when TRACY_ENABLE {
	ZoneCtx :: tracy.ZoneCtx
} else {
	ZoneCtx :: struct {}
}

zone_end :: #force_inline proc(ctx: ZoneCtx) {
	when TRACY_ENABLE {
		
		if !tracy.ProfilerStarted() do return
		tracy.ZoneEnd(ctx)
	}
}

when TRACY_ENABLE {

	@(deferred_out=zone_end)
	ZoneN :: #force_inline proc(name: string, active := true, loc := #caller_location) -> (ctx: ZoneCtx) {

		if !tracy.ProfilerStarted() do return
		return tracy.ZoneBegin(active, tracy.TRACY_CALLSTACK, name, 0, loc)
	}

	@(deferred_out=zone_end)
	Zone :: #force_inline proc(name: string = "", active := true, loc := #caller_location) -> (ctx: ZoneCtx) {
		if !tracy.ProfilerStarted() do return
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
		if lock.announced && tracy.ProfilerStarted() do tracy.LockBefore(lock.ctx)
	}
	sync.mutex_lock(m)
	when TRACY_ENABLE {
		if lock.announced && tracy.ProfilerStarted() do tracy.LockAfter(lock.ctx)
	}
}

tracing_mutex_unlock :: proc(m: ^sync.Mutex, lock: ^TracingLock) {
	sync.mutex_unlock(m)
	when TRACY_ENABLE {
		if lock.announced && tracy.ProfilerStarted() do tracy.LockAfterUnlock(lock.ctx)
	}
}
