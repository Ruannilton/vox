---
id: REF-ENGINE
titulo: "Referência — engine, engine_vulkan"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência — engine, engine_vulkan, types

Você chegou aqui pela [[sistema-engine-fundacao]], que contou a história da fundação: por que ela existe, como o frame flui, como a swapchain é recriada. Este documento é o passeio **struct por struct, procedure por procedure** dos três arquivos dessa fundação — um catálogo de consulta, no ritmo do trabalho. Leia as entradas na ordem em que aparecem; cada uma abre dizendo quem a chama, quando e por que.

Duas convenções valem para tudo o que segue:

- **Erros fatais**: `log.panic`/`log.panicf` (via `vk_check` ou explícito) — encerram o processo com diagnóstico. A inicialização inteira é fatal: não existe recuperação parcial de `CreateEngine`.
- **Recuperáveis**: retornos `ok: bool`/`false` — frame pulado ou recriação de swapchain adiada; nunca pânico.
- **Sincronização**: toda criação/destruição respeita a ordem de `CreateEngine`/`DestroyEngine` (contrato `REQ-FND-SYNC-02`); destruição abre com `vkDeviceWaitIdle`.
- Tipos `vk.*`/`vma.*`/`glfw.*` são bindings Odin padrão (vendor), não documentados aqui. Termos Vulkan genéricos que não foram definidos nos documentos anteriores (image view — a "janela" por meio da qual um shader lê uma imagem; semáforo binário — o objeto síncrono de dois estados usado para ordenar operações entre filas; command pool — o alocador de command buffers) ganham uma mini-definição na primeira menção; os conceitos internos do motor (timeline semaphore, VMA, push constant, ring de frames) já foram apresentados em [[visao-geral]] e [[sistema-engine-fundacao]], então aqui basta linkar.

Arquivos:

| Arquivo | Conteúdo |
| --- | --- |
| `src/engine/engine.odin` | Constantes, `VoxEngine`, singleton `app`, ciclo de vida, API de frame, `vk_check`, `load_file` |
| `src/engine/engine_vukan.odin` | Constantes de contrato, `DeviceFeatureChain`, todas as `create_vulkan_*` e auxiliares privadas |
| `src/engine/types.odin` | Structs de apoio (`QueueTuple`, `FrameResource`, `SwapChainFrameData`, `PresentationInfo`, `DepthBuffer`, enum `QueueType`) |

> O nome do arquivo `engine_vukan.odin` carrega um typo histórico ("vukan"), mantido de propósito — mencioná-lo evita confusão ao procurar o arquivo.

## Constantes

Estas constantes são as regras do jogo que todo o resto da engine assume. Foram apresentadas ao longo de [[sistema-engine-fundacao]]; aqui estão com seus valores exatos.

| Constante | Valor | Papel |
| --- | --- | --- |
| `NUM_FRAMES_IN_FLIGHT` | 2 | Tamanho do ring de frames (a fila circular de slots de recursos reutilizáveis, guardada pela timeline gráfica — ver [[sistema-engine-fundacao]]). Guarda a reutilização de `FrameResource` via timeline e limita a distância do wait (`N - NUM_FRAMES_IN_FLIGHT`). |
| `NUM_SWAP_CHAIN_IMAGES` | 3 (`NUM_FRAMES_IN_FLIGHT + 1`) | Quantidade de imagens da swapchain (a estrutura de "próxima imagem a exibir" do Vulkan — um a mais que frames em voo), limitado por `maxImageCount` do surface. |
| `ACQUIRE_TIMEOUT_NS` | 100 ms | Timeout de `vkAcquireNextImageKHR`. `TIMEOUT`/`NOT_READY` → frame pulado (recuperável). |
| `DESCRIPTOR_SET_BINDING_COUNT` | 22 | Número de bindings do set 0 (fonte única: `src/assets/shaders/common.slang`). Cresceu por spec: VS-11 (binding 19), VS-13 (binding 20), VS-20 (binding 21). |
| `PUSH_CONSTANTS_SIZE` | 92 | Bytes de push constants por passagem de pipeline (o pequeno bloco de dados por submit, definido em [[sistema-engine-fundacao]]). |
| `REQUIRED_DEVICE_EXTENSIONS` | swapchain, mesh shader, shader object, memory budget | Extensões **obrigatórias** na seleção de dispositivo (`REQ-FND-DEV-04`); ausência de qualquer uma rejeita o candidato. |

## Enum e structs — `types.odin`

Os cinco structs deste arquivo são os "invólucros" de pequenos conjuntos de recursos Vulkan. Nenhum deles tem comportamento próprio — são contratos de posse: quem criou, quem destrói, e o que sobrevive a um resize.

### `QueueType` (`types.odin:6`)

```odin
QueueType :: enum { Graphics, Compute, Transfer }
```

O índice do array `app.queues`. `Transfer` existe no enum mas nenhuma fila é provisionada para ele — só `Graphics` e `Compute` são criadas (`create_vulkan_device`).

### `QueueTuple` (`types.odin:12`)

```odin
QueueTuple :: struct {
    queue:       vk.Queue,
    familyIndex: u32,
}
```

Uma fila Vulkan mais o índice da família a que ela pertence. É preenchido em duas etapas porque a informação chega em duas etapas: `select_physical_device` já sabe a família e grava `familyIndex`; `create_vulkan_device` só depois pode resolver o handle e grava `queue` via `vkGetDeviceQueue`. Contrato: se compute não tem família dedicada, `queues[.Compute].familyIndex == queues[.Graphics].familyIndex` (o fallback logado como warning que você viu em [[sistema-engine-fundacao]]).

### `FrameResource` (`types.odin:17`)

```odin
FrameResource :: struct {
    vkCommandPool:      vk.CommandPool,
    vkCommandBuffer:    vk.CommandBuffer,
    vkAcquireSemaphore: vk.Semaphore,
}
```

O kit de recursos **por frame em voo** — um slot do ring de `NUM_FRAMES_IN_FLIGHT` frames. Criado por `create_frame_data`, ele embala os três objetos que a main thread usa para gravar cada frame: um command pool (o alocador de command buffers daquele slot), o command buffer primário gravado por frame, e um semáforo binário dedicado que ordena "imagem adquirida" → "comandos de render". O reuso do kit é guardado exclusivamente pela timeline gráfica — `WaitTimelineSemaphore` garante que a GPU terminou o uso anterior antes do reset do command pool. O semáforo de aquisição é binário e dedicado: um por slot, nunca reutilizado entre slots no mesmo acquire.

### `SwapChainFrameData` (`types.odin:23`)

```odin
SwapChainFrameData :: struct {
    vkPresentSemaphore: vk.Semaphore,
    image:              vk.Image,
    image_view:         vk.ImageView,
}
```

O espelho de `FrameResource`, mas **por imagem da swapchain** (3 imagens, criadas por `setup_swap_chain_frames`). A imagem pertence à swapchain (não é destruída pela engine); a image view (a janela de leitura/escrita da imagem, no aspecto color) e o semáforo de present **dedicado** por imagem são destruídos em `destroy_swap_chain`. A morte é junto com a swapchain: `recreate_swapchain` destrói tudo e recria — estes dados não sobrevivem a resize.

### `PresentationInfo` (`types.odin:29`)

```odin
PresentationInfo :: struct {
    vkSwapChain:         vk.SwapchainKHR,
    swapChainImageCount: u32,
    width, height:       u32,
    frames:              []SwapChainFrameData,
    format:              vk.Format,
    imageIndex:          u32,
}
```

Tudo que descreve a apresentação em um só lugar — é o campo `presentation` dentro de `VoxEngine`. `imageIndex` é o índice da imagem adquirida pela última `AcquireNextImage` bem-sucedida — **válido só até o próximo acquire** e consumido por `Present`. `frames` é alocado com o allocator padrão e liberado em `destroy_swap_chain` (`delete`). Sobrevive ao recreate: o struct inteiro é reescrito por `create_swap_chain`, mas o objeto em si não é destruído.

### `DepthBuffer` (`types.odin:38`)

```odin
DepthBuffer :: struct {
    vkImage:       vk.Image,
    vkImageView:   vk.ImageView,
    vmaAllocation: vma.Allocation,
    format:        vk.Format,
}
```

O depth buffer — a imagem auxiliar de profundidade que o passo de fragment usa para decidir quais pixels ficam na frente. É `D32_SFLOAT` da resolução atual, alocado via VMA (o Vulkan Memory Allocator, a biblioteca de alocação de memória de vídeo apresentada em [[sistema-engine-fundacao]]) com `DEDICATED_MEMORY`. Não sobrevive ao recreate: `recreate_swapchain` destrói e recria com a nova extent, por ter dimensão de janela.

## Struct global — `engine.odin`

### `VoxEngine` (`engine.odin:16`)

```odin
VoxEngine :: struct {
    runtimeContext: runtime.Context,

    glfwWindow:                glfw.WindowHandle,
    windowWidth, windowHeight: u32,

    vkInstance:               vk.Instance,
    vkDebugMessenger:         vk.DebugUtilsMessengerEXT,
    vkSurface:                vk.SurfaceKHR,
    vkPhysicalDevice:         vk.PhysicalDevice,
    vkDevice:                 vk.Device,
    queues:                   [QueueType]QueueTuple,
    presentation:             PresentationInfo,
    vmaAllocator:             vma.Allocator,
    depthBuffer:              DepthBuffer,
    frameData:                [NUM_FRAMES_IN_FLIGHT]FrameResource,

    timelineSemaphore:        vk.Semaphore,
    computeTimelineSemaphore: vk.Semaphore,
    currentTimelineValue:     u64,
    nextTimelineValue:        u64,

    descriptorSetLayout:      vk.DescriptorSetLayout,
    graphicsPipelineLayout:   vk.PipelineLayout,
    computePipelineLayout:    vk.PipelineLayout,

    validationLayersEnabled:  bool,
    swapchainNeedsRecreate:   bool,

    deltaTime:                f64,
    lastFrameTime:            f64,
    currentTime:              f64,
    tick:                     u64,
    frameIndex:               u32,
}
```

O **estado global da engine** — o único struct que praticamente todo módulo toca. Existe exatamente uma instância: a variável de pacote `app: VoxEngine` (`engine.odin:58`), acessada por todos os módulos sem passagem de parâmetro (é o que permite um `vk_check` em qualquer arquivo, por exemplo). Os campos, por bloco:

- **`runtimeContext`**: o `context` do chamador de `CreateEngine`, guardado para restaurar o contexto de Odin dentro dos callbacks C do GLFW e do debug messenger (sem isso o `log` do callback quebra).
- **glfw**: janela e dimensões. `windowWidth/Height` são atualizadas pelo callback de framebuffer **e** por `create_swap_chain` (source of truth no momento do create).
- **vulkan**: handles da cadeia instance→device, `queues` indexado por `QueueType`, e os agregados `PresentationInfo`, `DepthBuffer`, `frameData` — os structs de `types.odin` que você acabou de ver.
- **sync**: as duas timelines. `timelineSemaphore` é a guarda do ring de frames (sinalizada pelo submit do frame, esperada por `WaitTimelineSemaphore`). `computeTimelineSemaphore` pertence à worker (1 lote = 1 valor, regra 3). `currentTimelineValue`/`nextTimelineValue` implementam a reserva monotônica: `Update` reserva um valor por frame e `CancelFrameReservation` desfaz.
- **descriptors**: o set 0 único e os dois pipeline layouts (o contrato que todos os shaders assinam, detalhado em [[sistema-engine-fundacao]]).
- **estado**: `validationLayersEnabled` (se a layer Khronos foi de fato ativada), `swapchainNeedsRecreate` (set por resize/out-of-date, consumido por `AcquireNextImage`).
- **time**: `deltaTime`/`tick`/`frameIndex` etc., mantidos por `Update`. Nota: `Update` escreve `lastFrameTime = app.currentTime` (não o tempo atual) — `deltaTime` cobre o intervalo entre o início do frame anterior e agora.

## Ciclo de vida — `engine.odin`

### `CreateEngine` (`engine.odin:60`)

```odin
CreateEngine :: proc(width: u32 = 800, height: u32 = 600)
```

A porta de entrada da engine, chamada uma única vez por `main` antes de qualquer frame. Inicializa `app` e executa a sequência linear `init_glfw → create_vulkan_instance → create_vulkan_surface → create_vulkan_device → create_vma_allocator → config_validate_machine → create_swap_chain → create_depth_buffer → create_sync_objects → create_frame_data → create_descriptor_layouts → telemetry_init`. Contratos:

- **Fatal em qualquer falha** — sem recuperação parcial; `vk_check`/`log.panic` encerram o processo.
- `nextTimelineValue` inicia em `NUM_FRAMES_IN_FLIGHT + 1` (3), combinando com o valor inicial `NUM_FRAMES_IN_FLIGHT` (2) da timeline gráfica.
- `config_validate_machine` (módulo `config.odin`, ver [[ref-assets-config-events]]) roda **antes** de provisionar qualquer recurso dimensionado por config.

### `DestroyEngine` (`engine.odin:87`)

```odin
DestroyEngine :: proc()
```

O espelho de `CreateEngine`. Abre com `vkDeviceWaitIdle` (a GPU não pode estar usando nada) e destrói na **ordem inversa** da criação: layouts → frame data → sync objects → depth → swapchain → VMA → device → surface → instance → janela → `glfw.Terminate`. No jogo normal este caminho não roda (fast-exit com `os.exit` após flush do Tracy — ver [[visao-geral]]); é o teardown completo de `--full-teardown` (smokes/CI).

### `Update` (`engine.odin:103`)

```odin
Update :: proc()
```

Chamada pela main thread no início de cada frame (o passo 1 do pipeline de frame de [[sistema-engine-fundacao]]). Avança o estado por-frame: computa `deltaTime`, incrementa `tick`, avança `frameIndex` no ring de 2 e **reserva** o valor da timeline (`currentTimelineValue = nextTimelineValue++`). A reserva é monotônica — todo valor é reservado por exatamente um frame; a de-reserva só ocorre via `CancelFrameReservation` (ver [[sistema-engine-fundacao]] — invariável pós-deadlock da VS-00).

## API de frame — `engine.odin`

Quatro procedures que a main thread invoca, nesta ordem, a cada frame — você já viu o papel de cada uma no roteiro do frame; aqui estão os contratos exatos.

### `WaitTimelineSemaphore` (`engine.odin:172`)

```odin
WaitTimelineSemaphore :: proc() -> u64
```

A guarda do ring, chamada logo após `Update`. Faz `vkWaitSemaphores` bloqueante (`timeout = max(u64)`) na timeline gráfica pelo valor `currentTimelineValue - NUM_FRAMES_IN_FLIGHT` — só retorna quando a GPU confirmou o frame de 2 iterações atrás. Retorna o valor reservado (`signal_value`) para quem chamou sinalizá-lo no submit. **Fatal** se o wait falhar (`vk_check`) — não há recuperação de sincronização quebrada.

### `AcquireFrameResource` (`engine.odin:142`)

```odin
AcquireFrameResource :: proc() -> ^FrameResource
```

Retorna `&app.frameData[app.frameIndex]` — o kit do slot atual do ring. Puro acesso ao ring: não sincroniza nada; a garantia de reuso vem de `WaitTimelineSemaphore`, que a main chama antes.

### `CancelFrameReservation` (`engine.odin:166`)

```odin
CancelFrameReservation :: proc()
```

Desfaz a reserva do frame corrente: recua `frameIndex` e decrementa `currentTimelineValue`/`nextTimelineValue`. Quem chama é `AcquireNextImage` (via main) quando o frame é pulado (acquire com `TIMEOUT`/`NOT_READY`), para que o valor de timeline não fique "furado" — cada valor reservado é ou consumido por um submit ou cancelado.

### `AcquireNextImage` (`engine.odin:114`)

```odin
AcquireNextImage :: proc() -> (frame: SwapChainFrameData, ok: bool)
```

O ponto onde a swapchain é consultada — e, se necessário, recriada. Primeiro acorda a recriação se `swapchainNeedsRecreate` estiver marcado (`recreate_swapchain` falha com janela 0×0 → `ok = false`, frame pulado). Depois `vkAcquireNextImageKHR` com timeout de 100 ms e o semáforo de aquisição do frame. Tratamento:

- `TIMEOUT` / `NOT_READY` → `ok = false` (recuperável; chamador deve `CancelFrameReservation`).
- `OUT_OF_DATE` / `SUBOPTIMAL` → marca `swapchainNeedsRecreate`, `ok = false`.
- Qualquer outro erro → `vk_check` (fatal).
- Sucesso → grava `presentation.imageIndex` e retorna o `SwapChainFrameData` da imagem.

### `Present` (`engine.odin:146`)

```odin
Present :: proc() -> ()
```

O fechamento do frame. `vkQueuePresentKHR` na fila gráfica, aguardando o semáforo de present da imagem adquirida. `OUT_OF_DATE`/`SUBOPTIMAL` → marca `swapchainNeedsRecreate` (recuperável, nunca pânico); demais erros → `vk_check` (fatal). Pré-condição: `AcquireNextImage` bem-sucedida no mesmo frame (`imageIndex` válido).

## Utilitários — `engine.odin`

### `vk_check` (`engine.odin:237`, privada ao arquivo)

```odin
vk_check :: proc(result: vk.Result, exp := #caller_expression, location := #caller_location)
```

O filtro único de erros Vulkan — toda a init e o runtime crítico passam por aqui. `result != .SUCCESS` → `log.panicf` com o resultado, a expressão do chamador (`#caller_expression`) e o local (`#caller_location`). **Exceção deliberada**: acquire/present tratam `OUT_OF_DATE`/`SUBOPTIMAL`/`TIMEOUT`/`NOT_READY` antes de chegar a `vk_check` — ver [[sistema-engine-fundacao]].

### `load_file` (`engine.odin:244`, privada ao arquivo)

```odin
load_file :: proc(path: string, allocator: runtime.Allocator, location := #caller_location) -> []byte
```

Leitura íntegra do arquivo ou `log.panicf` com o caminho — usada para SPIR-V, `blocks.json` e assets (ver [[sistema-suporte]]). Quem chama é dono da liberação da fatia retornada.

### `init_glfw` (`engine.odin:187`, privada ao arquivo)

```odin
init_glfw :: proc()
```

O primeiro passo de `CreateEngine`. GLFW sem API de cliente (`NO_API` — Vulkan criará a surface). Registra dois callbacks que restauram `app.runtimeContext` antes de logar:

- **Error callback**: erros do GLFW → `log.errorf`.
- **Framebuffer size callback**: grava as novas dimensões e marca `swapchainNeedsRecreate = true` — a recriação é **adiada** para o próximo `AcquireNextImage`, nunca executada dentro do callback.

Falhas de `glfw.Init`/`CreateWindow` são fatais (`log.panic`).

### `recreate_swapchain` (`engine.odin:222`, privada ao arquivo)

```odin
recreate_swapchain :: proc() -> bool
```

Recuperável por construção, e acionada apenas por `AcquireNextImage`. Janela 0×0 (minimizada) → `false`, nada é criado (`REQ-FND-FRM-03`). Com extent válida: limpa a flag, `vkDeviceWaitIdle`, destrói depth + swapchain e recria ambos com a nova extent. Frame data, timelines, VMA e layouts **sobrevivem** ao resize — só o que tem dimensão de janela é recriado.

## Inicialização Vulkan — `engine_vukan.odin`

Cada `create_vulkan_*` desta seção é um passo da sequência de `CreateEngine` — e cada `destroy_*` correspondente é o passo espelhado de `DestroyEngine`. O passo a passo conceitual está em [[sistema-engine-fundacao]]; aqui valem os detalhes de implementação.

### `DeviceFeatureChain` (`engine_vukan.odin:22`)

```odin
DeviceFeatureChain :: struct {
    base:          vk.PhysicalDeviceFeatures,
    v11:           vk.PhysicalDeviceVulkan11Features,
    v12:           vk.PhysicalDeviceVulkan12Features,
    v13:           vk.PhysicalDeviceVulkan13Features,
    v14:           vk.PhysicalDeviceVulkan14Features,
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT,
    mesh_shader:   vk.PhysicalDeviceMeshShaderFeaturesEXT,
}
```

O pacote que a seleção de dispositivo consulta e requisita. Uma "cadeia pNext" é a lista encadeada de structs que o Vulkan permite anexar a uma chamada — aqui, as features suportadas/requeridas de Vulkan 1.0 a 1.4 mais as duas extensões. Serve duplo papel:

- **Consulta** (`query_device_features`): monta a cadeia, chama `vkGetPhysicalDeviceFeatures2` e devolve o que o dispositivo suporta; `collect_missing_features` compara contra a lista obrigatória e `select_physical_device` rejeita quem falta algo.
- **Requisição** (`init_device_feature_chain` + `create_vulkan_device`): a mesma cadeia com as features obrigatórias ligadas é passada em `pNext` do `DeviceCreateInfo`.

Features obrigatórias (ver [[sistema-engine-fundacao]]): `shaderInt16`, `shaderDrawParameters`, `storageBuffer16BitAccess`, `uniformAndStorageBuffer16BitAccess` (ring do mirror, [[sistema-mirror-fisica]]), `timelineSemaphore`, `scalarBlockLayout`, `dynamicRendering`, `synchronization2`, `shaderObject`, `meshShader`, `taskShader`.

### `create_vulkan_instance` (`engine_vukan.odin:33`)

```odin
@(private) create_vulkan_instance :: proc()
```

O passo 2 da init. Em ordem:

1. Carrega os ponteiros globais via `glfwGetInstanceProcAddress`; `vk.CreateInstance == nil` → `log.assert` (fatal).
2. Enumera layers; ativa `VK_LAYER_KHRONOS_validation` **somente se disponível** (ausente → warning e continua; `validationLayersEnabled` reflete o resultado).
3. Extensões: as exigidas pelo GLFW + `VK_EXT_debug_utils` (+ `VK_EXT_validation_features` quando a layer está ativa).
4. Debug messenger (severidade WARNING/ERROR, tipos VALIDATION/PERFORMANCE) com callback roteando para o `log` (restaura `runtimeContext`); quando a validation está ativa, liga `SYNCHRONIZATION_VALIDATION` (`REQ-FND-PLAT-02`).
5. Cria a instance (apiVersion 1.4), carrega os ponteiros de instância e cria o messenger. Falhas → `vk_check` (fatal).

### `destroy_vulkan_instance` (`engine_vukan.odin:129`)

Destrói o debug messenger antes da instance. Contrato: surface e device já devem estar destruídos (`DestroyEngine` garante pela ordem).

### `create_vulkan_surface` (`engine_vukan.odin:137`) / `destroy_vulkan_surface` (`:144`)

Surface via `glfw.CreateWindowSurface` (fatal em falha) / `vkDestroySurfaceKHR`. A surface é o vínculo janela↔Vulkan usado por toda consulta de capability da swapchain.

### `init_device_feature_chain` (`:151`), `collect_missing_features` (`:191`), `query_device_features` (`:206`), `collect_missing_extensions` (`:224`)

Auxiliares privados da seleção de dispositivo (ver `DeviceFeatureChain` acima e [[sistema-engine-fundacao]]). `collect_missing_extensions` confere `REQUIRED_DEVICE_EXTENSIONS`; cada candidato rejeitado é logado nominalmente.

### `create_vulkan_device` (`engine_vukan.odin:243`)

```odin
@(private) create_vulkan_device :: proc()
```

O passo mais importante da init — o que decide se há uma GPU que serve. Em ordem:

1. `select_physical_device` → `false` (nenhum candidato serve) → `log.panic` fatal com diagnóstico acumulado.
2. Cria 1–2 filas: gráfica sempre; de compute só se em família diferente (evita criar fila duplicada na mesma família).
3. Habilita as extensões de device (swapchain, shader object, sync2, mesh shader + deps de SPIR-V) e a cadeia de features completa.
4. Cria o device, carrega os ponteiros de device e resolve os handles das filas em `app.queues`.

### `destroy_vulkan_device` (`:311`)

`vkDestroyDevice`. Pré-condição: tudo alocado no device (swapchain, pipelines, semáforos, VMA) já destruído — garantido pela ordem de `DestroyEngine`.

### `create_swap_chain` (`:318`) / `destroy_swap_chain` (`:362`)

- **Create**: lê o framebuffer atual (atualiza `windowWidth/Height`), escolhe formato (`B8G8R8A8_SRGB`/`.SRGB_NONLINEAR`, fallback `formats[0]`), present mode (`MAILBOX`, fallback `FIFO`) e contagem de imagens (`max(3, minImageCount)`, teto `NUM_SWAP_CHAIN_IMAGES` e `maxImageCount`). Reescreve `app.presentation` (formato/extent), cria a swapchain e chama `setup_swap_chain_frames`. Uso de imagem: só `COLOR_ATTACHMENT`.
- **Destroy**: para cada frame da swapchain destrói image view + semáforo de present, depois a swapchain, e `delete(app.presentation.frames)`. Simétrico ao create: tudo que `setup_swap_chain_frames` alocou é liberado.

### `create_vma_allocator` (`:374`) / `destroy_vma_allocator` (`:390`)

Cria o allocator VMA com flag `EXT_MEMORY_BUDGET` — prerrequisito da telemetria de VRAM ([[VS-05-telemetria-profiling|VS-05]], [[ADR-T1-telemetria-vulkan-vma|ADR-T1]]). Todas as alocações de imagem/buffer do motor passam por ele (ex.: depth buffer aqui, pools de chunks no streaming).

### `create_depth_buffer` (`:397`) / `destroy_depth_buffer` (`:452`)

Imagem `D32_SFLOAT` do tamanho da apresentação, tiling ótimo, uso `DEPTH_STENCIL_ATTACHMENT`, alocação VMA `AUTO` + `DEDICATED_MEMORY`, e sua image view (aspect `DEPTH`). Recriado a cada resize (não sobrevive a `recreate_swapchain`).

### `create_sync_objects` (`:460`) / `destroy_sync_objects` (`:480`)

Cria as duas timelines via helper local `create_timeline`: gráfica com valor inicial `NUM_FRAMES_IN_FLIGHT` (2), de compute com 0. Contratos: a gráfica é a única guarda do ring de frames; a de compute é a ponte numérica main↔worker (1 lote = 1 valor, regra 3; ver [[sistema-streaming-mundo]], [[ADR-B1-ciclo-vida-slots|ADR-B1]]).

### `create_descriptor_layouts` (`:488`) / `destroy_descriptor_layouts` (`:573`)

O passo que define o contrato descriptor/push constant de todos os shaders (detalhado em [[sistema-engine-fundacao]] e [[ref-shaders]]):

1. **Valida limites do dispositivo** — `maxDescriptorSetStorageBuffers ≥ 22` e `maxPushConstantsSize ≥ 92`, senão `log.panicf` nominal (fatal).
2. **Set 0**: 22 bindings — 20 `STORAGE_BUFFER` (compute/mesh/fragment) + bindings 8/9 `COMBINED_IMAGE_SAMPLER` (atlas) + binding 21 `UNIFORM_BUFFER_DYNAMIC` só fragment (realce, [[VS-20-gameplay-selecao-construcao-pulo|VS-20]]).
3. **Dois pipeline layouts** com o mesmo set 0: gráfico (push 92 B a mesh/fragment) e compute (push 92 B a compute).

Destroy é a ordem inversa (layouts → set). Qualquer pipeline concreto (módulos de render/compute) deve morrer antes — também garantido pela ordem de `DestroyEngine`.

### `create_frame_data` (`:583`) / `destroy_frame_data` (`:631`)

Por frame em voo: command pool `TRANSIENT` na família gráfica, um command buffer primário alocado do pool, e um semáforo binário de aquisição. Destroy: semáforo → free do CB → pool. Recursos são imortais em runtime: sobrevivem a recriações de swapchain; só morrem no teardown.

### Seleção de dispositivo e swapchain — auxiliares privados

| Procedure | Papel |
| --- | --- |
| `select_physical_device` (`:642`) | Enumera GPUs; para cada candidato coleta extensões e features faltantes e valida as filas; o primeiro completo vence (loga nome + decisão de compute dedicado vs. compartilhada). Nenhum serve → `false` (o chamador panica). |
| `find_queue_families` (`:689`) | Retorna família gráfica (exige `GRAPHICS`+`COMPUTE`+present) e de compute (prefere família `COMPUTE` sem `GRAPHICS`; fallback = gráfica). `ok = false` se não há gráfica com present. |
| `list_queue_families` (`:718`) | Enumera `vkQueueFamilyProperties` do dispositivo (temp allocator). |
| `select_surface_format` (`:731`) | Prefere `B8G8R8A8_SRGB`/`SRGB_NONLINEAR`; fallback `formats[0]`. |
| `select_present_mode` (`:761`) | Prefere `MAILBOX`; fallback `FIFO`. |
| `get_swap_chain_capabilities` (`:791`) | Retorna capabilities + contagem de imagens (`max(3, minImageCount)`, teto por `maxImageCount`). |
| `setup_swap_chain_frames` (`:807`) | Para cada imagem da swapchain: image view (aspect `COLOR`) + semáforo de present dedicado; preenche `presentation.frames` e `swapChainImageCount`. Chamada só por `create_swap_chain`. |

## Contratos transversais

Para fechar, três regras que atravessam tudo o que você leu acima:

- **Ordem de vida**: criação em `CreateEngine`, destruição em `DestroyEngine` na ordem inversa, `vkDeviceWaitIdle` em ambos os pontos de transição (destroy e recreate). Nenhum `destroy_*` pode falhar — não checam resultados; a pré-condição é a ordem.
- **Fatal vs. recuperável**: init é sempre fatal; runtime só tem dois caminhos recuperáveis — frame pulado (`AcquireNextImage` → `CancelFrameReservation`) e recriação de swapchain (`AcquireNextImage`/`Present` → flag → `recreate_swapchain`).
- **Sincronização por valor, não por objeto compartilhado mutável**: a única espera de CPU é `WaitTimelineSemaphore`; trocas main↔GPU e main↔worker usam os valores monotônicos das timelines (regras 1 e 3 do AGENTS.md quanto ao lote).

## Para ir mais fundo

- Sistema: [[sistema-engine-fundacao]] · Macro: [[visao-geral]] · Spec: [[VS-00-fundacao-vulkan|VS-00]] · Telemetria sobre a fundação: [[VS-05-telemetria-profiling|VS-05]].
- Módulos vizinhos: [[ref-main]] (entry point), [[ref-voxel-gpu]] (recursos sobre VMA), [[ref-shaders]] (o contrato Slang do set 0).
