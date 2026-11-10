---
id: SISTEMA-SUPORTE
titulo: Suporte — assets, config, telemetria, Tracy e versionamento
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Suporte

Bem-vindo ao subsistema mais discreto do motor. Nada aqui produz um único voxel na tela — e é exatamente por isso que este documento existe. Vamos visitar os cinco serviços que **sustentam** tudo o que você viu em [[visao-geral]]: os dados de blocos (JSON), a configuração (INI), a telemetria Vulkan, o profiling Tracy e o versionamento.

Duas ideias unem todos eles. A primeira é o **timing**: quase tudo neste documento roda antes de qualquer janela existir, ou então fora do caminho quente do frame. A segunda é o **destino**: todo artefato de depuração vai para `bin/debug/<version>/` (onde `<version>` é o `VERSION_STRING`, por exemplo `0.1.25`), e é a rotina `debug_paths_init` (em `src/engine/debug_paths.odin`) quem cria essas pastas na inicialização. Quando você vir um caminho desses ao longo do texto, já sabe quem o preparou.

A ordem da visita segue a vida do programa: primeiro os dados (assets), depois a configuração que dimensiona a GPU, então os dois sistemas de profiling, e por fim o versionamento que nomeia os artefatos. Contratos finos de cada procedimento e struct ficam em [[ref-assets-config-events]] e [[ref-physics-tracing]] — aqui é a narrativa.

## Assets JSON: blocos são dados, não código

Comece pelo fato central: o que é um bloco no mundo 32³ não está escrito em Odin. Está em `assets/blocks.json`, que define três coleções:

- **`meshes`** — templates de malha: vértices em `[0,1]³`, triângulos com índices e `cull_tags` opcionais (0..5 por face, ou `NEVER`), e UVs por vértice.
- **`textures`** — nome → path de uma única PNG.
- **`blocks`** — id de 1 a 255, nome, e referência por nome a uma malha e a uma (ou mais) texturas.

Uma textura pode ser uma **string** simples (as 6 faces iguais) ou um objeto com as faces `top/bottom/front/back/left/right`. Internamente só existe a forma de objeto: a rotina `assets_parse_texture_faces` (em `src/engine/voxel_assets.odin`) normaliza tudo para `albedo_faces[6]` na ordem `FACE_NORMALS`. É essa normalização que permite ao mesh shader escolher a camada certa por face (VS-21).

### Decodificação de PNG com stb_image

Quem decodifica as PNGs não é uma biblioteca Vulkan — é **stb_image**, a biblioteca de imagem single-header de Sean Barrett, amarrada no Odin. O motor a chama para cada textura e recebe pixels em **RGBA8**, aplicando um `flip_rows` explícito logo em seguida (VS-21). Por que stb_image e não um decoder nativo? Porque é dependência zero, funciona em qualquer plataforma, e decodificar PNG em startup é barato o bastante para não merecer um pipeline assíncrono. A carga é medida: os contadores `stats_textures_decoded`, `stats_texture_bytes` e `stats_texture_decode_ms` registram quantas, quantos bytes e quanto tempo.

### O sampler NEAREST

Com os pixels na mão, o motor cria um único sampler Vulkan — o objeto que diz à GPU **como** ler um texel. Ele vive em `voxel_gpu.texture_sampler` (campo da struct em `src/engine/voxel_gpu.odin`) e é criado com `vk.CreateSampler` logo após a imagem de paleta. Os parâmetros contam a história do estilo visual do motor: `NEAREST` em mag/min/mipmap (texel nítido, sem blur — voxel é pixel), `REPEAT` nos três eixos e `maxLod = 0` (uma única camada de mip, sem chain). O shader o recebe como array sampler nos bindings 8 e 9 do set 0 (`block_albedo_textures`, `block_pbr_textures` — esta última um dummy, ADR-B7). Um sampler só serve porque textura nunca é filtrada: mudar para LINEAR mudaria a cara do jogo inteiro.

### Física separada do render

Cada bloco pode ter um objeto `physics` opcional — `blocking`, `hittable`, `friction ≥ 0`, `restitution ∈ [0,1]` — parseado campo a campo em `assets_parse_physics`. O resultado vai para a tabela **exclusivamente CPU-side** `voxel_physics` (`PhysicsDefinition`: flags + fricção + restituição). Repare o que *não* acontece: o `BlockDefinition` std430 (48 bytes) nunca carrega física — invariante do VS-19, a GPU não precisa saber de atrito. Os defaults do tipo completam a história: `blocking` deriva da solidez (`solid`, default true; `solid:false` marca NON_SOLID — a planta ocupa o voxel sem bloquear), e `hittable` é true para qualquer coisa que não seja ar.

### Validação antes da janela

`assets_load` roda **antes de `CreateEngine`** — a janela GLFW ainda não existe. Qualquer erro é fatal: `assets_fatal` imprime a mensagem citando o objeto e o campo e chama `os.exit(1)`. As regras validadas: nomes únicos, vértices/UVs em `[0,1]³`, índices dentro do range, capacities fixas de pool (`VERTEX/TRIANGLE/UV_POOL_CAPACITY = 1024`), pior caso de triângulos (culling direcional) ≤ `MAX_TEMPLATE_TRIANGLES`, dimensões uniformes entre PNGs e ≤ `MAX_ASSET_TEXTURE_DIM = 256`, ids 1..255 únicos com **id 0 reservado para AR** (invariante 2 — o slot 0 da paleta nunca é reciclado), e a presença dos **blocos 1..4 obrigatórios do worldgen**.

### Fallback built-in: o jogo sobrevive sem o JSON

E se `blocks.json` não existir? O motor não morre — ele **degrada com paridade semântica**. Um warning é emitido e `physics_init_builtin` instala uma tabela embutida (ids 1..3 bloqueantes, planta 4 não-bloqueante), e `voxel_assets.loaded` fica `false` para que consultas físicas saibam que devem usar a tabela built-in. A ideia é simples: um colaborador novo deve conseguir compilar, rodar e ver voxels sem ter montado nenhum asset — o fallback é a ponte entre "clonei o repo" e "criei meu primeiro bloco".

Genealogia: ADR-A1, ADR-T5 (texturas por face), specs VS-12, VS-14 (planta/`solid`), VS-19 (física), VS-21 (texturas 6 faces).

## Config INI: seis números que dimensionam a GPU

O motor tem exatamente seis parâmetros de dimensionamento, e todos vêm do arquivo `vox.ini` (com override por `--config`, VS-07): os quatro raios `streaming.vision`, `streaming.generation`, `streaming.unload`, `streaming.simulation`, e os dois de lote `compute.chunks_per_batch`, `compute.batches_in_flight`. Se o arquivo estiver ausente, defaults (8/9/10/5/16/3) entram com um warning — o jogo sempre liga.

### Parse estrito

`config_parse_ini` (em `src/engine/config.odin`) é intencionalmente rígido: só aceita as seções `[streaming]` e `[compute]` (outras geram warning e são ignoradas), comentários com `;`, e pares `chave=valor` com inteiro u32. Chave desconhecida → warning; linha malformada → fatal, com arquivo:linha na mensagem. A rigidez é um favor: config errada descoberta em startup custa segundos; descoberta em runtime custa uma tarde de debug.

### Derivações: dos raios às capacidades

Aqui está o salto que vale a pena entender de primeira. Nenhum buffer da GPU é dimensionado por número "chutado" — tudo deriva dos raios, em `config_derive_and_validate`:

- `visible_capacity = |esfera(vision)|` — quantos chunks a fila de visíveis comporta;
- `resident_slots = |esfera(unload)| × 1,05` — os slots GPU residentes, com 5% de folga para retenção CAGED e aposentadoria B1. Derivar de `generation` em vez de `unload` esgotaria o pool, porque chunks descarregados ainda precisam de slot enquanto aguardam a aposentadoria;
- `mirror_pages = ⌈|esfera(simulation)| × 1,5⌉` — as páginas do mirror denso na RAM;
- `mirror_ring_slots`, `scratch_chunks = batches × chunks`, `work_item_capacity` — os demais anéis e scratch.

As validações de coerência garantem que essas esferas fazem sentido juntas: histerese estrita `vision ≤ generation < unload`, `vision ≤ 25` (o `visible_index` tem 16 bits, VS-09), `scratch ≤ 256`, residentes ≤ 65535, sem overflow u32 em lugar nenhum.

### Memory budget: a validação de máquina

Antes de provisionar qualquer coisa, o motor pergunta à própria GPU: "você aguenta?". A rotina `config_validate_machine` roda **após `create_vma_allocator`** e soma `config_device_bytes_required` (pools, fila de trabalho, scratch, visíveis, jobs, fixos) para comparar com o **budget device-local** reportado pelo VMA — a alocadora de memória Vulkan (Vulkan Memory Allocator), biblioteca que gerencia as heaps de VRAM em vez de chamadas `vkAllocateMemory` individuais. O limite aceito é 90% do budget. Em excesso, fatal — com uma sugestão concreta: um novo raio de `unload` (piso em `generation + 1`). É o último portão antes da janela: erros fatais de config e assets sempre saem **antes do GLFW existir**, porque diagnosticar sem janela é imensamente mais fácil.

Genealogia: ADR-C1, spec VS-08 (depende da VS-05 para os budgets do VMA).

## Telemetria Vulkan: profiling sem dependências

A telemetria (spec VS-05) é a base de profiling **sempre disponível**: roda em qualquer build, sem servidor externo, sem defines. Timestamps da GPU mais consumo de VRAM, persistidos em arquivo. Existe porque o motor precisa de números mesmo quando ninguém está olhando um profiler — e porque capturas Tracy são comparáveis entre versões justamente quando a base é constante.

### Query pool e timestamp: como se mede tempo na GPU

Para medir duração de um comando na GPU a CPU não pode usar relógio próprio — ela pergunta. O mecanismo é o **query pool** Vulkan: um reservatório de "slots" de consulta que o command buffer preenche. Com `CmdWriteTimestamp2` no estágio `TOP_OF_PIPE` no início da operação e `BOTTOM_OF_PIPE` no fim, a GPU grava dois timestamps; a diferença é a duração. Os pools são organizados por trabalho em voo: um pool gráfico por frame (16 queries: FrameTotal, ApplyEdits, BuildWorkQueue, FinalizeWorkQueue, MeshDraw) e pools de compute por batch (8: generate + pack). A coleta usa `WITH_AVAILABILITY` e pula slots nunca submetidos (VUID 09401) — slot em uso por um frame ainda em voo não é lido. Os resultados aparecem em `last_times_us`, sob `results_mutex`, e alimentam também o Tracy (a seguir).

O resto da telemetria: `telemetry_collect_vram` amostra por heap (`GetHeapBudgets` + `CalculateStatistics` do VMA): usado, budget, blocos, alocações. A saída é uma série temporal CSV a cada 500 ms em `telemetry_service` e um snapshot JSON detalhado (`vma.BuildStatsString`) em `telemetry_snapshot` — ambos em `bin/debug/<version>/telemetry/`, com timestamp `YYYYMMDD_HHMMSS`. Regiões nomeadas nos command buffers e objetos nomeados (`EXT_debug_utils`) deixam os frames legíveis no Nsight/RenderDoc, e `telemetry_toggle` liga/desliga tudo em runtime (`TELEMETRY_DEFAULT_ENABLED = true`).

## Tracy: o profiler opt-in

Se a telemetria é o hodômetro, o Tracy é a telemetria completa: zonas nomeadas, call stacks, timeline por thread. Mas ele é **opt-in por define de compilação** — `TRACY_ENABLE`, default false no `run.bat`. Desligado, toda a API compila para no-op inline e nada é linkado; ligado (via `run_tracy.bat`, com `-define:TRACY_ENABLE=true -define:TRACY_CALLSTACK=10`), delega ao wrapper do odin-tracy, vendored em `vendor/tracy/`. Os dois convivem: a telemetria VS-05 continua existindo como base independente.

### Por que lifetime manual

Aqui está a decisão mais contraintuitiva do subsistema (VS-15, BLK-37). A lib Tracy é compilada com `TRACY_MANUAL_LIFETIME + TRACY_DELAYED_INIT` — ou seja, o profiler **sobe e desce por chamadas explícitas**, não automaticamente com o processo. O motivo é um bug real: com o client Tracy ativo desde o CRT init, `vkCreateComputePipelines` travava no driver NVIDIA. Profiler e init Vulkan simplesmente não podem coexistir naquele trecho.

A consequência: `TracingStartup` sobe o profiler **só depois do init Vulkan**, junto com `TracingShutdown` no caminho de saída. A struct de profiling GPU (`tracing_gpu_init`) e o anúncio dos locks sobem nesse mesmo momento. E `TracingShutdown(full_teardown)` só coleta as zonas GPU restantes antes de descer o profiler quando o teardown é completo (`--full-teardown`, smokes/CI) — no shutdown normal o profiler desce sem esperar a GPU, porque o processo vai sair de qualquer forma.

### O que entra no Tracy

- **CPU**: `ZoneN`/`Zone` com fim por `@(deferred_out)` (um único `ZoneEnd` por zone — sem aninhamento espúrio), `FrameMark` por frame, `SetThreadName`, plots, mensagens, e `AppInfo` com o resumo da config (`ConfigSummary`), para que cada captura carregue o contexto do run.
- **GPU** (VS-16): dois contextos ("graphics" e "compute"), cada um com **query pool própria de 4096 slots em ring** — independente das pools da telemetria. Cada zona aloca um par begin/end; há calibração inicial (um submit bloqueante, só no startup) e re-sync periódico a cada 60 frames. Resets pendentes são gravados no próximo command buffer por `tracing_gpu_record_context`; a coleta acontece nos pontos de espera já existentes, em blocos de até 256 queries. Sob pressão (margem de 64 slots), zonas são omitidas com um warning único — o profiling nunca pode atrasar o frame.
- **Locks** (VS-16): `LockBefore/After/AfterUnlock` nos mutexes principais (queue, results), com srclocs de storage estático.
- **Ferramental**: `tools/build_tracy_client.bat` reproduz `vendor/tracy/tracy.lib` a partir do oskarnp/odin-tracy (client C++ v0.14.1, `cl -MD -O2`, com os defines de lifetime manual); a UI fica em `tools/tracy/tracy-profiler.exe`; capturas headless vão para `bin/debug/<version>/tracy/`.

Genealogia: ADR-T3, ADR-T4, specs VS-15 e VS-16 (dependem da VS-05).

## Versionamento: cada commit carimba o binário

`VERSION_MAJOR/MINOR/BUILD` e o `VERSION_STRING` ("0.1.25") vivem em `src/version.odin`, mas ninguém os edita à mão: o hook `tools/git-hooks/pre-commit` incrementa o BUILD e reescreve o `VERSION_STRING` a cada commit (com `git add` do arquivo — o bump entra no próprio commit) e regenera a referência Odin em `docs/reference/` (`odin doc src/engine/`, `odin doc src/`).

A recompensa aparece em `bin/debug/`: como todo artefato — telemetria CSV/JSON, captures Tracy (`tracy/`), eventos — é separado por `<version>`, duas capturas de performance de builds diferentes vivem em pastas diferentes e são comparáveis lado a lado. É essa comparabilidade que sustenta a etapa de evidência de performance de cada spec.

## Fast-exit: sair sem esperar a GPU

Fechamos com um detalhe de shutdown que parece pequeno e não é. No caminho normal de saída o motor faz **fast-exit**: flush do Tracy e `os.exit` — nada de destruir device, pools e sync objects na ordem certa. Teardown completo só com `--full-teardown` (smokes/CI), que valida a ordem de destruição. Porque dois modos? O teardown Vulkan completo é lento e, no uso diário, inútil: o processo vai morrer e o driver limpa tudo. Mantê-lo só nos smokes preserva a validação onde ela importa sem custar segundos a cada fechamento da janela.

## Coordenação com os demais sistemas

| Suporte fornece | Para | Consumidor |
| --- | --- | --- |
| Templates/UVs + texturas em camadas | mesh shader e pack | [[sistema-renderizacao]] |
| Tabela física `voxel_physics` | solver de corpos e raycast | [[sistema-mirror-fisica]] |
| Capacidades derivadas (`Config`) | dimensão de todos os buffers/rings | [[sistema-engine-fundacao]], [[sistema-streaming-mundo]] |
| Timestamps/labels/budget | leitura de gargalos | [[sistema-renderizacao]] |
| Zones CPU+GPU, FrameMark | evidência de performance | todas as specs |
| `<version>` | namespace dos artefatos | smokes, CI, captures |

## Para ir mais fundo

- [[visao-geral]] para o macro do motor.
- [[ref-assets-config-events]] (assets, config, eventos) e [[ref-physics-tracing]] (physics, tracing, telemetry) para os contratos por proced.
- Genealogia: `../especificacoes/` (VS-05, VS-08, VS-12, VS-15, VS-16) e `../decisoes/` (T1, T3, T4, C1, A1).
