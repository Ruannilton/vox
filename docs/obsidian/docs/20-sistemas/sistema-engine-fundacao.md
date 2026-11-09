---
id: SISTEMA-ENGINE-FUNDACAO
titulo: Engine e fundação Vulkan
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Sistema — Engine e fundação Vulkan

A fundação é tudo que existe antes de existir mundo: janela, instância/dispositivo Vulkan, swapchain, sincronização de frames e os layouts de descriptors que todo o resto do motor consome. Ela não renderiza voxels, não gera chunks e não conhece gameplay — fornece o chão sobre o qual [[sistema-streaming-mundo]], [[sistema-renderizacao]], [[sistema-mirror-fisica]], [[sistema-edicao-eventos]] e [[sistema-suporte]] se apoiam. Contexto macro: [[visao-geral]]. Detalhes de struct/procedure: [[ref-engine]].

## Por que existe

Toda decisão de desenho do motor (GPU-driven, duas timelines, compute assíncrono, mesh shader) pressupõe capacidades de GPU que não são garantidas por padrão. A fundação transforma essas suposições em **contratos verificados na inicialização**: um dispositivo que não suporta `VK_EXT_mesh_shader`, `timelineSemaphore` ou `scalarBlockLayout` é rejeitado com diagnóstico nominal — o motor nunca cai no meio do frame por capability ausente. É a implementação da [[VS-00-fundacao-vulkan|VS-00]] (Fundação Vulkan), primeira spec do projeto; a telemetria GPU construída sobre ela é a [[VS-05-telemetria-profiling|VS-05]].

## Os módulos

| Arquivo | Papel |
| --- | --- |
| `src/engine/engine.odin` | Singleton `app: VoxEngine` (estado global), ciclo de vida (create/destroy), API de frame (`Update`, `AcquireNextImage`, `WaitTimelineSemaphore`, `Present`), `vk_check`, `load_file` |
| `src/engine/engine_vukan.odin` | Toda a conversa com Vulkan: instance, device, swapchain, depth, VMA, sync objects, frame data, layouts (o nome do arquivo tem o typo histórico "vukan", mantido) |
| `src/engine/types.odin` | Structs de apoio (`QueueTuple`, `FrameResource`, `SwapChainFrameData`, `PresentationInfo`, `DepthBuffer`, enum `QueueType`) |

## Inicialização

`CreateEngine` (`src/engine/engine.odin:60`) é uma sequência linear sem recuperação parcial — qualquer falha encerra o processo com diagnóstico. Ordem:

1. **`init_glfw`** — GLFW sem API de cliente (`NO_API`), janela "Vox Engine" e callback de framebuffer: resize marca `swapchainNeedsRecreate = true` em vez de recriar na hora (a recriação acontece no próximo `AcquireNextImage`).
2. **`create_vulkan_instance`** (`engine_vukan.odin:33`) — carrega os ponteiros de função globais via `glfwGetInstanceProcAddress`; instance Vulkan 1.4 com as extensões do GLFW + `VK_EXT_debug_utils` (callback de debug roteado ao logger, severidades WARNING/ERROR, tipos VALIDATION/PERFORMANCE). A validation layer `VK_LAYER_KHRONOS_validation` é **solicitada quando disponível** — se ausente, warning no log e continuação; quando ativa, inclui `SYNCHRONIZATION_VALIDATION` (`REQ-FND-PLAT-02`).
3. **`create_vulkan_surface`** — surface pela GLFW.
4. **`create_vulkan_device`** (`engine_vukan.odin:243`) — seleção explícita por capability: `select_physical_device` enumera extensões (`REQUIRED_DEVICE_EXTENSIONS`: swapchain, mesh shader, shader object, memory budget) e consulta a cadeia de features via `vkGetPhysicalDeviceFeatures2` (`DeviceFeatureChain`: `shaderInt16`, `shaderDrawParameters`, `storageBuffer16BitAccess`, `timelineSemaphore`, `scalarBlockLayout`, `dynamicRendering`, `synchronization2`, `shaderObject`, `meshShader`, `taskShader`). Cada dispositivo rejeitado é logado com a lista nominal do que falta; nenhum servir → falha fatal. As **filas** seguem a `REQ-FND-DEV-04`: preferência por família de compute dedicada (compute assíncrono, visão de etapa da arquitetura); sem ela, compute compartilha a família gráfica — o fallback é registrado no log, e a timeline de compute continua funcional na mesma fila.
5. **`create_vma_allocator`** — allocator VMA com `EXT_MEMORY_BUDGET`, prerrequisito da telemetria de VRAM ([[VS-05-telemetria-profiling|VS-05]], [[ADR-T1-telemetria-vulkan-vma|ADR-T1]]).
6. **`config_validate_machine`** — validação de coerência e de máquina do `vox.ini` antes de provisionar (ver [[sistema-suporte]]).
7. **`create_swap_chain` / `create_depth_buffer`** — swapchain `B8G8R8A8_SRGB` (fallback: primeiro formato), present `MAILBOX` (fallback `FIFO`), 3 imagens (2 frames em voo + 1, limitado por `maxImageCount`); para cada imagem, image view + semáforo de present **dedicado** (`SwapChainFrameData`). Depth `D32_SFLOAT` com alocação VMA dedicada. Tudo com **dynamic rendering** — não existem render passes na engine.
8. **`create_sync_objects`** — as duas timelines: gráfica (valor inicial `NUM_FRAMES_IN_FLIGHT` = 2) e de compute (valor inicial 0, reservada à worker — 1 lote = 1 valor, regra 3 do AGENTS.md).
9. **`create_frame_data`** — para cada frame em voo: command pool `TRANSIENT` + command buffer primário + semáforo binário de aquisição (`FrameResource`).
10. **`create_descriptor_layouts`** — o contrato que todos os shaders assinam (seção abaixo).
11. **`telemetry_init`** — query pools e coletores da [[VS-05-telemetria-profiling|VS-05]].

`DestroyEngine` (`engine.odin:87`) abre com `vkDeviceWaitIdle` e destrói na **ordem inversa** da criação (`REQ-FND-SYNC-02`): nenhum recurso morre enquanto a GPU pode usá-lo. No shutdown normal do jogo vale o fast-exit (`os.exit` após flush do Tracy — ver [[visao-geral]]); o teardown completo só roda com `--full-teardown` (smokes/CI).

## O frame

Constantes: `NUM_FRAMES_IN_FLIGHT = 2`, `ACQUIRE_TIMEOUT_NS = 100 ms`. A main thread executa, por frame (`src/main.odin`):

1. **`engine.Update`** — avança `frameIndex` no ring de 2, computa `deltaTime` e **reserva** o próximo valor da timeline gráfica (`currentTimelineValue = nextTimelineValue++`). A reserva é monotônica: todo valor é reservado por exatamente um frame.
2. **`WaitTimelineSemaphore`** (`engine.odin:172`) — `vkWaitSemaphores` na timeline gráfica pelo valor `N - NUM_FRAMES_IN_FLIGHT`: a CPU só reutiliza os recursos do slot de frame N quando a GPU confirmou que o uso anterior terminou. É o ponto onde telemetria e zonas GPU da iteração passada são coletadas (leitura com disponibilidade, nunca bloqueante — [[VS-05-telemetria-profiling|VS-05]]).
3. **`AcquireNextImage`** (`engine.odin:114`) — acquire com timeout de 100 ms e o semáforo de aquisição do frame. `TIMEOUT`/`NOT_READY` → o frame é pulado (`CancelFrameReservation` desfaz a reserva de timeline — invariável depois de um deadlock corrigido na validação da VS-00); `OUT_OF_DATE`/`SUBOPTIMAL` → `swapchainNeedsRecreate`.
4. **Gravação** — `ResetCommandPool` + begin `ONE_TIME_SUBMIT`; reset das queries de telemetria; barreiras de layout (swapchain → `COLOR_ATTACHMENT_OPTIMAL`, depth → `DEPTH_ATTACHMENT_OPTIMAL`); `voxel_render_prepare` (edições do flush, builder da fila de trabalho, finalize — ver [[sistema-renderizacao]] e [[sistema-edicao-eventos]]); `CmdBeginRendering` → draw mesh indireto → `CmdEndRendering`; barreira para `PRESENT_SRC_KHR`. Coordenadas de render e física/jogabilidade já rodaram antes, na fase de update ([[visao-geral]]).
5. **Submit** (`main.odin:376`) — `vkQueueSubmit2` na fila gráfica com **dois waits** (semáforo de aquisição; timeline de compute no valor do último publish — a renderização só lê chunks que o generate/pack da worker já concluiu) e **dois signals**: o semáforo de present da imagem adquirida e a timeline gráfica no valor reservado no passo 1.
6. **`Present`** (`engine.odin:146`) — `vkQueuePresentKHR` aguardando o semáforo de present; `OUT_OF_DATE`/`SUBOPTIMAL` marcam recriação para o próximo frame, nunca pânico.

### Por que timeline em vez de fences binários

A timeline gráfica é a única guarda entre iterações do ring de frames: um único objeto cobre todos os recursos reutilizáveis do slot (command pool, query pools, rings de 2 frames — ver a invariância C2 em [[sistema-renderizacao]]). E a timeline de compute é a **ponte numérica** entre as threads: a worker sinaliza um valor por lote de generate/pack e a main espera exatamente esse valor no submit, sem nenhum lock entre as duas threads na hora de desenhar ([[sistema-streaming-mundo]], [[ADR-B1-ciclo-vida-slots|ADR-B1]]).

## Recreate da swapchain

`recreate_swapchain` (`engine.odin:222`) é acionada por três caminhos (callback de resize, `OUT_OF_DATE`/`SUBOPTIMAL` no acquire/present) e segue a `REQ-FND-FRM-03`: se a janela está minimizada (extent 0×0), retorna falso e a aplicação pula frames — **nenhum recurso é criado com dimensão zero**. Com extent válida: `vkDeviceWaitIdle` (a GPU fica idle em relação aos frames em voo), destroi depth + swapchain (image views e semáforos de present incluídos) e recria ambos com a nova extent. Frame data, timelines e layouts **não** são recriados — sobrevivem ao resize.

## Erros e arquivos

- **`vk_check`** (`engine.odin:237`) — todo `vk.Result` de init e de runtime crítico passa por ele: diferente de `SUCCESS` → `log.panicf` com o resultado, a expressão chamadora (`#caller_expression`) e o local (`#caller_location`). Erros de acquire/present são a exceção deliberada: tratados como recriação de swapchain, nunca como pânico.
- **`load_file`** (`engine.odin:244`) — leitura íntegra de arquivo ou `log.panicf` com o caminho; usado para shaders SPIR-V, `blocks.json` e demais assets (ver [[sistema-suporte]]).

## O contrato que serve a todos: bindings, push constants, layouts

`create_descriptor_layouts` (`engine_vukan.odin:488`) define o **set 0 único** assinado por todos os shaders (Slang `common.slang`, ver [[ref-shaders]]):

- **`DESCRIPTOR_SET_BINDING_COUNT = 22`** bindings: 20 `STORAGE_BUFFER` visíveis a compute/mesh/fragment + bindings 8 e 9 `COMBINED_IMAGE_SAMPLER` (atlas de texturas, [[VS-21-texturas-nearest-flip-stb-faces|VS-21]]) + binding 21 `UNIFORM_BUFFER_DYNAMIC` visível só ao fragment (realce do voxel-alvo por frame, [[VS-20-gameplay-selecao-construcao-pulo|VS-20]], [[ADR-G2-gameplay-selecao-construcao-pulo|ADR-G2]]). O conjunto cresceu organicamente a cada spec (dicionário de blocos, templates, visible chunks, anéis de edição e mirror, flags de resultado, UVs — ver o histórico da [[VS-00-fundacao-vulkan|VS-00]]).
- **`PUSH_CONSTANTS_SIZE = 92`** bytes, empurrados a cada passagem (capacidades, câmera, parâmetros de frame).
- **Dois pipeline layouts** compartilhando o set 0: gráfico (push visível a mesh/fragment) e compute (push visível a compute) — os pipelines concretos pertencem às specs de renderização, mas assinam esses layouts.
- Antes de criar, o init **valida os limites do dispositivo**: `maxDescriptorSetStorageBuffers ≥ 22` e `maxPushConstantsSize ≥ 92`, com falha nominal se não.

Consequência: nenhum subsistema negocia layout com Vulkan. Streaming aloca e publica buffers no set 0; renderização e worker apenas os referenciam pelos bindings — a fundação é a fonte única do contrato descriptor/push constant.

## Coordenação com os demais subsistemas

| Subsistema | O que consome da fundação |
| --- | --- |
| [[sistema-streaming-mundo]] | Timeline de compute (1 lote = 1 valor), fila de compute dedicada, VMA para pools de chunks |
| [[sistema-renderizacao]] | Frame data (CB por frame em voo), swapchain/depth/dynamic rendering, pipeline layout gráfico, timeline gráfica como guarda dos rings de 2 frames |
| [[sistema-mirror-fisica]] | `storageBuffer16BitAccess`/`scalarBlockLayout` (exigidas na seleção por causa do ring do mirror), buffers no set 0 |
| [[sistema-edicao-eventos]] | Ring de edições publicado como storage buffer no set 0; janela GLFW como fonte de input |
| [[sistema-suporte]] | `vk_check`/`load_file`, VMA + `EXT_MEMORY_BUDGET` para telemetria, `config_validate_machine` no init, paths de debug versionados |

## Rastreabilidade

- Spec: [[VS-00-fundacao-vulkan|VS-00 — Fundação Vulkan]] (todos os requisitos `REQ-FND-*` vivem lá; a tabela de criar/destruir por par `create_*`/`destroy_*` também).
- Telemetria sobre a fundação: [[VS-05-telemetria-profiling|VS-05]] + [[ADR-T1-telemetria-vulkan-vma|ADR-T1]].
- Decisões que estenderam o contrato de bindings: [[ADR-V1-chunks-vazios-virtuais|ADR-V1]] (binding 18), [[ADR-U1-uvs-templates-malha|ADR-U1]] (binding 19), [[ADR-G1-heightmap-geracao-mirror|ADR-G1]] (binding 20, reserva futura), [[ADR-G2-gameplay-selecao-construcao-pulo|ADR-G2]] (binding 21).
- Próximo sistema: [[sistema-streaming-mundo]]. Referência de structs/procedures: [[ref-engine]].
