---
id: SISTEMA-ENGINE-FUNDACAO
titulo: Engine e fundação Vulkan
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Sistema — Engine e fundação Vulkan

Você acabou de ler a [[visao-geral]]: sabe que a CPU orquestra, a GPU fabrica, e que três threads dividem o trabalho. Este documento mergulha no primeiro subsistema: a **fundação** — tudo que existe antes de existir mundo.

Comece pensando nela assim: a fundação não renderiza voxels, não gera chunks e não conhece gameplay. Ela existe para responder "com" — com que janela, com que dispositivo Vulkan, com que capacidades, com que forma de a CPU e a GPU conversarem sem pisar nos pés uns dos outros. Sobre esse chão se apoiam [[sistema-streaming-mundo]], [[sistema-renderizacao]], [[sistema-mirror-fisica]], [[sistema-edicao-eventos]] e [[sistema-suporte]].

## Por que existe

Toda decisão de desenho do motor (GPU-driven, duas timelines, compute assíncrono, mesh shader) pressupõe capacidades de GPU que não são garantidas por padrão. A fundação transforma essas suposições em **contratos verificados na inicialização**: um dispositivo que não suporta `VK_EXT_mesh_shader`, `timelineSemaphore` ou `scalarBlockLayout` é rejeitado com diagnóstico nominal — o motor nunca cai no meio do frame por capability ausente. É a implementação da [[VS-00-fundacao-vulkan|VS-00]] (Fundação Vulkan), primeira spec do projeto; a telemetria GPU construída sobre ela é a [[VS-05-telemetria-profiling|VS-05]].

## Os módulos

A fundação cabe em três arquivos, todos em `src/engine/`:

| Arquivo | O que você vai encontrar lá |
| --- | --- |
| `src/engine/engine.odin` | O singleton `app: VoxEngine` (estado global), o ciclo de vida (`CreateEngine`/`DestroyEngine`), a API de frame (`Update`, `AcquireNextImage`, `WaitTimelineSemaphore`, `Present`), e duas utilidades centrais: `vk_check` e `load_file` — ambas introduzidas mais abaixo |
| `src/engine/engine_vukan.odin` | Toda a conversa com Vulkan: instance, device, swapchain, depth, VMA, sync objects, frame data e os layouts de descriptors. O nome do arquivo tem o typo histórico "vukan", mantido para não quebrar referências |
| `src/engine/types.odin` | Structs de apoio: `QueueTuple`, `FrameResource`, `SwapChainFrameData`, `PresentationInfo`, `DepthBuffer` e a enum `QueueType`. Cada uma tem contrato detalhado em [[ref-engine]] |

## Inicialização

A porta de entrada é `CreateEngine` (`src/engine/engine.odin:60`). Antes de ver a sequência, saiba uma regra do comportamento dela: é linear e **sem recuperação parcial** — qualquer falha encerra o processo com diagnóstico, em vez de deixar um motor meio-construído rodando. A sequência:

1. **`init_glfw`** — GLFW inicializada sem API de cliente (`NO_API`) — Vulkan, e não a GLFW, fala com a placa —, a janela "Vox Engine" e um callback de framebuffer. Repare no desenho: o callback de resize não recria a swapchain na hora; ele apenas marca `swapchainNeedsRecreate = true`, e a recriação acontece no próximo `AcquireNextImage`. Iremos ver por quê na seção "Recreate da swapchain".
2. **`create_vulkan_instance`** (`engine_vukan.odin:33`) — carrega os ponteiros de função globais via `glfwGetInstanceProcAddress` e cria a instance Vulkan 1.4 com as extensões exigidas pela GLFW mais `VK_EXT_debug_utils`, que roteia o callback de debug ao logger (severidades WARNING/ERROR, tipos VALIDATION/PERFORMANCE). A validation layer `VK_LAYER_KHRONOS_validation` é **solicitada quando disponível** — se ausente, warning no log e continuação; quando ativa, inclui `SYNCHRONIZATION_VALIDATION` (`REQ-FND-PLAT-02`).
3. **`create_vulkan_surface`** — a surface de apresentação, criada pela GLFW em cima da janela.
4. **`create_vulkan_device`** (`engine_vukan.odin:243`) — a etapa mais importante. A `select_physical_device` enumera as extensões de cada dispositivo (`REQUIRED_DEVICE_EXTENSIONS`: swapchain, mesh shader, shader object, memory budget) e consulta a cadeia de features via `vkGetPhysicalDeviceFeatures2` (`DeviceFeatureChain`: `shaderInt16`, `shaderDrawParameters`, `storageBuffer16BitAccess`, `timelineSemaphore`, `scalarBlockLayout`, `dynamicRendering`, `synchronization2`, `shaderObject`, `meshShader`, `taskShader`). Cada dispositivo rejeitado é logado **com a lista nominal do que falta** — quando algo não roda, o log diz exatamente por quê. Se nenhum dispositivo serve, falha fatal. Depois vêm as **filas**, seguindo a `REQ-FND-DEV-04`: a engine prefere uma família de compute dedicada (para o compute assíncrono, visão de etapa da arquitetura); sem ela, compute compartilha a família gráfica — o fallback é registrado no log, e a timeline de compute continua funcional na mesma fila.
5. **`create_vma_allocator`** — cria o **VMA** (*Vulkan Memory Allocator*, a biblioteca que centraliza alocações de memória de vídeo) com a extensão `EXT_MEMORY_BUDGET` — prerrequisito da telemetria de VRAM ([[VS-05-telemetria-profiling|VS-05]], [[ADR-T1-telemetria-vulkan-vma|ADR-T1]]).
6. **`config_validate_machine`** — validação de coerência e de máquina do `vox.ini` antes de provisionar; é o assunto de [[sistema-suporte]].
7. **`create_swap_chain` / `create_depth_buffer`** — a swapchain em `B8G8R8A8_SRGB` (fallback: primeiro formato que a placa oferece), present mode `MAILBOX` (fallback `FIFO`) e 3 imagens — 2 frames em voo mais 1, limitado pelo `maxImageCount` do dispositivo. Para cada imagem, uma image view e um semáforo de present **dedicado** (guardados no struct `SwapChainFrameData` de `types.odin`). O depth é `D32_SFLOAT`, com alocação VMA dedicada. Tudo usa **dynamic rendering** — a engine não cria render passes.
8. **`create_sync_objects`** — aqui nascem as **duas timeline semaphores**: uma gráfica, com valor inicial `NUM_FRAMES_IN_FLIGHT` = 2, e uma de compute, com valor inicial 0, reservada à worker — que sinaliza 1 valor por lote de generate/pack (regra 3 do AGENTS.md, ver [[sistema-streaming-mundo]]). Uma timeline semaphore é um semáforo Vulkan cujo valor é um inteiro que só cresce: em vez de "sinalizado/não sinalizado", quem espera diz "quero o valor ≥ N". É a peça-chave da sincronização do motor — a seção "O frame" mostra por quê.
9. **`create_frame_data`** — para cada frame em voo: um command pool `TRANSIENT`, um command buffer primário e um semáforo binário de aquisição (empacotados no struct `FrameResource`).
10. **`create_descriptor_layouts`** — o contrato de bindings que todos os shaders assinam (seção própria mais abaixo).
11. **`telemetry_init`** — query pools e coletores da [[VS-05-telemetria-profiling|VS-05]].

O espelho de `CreateEngine` é `DestroyEngine` (`engine.odin:87`): ele abre com `vkDeviceWaitIdle` (a CPU para até a GPU esvaziar todas as filas) e destrói os recursos na **ordem inversa** da criação (`REQ-FND-SYNC-02`) — nenhum recurso morre enquanto a GPU pode usá-lo. Uma ressalva prática: no shutdown normal do jogo quem roda é o fast-exit (`os.exit` após flush do Tracy — você viu isso na [[visao-geral]]); o teardown completo só roda com `--full-teardown` (smokes/CI). Se você estiver adicionando recursos, é no teardown completo que eles precisam ser destruídos.

## O frame

Duas constantes governam o ritmo: `NUM_FRAMES_IN_FLIGHT = 2` (quantos frames a CPU pode preparar enquanto a GPU ainda trabalha no anterior) e `ACQUIRE_TIMEOUT_NS = 100 ms`. A main thread executa, por frame (`src/main.odin`), seis passos:

1. **`engine.Update`** — avança `frameIndex` no ring de 2 e **reserva** o próximo valor da timeline gráfica (`currentTimelineValue = nextTimelineValue++`). A reserva é monotônica: todo valor é reservado por exatamente um frame — nunca dois frames tentam "sinalizar" o mesmo número.
2. **`WaitTimelineSemaphore`** (`engine.odin:172`) — `vkWaitSemaphores` na timeline gráfica pelo valor `N - NUM_FRAMES_IN_FLIGHT`. Traduzindo: a CPU só reutiliza os recursos do slot de frame N quando a GPU confirmou, através da timeline, que o uso anterior daquele slot terminou. É também aqui que a telemetria e as zonas GPU da iteração passada são coletadas — leitura com disponibilidade, nunca bloqueante ([[VS-05-telemetria-profiling|VS-05]]).
3. **`AcquireNextImage`** (`engine.odin:114`) — pede à swapchain a próxima imagem, com timeout de 100 ms e o semáforo de aquisição do frame. `TIMEOUT`/`NOT_READY` não são erro: o frame é pulado (`CancelFrameReservation` desfaz a reserva de timeline — um invariável nascido de um deadlock corrigido na validação da VS-00). Já `OUT_OF_DATE`/`SUBOPTIMAL` significam que a janela mudou e marcam `swapchainNeedsRecreate`.
4. **Gravação** — `ResetCommandPool` e begin `ONE_TIME_SUBMIT`; reset das queries de telemetria; barreiras de layout (swapchain → `COLOR_ATTACHMENT_OPTIMAL`, depth → `DEPTH_ATTACHMENT_OPTIMAL`); `voxel_render_prepare` (edições do flush, builder da fila de trabalho, finalize — assunto de [[sistema-renderizacao]] e [[sistema-edicao-eventos]]); `CmdBeginRendering` → draw mesh indireto → `CmdEndRendering`; e a barreira final para `PRESENT_SRC_KHR`. Coordenadas de render e física/jogabilidade já rodaram antes, na fase de update, como viu na [[visao-geral]].
5. **Submit** (`main.odin:376`) — `vkQueueSubmit2` na fila gráfica com **dois waits** (o semáforo de aquisição da imagem; e a timeline de compute no valor do último publish — a renderização só lê chunks que o generate/pack da worker já concluiu) e **dois signals**: o semáforo de present da imagem adquirida e a timeline gráfica no valor reservado no passo 1.
6. **`Present`** (`engine.odin:146`) — `vkQueuePresentKHR` aguardando o semáforo de present; `OUT_OF_DATE`/`SUBOPTIMAL` marcam recriação para o próximo frame, nunca pânico.

### Por que timeline em vez de fences binários

Vale parar nesta escolha, porque ela aparece em todo o resto do motor. A timeline gráfica é a única guarda entre iterações do ring de frames: um único objeto cobre **todos** os recursos reutilizáveis do slot — command pool, query pools, os rings de 2 frames da renderização (invariância C2, explicada em [[sistema-renderizacao]]). Uma fence binária por recurso funcionaria, mas multiplicaria objetos e sincronizações; um inteiro monotônico cobre tudo de uma vez.

E a timeline de compute é a **ponte numérica** entre as duas threads: a worker sinaliza um valor por lote de generate/pack e a main espera exatamente esse valor no submit — nenhum lock entre as threads na hora de desenhar ([[sistema-streaming-mundo]], [[ADR-B1-ciclo-vida-slots|ADR-B1]]).

## Recreate da swapchain

Você viu mais acima que ninguém recria a swapchain no momento do resize. O único lugar que faz isso é `recreate_swapchain` (`engine.odin:222`), acionado por três caminhos (o callback de resize, `OUT_OF_DATE`/`SUBOPTIMAL` no acquire/present). O motivo da demora: recriar é cara e exige a GPU parada, então a engine agrupa e posterga.

O procedimento segue a `REQ-FND-FRM-03`. Se a janela está minimizada (extent 0×0), ele retorna falso e a aplicação pula frames — **nenhum recurso é criado com dimensão zero**. Com extent válida: `vkDeviceWaitIdle` (a GPU fica idle em relação aos frames em voo), destroi depth + swapchain (image views e semáforos de present incluídos) e recria ambos com a nova extent. Repare no que **não** está na lista: frame data, timelines e layouts sobrevivem ao resize — só o que tem dimensão da janela é recriado.

## Erros e arquivos

Duas utilidades em `engine.odin` sustentam a política de falha da fundação:

- **`vk_check`** (`engine.odin:237`) — todo `vk.Result` de init e de runtime crítico passa por ela: diferente de `SUCCESS` → `log.panicf` com o resultado, a expressão chamadora (`#caller_expression`) e o local (`#caller_location`). Os erros de acquire/present são a exceção deliberada: tratados como recriação de swapchain, nunca como pânico. Ao adicionar uma chamada Vulkan nova, pergunte: "se isso falhar, o motor ainda tem sentido?" Se não, embrulhe em `vk_check`.
- **`load_file`** (`engine.odin:244`) — leitura íntegra de arquivo ou `log.panicf` com o caminho. É quem carrega shaders SPIR-V, `blocks.json` e demais assets — a parte de assets é contada em [[sistema-suporte]].

## O contrato que serve a todos: bindings, push constants, layouts

O passo 10 da inicialização merece uma seção própria, porque é a interface da fundação com todo o resto do motor. `create_descriptor_layouts` (`engine_vukan.odin:488`) define o **set 0 único** assinado por todos os shaders (Slang `common.slang`, referência em [[ref-shaders]]):

- **`DESCRIPTOR_SET_BINDING_COUNT = 22`** bindings: 20 `STORAGE_BUFFER` visíveis a compute/mesh/fragment; os bindings 8 e 9 são `COMBINED_IMAGE_SAMPLER` (atlas de texturas, [[VS-21-texturas-nearest-flip-stb-faces|VS-21]]); e o binding 21 é `UNIFORM_BUFFER_DYNAMIC` visível só ao fragment (realce do voxel-alvo por frame, [[VS-20-gameplay-selecao-construcao-pulo|VS-20]], [[ADR-G2-gameplay-selecao-construcao-pulo|ADR-G2]]). O conjunto cresceu organicamente a cada spec — dicionário de blocos, templates, visible chunks, anéis de edição e mirror, flags de resultado, UVs — e o histórico de cada binding está na [[VS-00-fundacao-vulkan|VS-00]].
- **`PUSH_CONSTANTS_SIZE = 92`** bytes, empurrados a cada passagem (capacidades, câmera, parâmetros de frame). Push constant é o pequeno bloco de dados que acompanha cada submit de comando — rápido, mas com limite de tamanho, por isso só o essencial do frame.
- **Dois pipeline layouts** compartilham o set 0: um gráfico (push visível a mesh/fragment) e um de compute (push visível a compute). Os pipelines concretos pertencem às specs de renderização, mas assinam esses layouts.
- Antes de criar qualquer coisa, o init **valida os limites do dispositivo**: `maxDescriptorSetStorageBuffers ≥ 22` e `maxPushConstantsSize ≥ 92`, com falha nominal se não — o mesmo espírito da seleção por capability.

A consequência prática: nenhum subsistema negocia layout com Vulkan. O streaming aloca e publica buffers no set 0; a renderização e a worker apenas os referenciam pelos bindings. A fundação é a fonte única do contrato descriptor/push constant — mudou aqui, mudou para todo mundo.

## Coordenação com os demais subsistemas

Para fechar, o mapa do que cada vizinho consome da fundação:

| Subsistema | O que consome da fundação |
| --- | --- |
| [[sistema-streaming-mundo]] | Timeline de compute (1 lote = 1 valor), fila de compute dedicada, VMA para pools de chunks |
| [[sistema-renderizacao]] | Frame data (CB por frame em voo), swapchain/depth/dynamic rendering, pipeline layout gráfico, timeline gráfica como guarda dos rings de 2 frames |
| [[sistema-mirror-fisica]] | `storageBuffer16BitAccess`/`scalarBlockLayout` (exigidas na seleção por causa do ring do mirror), buffers no set 0 |
| [[sistema-edicao-eventos]] | Ring de edições publicado como storage buffer no set 0; janela GLFW como fonte de input |
| [[sistema-suporte]] | `vk_check`/`load_file`, VMA + `EXT_MEMORY_BUDGET` para telemetria, `config_validate_machine` no init, paths de debug versionados |

## Para ir mais fundo

- Spec de origem: [[VS-00-fundacao-vulkan|VS-00 — Fundação Vulkan]] (todos os requisitos `REQ-FND-*` vivem lá; a tabela de criar/destruir por par `create_*`/`destroy_*` também).
- Telemetria sobre a fundação: [[VS-05-telemetria-profiling|VS-05]] + [[ADR-T1-telemetria-vulkan-vma|ADR-T1]].
- Decisões que estenderam o contrato de bindings: [[ADR-V1-chunks-vazios-virtuais|ADR-V1]] (binding 18), [[ADR-U1-uvs-templates-malha|ADR-U1]] (binding 19), [[ADR-G1-heightmap-geracao-mirror|ADR-G1]] (binding 20, reserva futura), [[ADR-G2-gameplay-selecao-construcao-pulo|ADR-G2]] (binding 21).
- Próximo sistema na ordem de leitura: [[sistema-streaming-mundo]].
- Referência de structs e procedures, um por um: [[ref-engine]].
