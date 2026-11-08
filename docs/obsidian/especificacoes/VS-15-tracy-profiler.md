---
id: VS-15
titulo: Tracy profiler (CPU zones)
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: em-validacao
depende_de:
  - VS-05
bloqueada_por: []
requisitos: [REQ-TRC-01, REQ-TRC-02, REQ-TRC-03, REQ-TRC-04, REQ-TRC-05]
ultima_atualizacao: 2026-11-07
---

# VS-15 — Tracy profiler (CPU zones)

## Objetivo

Integrar o Tracy profiler ao motor via bindings Odin ([oskarnp/odin-tracy](https://github.com/oskarnp/odin-tracy), v0.14.1), como camada **opt-in por define de compilação**: com `TRACY_ENABLE` desligado (padrão do `run.bat`) não há import, nem dependência de link, nem custo; ligado (`run_tracy.bat`), o app ganha zones de CPU (fim de escopo automático), FrameMark por frame, nomes de thread e plots — conectável à UI Tracy (binário separado do release oficial). A telemetria VS-05 (CSV/JSON/labels) permanece a base inalterada.

## Rastreabilidade

- GOAL: backlog **BLK-25** (SDK externo sobre os pontos de instrumentação — adiado pela ADR-T1) + pedido do mantenedor (2026-11-07) com os repos de referência.
- Referência: `oskarnp/odin-tracy` (`bindings.odin` — `foreign import tracy "tracy.lib"` **incondicional**; `wrapper.odin` — API no-opada por `when TRACY_ENABLE`, zones com `@(deferred_out=ZoneEnd)`), `wolfpld/tracy` v0.14.1 (client C++ via `build_windows.cmd`; servidor UI pre-built no release). Pontos de instrumentação atuais: `telemetry.odin` (VS-05), loop principal em `main.odin`, worker em `voxel_worker.odin`.
- Decisões: [[ADR-T3-tracy-profiler|ADR-T3]] (**bloqueia a aprovação desta spec**).
- Fundação: VS-05 (telemetria base — Tracy é aditivo, não substituto).

## Requisitos

### Empacotamento e build

- **REQ-TRC-01** — Vendor em `vendor/tracy/`: os 3 arquivos de binding (`bindings.odin`, `wrapper.odin`, `allocator.odin`) e a `tracy.lib` pré-compilada (x64, tracy v0.14.1), mais `tools/build_tracy_client.bat` versionado documentando a reprodução (clone de oskarnp/odin-tracy com `--recurse-submodules`, `build_windows.cmd`, cópia dos artefatos). `run.bat` **inalterado** (define desligado → package não importado → sem dependência de link). `run_tracy.bat` novo: shaders + `odin build ./src -out:./bin/vox.exe -define:TRACY_ENABLE=true` + executa; se a `tracy.lib` estiver ausente, erro claro apontando o script de build.

### Wrapper e opt-in

- **REQ-TRC-02** — Módulo `src/engine/tracing.odin`: `import tracy` sob `when TRACY_ENABLE` (`#config(TRACY_ENABLE, false)`); com o define desligado, exporta procs no-op inline (`ZoneN`, `Zone`, `FrameMark`, `PlotInt`, `SetThreadName`, `Message`, `AppInfo`, `IsConnected -> false`); ligado, delega ao wrapper do odin-tracy. Nenhum arquivo fora de `tracing.odin` referencia o package `tracy` diretamente. Chamadas de tracing espalhadas pelos pontos de instrumentação usam apenas a API do módulo — compilam para zero quando desligado.

### Instrumentação v1 (CPU)

- **REQ-TRC-03** — Zones (com fim de escopo): `frame` (corpo do loop principal); `engine_update` (`Update`, streaming/conclusões, publish visíveis, flush E1, service do mirror); `events_drain`; `render_record` (gravação do command buffer do frame); `frame_wait` (espera de timeline/aquisição); `present`. Worker: `worker_iteration`, `batch_assemble`, `batch_submit`. `FrameMark` por frame; nomes de thread (`main`, `voxel_worker`). Sem call stacks (`TRACY_CALLSTACK=0`), sem fibers, sem lock tracking nesta fatia.

### Plots e mensagens

- **REQ-TRC-04** — Plots por frame (`PlotInt`): `visible_chunks`, `work_items`, `empty_chunks`. `AppInfo` no startup (config efetiva resumida). Mensagens: nenhuma por frame (só erros de startup já logados). Coleta condicional a `IsConnected()` para os plots (evitar trabalho quando desconectado).

### Isolamento e coexistência

- **REQ-TRC-05** — A telemetria VS-05 não muda (CSV/JSON/labels/timestamps seguem funcionando com Tracy ligado ou não). Tracing nunca altera sincronização, ordem de submits, ou comportamento do pipeline; zonas não cruzam threads (cada zone nasce e morre na mesma thread). Shutdown: client compilado com `TRACY_MANUAL_LIFETIME` + `TRACY_DELAYED_INIT` — o app sobe o profiler manualmente após o init Vulkan/GLFW (`engine.TracingStartup`, chamado em `main` depois de `CreateEngine`) e desce no teardown (`engine.TracingShutdown`, defer declarado antes do destroy do voxel engine porque o worker emite zones até o join). Fora desse intervalo nenhuma API Tracy pode ser chamada (com `TRACY_DELAYED_INIT`, `GetProfiler()` asserta com o profiler não iniciado). Motivo: BLK-37 — com o client ativo desde o CRT init, `vkCreateComputePipelines` travava de forma intermitente-but-quase-sempre (conflito com o driver NVIDIA durante o init Vulkan).

## Escopo

- Vendor + script de reprodução + `run_tracy.bat` + módulo `tracing.odin` (wrapper opt-in).
- Zones/FrameMark/thread names/plots nos pontos listados (REQ-TRC-03/04).
- Docs: manual técnico (como rodar: build Tracy + abrir UI + Connect), arquitetura (§6/observabilidade), tracking; BLK-25 sai do backlog.

## Não escopo

- **GPU zones** (`TracyVkContext` + calibração por fila) — backlog (grande superfície: contexto por queue, timestamps de calibração).
- Memory profiling (allocator custom do odin-tracy), lock tracking (`LockCtx` nos mutexes do streaming), call stacks (`TRACY_CALLSTACK > 0`), sampling, fibers.
- Versionar o servidor UI Tracy (binário do release oficial, download manual documentado).
- Mudanças na telemetria VS-05.

## Dependências

- [[VS-05-telemetria-profiling|VS-05]] concluída e verificada (pontos de instrumentação existem; Tracy é aditivo).
- [[ADR-T3-tracy-profiler|ADR-T3]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `vendor/tracy/` | bindings (3 .odin) + `tracy.lib` (x64, v0.14.1) | reprodução via `tools/build_tracy_client.bat` |
| `engine/tracing.odin` | API no-op/ativa por `TRACY_ENABLE` | único ponto que importa o package `tracy` |
| `run_tracy.bat` | build com `-define:TRACY_ENABLE=true` | exige `tracy.lib`; erro claro se ausente |
| UI Tracy | binário do release oficial (v0.14.1), Connect manual | parte manual do AC-02 |

### Comportamento quando limites são atingidos

- Sem servidor UI: client desconectado, custo residual mínimo; `IsConnected()=false` → plots pulados.
- `tracy.lib` ausente: `run_tracy.bat` falha com mensagem apontando o script de build; `run.bat` (default) nunca depende dela.

## Cenários

### Cenário de sucesso — build e smoke

- **Dado** o repo com `vendor/tracy/` completo.
- **Quando** roda `run.bat` (default) e depois `run_tracy.bat`.
- **Então** ambos buildam e executam; o smoke Tracy loga `IsConnected()=false` (sem UI) e roda sem erros de validation; o build default não referencia a lib.

### Ponta a ponta com a UI (manual)

- **Dado** o Tracy Profiler v0.14.1 aberto e `vox.exe` rodando via `run_tracy.bat`.
- **Quando** Connect na UI.
- **Então** frames aparecem com FrameMark; zonas `frame`/`engine_update`/`render_record`/worker visíveis com tempos; plots `visible_chunks`/`work_items`/`empty_chunks` atualizando.

### Isolamento da telemetria base

- **Dado** Tracy ligado.
- **Quando** a sessão roda e F8/F9/CSV são exercitados (replay com `TelemetrySnapshot`).
- **Então** CSV/JSON/labels da VS-05 seguem corretos (soma das partes ≤ frame total etc.).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-15-AC-01 | Build default sem dependência da lib; build Tracy ligado executa; smoke com `IsConnected()=false`, zero erros de validation; telemetria VS-05 intacta | `run.bat` e `run_tracy.bat` (build + smoke ~20 s com replay de `TelemetrySnapshot`); inspeção do log | **Verificado (2026-11-07, corrigido em 2026-11-07):** (a) `odin build ./src -out:./bin/vox.exe` default OK, e com `vendor/tracy/tracy.lib` removida temporariamente o build default segue OK (import condicional por `when TRACY_ENABLE` no foreign import de `bindings.odin` — Odin não permite `import` dentro de `when`; package sempre importado, link só com o define); (b) build `-define:TRACY_ENABLE=true` OK com a lib (rebuild do client com `-MD` para casar com o CRT do VMA); (c) smoke Tracy de `bin/` com replay (`--replay vs15_smoke.jsonl --exit-after-replay --no-record`, 11 s): exit 0, log `Tracy IsConnected()=false` (main.odin), zero erros de validation atribuíveis ao Tracy (as únicas mensagens de validation presentes — trocas de present/semaphore no swapchain — reproduzem no baseline pré-VS-15 nas mesmas condições); (d) replay com 2× `TelemetrySnapshot`: snapshot JSON parseado (`heaps`, `times_us`, `vma_detailed_map`) e CSV com 22 linhas × 13 colunas íntegros; (e) sims `render_sim`/`pack_sim`/`mirror_sim`/`heightmap_sim` verdes (2926/968/53/13 casos). Sem processos órfãos. **Ressalva da validação de 2026-11-07 (pós-fix):** as "trocas de present/semaphore" do item (c) eram a regressão de present duplicado introduzida pelo próprio diff da VS-15 (corrigida no commit `ff5842d`); e o hang do build Tracy em `voxel_gpu_init` (BLK-37) não apareceu naquele smoke por intermitência — reproduz 5/5 em re-runs, e só ficou estável (8/8 verdes, replay real de 125 eventos, resize/minimize) após o fix de lifetime manual (commit seguinte ao `ff5842d`). A evidência desta célula permanece válida quanto aos itens (a)(b)(d)(e); os itens (c) e o smoke Tracy foram revalidados com o fix |
| VS-15-AC-02 | UI Tracy conecta e mostra frames, zonas (frame/engine_update/render_record/worker) e plots | **Manual do mantenedor**: abrir Tracy v0.14.1, Connect, conferir zonas e plots | Pendente (manual) — passo a passo em `docs/manual-tecnico.md` §Tracy |

## Tarefas da especificação

- [x] Vincular o backlog BLK-25 e o pedido (repos de referência pesquisados: modelo de define, link incondicional, servidor separado).
- [x] Formalizar o empacotamento (vendor + reprodução), o wrapper opt-in e a instrumentação v1.
- [x] Cobrir isolamento da telemetria base; definir AC automatizado + manual.
- [x] Ratificar a ADR-T3 e obter aprovação da spec. — ADR-T3 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-07.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-T3. Cada tarefa referencia requisitos e critérios de aceitação.

1. [x] **VS-15-IMPL-01 — Vendor e build** (REQ-TRC-01; AC-01). ✅ 2026-11-07 — `vendor/tracy/` (bindings 3 .odin + `tracy.lib` x64 v0.14.1 compilada localmente com MSVC 18 via `build_windows.cmd` do odin-tracy, **patched para `-MD`** — `-MT` do upstream colide com o CRT dinâmico do VMA no `/FAILIFMISMATCH`); `tools/build_tracy_client.bat` reproduz o processo (clone `--recurse-submodules`, patch `-MT`→`-MD`, build, cópia); `run_tracy.bat` novo (erro claro + exit ≠ 0 sem a lib, verificado). Desvio registrado: Odin não permite `import` dentro de `when` — o package tracy é importado sempre por `tracing.odin`, e o desligamento real é feito pelo `foreign import` condicional a `TRACY_ENABLE` em `bindings.odin` (branch desligada usa `system:kernel32`, já linkado pelo runtime). Build default verificado sem a lib presente.
2. [x] **VS-15-IMPL-02 — Wrapper opt-in** (REQ-TRC-02; AC-01). ✅ 2026-11-07 — `engine/tracing.odin`: `TRACY_ENABLE :: #config(TRACY_ENABLE, false)`; com o define desligado toda a API (`ZoneN`, `Zone`, `FrameMark`, `PlotInt`, `SetThreadName`, `Message`, `AppInfo`, `TracingIsConnected`) compila para no-op inline e `TracingIsConnected()` retorna `false`; ligado, delega ao wrapper do odin-tracy. Somente `tracing.odin` referencia o package.
3. [x] **VS-15-IMPL-03 — Instrumentação** (REQ-TRC-03/04/05; AC-01). ✅ 2026-11-07 — Zones no loop principal (`frame`, `events_drain`, `engine_update`, `frame_wait`, `render_record`, `present`) e no worker (`worker_iteration`, `batch_assemble`, `batch_submit`); `FrameMark` por frame; `SetThreadName("main")`/`("voxel_worker")`; `AppInfo` com `ConfigSummary()`; plots `visible_chunks`/`work_items` (contador `update_appended_tasks` do último update)/`empty_chunks` (`empty_chunks_active`), todos guardados por `TracingIsConnected()`. Telemetria VS-05 sem nenhuma mudança.
4. [x] **VS-15-IMPL-04 — Evidências e fechamento** (AC-01..02). ✅ 2026-11-07 — builds default/com-lib/removida e Tracy OK; smoke Tracy com replay (exit 0, `IsConnected()=false`, snapshots + CSV íntegros, sims verdes); docs atualizados (manual técnico §Tracy com passo a passo da UI, arquitetura §observabilidade, status, backlog — BLK-25 fechado, BLK-33..36 abertos); commit com o nome da spec. AC-02 (UI) permanece manual do mantenedor.

## Questões abertas

- Versão exata do server UI a documentar: v0.14.1 (mesma do client vendored). Não bloqueia a aprovação.
- Se o ambiente de build não possuir MSVC para reproduzir a lib, o script documenta o passo e a lib pré-compilada versionada garante o funcionamento. Não bloqueia a aprovação.

## Histórico

- 2026-11-07 — Rascunho elaborado a partir do pedido do mantenedor (Tracy + odin-tracy) e da pesquisa dos repos (bindings com link incondicional — contornado por import condicional; wrapper no-op por define); ADR-T3 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-07 — **ADR-T3 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-15-IMPL-01..04 destravadas.
- 2026-11-07 — **Implementação concluída (IMPL-01..04)**: vendor + `tracy.lib` x64 v0.14.1 (build local MSVC, client com `-MD`), wrapper opt-in (`tracing.odin`), instrumentação (zones/FrameMark/thread names/plots/AppInfo), `run_tracy.bat`. Desvio técnico: import incondicional do package com `foreign import` condicional (restrição do Odin). AC-01 verificado com evidências; AC-02 manual pendente do mantenedor.
- 2026-11-07 — **Regressão de sincronização introduzida pela instrumentação (fix)**: ao envolver o fim do loop com a zone `present`, o diff do commit `76ea467` deixou `engine.Present()` **duplicado** em `src/main.odin` (a chamada original fora da zone + a chamada dentro do bloco `{ ZoneN("present"); Present() }`). Cada frame apresentava a mesma imagem 2×: o segundo present esperava o `vkPresentSemaphore` já consumido pelo primeiro (VUID-vkQueuePresentKHR-pWaitSemaphores-03268), apresentava imagem sem acquire válido (VUID-VkPresentInfoKHR-pImageIndices-01430) e escrevia após present (WRITE_AFTER_PRESENT) — reproduzia em rajada a cada frame, também sem resize. **Causa:** edição do diff, não do design (REQ-TRC-05 não foi violado intencionalmente). **Fix:** remoção da chamada fora da zone (uma única `Present()` por frame, esperando o semaphore sinalizado pelo submit do mesmo frame). **Evidência:** build com validation layers pré-fix reproduziu 03268/01430 em execução de ~30 s; pós-fix, zero ocorrências dos três VUIDs em smoke interativo (~30 s), replay (`--exit-after-replay`), 3× resize + minimize/restore via Win32 e smoke do build Tracy. As "trocas de present/semaphore" citadas como baseline no AC-01 eram, na verdade, esta regressão (o baseline citado já continha o commit da VS-15).
- 2026-11-07 — **BLK-37 — build Tracy travava no init Vulkan (fix)**: com o client Tracy ativo desde o CRT init (lib compilada sem `TRACY_MANUAL_LIFETIME`), `voxel_gpu_init` travava em `vkCreateComputePipelines` — thread principal presa em `NtGdiDdDDIWaitForSynchronizationObjectFromCpu` (espera de sync de GPU que nunca completava) com thread do driver NVIDIA spinando a 100% CPU; 100% reproduzível em re-runs (5/5 no HEAD), mas intermitente o bastante para não aparecer no smoke original do AC-01. Não era validation layer (reproduzia com `VK_LOADER_LAYERS_DISABLE`), não era hook de alocação (a lib não define operadores globais). **Fix:** lib recompilada com `-DTRACY_MANUAL_LIFETIME -DTRACY_DELAYED_INIT`; o app sobe o profiler manualmente (`engine.TracingStartup`, após `CreateEngine`/`voxel_gpu_init`) e desce no teardown (`engine.TracingShutdown`, defer antes do destroy do voxel engine — o worker emite zones até o join). Com `TRACY_DELAYED_INIT`, qualquer API Tracy fora do intervalo crasha (`GetProfiler()` asserta), então a ordem é contratual. **Evidência pós-fix:** 8/8 execuções Tracy verdes (init completo, `IsConnected()=false`, replay real de 125 eventos com exit 0, 18 recreates de swapchain em resize/minimize, zero VUIDs); build default inalterado; sims verdes; teardown lento de `vkDestroyDevice` (~60 s no replay longo) é pré-existente (reproduz no build default) e ficou registrado como observação, não regressão. AC-01 revalidado (ver ressalva na célula).
- 2026-11-07 — **"Zone is ended twice" na UI Tracy (fix)**: o wrapper de `src/engine/tracing.odin` declarava `ZoneN`/`Zone` com `@(deferred_out=zone_end)` **e** delegava a `tracy.ZoneN`/`tracy.Zone` do odin-tracy — que já têm `@(deferred_out=ZoneEnd)`. Com `#force_inline`, cada ZoneBegin era pareado com dois ZoneEnd (o defer interno disparava no fim do escopo do nosso wrapper, o externo no do chamador); a UI reportava `batch_assemble` (worker) mas todas as zones de main/worker estavam assim. **Fix:** nosso wrapper chama `tracy.ZoneBegin` (proc sem defer do odin-tracy) e passa a ser o único dono do par deferido (idêntico ao caminho interno que `tracy.ZoneN` já usava: depth 0, `___tracy_emit_zone_begin_alloc_callstack`). **Evidência:** `tools\tracy\tracy-capture.exe -o sessao.tracy` (mesma validação de instrumentação da UI, headless) contra o app em replay de 125 eventos: 235 frames, 2.720 zones, zero falhas de instrumentação; csvexport confirma zonas nomeadas de main e worker em contagem consistente (441 `worker_iteration`/`batch_assemble`, 440 `batch_submit`, 233 por zone na main); build default e Tracy OK, zero VUIDs, sem processos órfãos. AC-02 (UI manual) segue pendente só de confirmação do mantenedor — a checagem que falhava agora passa no capture.
- 2026-11-08 — **Fast-exit por decisão do mantenedor (BLK-39).** `vkDestroyDevice` no NVIDIA continua 30–60 s após stop/join e waits, com ou sem validation; BLK-28 já eliminara a corrida. Default: após o loop, `TracingShutdown(false)` faz somente o flush/shutdown CPU (sem coleta GPU/Vulkan) e `os.exit(0)` deixa o SO reclaimar worker/GLFW/Vulkan. `--full-teardown`, parseado em `events.odin`, preserva o fluxo completo ordenado e é obrigatório nos smokes de VUIDs/CI. Evidência: fast-exit em replay longo ~15,6 s total nos dois builds (replay ~14,7 s); após 60 s interativo, ESC/X <0,24 s. Capture fast-exit concluiu 230 frames/6.030 zonas e export contém GPU zones até 14,93 s, além do fim do replay (~14,62 s). Full teardown default terminou com zero VUIDs/threading; sims 2.926/968/53/13 verdes.
