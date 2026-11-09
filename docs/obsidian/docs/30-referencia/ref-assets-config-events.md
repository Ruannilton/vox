---
id: REF-ASSETS-CONFIG-EVENTS
titulo: "Referência: voxel_assets + config + events + debug_paths"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência — assets, config, eventos e caminhos de debug

Os quatro módulos de suporte que rodam **antes da janela** (assets, config, debug paths) ou **na borda do frame** (bus de eventos): dados de blocos via JSON (`voxel_assets.odin`), dimensionamento via INI (`config.odin`), a única porta de input/comandos (`events.odin`) e a convenção de artefatos de depuração (`debug_paths.odin`). Contexto macro: [[visao-geral]]; sistemas correspondentes: [[sistema-suporte]] (assets/config/telemetria/Tracy) e [[sistema-edicao-eventos]] (bus de eventos, journal E1). Todos os módulos são do package `engine` — thread e sincronização são indicados por proced.

---

## Assets JSON (`src/engine/voxel_assets.odin`)

Blocos são **dados, não código**: `assets/blocks.json` (constante `ASSETS_DEFAULT_PATH`) define `meshes`, `textures` e `blocks`. Spec [[VS-12-assets-json|VS-12]], decisões [[ADR-A1-assets-json|ADR-A1]] e [[ADR-T5-texturas-stb-face|ADR-T5]]; complementos em [[VS-14-plantas-alpha-test-spawn|VS-14]] (`solid`), [[VS-19-fisica-solver-mirror|VS-19]] (física CPU-side) e [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (decode stb + 6 faces).

### Constantes

| Constante | Valor | Papel |
| --- | --- | --- |
| `VERTEX_POOL_CAPACITY` / `TRIANGLE_POOL_CAPACITY` / `UV_POOL_CAPACITY` | 1024 | Pools fixos de templates (buffers GPU criados em `voxel_gpu_init`; estourar é fatal). |
| `MAX_ASSET_TEXTURE_DIM` | 256 | Teto de dimensão por PNG. |
| `PHYSICS_FLAG_BLOCKING` / `_HITTABLE` / `_CLIMBABLE` / `_LIQUID` | 1 / 2 / 4 / 8 | Bitmask da tabela física; 4 e 8 reservados (líquidos/escaláveis fora de escopo). |
| `PHYSICS_DEFAULT_FRICTION` / `_RESTITUTION` | 0.6 / 0.0 | Defaults documentados (REQ-PHY-01). |

### Structs

- `PhysicsDefinition :: struct { flags: u32, friction: f32, restitution: f32 }` — uma linha da tabela física **exclusivamente CPU-side** `voxel_physics` (indexada por block id, paralela ao registry std430). Invariante VS-19: nenhuma propriedade física vai ao shader; `BlockDefinition` permanece 48 B.
- `VoxelAssets :: struct` — o estado global `voxel_assets`: `loaded` (false = fallback built-in), `templates` (`[]MeshTemplate`, slot 0 = AR na posição 0 — invariante 2), `vertices`/`triangles`/`uvs` (pools formatados; triângulos packed com cull tag nos bits 24–26), `registry` (`[BLOCK_REGISTRY_CAPACITY]BlockDefinition`), `block_names` (por id; `""` quando o id não tem bloco), `texture_pixels`/`texture_width`/`texture_height`/`texture_layers` (RGBA8 único, w·h·4·layers na ordem de definição), `layer_of` (mapa nome→camada, privado ao build) e os contadores VS-21 `stats_textures_decoded`/`stats_texture_bytes`/`stats_decode_ms`.
- Structs de parse (espelham o schema do JSON, tags explícitas): `assets_json_mesh { name, vertices: [][3]f64, triangles: [][3]i64, cull_tags: []i64, uvs: [][2]f64 }`; `assets_json_texture { name, path }`; `assets_json_block { id: i64, name, mesh, transparent: bool, solid: Maybe(bool), physics: json.Value, texture: json.Value }` — `physics` e `texture` são `json.Value` porque o parse é manual (dois formatos de textura; validação campo a campo de física); `assets_json_doc` junta as três coleções.
- `asset_tex_dim :: struct { name, width, height }` — dimensões por textura, para o relatório de divergência.

### `assets_load :: proc()` — thread main, pré-janela

Sequência (REQ-AST-06): lê `blocks.json`; **ausente → warning + fallback built-in** (`physics_init_builtin`, `loaded = false`) — paridade semântica com o caminho do JSON; JSON inválido → `assets_fatal`. Válido → `assets_build_meshes` → `assets_build_textures` → `assets_build_blocks`, `loaded = true`, e log-resumo (malhas/texturas/blocos + contadores VS-21 e `decode_ms` da zone `assets_texture_decode`). **Contrato**: qualquer erro de validação é fatal (`assets_fatal` → `log.errorf` + `os.exit(1)`) com mensagem citando objeto e campo; nenhuma janela GLFW existe nesse ponto. Não há concorrência — `voxel_assets`/`voxel_physics` são preenchidos aqui e lidos depois como read-only (síncrono por construção).

### Build de malhas, texturas e blocos (privados, thread main)

- `assets_build_meshes(doc)` — validação **espelhada**: reaplica as mesmas regras de `validate_template`/`validate_template_uvs` (módulo de templates) com nome do objeto e índice na mensagem. Checa capacidade de templates (`MESH_TEMPLATE_CAPACITY`), nome não vazio/único, vértices e triângulos não vazios, tetos `MAX_TEMPLATE_VERTICES`/`MAX_TEMPLATE_TRIANGLES`, vértices em `[0,1]³`, UVs (se presentes) em número igual ao de vértices e em `[0,1]²`, índices de triângulo dentro do range, `cull_tags` (se presentes) em número igual e valor 0..5 ou `CULL_FACE_NEVER`, e **pior caso de triângulos** (`compute_worst_case_tris`, culling direcional) ≤ `MAX_TEMPLATE_TRIANGLES`. Formatação (REQ-AST-02): appends nos pools com checagem de capacidade (1024), triângulos packed via `pack_template_triangle`, flag `TEMPLATE_FLAG_HAS_FLUSH_FACES` se alguma face tem tag ≤ 5, `uv_offset` por malha (`NO_TEMPLATE_UV_OFFSET` quando sem UVs). Slot 0 = AR (`uv_offset = NO_TEMPLATE_UV_OFFSET`) é reservado antes do loop.
- `assets_build_textures(doc, json_path)` — zone-reentrante: mede `decode_start` para `stats_decode_ms`. Por textura: nome único/não vazio, path não vazio, arquivo relativo ao diretório do JSON; decode via `stbi.load_from_memory` (força 4 canais → **RGBA8**) + **`flip_rows` explícito** pós-decode (VS-21, REQ-TEX-01/02 — nem o decoder antigo nem o upload invertiam linhas), dimensões válidas ≤ 256, contadores de decode. Depois do loop: **dimensões uniformes** entre todas as PNGs, senão fatal listando `nome WxH` de cada uma. Resultado: `texture_pixels` (uma layer por textura, ordem de definição), `layer_of` e dims comuns. Por que em memória: `stbi.image_free` no buffer do decoder; a cópia flipada vai para `pixels`.
- `assets_build_blocks(doc)` — por bloco: nome não vazio, **id 1..255** (0 reservado a AR — invariante 2), id único (mapa `seen` cita o bloco anterior), `mesh` resolvido por nome no índice de templates (1-based), textura via `assets_parse_texture_faces`, flags `TRANSPARENT`/`NON_SOLID` (VS-14), escrita no `registry[id]` + `block_names[id]`, e física via `assets_parse_physics` com default do tipo (blocking = solidez, hittable = true). Bloco id 1 (grama) loga as 6 camadas de `albedo_faces` para conferência VS-21. **Contrato worldgen** (REQ-PLT-05): os blocos **1..4 devem existir** — ausência é fatal listando os ids. **Invariantes físicos** (log.assert): id 0 (AR) nunca bloqueia nem é atingível; se o id 4 for NON_SOLID, é não-bloqueante e atingível.

### Parse manual e helpers (privados)

- `assets_parse_texture_faces(ctx, value, layer_of) -> [6]u32` — VS-21 (REQ-TEX-04), normalização string→objeto: **string não vazia** vira o objeto com as 6 faces iguais; **objeto** deve ter exatamente as chaves `top/bottom/front/back/left/right` (faltante ou não-string → fatal); ordena para `albedo_faces[6]` na ordem `FACE_NORMALS` (+X,−X,+Y,−Y,+Z,−Z) via `TEXTURE_FACE_TO_SLOT`; cada face resolvida contra `layer_of` (textura não encontrada → fatal citando a face).
- `assets_parse_physics(ctx, value, default_flags) -> PhysicsDefinition` — objeto opcional validado **campo a campo**, citando o bloco: `blocking`/`hittable` (bool), `friction` (número ≥ 0), `restitution` (número ∈ [0,1]); chave desconhecida → fatal listando as conhecidas.
- `flip_rows(pixels, width, height)` — inverte linhas de um buffer RGBA8 trocando y com height−1−y; idempotente em dupla aplicação.
- `physics_init_builtin` — fallback sem arquivo: ids 1..3 bloqueantes + atingíveis, planta (4) não-bloqueante + atingível, fricção/restituição nos defaults.
- Consultas físicas (contextless, chamadas do solver/raycast): `block_is_solid(id)` (com assets: flag NON_SOLID; sem assets: regra built-in ids 1..3 sólidos, 4 não), `block_is_blocking(id)`, `block_is_hittable(id)` — bitmask sobre `voxel_physics`.
- Utilitários de mensagem: `fmt_mesh_where` (contexto `malha[i]`/`malha 'nome'`), `json_number` (f64|i64), `variant_type_name` (nome PT do tipo JSON), `assets_fatal` (log + `os.exit(1)`), `face_names_face` (camada→nome, para o log da grama).

---

## Config INI (`src/engine/config.odin`)

Spec [[VS-08-config-ini-provisionamento|VS-08]], decisão [[ADR-C1-config-ini-provisionamento|ADR-C1]]; limite de formato em [[VS-09-visible-index-16-bits|VS-09]]. O `Config` global é carregado/validado **antes de `CreateEngine`** (erro fatal sai sem janela); a validação de máquina roda **após `create_vma_allocator`**.

### Constantes e estado

- `CONFIG_DEFAULT_PATH = "vox.ini"`; `MIRROR_PAGE_FACTOR_NUM/DEN = 3/2` (folga do pool de páginas do mirror); `CONFIG_BUDGET_MARGIN_NUM/DEN = 9/10` (margem de segurança do budget device-local).
- `config: Config` — o global efetivo. `config_path: string` — override pela flag `--config` (VS-07, parse em `events_init`).

### `Config :: struct`

| Campo | Origem | Papel |
| --- | --- | --- |
| `radius_vision/generation/unload/simulation` | parâmetros (INI) | Raios de streaming em chunks. |
| `chunks_per_batch`, `batches_in_flight` | parâmetros (INI) | Batching de compute. |
| `visible_capacity` | derivado | `\|esfera(vision)\|` — chunks visíveis simultâneos. |
| `resident_slots` | derivado | `\|esfera(unload)\| × 1,05` — slots residentes (retenção CAGED + transitório de aposentadoria B1; derivar de `generation` esgotaria o pool). |
| `scratch_chunks` | derivado | `batches_in_flight × chunks_per_batch`. |
| `mirror_pages` | derivado | `⌈\|esfera(simulation)\| × 1,5⌉`. |
| `mirror_ring_slots` | derivado | `max(64, próxima potência de 2 ≥ scratch_chunks)`. |
| `work_item_capacity` | derivado | `visible_capacity × BRICKS_PER_CHUNK`. |
| `work_queue_slot_words` | derivado | `WORK_QUEUE_STATE_WORDS + work_item_capacity`. |
| `provisioned_device_bytes` | validação de máquina | Bytes device somados em `config_validate_machine`. |

### Procedures

- `config_load :: proc()` — thread main, pré-janela. Defaults (visão 8, geração 9, descarga 10, simulação 5, lote 16, lotes em voo 3); INI ausente → warning + defaults; presente → `config_parse_ini`; depois `config_derive_and_validate`, publica em `config` e loga. Erros fatais (`config_fatal` → exit 1) **antes de qualquer janela**.
- `config_parse_ini(text, path, cfg)` (privado) — **INI estrito**: comentários `;` (linha inteira ou inline), seção `[nome]` malformada → fatal com `arquivo:linha`; seções fora de `streaming`/`compute` warn e são ignoradas; linha sem `=` → fatal; chave desconhecida → warn; valor inteiro u32 malformado → fatal com arquivo:linha. Chaves: `streaming.vision/generation/unload/simulation`, `compute.chunks_per_batch/batches_in_flight`.
- `config_derive_and_validate(cfg)` (privado) — regras: `vision ∈ 1..25` (visible_index de 16 bits; vision=26 daria 73.525 > 65.535 — VS-09), `simulation ≥ 1`, `generation ≥ vision`, **histerese estrita** `generation < unload`, `chunks_per_batch ∈ 1..64`, `batches_in_flight ∈ 1..8`. Derivações: esferas via `sphere_count` (pontos inteiros com x²+y²+z² ≤ r²), `resident = ⌈esfera(unload) × 1,05⌉`, `mirror_pages = ⌈esfera(simulation) × 1,5⌉`, ring via `next_power_of_two` (piso 64). Tetos: capacidades derivadas cabem em u32, `resident ≤ 65535`, `scratch ≤ 256`, `work_item_capacity` em u32 — excesso é fatal com mensagem orientada.
- `config_validate_machine :: proc()` — thread main, **após `create_vma_allocator`**, antes de qualquer provisionamento. Soma `config_device_bytes_required` (pools por slot residente, fila de trabalho por frame em voo, scratch, visíveis, jobs de geração, fixos — registry/templates/pools/dummy — e o residual VS-10 de feedback de flags) e compara com o **budget device-local do VMA × 0,9** (somado por heap device-local). Excesso → fatal com **sugestão**: iterar `unload` para baixo (piso `generation + 1`), economizando por slot removido; se o piso não basta, pede redução manual de vision/generation. OK → log `validação de máquina OK`.
- `config_log_effective` (privado) — log dos 6 parâmetros + 6 capacidades derivadas.
- `ConfigSummary() -> string` — resumo de uma linha para o AppInfo do Tracy (VS-15, REQ-TRC-04).
- Helpers privados: `sphere_count(radius)` e `next_power_of_two(v)` (contextless), `config_fatal`.

**Sincronização**: todo o módulo é single-threaded por construção — escrita só em `config_load`/`config_validate_machine` (main, pré-loop); a worker e a GPU leem `config` como read-only depois.

---

## Bus de eventos (`src/engine/events.odin`)

Spec [[VS-07-eventos-input-replay|VS-07]], decisão [[ADR-I1-bus-eventos-input-replay|ADR-I1]]; consumidor do journal E1: [[VS-03-edicao-e1|VS-03]]. Detalhes de `edit_update`/`edit_ring_write`: [[ref-edit-mirror]] e [[sistema-edicao-eventos]].

### Tipos e payloads

`EventType :: enum` — 13 tipos: **input** `KeyPress`, `KeyRelease`, `MouseMove`, `MouseButton`, `CloseRequested`; **comando** `TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `Wait`, `ToggleTelemetry`, `TelemetrySnapshot`. `Event = { t: f64, type: EventType, payload: EventPayload }` — `t` em segundos desde o início da aplicação (`glfw.GetTime() − t0`).

| Payload | Campos | Usado por |
| --- | --- | --- |
| `KeyPayload` | `key`, `scancode: i32`, `duration: f64` (< 0 = ausente) | KeyPress/KeyRelease — `duration ≥ 0` agenda release sintetizado |
| `MouseMovePayload` | `dx, dy: f32` | MouseMove (delta, não posição absoluta) |
| `MouseButtonPayload` | `button: i32`, `press: bool` | MouseButton |
| `Vec3fPayload` | `v: [3]f32` | TeleportTo (`position`), LookAt (`target`) |
| `Vec3iPayload` | `v: [3]i32`, `block_id: u32` | AddBlock/RemoveBlock |
| `WaitPayload` | `seconds: f64` | Wait — segura o cursor de replay |
| `struct {}` | — | CloseRequested, ToggleTelemetry, TelemetrySnapshot |

`EventPayload :: union` reúne os sete. `json_event` (privado) é a forma JSONL com campos `Maybe` por tipo — um schema único para todas as linhas.

### Estado global `events`

`EVENT_QUEUE_CAPACITY = 4096`. O estado global agrupa: `t0`; a **fila anel** (`queue`, `head`/`tail`, `overflow_count`, `overflow_warned`); o **estado de teclas derivado** (`pressed: map[i32]bool`, `scheduled_release: map[i32]f64`); `handlers: map[EventType]proc(Event)`; o bloco de **gravação** (`record_enabled`, `record_path`, `record_file`); e o bloco de **replay** (`replay_path`, `replay_events` ordenado por `t`, `replay_cursor`, `replay_hold_until`, `replay_dispatched`, `replay_skipped`, `replay_finished`, `replay_finish_time`, `exit_after_replay`). `full_teardown: bool` é global separado (flag `--full-teardown`).

### Init, flags e teardown (thread main, pré-janela)

- `events_init :: proc()` — aloca mapas/handlers e faz o **parse de flags**: `--record <caminho>` (fixa destino; exige argumento), `--no-record` (desliga), `--replay <caminho>` (carrega replay), `--exit-after-replay`, `--full-teardown` (seta o global), `--config <caminho>` (alimenta `config_path` do módulo de config). Conflito `--no-record` + `--record`: `--record` vence (warn). Se há replay, `events_load_replay` roda aqui — **fatal antes da janela** se o arquivo estiver ausente/ilegível ou com JSON inválido na primeira linha (REQ-EVT-08).
- `events_set_t0 :: proc()` — fim do init, **antes do primeiro `PollEvents`** (REQ-EVT-07): fixa `t0 = glfw.GetTime()` e abre o recorder se habilitado. Invariante: callbacks são registrados antes, mas nenhum evento é processado antes de `t0` existir.
- `events_destroy :: proc()` — flush + close do arquivo de gravação; libera mapas e `replay_events`.

### Produtores (contextless — callbacks GLFW e cursor de replay)

`events_push_now(type, payload)` e `events_push(e)` são `proc "contextless"`: sem context de runtime, sem alocação, sem log — só empurram na fila anel. `events_push` detecta overflow (anel cheio): descarta e conta (`overflow_count`); o warning é único por sessão, emitido no dreno. `events_emit(type, payload)` é a variante com context para emissão fora de callback (cursor de replay, handlers). `events_now()` (contextless) = `glfw.GetTime() − events.t0`. **Sincronização**: produtores rodam na thread do GLFW; o dreno na thread main; a fila anel é o único ponto de comunicação e a invariante é produtor-simples/consumidor-simples por frame (nenhum lock — thread única de produtores).

### Dreno e estado derivado (thread main, 1×/frame)

- `events_drain :: proc()` — zone Tracy `drain` (VS-16). Antes de drenar: (1) vence `scheduled_release` — `KeyPress{duration}` gera um `KeyRelease` sintetizado no tempo corrente; (2) warn único de overflow. No loop: pop do anel → `events_record_line` (JSONL) → `events_apply_key_state` → handler registrado, se houver. **A ordem importa**: gravação e estado de teclas acontecem para todo evento, mesmo sem handler.
- `events_apply_key_state` (privado) — mantém `pressed` e `scheduled_release`; última escrita vence (re-press marca novo release); `KeyRelease` limpa o agendamento. É o que substituiu o polling `glfw.GetKey`.
- `events_register(types, handler)` — um handler por tipo (sobrescreve).
- `events_is_pressed(key) -> bool` — leitura do conjunto de teclas pressionadas (usada por `update_camera_movement` em `main`).

### Gravação JSONL (thread main)

Default **ligada**: cada evento drenado vira uma linha (`events_record_line`), escrita e flushed — JSONL não tem trailer, então crash não corrompe o arquivo. `events_recorder_open` (chamado de `events_set_t0`): destino default `bin/debug/<VERSION_STRING>/events/events_YYYYMMDD_HHMMSS.jsonl` (diretórios de `debug_paths_init`); `--record` fixa o caminho. Falha ao abrir → gravação desligada com erro (não fatal). Timestamps com 6 casas; `key_name` via `glfw.GetKeyName`. Gravar durante replay usa o tempo da sessão corrente — invariante "`t` = quando foi emitido".

### Replay (cursor por frame, thread main)

- `events_replay_feed(now)` — zone `replay_cursor`; chamado no loop **antes** do dreno. Empurra na fila os eventos com `t ≤ now`, com timestamp da sessão corrente. **`Wait`** (REQ-EVT-05): ao despachar um Wait, `replay_hold_until = t_emitido + seconds`; nada com `t` anterior ao hold sai antes de o **relógio da sessão** passar desse instante (o app continua renderizando). Fim do stream: marca `replay_finished`, loga o sumário (`despachados`, `pulados(linhas)`, `ignorados(aguardando)`, `duração`).
- `events_load_replay(path)` (privado) — valida e carrega antes da janela: linha vazia ignorada; primeira linha de conteúdo inválida → fatal; demais linhas inválidas ou tipo desconhecido → skip com warn + contagem em `replay_skipped`. `events_parse_line` converte JSON → `Event` por tipo (ex.: `MouseButton.action` deve ser `"press"`/`"release"`; `AddBlock.block_id` ∈ 1..65535; `Wait.seconds ≥ 0`). Depois: **ordenação por `t`** (insertion sort — arquivos já vêm quase ordenados).
- `events_replay_is_finished()` / `events_should_exit_after_replay()` — sinais consumidos pelo loop de `main` (`--exit-after-replay` fecha a aplicação para pipelines de captura).
- Utilitários privados: `event_type_from_name`/`event_type_name` (tabela de nomes), `events_key_name`, `events_timestamp_string`, `events_try_open` (cria diretórios do caminho).

### Ponte com o journal E1

Os comandos `AddBlock`/`RemoveBlock` desaguam no handler de `main`, que chama `ve_request_voxel_edit` (intake do journal, [[sistema-edicao-eventos]]). Do outro lado, o **flush E1** roda na worker: `edit_update(ve, frame_index)` (`voxel_edit.odin:225`, chamada do laço da worker em `voxel_worker.odin:239`) faz feedback → retry de EMPTYs → flush devido (`EDIT_FLUSH_INTERVAL_MS` + `force_next_flush`); a main consome o staging em `edit_ring_write` por frame. O bus e o journal são mundos separados que se encontram no handler.

---

## Caminhos de debug (`src/engine/debug_paths.odin`)

Convenção de artefatos: **tudo** de depuração — log, telemetria (CSV/JSON), eventos JSONL, captures Tracy — vive em `bin/debug/<version>/`, com `<version>` = `VERSION_STRING` (ex.: `0.1.25`, `src/version.odin`), o que torna comparáveis as capturas entre builds.

- `debug_paths_init(version)` — thread main, **primeira coisa em `main`** (antes do logger): cria `debug/<version>/` e as subpastas `telemetry/`, `events/`, `tracy/`, e define os globais `debug_log_path` (`debug/<version>/log.txt`), `telemetry_output_directory`, `events_output_directory`, `tracy_output_directory` (com `debug/` como prefixo — o binário roda com cwd `bin/`, daí o caminho efetivo `bin/debug/...`).
- **Contrato**: `os.make_directory` em diretório existente retorna erro ignorado (idempotente); nenhum dos caminhos é configurável — a convenção é única para todos os consumidores (telemetria, recorder de eventos, Tracy, log). Não há sincronização: escrita uma vez no startup, leitura read-only depois.

---

## Leitura sugerida

[[sistema-suporte]] (o porquê de assets/config/Tracy), [[sistema-edicao-eventos]] (o bus e o journal E1), [[visao-geral]] (pipeline de um frame). Vizinhos de referência: [[ref-main]] (callbacks e handlers em `main`), [[ref-voxel-gpu]] (consumo de templates/texturas/capacidades), [[ref-voxel-types]] (structs de contrato). Genealogia: specs [[VS-07-eventos-input-replay|VS-07]], [[VS-08-config-ini-provisionamento|VS-08]], [[VS-12-assets-json|VS-12]], [[VS-21-texturas-nearest-flip-stb-faces|VS-21]]; decisões [[ADR-A1-assets-json|ADR-A1]], [[ADR-C1-config-ini-provisionamento|ADR-C1]], [[ADR-I1-bus-eventos-input-replay|ADR-I1]], [[ADR-T5-texturas-stb-face|ADR-T5]].
