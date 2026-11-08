---
id: VS-16
titulo: Instrumentação detalhada (CPU + GPU)
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: em-validacao
depende_de:
  - VS-15
bloqueada_por: []
requisitos: [REQ-GPU-01, REQ-GPU-02, REQ-GPU-03, REQ-CPU-01, REQ-CPU-02, REQ-CPU-03, REQ-VAL]
ultima_atualizacao: 2026-11-07
---

# VS-16 — Instrumentação detalhada (CPU + GPU)

## Objetivo

Aprofundar a instrumentação Tracy da VS-15: **zonas GPU** para as passagens das duas filas (gráfica e compute) na timeline do Tracy, correlacionadas com as zonas CPU — sobre query pools dedicadas com calibração própria, coexistindo com os timestamps da telemetria VS-05 — e CPU detalhada: call stacks, lock tracking nos mutexes principais e sub-zones nas etapas internas do loop, do worker e do render.

## Rastreabilidade

- GOAL: pedido do mantenedor (2026-11-07) — "instrumentação detalhada, instrumentar a GPU também". Fecha o backlog BLK-33 (GPU zones) e absorve BLK-35 (locks) e BLK-36 (call stacks).
- Referência: VS-15 (`engine/tracing.odin`, lifetime manual pós-init — BLK-37), odin-tracy (primitivas `___tracy_emit_gpu_*` sem wrapper de alto nível — ver `vendor/tracy/bindings.odin`), pontos de espera existentes (`WaitTimelineSemaphore` no loop; espera de lote no worker), query pools/timestamps da VS-05 (`telemetry.odin` — inalterados), passagens já nomeadas por labels (`generate`, `pack`, `apply_voxel_edits`, `build_work_queue`, `finalize_work_queue`, `draw_mesh`).
- Decisões: [[ADR-T4-instrumentacao-detalhada|ADR-T4]] (**bloqueia a aprovação desta spec**).
- Fundação: VS-15 concluída (AC-02 da UI é independente desta fatia).

## Requisitos

### GPU zones

- **REQ-GPU-01** — Contextos TracyVk: um por fila (gráfica = contexto 0, compute = 1), implementados em `engine/tracing_gpu.odin` sobre as primitivas `___tracy_emit_gpu_*`: query pool de timestamps **dedicada** por contexto (ring de slots; reset apenas de faixas já coletadas), calibração inicial (timestamp dedicado + CPU time no padrão `TracyVkContext`) e re-sync periódica (a cada N frames, reaproveitando o ponto de coleta). **Guard:** nenhuma zona GPU emite antes do `TracingStartup()` (`TRACY_DELAYED_INIT` asserta) — flag interna `gpu_tracing_active`; teardown grava coleta final após `DeviceWaitIdle`, antes do `TracingShutdown()`.
- **REQ-GPU-02** — Zonas gravadas nos command buffers ao redor das passagens existentes — compute: `generate`, `pack`; gráfica: `apply_edits`, `build_work_queue`, `finalize_work_queue`, `draw_mesh` — cada uma com srcloc alocada (`___tracy_alloc_srcloc_name`, padrão do wrapper CPU) e par begin/end por queryId (u16). As query pools/timestamps da VS-05 ficam **intactas e independentes** (sem compartilhamento de slots).
- **REQ-GPU-03** — Coleta: fila gráfica após `WaitTimelineSemaphore` (leitura com disponibilidade, padrão VS-05 — nunca bloqueante); compute após a espera do lote na worker (pós-timeline do lote). Slots só são reutilizados após coleta confirmada; se a coleta atrasar, a gravação de zonas **degrada para omitir** (nunca estourar o ring — sem falha de instrumentação).

### CPU detalhada

- **REQ-CPU-01** — Sub-zones: `engine_update` dividida em `service_completions`, `promote_visibility`, `publish_visible`, `edit_flush`, `mirror_service`; worker em `claim_batch`, `build_jobs`, `wait_batch_slot`, `submit_batch`; render em `apply_edits_record`, `builder_record`, `finalize_record`, `mesh_draw_record`, `barriers_record`; events em `drain`, `replay_cursor`. (Ajuste fino de nomes na implementação; a lista é o mínimo.)
- **REQ-CPU-02** — Call stacks: `run_tracy.bat` passa `-define:TRACY_CALLSTACK=10` (config do odin-tracy; as zones CPU usam `ZoneBegin` com depth — o wrapper da VS-15 já encaminha `depth`). Custo documentado no manual.
- **REQ-CPU-03** — Lock tracking: `LockCtx` do odin-tracy nos mutexes principais — `queue_mutex` do voxel engine e `results_mutex` da telemetria — com wrappers `tracing_mutex_lock/unlock` (announce uma vez; before/after lock). Demais mutexes ficam fora (baixo valor).

### Validação

- **REQ-VAL** — Headless com `tools\tracy\tracy-capture.exe` (padrão já usado na VS-15): capture conectado durante replay completo **sem falhas de instrumentação**; `tracy-csvexport` evidencia zonas GPU (`generate`/`pack`/`draw_mesh`…) com durações plausíveis (> 0 e < frame total); contagem begin/end pareada. AC manual (UI): timeline híbrida com zonas GPU alinhadas às CPU; locks visíveis; call stacks abrindo nas zones.

## Escopo

- `engine/tracing_gpu.odin` (contextos, rings, calibração, coleta, guard de lifecycle) + hooks nas passagens.
- Sub-zones CPU, call stacks (`run_tracy.bat`), lock tracking (2 mutexes).
- Validação headless automatizada + AC manual da UI.
- Docs: spec, manual técnico §11 (GPU zones, call stacks, locks), arquitetura, tracking; backlog (BLK-33/35/36 saem; memory profiling BLK-34 permanece).

## Não escopo

- Memory profiling via allocator custom (BLK-34 — permanece; é o mais ruidoso).
- Fibers, screenshot capture (`FrameImage`), sampling do Tracy, zonas por brick/dentro de shaders (granularidade de passagem, não por dispatch).
- Mais de dois contextos GPU (uma fila extra exigiria novo contexto — extensão natural futura).
- Mudanças na telemetria VS-05 e nos timestamps CSV.

## Dependências

- [[VS-15-tracy-profiler|VS-15]] concluída (wrapper, lifetime manual, tracy-capture validado).
- [[ADR-T4-instrumentacao-detalhada|ADR-T4]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `tracing_gpu.odin` | contextos 0 (gráfica) / 1 (compute); `gpu_zone_begin/end`; `gpu_collect_graphics/compute`; `tracing_gpu_init/shutdown` | guard `gpu_tracing_active`; degradação por omissão ao invés de overflow |
| Query pools dedicadas | 1 por contexto (timestamps), rings com coleta em avail | VS-05 intacta |
| `run_tracy.bat` | + `-define:TRACY_CALLSTACK=10` | custo documentado |
| Locks | wrappers tracy em `queue_mutex`, `results_mutex` | `LockCtx` do odin-tracy |

### Comportamento quando limites são atingidos

- Ring de queries cheio/a coleta atrasada: zonas GPU omitidas (log de debug único por sessão), nunca "ended twice"/overflow.
- Sem UI conectada: coleta roda normalmente (o client bufferiza); custo já conhecido da VS-15.
- Build default: tudo no-op (mesmo isolamento da VS-15).

## Cenários

### Cenário de sucesso — timeline híbrida

- **Dado** `run_tracy.bat` com o app rodando e a UI (ou `tracy-capture`) conectada.
- **Quando** frames avançam com streaming, edições e worker ativos.
- **Então** a timeline mostra zonas GPU (`generate`, `pack` na fila compute; `draw_mesh`, `builder` na gráfica) ancoradas no tempo GPU e alinhadas às zonas CPU que as gravaram; locks e call stacks disponíveis.

### Coleta atrasada / ring sob pressão

- **Dado** uma sessão longa com coleta lenta.
- **Quando** o ring de queries se aproxima do limite.
- **Então** as zonas excedentes são omitidas com log único; nenhuma falha de instrumentação; captura continua válida.

### Isolamento

- **Dado** o build default (sem define).
- **Quando** compila e roda.
- **Então** nenhuma query pool GPU de tracing é criada, nenhum código Tracy executa; telemetria VS-05 inalterada.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-16-AC-01 | Capture headless durante replay completo: zero falhas de instrumentação; zonas GPU presentes no export com durações plausíveis; begin/end pareados; builds default/Tracy OK; telemetria VS-05 intacta; 0 VUIDs | `tracy-capture` + `tracy-csvexport` (protocolo da VS-15) | **Verificado (2026-11-07/08):** replay de 125 eventos, capture final 231 frames/15,39 s/6.114 zonas e export GPU com 1.358 zonas (`generate=443`, `pack=231`, `draw_mesh=228`, `build_work_queue=228`, `finalize_work_queue=228`), todas > 0 (mínimo 1.824 ns); sem omissões ou erros de instrumentação/VUIDs. `apply_edits` não é exercitada por esse replay (sem edições). Builds default/Tracy OK, inclusive default com `tracy.lib` temporariamente ausente; CSV VS-05 com 28 linhas × 13 colunas e tempos por operação; sims 2.926/968/53/13 verdes. Ressalva pré-existente: warnings `THREADING ERROR` no teardown (BLK-28), reproduzidos no default, não são VUIDs nem falhas Tracy |
| VS-16-AC-02 | UI Tracy: timeline híbrida com zonas GPU ancoradas no tempo GPU, alinhadas às CPU; locks visíveis; call stacks abrem nas zones | **Manual do mantenedor** (mesmo protocolo do AC-02 da VS-15) | Pendente |

## Tarefas da especificação

- [x] Vincular o pedido ao backlog (BLK-33/35/36) e às primitivas pesquisadas (`___tracy_emit_gpu_*`).
- [x] Formalizar contextos GPU, coleta nos pontos de espera existentes, guard de lifecycle e degradação por omissão.
- [x] Formalizar CPU detalhada (sub-zones, call stacks, locks) e coexistência com a VS-05.
- [x] Definir validação automatizada (capture+export) e manual (UI).
- [x] Ratificar a ADR-T4 e obter aprovação da spec. — ADR-T4 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-07.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-T4. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-16-IMPL-01 — tracing_gpu (núcleo)** (REQ-GPU-01; AC-01). Contextos, query pools/rings, calibração, guard de lifecycle, init/shutdown integrados ao `TracingStartup/Shutdown` da VS-15.
2. **VS-16-IMPL-02 — Zonas GPU nas passagens** (REQ-GPU-02/03; AC-01). Hooks em generate/pack/apply_edits/builder/finalize/draw; coleta gráfica no `WaitTimelineSemaphore` e compute na espera do lote; degradação por omissão.
3. **VS-16-IMPL-03 — CPU detalhada** (REQ-CPU-01..03; AC-01/02). Sub-zones, `-define:TRACY_CALLSTACK=10`, lock tracking nos dois mutexes.
4. **VS-16-IMPL-04 — Evidências e fechamento** (AC-01/02). Capture headless + csvexport, smokes, docs (manual §11, arquitetura, tracking, backlog) e commit com o nome da spec.

## Questões abertas

Nenhuma. Rings de **4.096 timestamps por contexto** (2.047 pares úteis; slots 0 e 4.095 reservados a calibração/re-sync, margem de 64), re-sync a cada **60 coletas** por contexto. Nomes finais das sub-zones são os da REQ-CPU-01, sem renomeações adicionais.

## Histórico

- 2026-11-07 — Rascunho elaborado a partir do pedido do mantenedor (instrumentação detalhada + GPU); ADR-T4 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-07 — **ADR-T4 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-16-IMPL-01..04 destravadas.
- 2026-11-07/08 — **Implementação concluída e AC-01 verificado.** Dois contextos (`graphics=0`, `compute=1`), pools dedicadas e rings de 4.096; slots só são resetados após coleta e o sync não é regravado enquanto pendente. Emits GPU usam as variantes `_serial` do C API, como `TracyVulkan.hpp`: são funções chamadas pelas threads da aplicação, com lock interno na fila serial; não são exclusivas da thread do profiler. **Diagnóstico do crash:** probes mínimos mostraram que `GpuNewContext` e uma zona completa isolados capturavam; somente init sem zonas também capturava, com e sem call stacks. No engine, emits não-serial concorrentes entre main/worker/coleta derrubavam capture e capture-daemon. A troca para o caminho serial upstream eliminou o segfault e permitiu o replay completo. Duas correções adicionais: `GpuZoneEnd` usa o ID do seu próprio timestamp (`begin+1`, não reutiliza begin); `GpuCalibration` foi removido do domínio `DEVICE` (o evento exige contexto com flag de calibração e delta entre amostras, não timestamp CPU absoluto). AC-02 manual da UI permanece pendente.
