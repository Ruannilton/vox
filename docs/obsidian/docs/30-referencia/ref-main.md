---
id: REF-MAIN
titulo: "Referência: main, camera, utils (package main)"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência — package main (`main.odin`, `camera.odin`, `utils.odin`)

Bem-vindo à camada mais externa do motor. Este documento cobre o package `main` — o arquivo `main.odin`, que contém o ponto de entrada, o loop principal e o jogador (input → corpo físico → câmera), o arquivo `camera.odin`, com a câmera livre, e o arquivo `utils.odin`, com um único utilitário de checagem Vulkan.

Antes de mergulhar, vale fixar uma ideia: **tudo aqui é orquestração**. Nenhum trabalho pesado acontece neste package — o init Vulkan, o streaming de chunks, o render e a física vivem nos módulos `engine`, documentados em [[ref-engine]], [[ref-voxel-engine-worker]], [[ref-voxel-render]] e [[ref-physics-tracing]]. Se você está chegando agora, leia primeiro [[visao-geral]] para o pipeline macro e [[sistema-engine-fundacao]] para entender init/janela/swapchain; os sistemas [[sistema-edicao-eventos]] (bus de eventos, journal E1) e [[sistema-mirror-fisica]] (corpo do jogador e física) dão o contexto das seções correspondentes abaixo.

## Constantes do jogador (`main.odin:25-29`)

Estas constantes definem as medidas do jogador que todo o resto do package assume. Elas são lidas pelo solver de física (tamanho do corpo), pelas funções de movimento (velocidade) e pelo código que ancora a câmera nos olhos:

| Constante | Valor | Papel |
| --- | --- | --- |
| `PLAYER_SIZE` | `(0.6, 1.8, 0.6)` | Tamanho do corpo AABB do jogador no solver. |
| `PLAYER_HALF_WIDTH` | `0.3` | Metade da largura; usado para recentrar o corpo sob a câmera (`position - (hw, eye, hw)`). |
| `PLAYER_EYE_HEIGHT` | `1.62` | Altura dos olhos acima dos pés; a câmera segue `body.position + (hw, eye, hw)` (VS-19). |
| `PLAYER_WALK_SPEED` | `6.0` | Velocidade horizontal base (unidades/s). |
| `PLAYER_SPRINT_FACTOR` | `2.0` | Multiplicador com LEFT_SHIFT. |

Invariante: o corpo é criado com os pés `PLAYER_EYE_HEIGHT` abaixo da câmera inicial; qualquer teletransporte (`TeleportTo`) reposiciona corpo **e** câmera juntos, zerando a velocidade.

## Estado global do package (`main.odin:13-23`)

O package `main` mantém um punhado de variáveis globais — isto é de propósito: são o estado da aplicação inteira, acessado pelo loop principal e pelos handlers do bus de eventos. Cada uma abaixo já diz quem a lê e quem a escreve:

- `camera: Camera` — a câmera da aplicação; a worker a recebe por cópia no pedido de frame.
- `voxel_engine: ^engine.VoxelEngine` — handle global do motor (init em `main`, usado por todos os handlers).
- `last_x, last_y: f64`, `first_cursor_event: bool` — estado do cursor para deltas de mouse; o primeiro evento após `CURSOR_DISABLED` só ressincroniza `last_x/last_y` sem aplicar delta (recentering do GLFW dispara posição defasada).
- `player_body: engine.PhysicsHandle` — handle do corpo AABB do jogador no solver (VS-19).
- `space_pressed: bool` — dedup de auto-repeat do SPACE (REQ-GPL-06): um pulo por press.
- `jump_tracking, jump_base_y, jump_apex_y` — janela de amostragem do ápice do pulo (AC-04 da VS-20): abre quando `stats_jumps` avança e o corpo deixou o chão; fecha no próximo pouso, logando base/ápice/delta.

## `main :: proc()` (`main.odin:31`)

Esta é a procedure de entrada — quem o sistema operacional chama ao iniciar o executável. Sua única função é montar o mundo na ordem certa (logging → config → assets → Vulkan → mundo → callbacks) e cair no loop principal. A sequência, passo a passo:

1. **Logging**: `debug_paths_init(VERSION_STRING)` + arquivo em `engine.debug_log_path`; logger multi (console + arquivo); banner de versão.
2. **Pré-janela**: `events_init` → `config_load` → `assets_load` (parsing/validação de assets antes da janela; ausência cai em fallback built-in — REQ-AST-06). Flags de replay/config são validadas fatalmente aqui ([[sistema-edicao-eventos]]).
3. **Init Vulkan/GLFW**: `CreateEngine`/`DestroyEngine` (defer).
4. **Tracy**: `TracingStartup`/`TracingShutdown` — Tracy só inicia **após** init Vulkan/GLFW (VS-15, BLK-37) e o shutdown defer fica antes do destroy do voxel engine porque a worker (que emite zones) é encerrada dentro dele ([[ref-physics-tracing]]).
5. **Mundo**: `voxel_engine_init`.
6. **Câmera e jogador**: `camera_create((32,75,60), (-50,-90,0), 45°)`; `physics_body_create` com os pés sob a câmera.
7. **Projeção**: `mat4Perspective(fov, aspect, 0.5, 500)`; a constante `GL_TO_VK_CLIP` corrige clip space OpenGL→Vulkan (y para baixo, z `[0,1]`), aplicada por último: `vp_final = GL_TO_VK_CLIP * projection * view`.
8. **Callbacks GLFW** (todos produtores puros — só empurram eventos no bus): key, cursor pos, mouse button, window close. Registrados **antes** de `events_set_t0()` — invariante: `t0` é fixado após o init, antes do primeiro `PollEvents`.
9. **Handlers registrados** no bus (ver seção abaixo).
10. **Loop principal** (ver seção abaixo).
11. **Saída**: log da pose final (`FINAL pose` — estado observável para validação de replay) + `edit_log_stats`; **fast-exit** por default (`TracingShutdown(false)` + `os.exit(0)`, teardown Vulkan pulado — SO reclaim); com `--full-teardown`, `voxel_engine_destroy` para e junta a worker antes do `DeviceWaitIdle` interno (BLK-28).

### Loop principal — fases por frame (`main.odin:181-424`)

Aqui é onde o jogo vive. Cada iteração desta área é uma zone Tracy `frame`, aberta com `free_all(context.temp_allocator)` — tudo alocado com o temp allocator dentro do frame é descartado de uma vez no próximo. As fases, na ordem em que acontecem:

1. **`events_drain`** — `events_replay_feed(now)` + `events_drain()`: dreno único do bus (input + comandos de replay); `events_should_exit_after_replay` pode fechar a janela ([[sistema-edicao-eventos]]).
2. **`engine_update`** — `engine.Update()` (telemetria/service de engine), `telemetry_service()`, depois:
   - `frame_dt = min(deltaTime, 0.1)` (clamp anti-spiral);
   - `update_camera_movement(frame_dt)` — velocidade horizontal imposta pelo input;
   - `physics_tick(voxel_engine, frame_dt)` — passos fixos do solver (VS-19; detalhes [[sistema-mirror-fisica]], [[ref-physics-tracing]]);
   - `player_track_jump_apex()` + `player_sync_camera()` — a câmera segue o corpo;
   - `gameplay_update_target(...)` — DDA central da mira, 1×/frame **após** física/câmera (VS-20, REQ-GPL-01);
   - `voxel_engine_request_frame(...)` — acorda a worker com a câmera e o `currentTimelineValue` (handoff main→worker, [[sistema-streaming-mundo]]).
3. **`frame_wait`** —
   - `WaitTimelineSemaphore()` → `signal_value` (espera do slot de frame; [[sistema-engine-fundacao]]);
   - `telemetry_collect_graphics(frameIndex)` + `tracing_gpu_collect_graphics()` (coleta com disponibilidade, nunca bloqueante — VS-16);
   - `camera_view(&camera)` → `vp = GL_TO_VK_CLIP * projection * view`;
   - `AcquireFrameResource()` + `AcquireNextImage()`; falha → `CancelFrameReservation()` + `continue`;
   - **`publish_visible`**: `voxel_engine_wait_published(ve, signal_value, camera_chunk)` → `visible_count` + `published_compute_value` (o valor da timeline de compute que o render vai esperar; contrato B1 de anti-ABA, [[sistema-streaming-mundo]]);
   - **`edit_flush`**: `edit_ring_write(ve, frameIndex)` → `edit_job_count` (staging consumido em uma cópia, [[sistema-edicao-eventos]]);
   - plots Tracy por frame (`visible_chunks`, `work_items`, `empty_chunks`) só quando a UI está conectada.
4. **`render_record`** — gravação do CB do frame:
   - `ResetCommandPool` + `BeginCommandBuffer` (ONE_TIME_SUBMIT);
   - reset de pool de telemetria + timestamp begin;
   - barreiras: swapchain `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL`, depth `UNDEFINED → DEPTH_ATTACHMENT_OPTIMAL`;
   - `voxel_render_prepare(cmd, vp, camera.position, visible_count, frameIndex, edit_job_count)` — edições do flush + builder da fila de trabalho (a espera de compute usa `compute_wait_value`; se 0, só a acquire é esperada) ([[ref-voxel-render]]);
   - `CmdBeginRendering` (clear azul, depth clear 1) + `voxel_render_record(...)` — draws mesh indiretos;
   - barreira `COLOR_ATTACHMENT_OPTIMAL → PRESENT_SRC_KHR`; timestamp end; `EndCommandBuffer`.
5. **Submit/present** — `QueueSubmit2` na fila gráfica: espera acquire + timeline de compute (`wait_count = 2` sse `compute_wait_value > 0`), sinais present + timeline (`signal_value`); `sync.mutex_unlock(&voxel_engine.frame_mutex)` libera a worker para reescrever o publish; marca `gfx_slot_submitted[frameIndex] = true`; `Present()`.
6. `FrameMark()` fecha o frame no Tracy.

Invariantes do loop: a main nunca espera uma rodada inteira da worker (renderiza com o último publish válido); rings de 2 frames só são reescritos após a timeline gráfica confirmar o uso anterior; o unlock do `frame_mutex` só acontece depois do submit.

### Handlers registrados no bus (`main.odin:139-171`)

O bus de eventos ([[sistema-edicao-eventos]]) é a fronteira entre input e estado: os callbacks GLFW só produzem eventos, e estas procedures são as únicas que consomem. A tabela diz, para cada tipo de evento, qual handler o atende e o que ele faz com o estado da aplicação:

| Tipos | Handler | Efeito |
| --- | --- | --- |
| `KeyPress`, `KeyRelease` | `key_handler` | ESC→`CloseRequested` (registra o fechamento), F8/F9 telemetria, F7 validação debug (packed×denso + heights), SPACE→`gameplay_jump` com dedup de auto-repeat. |
| `MouseMove`, `MouseButton` | `mouse_handler` | move: `camera_rotate` com sensibilidade 0.07 (dx→yaw, dy→pitch, Y invertido); botão: press esquerdo coloca pedra, direito remove — consome o snapshot da mira do frame (VS-20 REQ-GPL-04/05). |
| `CloseRequested` | `close_handler` | `glfw.SetWindowShouldClose(true)`. |
| `TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `ToggleTelemetry`, `TelemetrySnapshot` | handler anônimo | `TeleportTo`: move câmera **e** corpo (zera velocidade) + `gameplay_clear_target`; `LookAt`: `camera_look_at`; `AddBlock`/`RemoveBlock`: `ve_request_voxel_edit` (porta única do journal E1, [[sistema-edicao-eventos]]); telemetria: toggle/snapshot. |

Os callbacks GLFW (produtores) e os handlers (consumidores) vivem em lados opostos do dreno — callbacks **nunca** tocam estado da aplicação.

### Funções privadas do jogador

São as helpers que o loop principal e os handlers chamam para mover o jogador. Nenhuma é pública para outros módulos — toda a interação externa passa pelo bus:

- `update_camera_movement(delta_time)` (`main.odin:446`) — chamada uma vez por frame durante `engine_update`. Lê o conjunto de teclas pressionadas derivado do bus (`events_is_pressed`), aplica sprint, normaliza a diagonal (`×0.7071`), projeta o input na base horizontal do yaw (`forward = (cos yaw, 0, sin yaw)`, `right = (-sin yaw, 0, cos yaw)`) e **impõe** `velocity.x/z`. Contrato: input-driven — o solver integra o resto (gravidade, sweep, fricção).
- `player_track_jump_apex()` (`main.odin:477`) — amostra o ápice entre impulso e pouso; só abre a janela quando o corpo de fato deixou o chão.
- `player_sync_camera()` (`main.odin:500`) — `camera.position = body.position + (hw, eye, hw)`; `target = position + direction`. É o único escritor da posição da câmera no caminho normal do frame.
- `key_handler` / `mouse_handler` / `close_handler` — ver tabela acima.

## `Camera` e `camera_*` (`camera.odin`)

Este módulo é dono do conceito de câmera: uma base ortonormal (position/direction/right/up) que o render usa para montar a view matrix. O jogador nunca a move diretamente — `player_sync_camera` (acima) posiciona ela a partir do corpo físico, e o mouse handler a gira via `camera_rotate`. O struct primeiro, depois as procedures que mantêm seus invariantes:

`Camera :: struct` — câmera look-at com base ortonormal derivada: `position`, `rotation` (graus; **x: pitch, y: yaw, z: roll**), `fov`, `target`, `direction`, `up`, `right`. Invariante: `direction`/`right`/`up` são sempre ortonormais e derivados de `rotation` (via `camera_rotate`) ou de um alvo (via `camera_look_at`); `target = position + direction` sempre que a posição muda.

- `camera_create(position, rotation, fov)` — o construtor; chamado uma única vez no `main`. Constrói e normaliza a base chamando `camera_rotate(&c, {0,0,0})`.
- `camera_view(c) -> mat4` — `mat4LookAt(position, target, up)`; a conversão para clip Vulkan (`GL_TO_VK_CLIP * projection`) é responsabilidade do chamador (`main`).
- `camera_move(c, forward_amount, right_amount)` — desloca na base `direction`/`right` e rederiva `target`. Não usado no caminho do jogador (o movimento é pelo corpo físico).
- `camera_look_at(c, target)` — aponta para um ponto fixo: rederiva `direction`, `right = normalize(cross(direction, up_world))`, `up = cross(right, direction)`. Não altera `rotation` (losango: `rotation` e a base podem divergir após este call — rotações subsequentes por `camera_rotate` usam `rotation`).
- `camera_rotate(c, delta)` — aplica delta em graus a `rotation`, **clamp de pitch em ±89°** (evita gimbal na vertical), e rederiva `direction` (fórmula yaw/pitch esférica), `target`, `right`, `up`. Roll (`rotation.z`) é armazenado mas não entra na fórmula de `direction`. Chamado pelo mouse handler e por `camera_create`.

## Utilitários (`utils.odin`)

O arquivo `utils.odin` tem uma única procedure — um guarda de falhas Vulkan para todo o package:

- `vk_check(result, location := #caller_location)` — `log.panicf` em qualquer `vk.Result != .SUCCESS`. Usado em todos os call sites Vulkan do package main (command pool, CB, submit). Contrato: falha Vulkan é fatal, com o caller location no log.

## Leitura sugerida

[[sistema-engine-fundacao]] (init, swapchain, sincronização) · [[sistema-edicao-eventos]] (bus, journal E1) · [[sistema-mirror-fisica]] (solver de corpos, mirror) · [[visao-geral]] (pipeline de um frame). Outros módulos de referência: [[ref-engine]], [[ref-voxel-engine-worker]], [[ref-voxel-render]], [[ref-physics-tracing]].
