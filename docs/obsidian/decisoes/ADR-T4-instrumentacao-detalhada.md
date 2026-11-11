---
id: ADR-T4
titulo: Instrumentação detalhada — GPU zones e CPU aprofundada
tipo: decisao
status: aceita
specs_afetadas: [VS-16]
ultima_atualizacao: 2026-11-07
---

# ADR-T4 — Instrumentação detalhada: GPU zones (TracyVk) + CPU aprofundada

## Contexto

A VS-15 entregou Tracy CPU (zones básicas, FrameMark, plots) e fechou o ciclo de vida do client (manual lifetime pós-init Vulkan — BLK-37). O mantenedor quer instrumentação **detalhada**, incluindo **GPU**: as passagens GPU (generate/pack na fila de compute; apply_edits/build_work_queue/finalize/draw na fila gráfica) devem aparecer como zonas na timeline do Tracy, correlacionadas com as zonas CPU. CPU: call stacks, lock tracking e sub-zones nas etapas internas.

## Requisitos relacionados

- REQ-GPU-01..03, REQ-CPU-01..03 e REQ-VAL da [[VS-16-instrumentacao-detalhada|VS-16]].

## Opções

### Opção A — TracyVk nativo com query pools dedicadas + CPU aprofundada (recomendada)

- **GPU:** módulo `engine/tracing_gpu.odin` escrito sobre as primitivas `___tracy_emit_gpu_*` do odin-tracy (que não têm wrapper de alto nível): um contexto Tracy por fila (gráfica = 0, compute = 1), cada um com **query pool de timestamps dedicada** (rings de slots, reset por frame de slots já coletados), calibração inicial (timestamp dedicado + CPU time, padrão `TracyVkContext`) e re-sync periódico. Zonas gravadas nos command buffers ao redor das passagens existentes (que já têm labels/timestamps VS-05); coleta: fila gráfica após `WaitTimelineSemaphore`, compute após a espera do lote — exatamente onde a engine já sabe que os trabalhos completaram. Guard obrigatório: nenhuma zona GPU (nem CPU) emite antes do `TracingStartup()` (`TRACY_DELAYED_INIT` asserta); teardown com coleta final pós-`DeviceWaitIdle`.
- **CPU:** `-define:TRACY_CALLSTACK=10`; lock tracking (`LockCtx` do odin-tracy) nos mutexes principais (`queue_mutex` do engine, `results_mutex` da telemetria); sub-zones nas etapas internas (completions/service/mirror/flush/publicação no update; claim/wait/submit no worker; passes do render prepare; dreno/cursor de replay).
- **Coexistência:** as query pools da VS-05 (timestamps CSV) ficam intactas e independentes — Tracy tem as suas.
- Vantagens: timeline híbrida CPU/GPU fiel ao modelo do Tracy; reusa a disciplina de sincronização já existente (B1/timelines); validável headless com `tracy-capture`.
- Desvantagens: mecanismo de query ring + calibração é código de sync novo (risco contido: validação headless pega desbalanceamento begin/end como na VS-15).

### Opção B — Alimentar o Tracy com os timestamps VS-05 existentes

- Reusar os query pools da telemetria e emitir `gpu_time` no Tracy. Pior: matching begin/end fora do padrão Tracy, acoplamento com o gating de coleta da VS-05, e perde a correlação natural de zonas.

### Opção C — Só CPU aprofundada (sem GPU)

- Não cumpre o pedido central (GPU).

## Decisão

**Opção A** — TracyVk nativo com query pools dedicadas (dois contextos: gráfica e compute), coleta nos pontos de espera existentes, guard de lifecycle e degradação por omissão; CPU aprofundada com sub-zones, call stacks e lock tracking em dois mutexes; VS-05 intacta. Ratificada pelo mantenedor em 2026-11-07, junto à aprovação da VS-16.

## Consequências

- Dois contextos TracyVk (gráfica/compute), query pools dedicadas, calibração e coleta integradas aos pontos de espera existentes.
- `run_tracy.bat` ganha `-define:TRACY_CALLSTACK=10` (config do odin-tracy).
- Memory profiling (allocator) permanece em backlog (BLK-34) — é o mais ruidoso; Fibers/screenshots ficam fora.
- BLK-33 (GPU zones) sai do backlog; BLK-35/36 (locks/call stacks) são absorvidos.

## Histórico

- 2026-11-07 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-16 até a ratificação do mantenedor.
- 2026-11-07 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-16.
