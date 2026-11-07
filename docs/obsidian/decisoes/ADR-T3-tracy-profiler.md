---
id: ADR-T3
titulo: Tracy profiler via odin-tracy, opt-in por define
tipo: decisao
status: aceita
specs_afetadas: [VS-15]
ultima_atualizacao: 2026-11-07
---

# ADR-T3 — Tracy profiler via odin-tracy, opt-in por define

## Contexto

Backlog BLK-25 (adiado pela ADR-T1): integrar um SDK de profiling sobre os pontos de instrumentação. O mantenedor escolheu o **Tracy** ([wolfpld/tracy](https://github.com/wolfpld/tracy)) com as bindings Odin oficiais da comunidade ([oskarnp/odin-tracy](https://github.com/oskarnp/odin-tracy), v0.14.1). Pesquisa dos repos (2026-11-07):

- As bindings envolvem a API C do client; o **wrapper** (`wrapper.odin`) no-opa tudo quando `TRACY_ENABLE=false` (`when`/`@(disabled=...)`), com zones com `@(deferred_out=ZoneEnd)` (fim de escopo automático).
- **Detalhe crítico:** `bindings.odin` faz `foreign import tracy "tracy.lib"` **incondicionalmente** — importar o package exige a `tracy.lib` presente no link mesmo desligado. O client C++ é compilado uma vez pelo `build_windows.cmd` do repo (precisa de toolchain C++ Windows).
- O **servidor/UI Tracy** é binário separado (pre-built no release oficial); o app conecta por TCP ao clicar Connect. Sem UI, o client roda desconectado sem custo relevante.

## Opções

### Opção A — Vendor de bindings + tracy.lib, import condicional, build por define (recomendada)

- Vendora-se os 3 arquivos de binding (`bindings.odin`, `wrapper.odin`, `allocator.odin`) + `tracy.lib` pré-compilada em `vendor/tracy/`, com `tools/build_tracy_client.bat` documentando a reprodução (clone de oskarnp/odin-tracy com submodule, tracy v0.14.1, `build_windows.cmd`).
- Wrapper próprio `engine/tracing.odin`: `import tracy` dentro de `when TRACY_ENABLE` — com o define **desligado** (padrão do `run.bat`) o package nem é importado e **nenhuma dependência de link existe**; ligado (`run_tracy.bat`, `-define:TRACY_ENABLE=true`), a API vira as chamadas reais. A telemetria VS-05 (CSV/JSON, labels) permanece a base, inalterada — Tracy é aditivo.
- V1: **zones de CPU** (frame total, update de engine/streaming, dreno de eventos, gravação do frame, espera de timeline, worker) + `FrameMark` por frame + nomes de thread + poucos plots (`visible_chunks`, `work_items`) + `AppInfo`.
- Vantagens: build default intocado; custo zero desligado; reprodutível (script de rebuild versionado); sem churn na pipeline Vulkan.
- Desvantagens: `tracy.lib` binária versionada no repo (alternativa seria exigir setup manual, quebrando o build Tracy fora da caixa).

### Opção B — Import incondicional, lib sempre necessária

- `run.bat` passa a exigir `tracy.lib` presente para qualquer build. Simples, mas piora o caminho default por causa de uma ferramenta opt-in.

### Opção C — Integração via servidor manual só (documentar pontos)

- Não integra — não cumpre o pedido.

## Decisão

**Opção A** — vendor de bindings + tracy.lib com script de reprodução, import condicional sob `when TRACY_ENABLE` (build default sem dependência de link), build Tracy via `run_tracy.bat`, zones de CPU + FrameMark + thread names + plots, telemetria VS-05 inalterada. Ratificada pelo mantenedor em 2026-11-07, junto à aprovação da VS-15.

## Consequências

- `run_tracy.bat` novo (shaders + `odin build -define:TRACY_ENABLE=true` + executa); `run.bat` inalterado.
- AC de ponta a ponta exige a UI Tracy (binário do release oficial) — parte manual do mantenedor, como foi o AC-01 da VS-05; o automatizado cobre build ligado/desligado, smoke e `IsConnected()=false` sem servidor.
- Backlog pós-VS-15: GPU zones (`TracyVkContext` + calibração por fila), memory profiling (allocator custom do odin-tracy), lock tracking (`LockCtx` nos mutexes), call stacks (`TRACY_CALLSTACK`), sampling. BLK-25 sai do backlog.

## Histórico

- 2026-11-07 — Decisão registrada como pendente, com recomendação da Opção A (pesquisa dos repos oskarnp/odin-tracy e wolfpld/tracy em anexo no Contexto); bloqueia a aprovação da VS-15 até a ratificação do mantenedor.
- 2026-11-07 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-15.
