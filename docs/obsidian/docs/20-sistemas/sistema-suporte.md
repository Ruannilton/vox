---
id: SISTEMA-SUPORTE
titulo: Suporte — assets, config, telemetria, Tracy e versionamento
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Suporte

Os cinco subsistemas que **sustentam** o motor mas não produzem frames: dados de blocos (JSON), configuração (INI), telemetria Vulkan, profiling Tracy e versionamento. O que os une é o timing — quase tudo aqui roda **antes de qualquer janela existir** ou **fora do caminho quente do frame** — e o destino: artefatos de depuração em `bin/debug/<version>/` (version = `VERSION_STRING`, ex.: `0.1.25`), criados em `debug_paths_init` (`src/engine/debug_paths.odin`). Contexto macro: [[visao-geral]]. Detalhes por proced/struct: [[ref-assets-config-events]] e [[ref-physics-tracing]].

## Assets JSON (`voxel_assets.odin`)

Os blocos são **dados, não código**: `assets/blocks.json` define três coleções — `meshes` (templates de malha: vértices em `[0,1]³`, triângulos com índices e `cull_tags` opcionais 0..5/`NEVER`, UVs por vértice), `textures` (nome → path de PNG única) e `blocks` (id 1..255, nome, referência por nome de malha e de textura). Textura pode ser uma **string** (6 faces iguais) ou um objeto com as 6 faces `top/bottom/front/back/left/right` — internamente só existe a forma de objeto, normalizada por `assets_parse_texture_faces` para `albedo_faces[6]` na ordem `FACE_NORMALS` (VS-21).

- **Física separada do render**: cada bloco tem um objeto opcional `physics` (blocking, hittable, friction ≥ 0, restitution ∈ [0,1]), parseado campo a campo em `assets_parse_physics`. O resultado vai para a tabela **exclusivamente CPU-side** `voxel_physics` (`PhysicsDefinition`, flags + fricção + restituição) — o `BlockDefinition` std430 (48 B) nunca carrega física (invariante do VS-19). Defaults do tipo: blocking deriva da solidez (`solid`, default true; `solid:false` marca NON_SOLID — a planta ocupa o voxel sem bloquear), hittable = true para qualquer não-ar.
- **Validação pré-janela**: `assets_load` roda **antes de `CreateEngine`**; qualquer erro é fatal (`assets_fatal`, `os.exit(1)`) com mensagem citando o objeto e o campo. Regras: nomes únicos, vértices/UVs em `[0,1]`, índices dentro do range, capacities fixas de pool (`VERTEX/TRIANGLE/UV_POOL_CAPACITY = 1024`), pior caso de triângulos (culling direcional) ≤ `MAX_TEMPLATE_TRIANGLES`, dimensões uniformes entre PNGs e ≤ `MAX_ASSET_TEXTURE_DIM = 256`, ids 1..255 únicos com **id 0 reservado (AR)** (invariante 2), e os **blocos 1..4 obrigatórios do worldgen** presentes. Decode via stb_image → RGBA8 + `flip_rows` explícito (VS-21), com contadores (`stats_textures_decoded/bytes/decode_ms`).
- **Fallback built-in**: `blocks.json` ausente → warning + `physics_init_builtin` com paridade semântica (ids 1..3 bloqueantes, planta 4 não-bloqueante) — `voxel_assets.loaded = false` e consultas físicas usam a tabela built-in.

Genealogia: ADR-A1, ADR-T5 (texturas por face), specs VS-12, VS-14 (planta/`solid`), VS-19 (física), VS-21 (texturas 6 faces).

## Config INI (`config.odin`)

Os seis parâmetros de dimensionamento — `streaming.vision/generation/unload/simulation` e `compute.chunks_per_batch/batches_in_flight` — vêm de `vox.ini` (override por `--config`, VS-07). Ausente → defaults (8/9/10/5/16/3) com warning.

- **Parse estrito** (`config_parse_ini`): seções `[streaming]`/`[compute]` (outras warn e são ignoradas), comentários `;`, `chave=valor` com inteiro u32 — chave desconhecida warn, linha malformada fatal, com arquivo:linha na mensagem.
- **Derivações** (`config_derive_and_validate`): todas as capacidades de GPU saem dos raios — `visible_capacity = |esfera(vision)|`, `resident_slots = |esfera(unload)| × 1,05` (retenção CAGED + aposentadoria B1; derivar de `generation` esgota o pool), `mirror_pages = ⌈|esfera(simulation)| × 1,5⌉`, `mirror_ring_slots`, `scratch_chunks = batches × chunks`, `work_item_capacity`. Validações de coerência: histerese estrita `vision ≤ generation < unload`, vision ≤ 25 (visible_index 16 bits, VS-09), `scratch ≤ 256`, residentes ≤ 65535, sem overflow u32.
- **Validação de máquina** (`config_validate_machine`): roda **após `create_vma_allocator`** e antes de qualquer provisionamento — soma `config_device_bytes_required` (pools, fila de trabalho, scratch, visíveis, jobs, fixos) e compara com o budget device-local do VMA × 0,9; em excesso, fatal com sugestão de novo raio de `unload` (piso em `generation + 1`). Erros fatais de config/assets saem **antes da janela GLFW existir**.

Genealogia: ADR-C1, spec VS-08 (depende da VS-05 para os budgets do VMA).

## Telemetria Vulkan (`telemetry.odin`)

Base de profiling **sempre disponível, sem dependências externas** (spec VS-05): timestamps GPU por operação + consumo de VRAM via VMA, persistidos em arquivo.

- **Timestamps** (`CmdWriteTimestamp2` TOP/BOTTOM_OF_PIPE): pool gráfica por frame em voo (16 queries: FrameTotal, ApplyEdits, BuildWorkQueue, FinalizeWorkQueue, MeshDraw) e pools de compute por batch em voo (8: generate + pack). Coleta com `WITH_AVAILABILITY`; slot nunca submetido é pulado (VUID 09401). Resultados publicados em `last_times_us` sob `results_mutex`.
- **Budget VMA**: `telemetry_collect_vram` amostra por heap (`GetHeapBudgets` + `CalculateStatistics`): usado, budget, blocos, alocações.
- **Saída**: série temporal CSV a cada 500 ms em `telemetry_service` e snapshot JSON (`vma.BuildStatsString` detalhado) em `telemetry_snapshot` — ambos em `bin/debug/<version>/telemetry/`, timestamped `YYYYMMDD_HHMMSS`.
- **Labels e nomes** (`EXT_debug_utils`): regiões nomeadas nos command buffers e objetos nomeados para Nsight/RenderDoc. Liga/desliga em runtime com `telemetry_toggle` (`TELEMETRY_DEFAULT_ENABLED = true`).

## Tracy (`tracing.odin`, `tracing_gpu.odin`)

Profiler **opt-in por define de compilação** (`TRACY_ENABLE`, default false no `run.bat`): desligado, toda a API compila para no-op inline e nada é linkado; ligado (`run_tracy.bat`, `-define:TRACY_ENABLE=true -define:TRACY_CALLSTACK=10`), delega ao wrapper do odin-tracy (vendored em `vendor/tracy/`). A telemetria VS-05 continua existindo como base independente.

- **Lifetime manual** (VS-15, BLK-37): a lib é compilada com `TRACY_MANUAL_LIFETIME + TRACY_DELAYED_INIT` — o profiler **não pode estar ativo durante o init Vulkan** (com o client ativo desde o CRT init, `vkCreateComputePipelines` travava no driver NVIDIA). `TracingStartup` sobe o profiler só depois do init, junto com `tracing_gpu_init` e o anúncio dos locks; `TracingShutdown(full_teardown)` — só o teardown completo (`--full-teardown`, smokes/CI) coleta as zonas GPU restantes antes de descer o profiler.
- **CPU**: `ZoneN`/`Zone` com fim por `@(deferred_out)` (um único ZoneEnd por zone), FrameMark por frame, `SetThreadName`, plots, mensagens, `AppInfo` com o resumo da config (`ConfigSummary`); lock tracking (`LockBefore/After/AfterUnlock`) nos mutexes principais (queue, results) com srclocs de storage estático (VS-16).
- **GPU** (VS-16): dois contextos ("graphics" e "compute"), cada um com query pool própria de 4096 slots em **ring** — cada zona aloca um par begin/end, com calibração inicial (submit bloqueante só no startup) e re-sync periódico a cada 60 frames. Resets pendentes são gravados no próximo CB (`tracing_gpu_record_context`); coleta nos pontos de espera existentes, em blocos de até 256 queries; com o ring sob pressão (margem 64), zonas são omitidas com um warning único. Zonas e queries são independentes das pools da telemetria.
- **Ferramental**: `tools/build_tracy_client.bat` reproduz `vendor/tracy/tracy.lib` a partir do oskarnp/odin-tracy (client C++ v0.14.1, cl `-MD -O2`, com os defines de lifetime manual); a UI fica em `tools/tracy/tracy-profiler.exe` (release oficial); capturas headless vão para `bin/debug/<version>/tracy/`.

Genealogia: ADR-T3, ADR-T4, specs VS-15 e VS-16 (dependem da VS-05).

## Versionamento (`src/version.odin`, hook pre-commit)

`VERSION_MAJOR/MINOR/BUILD` + `VERSION_STRING` ("0.1.25") vivem em `src/version.odin`. O hook `tools/git-hooks/pre-commit` incrementa o BUILD e reescreve o `VERSION_STRING` a cada commit (com `git add` do arquivo — o bump entra no próprio commit) e regenera a referência Odin em `docs/reference/` (`odin doc src/engine/`, `odin doc src/`). Todo artefato de depuração — telemetria (CSV/JSON), captures Tracy (`tracy/`), eventos — é separado por versão em `bin/debug/<version>/`, o que torna comparáveis as capturas de performance entre builds (etapa de evidência de cada spec).

## Coordenação com os demais sistemas

| Suporte fornece | Para | Consumidor |
| --- | --- | --- |
| Templates/UVs + texturas em camadas | mesh shader e pack | [[sistema-renderizacao]] |
| Tabela física `voxel_physics` | solver de corpos e raycast | [[sistema-mirror-fisica]] |
| Capacidades derivadas (`Config`) | dimensão de todos os buffers/rings | [[sistema-engine-fundacao]], [[sistema-streaming-mundo]] |
| Timestamps/labels/budget | leitura de gargalos | [[sistema-renderizacao]] |
| Zones CPU+GPU, FrameMark | evidência de performance | todas as specs |
| `<version>` | namespace dos artefatos | smokes, CI, captures |

## Leitura sugerida a partir daqui

[[visao-geral]] para o macro; [[ref-assets-config-events]] (assets/config/eventos) e [[ref-physics-tracing]] (physics/tracing/telemetry) para os contratos por proced; genealogia em `../especificacoes/` (VS-05, VS-08, VS-12, VS-15, VS-16) e `../decisoes/` (T1, T3, T4, C1, A1).
