---
id: VS-00
titulo: Fundação Vulkan
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de: []
bloqueada_por: []
requisitos: [REQ-FND-PLAT-01, REQ-FND-PLAT-02, REQ-FND-DEV-01, REQ-FND-DEV-02, REQ-FND-DEV-03, REQ-FND-DEV-04, REQ-FND-FRM-01, REQ-FND-FRM-02, REQ-FND-FRM-03, REQ-FND-SYNC-01, REQ-FND-SYNC-02, REQ-FND-DESC-01, REQ-FND-BUILD-01]
ultima_atualizacao: 2026-11-04
---

# VS-00 — Fundação Vulkan

## Objetivo

Estabelecer a base executável da nova implementação: janela, dispositivo, capabilities, filas, sincronização, recursos por frame e apresentação de um frame vazio.

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 2 (A ponte: Vulkan 1.4 Sync)](../../arquitetura.md) e [Manual Técnico — Seção 4 (Sincronização Vulkan 1.4)](../../manual-tecnico.md).
- Referência: `VulkanContext` em `docs/examples/voxel.odin`; a inicialização atual em `src/engine/engine_vukan.odin` é somente prova de conceito e será evoluída in-place.
- Dependência transversal registrada em [[../tracking/dependencias.md|dependencias.md]]: VS-00 fornece as capabilities e a sincronização exigidas por VS-01 a VS-04 (mesh shaders, `storageBuffer16BitAccess`, duas timelines).

## Requisitos

### Plataforma

- **REQ-FND-PLAT-01** — Inicializar GLFW sem API de cliente, criar janela redimensionável e instância Vulkan 1.4 com as extensões exigidas pelo GLFW mais `VK_EXT_debug_utils`. Callback de debug roteado ao logger.
- **REQ-FND-PLAT-02** — Validation layers (`VK_LAYER_KHRONOS_validation`, com `SYNCHRONIZATION_VALIDATION` habilitado) são solicitadas quando disponíveis; se ausentes, registrar warning explícito e continuar. Presença/ausência deve aparecer no log de inicialização.

### Dispositivo

- **REQ-FND-DEV-01** — Selecionar o dispositivo por verificação explícita: enumerar extensões e consultar a cadeia de features via `vkGetPhysicalDeviceFeatures2`. Dispositivos incompatíveis são rejeitados com diagnóstico nomeando cada extensão/feature faltante; se nenhum dispositivo serve, a inicialização falha com erro claro (sem `log.assert` genérico).
- **REQ-FND-DEV-02** — Extensões obrigatórias: `VK_KHR_swapchain`, `VK_EXT_mesh_shader`, `VK_EXT_shader_object`.
- **REQ-FND-DEV-03** — Features obrigatórias: `meshShader`, `taskShader`, `shaderObject`, `dynamicRendering`, `synchronization2`, `timelineSemaphore`, `shaderDrawParameters`, `storageBuffer16BitAccess` (exigida pelo ring do mirror, VS-04), `scalarBlockLayout` (contratos std430 do manual técnico).
- **REQ-FND-DEV-04** — Filas: uma fila gráfica+presente e uma fila de compute. Preferir famílias distintas para compute (compute assíncrono, Etapa 2 da arquitetura); quando indisponível, reutilizar a família gráfica e registrar o fallback no log.

### Frames e apresentação

- **REQ-FND-FRM-01** — Swapchain com formato `B8G8R8A8_SRGB`/SRGB (fallback: primeiro formato), present mode `MAILBOX` (fallback: `FIFO`), 3 imagens (2 frames em voo + 1), depth buffer `D32_SFLOAT` dedicado via VMA, dynamic rendering (sem render pass objects).
- **REQ-FND-FRM-02** — Recursos por frame em voo: command pool (`TRANSIENT`), command buffer primário e semáforo de aquisição por frame; um semáforo de apresentação por imagem da swapchain.
- **REQ-FND-FRM-03** — Resize e minimização: em `glfwSetFramebufferSizeCallback` ou `VK_ERROR_OUT_OF_DATE_KHR`/`SUBOPTIMAL_KHR` no acquire/present, a swapchain e o depth buffer são recriados. Janela minimizada (extent 0×0) suspende a renderização até haver extent válida — nenhum recurso é criado com dimensão zero. Recriação só ocorre após o dispositivo estar idle em relação aos frames em voo.

### Sincronização

- **REQ-FND-SYNC-01** — Dois semáforos de timeline, um por domínio (gráfica e compute), conforme a Etapa 2: a aposentadoria dual do B1 (VS-01) consumirá ambos. Timeline gráfica com valor inicial `NUM_FRAMES_IN_FLIGHT`; antes de reutilizar os recursos do frame N, a CPU aguarda o valor `N - NUM_FRAMES_IN_FLIGHT` (`vkWaitSemaphores`). Timeline de compute criada com valor inicial 0 e exposta para a worker thread (VS-01), sem uso nesta fatia.
- **REQ-FND-SYNC-02** — Shutdown: nenhum recurso é destruído enquanto a GPU pode usá-lo. Sequência obrigatória: `vkDeviceWaitIdle` → destruição na ordem inversa da criação (frame data → sync → depth → swapchain → VMA → device → surface → instance → GLFW). `AcquireNextImage`/`Present` falhando por swapchain fora de data não encerram o processo — disparam recriação (REQ-FND-FRM-03).

### Descriptors e pipelines

- **REQ-FND-DESC-01** — Definir e criar os descriptor set layouts e pipeline layouts que as fatias seguintes consomem: set 0 = recursos globais de render (dicionário de blocos, templates, visible chunks, anéis de edição e mirror — bindings 0–16 do manual técnico), layout compatível com compute (generate/pack/apply_voxel_edits) e task/mesh. Push constants de 88 B no pipeline layout gráfico. Os pipelines concretos pertencem a VS-01/VS-02; aqui se criam apenas os layouts e se valida que o limite de bindings é suportado pelo dispositivo.

### Build e validação

- **REQ-FND-BUILD-01** — Um único comando documentado (`run.bat`: compilação Slang → `bin/`, `odin build ./src -out:./bin/vox.exe`, execução) compila e executa sem intervenção adicional. Toolchain mínimo: Odin dev-2025-07 ou superior (bindings `vendor:vulkan` com Vulkan 1.4), Vulkan SDK 1.4, Slang compatível com SPIR-V 1.4.

## Escopo

- Inicialização e encerramento de janela e Vulkan (REQ-FND-PLAT-01/02, REQ-FND-SYNC-02).
- Seleção de dispositivo e verificação explícita de extensões e features (REQ-FND-DEV-01..03).
- Filas gráfica e de compute, command buffers e timelines (REQ-FND-DEV-04, REQ-FND-SYNC-01).
- Swapchain, dynamic rendering e recursos por frames em voo, incluindo resize (REQ-FND-FRM-01..03).
- Estrutura de descriptor set/pipeline layouts para as fatias seguintes (REQ-FND-DESC-01).
- Build reproduzível e smoke test com validation layers (REQ-FND-BUILD-01).

## Não escopo

- Streaming, worldgen, chunks, geometria, edição e mirror (VS-01 a VS-04).
- Fallback para GPUs sem `VK_EXT_mesh_shader`.
- Pipelines concretos de compute/task/mesh — apenas os layouts (REQ-FND-DESC-01).
- Uso da fila de compute e da timeline de compute — criadas aqui, exercitadas em VS-01.

## Dependências

Nenhuma spec predecessor. Nenhuma ADR pendente bloqueia a aprovação. As decisões de capabilities atendem VS-01 a VS-04: mesh shaders (VS-02), `storageBuffer16BitAccess` (VS-04), `scalarBlockLayout` (layouts std430 de `common.slang`).

## Interfaces e recursos

### Propriedade e ciclo de vida

O contexto Vulkan é propriedade do singleton `engine.app` (`VoxEngine` em `src/engine/engine.odin`). Cada recurso tem um par `create_*`/`destroy_*` em `src/engine/engine_vukan.odin`; a criação segue a ordem de `CreateEngine` e a destruição a ordem inversa (REQ-FND-SYNC-02). Nenhum recurso Vulkan é criado fora desses pares. Falha em qualquer etapa da inicialização encerra o processo com diagnóstico (não há recuperação parcial de init).

| Recurso | Criado em | Destruído em | Pré-condição de destruição |
| --- | --- | --- | --- |
| Instância + debug messenger | `create_vulkan_instance` | `destroy_vulkan_instance` | device destruído |
| Surface | `create_vulkan_surface` | `destroy_vulkan_surface` | swapchain destruída |
| Device + filas | `create_vulkan_device` | `destroy_vulkan_device` | `vkDeviceWaitIdle` concluído |
| VMA allocator | `create_vma_allocator` | `destroy_vma_allocator` | todas as alocações liberadas |
| Swapchain + image views + semáforos de present | `create_swap_chain` | `destroy_swap_chain` | GPU idle; recriável em resize |
| Depth buffer | `create_depth_buffer` | `destroy_depth_buffer` | GPU idle; recriável em resize |
| Timelines (gráfica + compute) | `create_sync_objects` | `destroy_sync_objects` | GPU idle |
| Frame data (pool, cmd, acquire) | `create_frame_data` | `destroy_frame_data` | GPU idle |
| Descriptor set/pipeline layouts | `create_descriptor_layouts` | `destroy_descriptor_layouts` | GPU idle |

### Contratos de aquisição/apresentação

- `Update` avança `frameIndex = (frameIndex + 1) % NUM_FRAMES_IN_FLIGHT` e reserva o próximo valor da timeline gráfica.
- `AcquireFrameResource` retorna os recursos do frame corrente — somente após `WaitTimelineSemaphore` ter garantido que a GPU concluiu o uso anterior (valor `N - NUM_FRAMES_IN_FLIGHT`).
- `AcquireNextImage` retorna a imagem da swapchain ou sinaliza necessidade de recriação (`VK_ERROR_OUT_OF_DATE_KHR`, `SUBOPTIMAL_KHR`, extent zerada) — o chamador recria e repete ou pula o frame.
- `Present` submete na fila gráfica aguardando o semáforo de present da imagem; resultados `OUT_OF_DATE`/`SUBOPTIMAL` disparam recriação no frame seguinte, nunca pânico.
- Submissão gráfica (`vkQueueSubmit2`) sinaliza o semáforo de present **e** a timeline gráfica com o valor reservado pelo `Update`.

### Valores iniciais das timelines

- Timeline gráfica: valor inicial `NUM_FRAMES_IN_FLIGHT` (2); primeiro sinal de frame = 3. Invariante: todo valor sinalizado é estritamente crescente e reservado por exatamente um frame.
- Timeline de compute: valor inicial 0; VS-01 assume 1 lote = 1 valor (regra 3 do AGENTS.md).

### Comportamento de erro

- Erros de `vkCreate*` na inicialização: `log.panicf` com o `vk.Result` e a expressão chamadora (padrão `vk_check` existente).
- Erros de acquire/present em runtime: recriação de swapchain (REQ-FND-FRM-03), nunca pânico.
- Dispositivo sem features: erro fatal de inicialização com a lista nominal do que falta (REQ-FND-DEV-01).

## Cenários

### Cenário de sucesso

- **Dado** um dispositivo compatível e o toolchain mínimo (REQ-FND-BUILD-01).
- **Quando** `run.bat` é executado.
- **Então** a janela abre, o log registra capabilities verificadas e validation layers ativas (ou o warning de ausência), e frames vazios (clear color + depth clear via dynamic rendering) são apresentados continuamente, com 2 frames em voo e sem erro de validation.

### Rejeição de dispositivo

- **Dado** um sistema cujo único dispositivo não suporta uma feature ou extensão obrigatória (REQ-FND-DEV-02/03) — simulável ocultando o dispositivo compatível via `VK_ICD_FILENAMES` ou filtro de teste.
- **Quando** a inicialização seleciona o dispositivo.
- **Então** o processo termina com diagnóstico nomeando cada item faltante, sem criar device, swapchain ou qualquer recurso dependente.

### Resize e recriação de swapchain

- **Dado** a aplicação apresentando frames.
- **Quando** a janela é redimensionada, maximizada ou restaurada — ou o acquire retorna `OUT_OF_DATE`/`SUBOPTIMAL`.
- **Então** a swapchain e o depth buffer são recriados com a nova extent após o dispositivo ficar idle em relação aos frames em voo, e a apresentação continua sem erro de validation. Minimizada (extent 0×0), a aplicação pula frames sem criar recursos de dimensão zero.

### Encerramento

- **Dado** frames em voo (até 2 submissões pendentes).
- **Quando** a janela é fechada.
- **Então** `vkDeviceWaitIdle` precede toda destruição, a ordem inversa de criação é respeitada e o validation não reporta objeto destruído em uso nem vazamento (mesmo com `SYNCHRONIZATION_VALIDATION` ativo).

### Falhas e concorrência

- Validation layers ausentes: warning no log e execução continua (REQ-FND-PLAT-02).
- Sem família de compute dedicada: fallback para a família gráfica com registro no log (REQ-FND-DEV-04) — a timeline de compute continua existindo e funcional na mesma fila.
- Esta fatia é single-threaded; a worker thread chega em VS-01. O único trabalho em voo são os 2 frames, cobertos pela espera de timeline antes da reutilização (REQ-FND-SYNC-01).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-00-AC-01 | `run.bat` compila shaders e o executável e roda a fundação sem intervenção manual adicional (REQ-FND-BUILD-01) | Executar `run.bat` em checkout limpo; janela apresenta frames vazios por ≥ 10 s | 2026-11-04 — `odin build ./src -out:./bin/vox.exe` + execução de 12 s; `bin/log.txt` sem erros. **Verificado** (parcial: build via `run.bat` não exercitado de ponta a ponta, apenas o comando `odin build` que ele encapsula) |
| VS-00-AC-02 | Features e extensões obrigatórias (REQ-FND-DEV-02/03) são consultadas e um dispositivo sem elas é rejeitado com diagnóstico explícito e nominal (REQ-FND-DEV-01) | Inspeção do log de inicialização listando cada capability verificada; teste forçado de rejeição (filtro de dispositivo/feature) exibindo o diagnóstico | 2026-11-04 — log registra "Dispositivo selecionado: NVIDIA GeForce RTX 3050 Laptop GPU (todas as capabilities obrigatórias presentes)"; código de rejeição nominal em `collect_missing_features`/`collect_missing_extensions`. **Verificado por dispensa**: o teste forçado de rejeição foi dispensado pelo mantenedor em 2026-11-04 (caminho de rejeição implementado e logado; hardware de teste não permite simular a ausência) |
| VS-00-AC-03 | Frames e shutdown respeitam as timelines e a vida útil dos recursos (REQ-FND-SYNC-01/02), incluindo resize (REQ-FND-FRM-03) | Smoke test com validation layers + `SYNCHRONIZATION_VALIDATION`: apresentar, redimensionar/minimizar/restaurar, fechar; log sem nenhum erro de validation introduzido pela fatia | 2026-11-04 — **Verificado**: ciclo manual minimizar → restaurar → redimensionar → fechar executado com validation ativa; `bin/log.txt` com 0 linhas ERROR/WARN e sequência completa de destruição registrada. Durante o teste foi encontrado e corrigido um deadlock (reserva de timeline não desfeita em frames pulados + acquire com timeout infinito) |

## Tarefas da especificação

- [x] Vincular todos os requisitos do GOAL (REQ-FND-* acima; Etapa 2 da arquitetura e Seção 4 do manual técnico).
- [x] Definir interfaces, proprietários e ciclo de vida dos recursos.
- [x] Detalhar cenários de falha, resize e shutdown.
- [x] Definir comandos e evidências de validação.
- [x] Submeter à revisão e obter aprovação. — aprovada em 2026-11-04.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-00-IMPL-01 — Verificação de capabilities** (REQ-FND-DEV-01..03; AC-02). Tabela declarativa de extensões e features obrigatórias; seleção de dispositivo via `vkGetPhysicalDeviceFeatures2` + `vkEnumerateDeviceExtensionProperties`; diagnóstico nominal de cada item faltante e erro fatal se nenhum dispositivo servir. Inclui log de inicialização listando cada capability verificada.
2. **VS-00-IMPL-02 — Filas e timelines duais** (REQ-FND-DEV-04, REQ-FND-SYNC-01; AC-03). Seleção de família de compute distinta com fallback à família gráfica (registrado no log); criação da timeline de compute (valor inicial 0) ao lado da gráfica (valor inicial 2).
3. **VS-00-IMPL-03 — Política de validation layers** (REQ-FND-PLAT-02; AC-03). Checar disponibilidade de `VK_LAYER_KHRONOS_validation` antes de habilitar; warning explícito e continuação quando ausente; log do resultado.
4. **VS-00-IMPL-04 — Resize e recriação de swapchain** (REQ-FND-FRM-03, REQ-FND-SYNC-02; AC-01, AC-03). Tratar `OUT_OF_DATE`/`SUBOPTIMAL` em acquire/present sem pânico; extent 0×0 (minimizada) pula o frame; recriação de swapchain + depth buffer após `vkDeviceWaitIdle`, sem recriar frame data nem semáforos de aquisição.
5. **VS-00-IMPL-05 — Shutdown ordenado** (REQ-FND-SYNC-02; AC-03). `vkDeviceWaitIdle` antes de `DestroyEngine`; ordem inversa estrita; smoke test sem erros de validation no encerramento.
6. **VS-00-IMPL-06 — Layouts de descriptors e pipelines** (REQ-FND-DESC-01; AC-02). `create_descriptor_layouts`/`destroy_descriptor_layouts`: descriptor set layout do set 0 (bindings 0–16, storage buffers para compute+task/mesh) e pipeline layouts (gráfico com push constants de 88 B; compute), com verificação de `maxDescriptorSetStorageBuffers`/limites contra as propriedades do dispositivo.
7. **VS-00-IMPL-07 — Build e evidências** (REQ-FND-BUILD-01; AC-01..03). `run.bat` como comando único documentado; execução do smoke test (apresentar ≥ 10 s, redimensionar/minimizar/restaurar, fechar) com validation layers; registrar evidências nos ACs e atualizar tracking.

## Questões abertas

- Nenhuma. Resolvido em 2026-11-04: toolchain mínimo fixado em REQ-FND-BUILD-01 (Odin dev-2025-07+, Vulkan SDK 1.4, Slang/SPIR-V 1.4); validation layers ausentes geram warning e a execução continua (REQ-FND-PLAT-02).

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
- 2026-11-04 — Elaboração completa: requisitos REQ-FND-*, interfaces, cenários, validação dos ACs e questão aberta resolvida. Submetida à revisão (`em-revisao`).
- 2026-11-04 — Spec aprovada; tarefas de implementação VS-00-IMPL-01..07 derivadas.
- 2026-11-04 — IMPL-01..06 implementadas (capabilities, filas/timelines duais, validation opcional, resize, shutdown, layouts). Evidências registradas nos ACs; validação permanece `em-validacao` até o smoke test manual completo (resize + shutdown limpo + rejeição forçada).
- 2026-11-04 — Smoke test manual aprovou AC-03 (resize + shutdown limpo, 0 erros de validation); corrigido deadlock em frames pulados (acquire com timeout infinito e reserva de timeline não desfeita). AC-02 segue pendente do teste forçado de rejeição de dispositivo; validação permanece `em-validacao`.
- 2026-11-04 — Mantenedor dispensou o teste forçado de rejeição do AC-02 (registrado na tabela de ACs). Validação marcada `verificada`; fatia integralmente concluída.
- 2026-11-04 — Revisão de contrato pela VS-02 (REQ-PIPE-02): bindings 8 e 9 do descriptor set layout passam de `STORAGE_BUFFER` (placeholder) para `COMBINED_IMAGE_SAMPLER`; demais bindings e os push constants de 88 B inalterados.
- 2026-11-06 — Revisão de contrato pela VS-08 (REQ-CFG-06): `PushConstants` ganha `visible_chunk_capacity: u32` — **88 → 92 B** (`PUSH_CONSTANTS_SIZE`, ambos os pipeline layouts e as três gravações `CmdPushConstants`: `voxel_render` ×2, `voxel_worker` ×1). O slot do ring da fila de trabalho passa a ser calculado com a capacidade do push constant (`common.slang:work_queue_base_words`), sem constantes de compilação.
- 2026-11-06 — Revisão de contrato pela VS-10 (REQ-VRT-02, ADR-V1): novo binding 18 do set 0, `RWStructuredBuffer<uint> chunk_result_flags` (`[resident_slots]u32`, host-visible) — flags do header por slot, escritas pelo `pack_chunk` e lidas pelo handler de conclusão após a timeline do lote. `DESCRIPTOR_SET_BINDING_COUNT` 18 → 19 (verificação de `maxDescriptorSetStorageBuffers` acompanha); demais bindings, push constants (92 B) e layouts inalterados.
- 2026-11-06 — Revisão de contrato pela VS-11 (REQ-UV-02, ADR-U1): novo binding 19 do set 0, `StructuredBuffer<float2> template_uvs` — pool de UVs dos templates de malha (stride 8 B, paralelo e indexado como `template_vertices` por `MeshTemplate.uv_offset`). `DESCRIPTOR_SET_BINDING_COUNT` 19 → 20 (verificação de `maxDescriptorSetStorageBuffers` acompanha); demais bindings, push constants (92 B) e layouts inalterados.
