---
id: REF-PHYSICS-TRACING
titulo: "Referência: physics + tracing(+gpu) + telemetry (engine)"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência — physics, tracing, tracing_gpu, telemetry

Três subsistemas de suporte do `engine`: o **solver de física de gameplay** (CPU, sobre o mirror C2 — [[sistema-mirror-fisica]]), o **instrumentação Tracy** (CPU e GPU, opt-in — [[sistema-suporte]]) e a **telemetria** (timestamps GPU, VRAM e export CSV/JSON). Contexto macro: [[visao-geral]]; visões de sistema: [[sistema-mirror-fisica]] (física), [[sistema-suporte]] (tracing/telemetria). Decisões: specs [[VS-19-fisica-solver-mirror]], [[VS-15-tracy-profiler]], [[VS-16-instrumentacao-detalhada]], [[VS-05-telemetria-profiling]].

**Threads.** A física roda **somente na main** (`physics_tick` é chamada no loop principal, após o input de movimento e antes de `player_sync_camera`). Os pedidos de página que o solver coalesce (`pending_requests`) são drenados pela **worker**, sob `mirror.mutex`, em `physics_drain_requests` — o único ponto em que o solver toca o mundo por fora da main. Tracing GPU é gravado nos command buffers da main/worker e coletado nos pontos de espera já existentes. Telemetria: `telemetry_service` e `telemetry_snapshot` na main; `telemetry_collect_compute` na worker.

---

## 1. `physics.odin` — solver de corpos AABB (VS-19)

Solver determinístico de gameplay sobre o mirror C2. Corpos são AABB de 1 voxel ou mais; algoritmo espelhado bit a bit por `tools/sim/physics_sim.py` (28 checks). Consulta **tri-state** ao mundo: `blocking/known/block_id` — página desconhecida **nunca** é presumida como ar (regra 2 do AGENTS.md se aplica à paleta; aqui, a ambiguidade congela o corpo).

### Constantes (`physics.odin:15-23`)

| Constante | Valor | Papel |
| --- | --- | --- |
| `PHYSICS_FIXED_DT` | `1/60` | Passo fixo do acumulador (REQ-PHY-02). |
| `PHYSICS_MAX_STEPS_PER_FRAME` | `5` | Teto anti espiral de morte; excesso é **descartado** (contabilizado em `dropped_steps`). |
| `PHYSICS_MAX_FRAME_DT` | `0.25` | Clamp do dt de frame antes de entrar no acumulador. |
| `PHYSICS_GRAVITY` | `-24.0` | Gravidade (unidades/s²). |
| `PHYSICS_TERMINAL_VELOCITY` | `-60.0` | Velocidade terminal (clamp inferior em Y). |
| `PHYSICS_MAX_SUBSTEP` | `0.4` | Subdivisão anti-tunneling do sweep: `< 1` voxel — nunca atravessa um voxel sem teste. |
| `PHYSICS_STEP_UP_HEIGHT` | `1.0` | Limite de step-up: 1 voxel por tentativa (REQ-PHY-04). |
| `PHYSICS_GROUND_EPS` | `0.0001` | Epsilon de apoio/fronteira de AABB. |
| `PHYSICS_FRICTION_DAMPING` | `10.0` | Damping horizontal = `friction * 10 * dt` quando grounded. |
| `PHYSICS_DEFAULT_FRICTION` | `0.6` | Definida em `voxel_assets.odin:35`; usada como material neutro de apoio (o probe de chão não devolve block id). |

### Structs (`physics.odin:25-64`)

**`PhysicsBody`** — um corpo AABB:
- `position: [3]f32` — **canto mínimo** da AABB (não o centro).
- `size: [3]f32` — extensões. `size.x <= 0` marca handle removido (slot livre).
- `velocity: [3]f32`, `grounded: bool` — recalculado por contato a cada passo (nunca cache entre passos).
- `frozen: bool` — página desconhecida: congelado no último estado válido, sem deslocamento parcial (REQ-PHY-06).
- `allow_step_up: bool` — habilita step-up nos eixos horizontais.

**`PhysicsHandle`** — `distinct u32`; `PHYSICS_HANDLE_INVALID = max(u32)`. Handles são índices em `bodies`, reciclados via `free_handles` (pop/append).

**`PhysicsRayResult`** — enum tri-state: `.HIT` / `.MISS` / `.UNKNOWN`.

**`PhysicsRayHit`** — resultado do raycast: `result`, `voxel`, `block_id`, `distance`, `normal` (`{0,0,0}` quando a origem já está dentro do voxel), `unknown_chunk` (coordenada da página ausente).

**`PhysicsManager`** (`ve.physics`) — `bodies`/`free_handles` (alocação reciclada), `accumulator`, `dropped_steps`, `pending_requests: map[ChunkCoordinate]struct{}` (pedidos de página **coalescidos**, dedup por map; consumo pela worker). Estatísticas para plots Tracy: `stats_steps`, `stats_contacts`, `stats_voxels`, `stats_frozen_frames`, `unknown_hits` (**monotônico** — serve de marcador de "desconhecido dentro do passo", já que o map é coalescido).

### Ciclo de vida e tick (API pública, REQ-PHY-10)

- `physics_init` / `physics_destroy` (`physics.odin:66-76`) — chamados por `voxel_engine_init`/destroy (main thread). Alocam os arrays dinâmicos e o map.
- `physics_body_create(ve, position, size, allow_step_up := true) -> PhysicsHandle` (`:80`) — recicla handle livre ou anexa; main thread.
- `physics_body_remove(ve, handle)` (`:95`) — zera o slot e devolve o handle. Não desloca `bodies`.
- `physics_body_get(ve, handle) -> ^PhysicsBody` (`:102`) — ponteiro direto; usado pelos hooks do jogador na main. Índice inválido → `nil`.
- **`physics_tick(ve, frame_dt)`** (`:109`, zone Tracy `physics_tick`) — chamada **uma vez por frame na main**, após `update_camera_movement` e antes de `player_sync_camera`:
  1. `accumulator += min(frame_dt, PHYSICS_MAX_FRAME_DT)`;
  2. enquanto `accumulator >= FIXED_DT && steps < 5`: itera todos os corpos vivos e chama `physics_step` (zone `physics_body_step`), decrementa o acumulador;
  3. se ainda há passos pendentes após o teto: conta e **zera** o excesso em `dropped_steps` (descarte documentado da espiral de morte);
  4. publica plots Tracy (`physics_steps`, `physics_bodies`, `physics_contacts`, `physics_voxels`) quando conectado.

### Freeze e pedidos de página (REQ-PHY-06)

- `physics_request_chunk(ve, coord)` (`:149`) — única proc que toca `mirror.mutex`: insere o pedido coalescido em `pending_requests`. Chamada por qualquer thread do solver (na prática, main; o raycast também).
- **`physics_drain_requests(ve)`** (`:138`) — **chamada pela worker sob `mirror.mutex`** (em `mirror_update_bubble`): para cada pedido, se o chunk já está ativo, emite `mirror_request_page`; depois limpa o map. A main nunca drena.
- `physics_unknown(ve, voxel)` (`:181`, privada) — incrementa `unknown_hits` e registra o pedido. `physics_step` compara `unknown_hits` antes/depois do passo: qualquer incremento **descarta o passo inteiro** e congela o corpo (`physics_freeze` zone): posição, velocidade e `grounded` revertem ao estado de entrada, `frozen = true`, `stats_frozen_frames += 1`. Não existe proc separada `physics_freeze_body` — o freeze é o bloco final de `physics_step` (`physics.odin:416-426`).

### Consulta ao mundo e primitivas privadas

- `physics_voxel_query(ve, voxel) -> (blocking, known, block_id)` (`:156`) — wrapper sobre `voxel_get` + `block_is_blocking`.
- `physics_aabb_voxels(pos, size) -> (lo, hi)` (`:163`, privada, `contextless`) — faixa de voxels coberta pela AABB com epsilon na fronteira superior.
- `physics_aabb_free(ve, body, pos) -> bool` (`:189`, privada) — AABB inteiramente livre **e conhecida**; desconhecido congela o pedido e retorna false.
- **`physics_sweep_axis(ve, body, axis, delta, contacts) -> (moved, blocked)`** (`:208`, privada) — coração do movimento: subdivide `delta` em passos de `|step| <= 0.4` (anti-tunneling), e para cada subpasso varre a AABB deslocada no eixo e calcula o **clamp** de contato mais restritivo (`c = voxel[axis] - size[axis]` subindo, `+1` descendo). Ao bloquear: move até o clamp, registra o voxel de contato, retorna `blocked = true`. Desconhecido aborta o subpasso com `blocked = true` **sem** contato — quem chama distingue pelo tamanho da lista de contatos.
- `physics_support_probe(ve, body) -> bool` (`:266`, privada) — apoio real: AABB deslocada `2*eps` para baixo; qualquer voxel bloqueante/conhecido decide.
- **`physics_ground_probe(ve, body) -> bool`** (`:293`, privada, zone `physics_ground_probe` + `physics_fastpath_scan`) — **fast-path de chão via `heights` (REQ-PHY-05, O(1)/coluna)** quando: `velocity.y <= 0`, todas as colunas cobertas pela AABB têm topo conhecido `!= 0xFFFF`, estão no mesmo chunk no plano XZ, e o corpo está inteiramente acima do topo mais alto. Pousado (`|y - top_max| <= 2*eps`) → `true` sem varredura. Qualquer ambiguidade (0xFFFF, coluna vazia cujo apoio pode estar no chunk de baixo, travessia de chunk XZ, corpo abaixo do topo = interior/caverna, deslocamento vertical) **cai no sweep completo** (`physics_support_probe`). Equivalência com o sweep provada em `tools/sim/physics_sim.py`.
- `physics_step_up(ve, body, axis, delta) -> bool` (`:338`, privada) — só após bloqueio horizontal com progresso parcial e corpo grounded: exige AABB inteiramente livre elevada em 1 voxel, sweep horizontal com pelo menos 50% do delta, e **assentamento** com apoio bloqueante ao descer; qualquer falha reverte à posição inicial.

**`physics_step(ve, body)`** (`:359`, privada) — um passo fixo de um corpo:
1. Gravidade: `vy += g*dt`, clamp na terminal.
2. `grounded = physics_ground_probe`; se grounded e `vy < 0` → `vy = 0`; damping horizontal com fricção default.
3. Sweep **eixo a eixo na ordem X→Y→Z** (a ordem é o que torna o sliding e o step-up determinísticos): por eixo, `delta = velocity[axis]*dt`; ao bloquear com contato real, aplica **restituição** do bloco de contato (`voxel_physics[block_id].restitution`; se > 0 e `|v| > 1`, reflete; senão zera); tenta **step-up** nos eixos horizontais se `allow_step_up && grounded` e houve progresso parcial (contato removido da lista em caso de sucesso).
4. Recalcula `grounded` ao final; zera `vy < 0` se apoiado.
5. **Freeze check**: `unknown_hits > unknown_before` → reverte tudo (acima).

### Raycast DDA (REQ-PHY-08/09)

**`physics_raycast(ve, origin, direction, max_distance) -> PhysicsRayHit`** (`:433`, zone `physics_raycast`) — Amanatides & Woo sobre o mirror, resultado tri-state. Contratos: `max_distance > 0` e direção não nula, caso contrário retorna `.MISS` **sem percorrer a grade** (rejeição definida). Direção é normalizada internamente. A primeira célula testada é a da origem (origem dentro de voxel bloqueante → `.HIT` com `normal = {0,0,0}` e `distance = 0`). Página ausente/em readback **antes** do limite → `.UNKNOWN` com `unknown_chunk` e pedido coalescido — nunca `.MISS`. Percorre até `max_distance`, retornando `.MISS` caso atravesse apenas ar.

### Hooks do jogador (package main)

O solver não conhece o jogador; a main o dirige por handles:
- `physics_body_create` em `main.odin:64` cria o corpo com os pés `PLAYER_EYE_HEIGHT` abaixo da câmera.
- `update_camera_movement` (`main.odin:446`) — **impõe** `velocity.x/z` do input a cada frame (diagonal normalizada por 0.7071; sprint ×2); o solver integra o resto. Nunca escreve `velocity.y` (pulo sai pelo gameplay, VS-20).
- `player_sync_camera` (`main.odin:500`) — câmera = `body.position + (hw, eye, hw)`.
- `player_track_jump_apex` (`main.odin:477`) — amostragem de ápice do pulo (AC-04 VS-20).
- `gameplay_update_target` (`gameplay.odin:44`) — DDA da mira 1×/frame após física/câmera, usando `physics_raycast` com `GAMEPLAY_REACH`.

---

## 2. `tracing.odin` — wrapper opt-in do Tracy (VS-15)

Único módulo que importa o package `tracy` (vendored em `vendor/tracy/`). `TRACY_ENABLE :: #config(TRACY_ENABLE, false)` — com `false` (padrão de `run.bat`) **nada do Tracy é importado** e toda a API compila para no-op inline; ligado via `-define:TRACY_ENABLE=true` (`run_tracy.bat`).

- **`ZoneN(name, active := true)` / `Zone(name := "")`** (`tracing.odin:37-55`) — zonas CPU com par deferido único: chama `ZoneBegin` e é a única dona do `defer ZoneEnd` (`@(deferred_out=zone_end)`); delegar a `tracy.ZoneN/Zone` com defer próprio emitia dois `ZoneEnd` por zone ("zone ended twice"). Profundidade de callstack de `TRACY_CALLSTACK` (REQ-CPU-02, `run_tracy.bat` passa 10).
- `zone_end(ctx)` — `defer` interno; não chamar diretamente.
- `FrameMark()` — marcação de frame na main.
- `PlotInt(name: cstring, value: i64)` — séries temporais (steps/corpos/contatos/voxels da física).
- `SetThreadName(name)` — nomes de thread (`main`, worker).
- `Message(text)` / `AppInfo(text)` — mensagens no timeline / info de aplicação (a main publica `version + ConfigSummary`).
- `TracingIsConnected() -> bool` — com Tracy desligado retorna `false` (gates de plot).

### Lifetime manual (BLK-37)

A lib Tracy é compilada com `TRACY_MANUAL_LIFETIME` + `TRACY_DELAYED_INIT`: o profiler **nasce só em `TracingStartup`** (`tracing.odin:103`), chamado pela main **depois** do init Vulkan/GLFW — o client Tracy ativo desde o CRT init conflitava com `vkCreateComputePipelines` (hang). Consequências:
- Nenhuma API Tracy pode ser usada no intervalo de init Vulkan/GLFW (o `GetProfiler` asserta com profiler não iniciado).
- `TracingStartup` também sobe os contextos GPU (`tracing_gpu_init`) e anuncia os locks rastreados (`tracing_locks_init`) — VS-16.
- **`TracingShutdown(full_teardown := true)`** — com `full_teardown`, primeiro `tracing_gpu_shutdown` (drena as zonas GPU restantes com a GPU ociosa) e depois `ShutdownProfiler`. A main usa `full_teardown = false` no fast-exit (`TracingShutdown(false)` + `os.exit(0)`), pois não há teardown Vulkan; o defer completo cobre o caminho `--full-teardown`. O defer fica **antes** do destroy do voxel engine porque a worker (que emite zones) é encerrada dentro dele.

### Lock tracking (VS-16, REQ-CPU-03)

- `TracingLock` — `ctx: ^tracy.LockCtx` + `announced`; com Tracy off é `struct {}` vazio.
- `queue_lock_srcloc` / `results_lock_srcloc` — `SourceLocationData` em **storage estático** (o protocolo Tracy envia o ponteiro bruto, `lockAnnounce.lckloc = srcloc`).
- `tracing_locks_init` — anúncio único no startup (`LockAnnounce`) para os dois locks: `queue_mutex` (engine) e `results_mutex` (telemetry).
- `tracing_mutex_lock(m, lock)` / `tracing_mutex_unlock(m, lock)` — wrappers sobre `sync.mutex_lock/unlock` que emitem `LockBefore`/`LockAfter`/`LockAfterUnlock` ao redor do lock real, **se** anunciado. Usados onde o lock é hot e rastreado (fila de resultados da telemetria, queue_mutex).

---

## 3. `tracing_gpu.odin` — zonas GPU do Tracy (VS-16)

Zonas GPU sobre **query pools Vulkan dedicadas** (REQ-GPU-01/02/03), independentes das pools de telemetria (VS-05). Com `TRACY_ENABLE=false` tudo é no-op e **nenhuma query pool é criada**.

### Constantes e layout do ring (`tracing_gpu.odin:13-27`)

| Constante | Valor | Papel |
| --- | --- | --- |
| `TRACING_GPU_CONTEXT_GRAPHICS` / `_COMPUTE` / `_COUNT` | `0` / `1` / `2` | Índices de contexto (uma pool por fila). |
| `TRACING_GPU_RING_SIZE` | `4096` | Slots de timestamp por contexto. |
| `TRACING_GPU_ZONE_SLOT_FIRST` | `2` | Primeiro slot de zona. |
| `TRACING_GPU_ZONE_SLOT_LIMIT` | `4095` | Fim exclusivo das zonas. |
| `TRACING_GPU_RING_MARGIN` | `64` | Margem anti-omissão (ver abaixo). |
| `TRACING_GPU_SYNC_INTERVAL` | `60` | Frames entre re-syncs periódicos. |
| `TRACING_GPU_CALIB_SLOT` | `0` | Timestamp de calibração inicial. |
| `TRACING_GPU_SYNC_SLOT` | `4095` | Timestamp de re-sync periódico. |

Cada zona usa **2 slots em par** (begin/end) alocados sequencialmente; o slot 0 é reservado para a calibração e o último para o `gpu_time_sync`.

**`GpuTracingContext`** — por contexto: `query_pool`, `period_ns` (timestampPeriod do device, ns por tick), cursores absolutos do ring `record_pos` / `collect_pos` / `reset_pos`, `frames_since_sync`, `sync_pending`, `omitted_logged`. O estado global `gpu_tracing` (privado) tem `active` + os dois contextos.

### Procs

- **`tracing_gpu_init`** (`:47`) — chamada **somente dentro de `TracingStartup`** (main, após init Vulkan). Por contexto: cria a query pool TIMESTAMP, lê `timestampPeriod`, faz um único submit **bloqueante** de reset + timestamp de calibração (padrão `TracyVkContext`, só no startup), anuncia ao Tracy (`GpuNewContext` + `GpuContextName` "graphics"/"compute") e posiciona os cursores em `ZONE_SLOT_FIRST`.
- **`tracing_gpu_shutdown`** (`:115`) — só com `full_teardown`: `DeviceWaitIdle` (worker já encerrada, main em teardown), coleta final (`collect_range(drain = true)` dos dois contextos), destrói as pools, marca inativo.
- **`tracing_gpu_record_context(cmd, context_index)`** (`:135`) — **uma vez por command buffer** que grava zonas do contexto (main: fila gráfica; worker: compute): aplica os resets pendentes das faixas já coletadas (`[reset_pos, collect_pos)`, em blocos que não cruzam o fim do ring) e, a cada `SYNC_INTERVAL` frames, grava o timestamp de re-sync no `SYNC_SLOT` (`sync_pending = true`).
- **`tracing_gpu_zone_begin(cmd, context_index, name, loc) -> u16`** (`:160`) — aloca o par de slots e emite `CmdWriteTimestamp2(TOP_OF_PIPE)` + `GpuZoneBegin`. **Degradação por omissão**: se `record_pos - collect_pos` excede `ZONE_SLOT_LIMIT - RING_MARGIN` (ring sob pressão), omite a zona, loga um warning único e retorna `max(u16)`. O par nunca cruza o fim do ring nem toca o slot de sync. **Contrato**: quem recebe `max(u16)` não deve chamar `zone_end`.
- **`tracing_gpu_zone_end(cmd, context_index, query_id)`** (`:198`) — `CmdWriteTimestamp2(BOTTOM_OF_PIPE)` no slot `query_id + 1` + `GpuZoneEnd`. No-op se `query_id == max(u16)` (zona omitida).
- `tracing_gpu_collect_graphics` / `tracing_gpu_collect_compute` (`:207-221`) — chamadas nos pontos de espera já existentes (sync de frame / worker); incrementam `frames_since_sync` e chamam `collect_range(ctx, drain = false)`.
- `collect_range(context_index, drain)` (`:224`, privada) — lê `GetQueryPoolResults` com `WITH_AVAILABILITY`, em blocos de até 256 queries que não cruzam o fim do ring; emite `GpuTime` para os pares cujos dois slots estão disponíveis, avança `collect_pos` e para no primeiro par em voo. Depois, se `sync_pending`, lê o `SYNC_SLOT` e emite `GpuTimeSync` (fecha `sync_pending`).

---

## 4. `telemetry.odin` — telemetria (VS-05)

Timestamps GPU por operação, amostragem de heaps VRAM (budget VMA) e export para arquivo. **Sempre compilada** (independe do Tracy); ligada/desligada em runtime por `TELEMETRY_DEFAULT_ENABLED` (default `true`) + `telemetry_toggle` (F8). Com `times_available == false` (sem suporte de timestamp), tudo vira no-op exceto CSV de zeros.

### Constantes e structs (`telemetry.odin:12-50`)

| Constante | Valor | Papel |
| --- | --- | --- |
| `TELEMETRY_CSV_INTERVAL_MS` | `500` | Intervalo da série temporal CSV (0 = desligada). |
| `TELEMETRY_GFX_QUERY_COUNT` | `16` | 5 operações + frame total (pares) = 12 ≤ 16. |
| `TELEMETRY_COMPUTE_QUERY_COUNT` | `8` | generate + pack (pares) = 4 ≤ 8. |
| `TELEMETRY_OPERATION_COUNT` | `7` | Tamanho do array de tempos. |

- **`TelemetryOperation`** — enum: `Generate`, `Pack`, `ApplyEdits`, `BuildWorkQueue`, `FinalizeWorkQueue`, `MeshDraw`, `FrameTotal`. Mapeamento de slots da pool gráfica (em `telemetry_collect_graphics`): FrameTotal=0, ApplyEdits=2, BuildWorkQueue=4, FinalizeWorkQueue=6, MeshDraw=8.
- **`TelemetryHeapSample`** — `used_bytes`, `budget_bytes`, `block_bytes`, `allocation_bytes`, `block_count`, `allocation_count` (de `vma.GetHeapBudgets` + `CalculateStatistics`).
- **`Telemetry`** (instância global privada `telemetry`) — `enabled`, `times_available`, `timestamp_period_ns`, `gfx_pools[NUM_FRAMES_IN_FLIGHT]`, `gfx_slot_submitted[NUM_FRAMES_IN_FLIGHT]` (slot já submetido ao menos uma vez — **VUID 09401**, ver abaixo), `compute_pools[config.batches_in_flight]` (VS-08), `results_mutex` (rastreada pelo Tracy), `last_times_us[7]`, `heap_count`/`heaps`, `csv_file`, `last_csv_tick`.

### Procs

- `telemetry_init` (`:57`) / `telemetry_destroy` (`:107`) — init: detecta suporte a timestamps (`timestampPeriod > 0 && timestampComputeAndGraphics && timestampValidBits > 0` nas filas gráfica e compute), cria as pools gráficas (uma por frame in flight) e as pools compute (uma por batch in flight), abre o CSV. Destroy: destroi pools e fecha o arquivo.
- `telemetry_toggle` (`:120`) — flip de `enabled` (evento F8).
- Regiões nomeadas (`:126-154`) — `telemetry_begin_label` / `telemetry_end_label` (`EXT_debug_utils`, regiões nos command buffers) e `telemetry_name_object` (nomes de objetos para capturas). Respeitam `enabled`.
- `telemetry_timestamp_begin/end(cmd, pool, query)` (`:158-166`) — `CmdWriteTimestamp2` TOP/BOTTOM_OF_PIPE; no-op se desligado ou sem suporte.
- `telemetry_reset_pool(cmd, pool, query_count)` (`:168`) — reset da pool antes do uso.
- **`telemetry_collect_graphics(frame_index)`** (`:173`) — main, no ponto de espera do frame. **VUID-vkGetQueryPoolResults-None-09401**: slot nunca submetido não pode ser lido (as queries ainda não passaram por reset no command buffer) → `gfx_slot_submitted[frame_index]` gateia a leitura. Lê os 5 pares com `WITH_AVAILABILITY` e publica.
- `telemetry_collect_compute(ring_index)` (`:209`) — worker; lê generate (slots 0-1) e pack (2-3) do pool do batch.
- `telemetry_service` (`:234`) — main, 1×/frame: a cada 500 ms coleta VRAM, lê `last_times_us` sob `results_mutex` (via `tracing_mutex_lock` rastreado) e escreve uma linha CSV.
- `telemetry_snapshot` (`:258`) — F9: JSON com `times_us`, heaps (com `block_mib`/`allocation_mib`), `times_available` e o `vma_detailed_map` inteiro (`vma.BuildStatsString`), em `bin/debug/<version>/telemetry/telemetry_<ts>_snapshot.json`. Loga o caminho.
- `telemetry_collect_vram` (`:318`, privada) — `GetHeapBudgets` + `CalculateStatistics` por heap.
- `telemetry_csv_open` (`:341`, privada) — cria `bin/debug/<version>/telemetry/telemetry_<ts>.csv` com cabeçalho `timestamp_ms,tick,generate_us,...,frame_total_us,heapN_used_mib,heapN_budget_mib`.
- `telemetry_publish_pair(op, values)` (`:364`, privada) — valida disponibilidade dos dois slots e `end > begin`; converte ticks→µs com `timestamp_period_ns` e publica em `last_times_us[op]` **sob `results_mutex`**.
- `telemetry_timestamp_string` (`:375`, privada) — carimbo `YYYYMMDD_HHMMSS` para nomes de arquivo.

Saída em `bin/debug/<version>/telemetry/` — diretório montado por `debug_paths_init` (`debug_paths.odin`), versão = `VERSION_STRING`.

---

## Contratos transversais

- **Física**: somente main escreve corpos; a worker só drena pedidos (`physics_drain_requests`, sob `mirror.mutex`). Corpo desconhecido nunca presume ar; freeze sempre reverte o passo inteiro. `grounded` é derivado por contato a cada passo — não persistir decisões de gameplay nele entre frames sem rechecar.
- **Tracing**: `TracingStartup` é o marco zero; antes dele (init Vulkan/GLFW, load de assets) nenhuma API Tracy. `TracingShutdown(false)` em fast-exit não coleta zonas GPU pendentes — esperado, pois não há teardown Vulkan.
- **Tracing GPU**: `zone_begin` pode omitir (`max(u16)`); o caller deve propagar o `query_id` opaco. O ring nunca cruza o slot de sync nem o fim físico do pool.
- **Telemetria**: `results_mutex` protege `last_times_us` (leitores: service/snapshot; escritor: publish_pair). `gfx_slot_submitted` deve ser marcado pela renderização após o primeiro submit do slot, sob pena de violar o VUID 09401. Telemetria e tracing GPU usam pools **separadas** — não reutilizar uma na outra.

## Ver também

- [[sistema-mirror-fisica]] — modelo de dados do mirror e ciclo do solver.
- [[sistema-suporte]] — Tracy, telemetria e versionamento no contexto do motor.
- [[ref-voxel-engine-worker]] — worker, `mirror_update_bubble` (drain de pedidos) e coleta compute.
- [[ref-voxel-render]] — onde `tracing_gpu_record_context` e os timestamps gráficos são gravados.
- Specs: [[VS-19-fisica-solver-mirror]], [[VS-15-tracy-profiler]], [[VS-16-instrumentacao-detalhada]], [[VS-05-telemetria-profiling]].
