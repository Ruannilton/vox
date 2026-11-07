// VS-15 (REQ-TRC-02): wrapper opt-in do Tracy. Único módulo que importa o
// package tracy (vendored em vendor/tracy/). Com TRACY_ENABLE=false (padrão
// do run.bat) nada é importado e toda a API compila para no-op inline;
// ligado (-define:TRACY_ENABLE=true, run_tracy.bat), delega ao wrapper do
// odin-tracy.

package engine

TRACY_ENABLE :: #config(TRACY_ENABLE, false)

// Odin não permite `import` dentro de `when`; o package é importado sempre,
// mas com TRACY_ENABLE=false o próprio package no-opa toda a API e o foreign
// import condicional (bindings.odin) elimina a dependência de link.
import tracy "../../vendor/tracy"

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
	@(deferred_out=zone_end)
	ZoneN :: #force_inline proc(name: string, active := true) -> (ctx: ZoneCtx) {
		return tracy.ZoneN(name, active)
	}

	@(deferred_out=zone_end)
	Zone :: #force_inline proc(name: string = "", active := true) -> (ctx: ZoneCtx) {
		return tracy.ZoneN(name, active)
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
