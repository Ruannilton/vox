---
id: REF-VOXEL-RENDER
titulo: "Referência: voxel_render — gravação do CB do frame + pipeline mesh"
tipo: referencia
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_render` — gravação do CB do frame + pipeline mesh

Você chegou ao módulo que **escreve o command buffer gráfico de cada frame**. Se você veio de [[sistema-renderizacao]] (a narrativa principal — leia primeiro se ainda não leu), já sabe o *quê* a GPU executa: edições, builder da fila de trabalho, finalize e o draw mesh indireto. Este documento mostra o *como* no código Odin — cada comando que é gravado, em que ordem, com que barreiras e esperando o quê.

O módulo é `src/engine/voxel_render.odin` (package `engine`). Um detalhe importante antes de começar: ele **não possui estado próprio**. Tudo que ele usa foi criado por [[ref-voxel-gpu|voxel_gpu]] (recursos) e [[ref-engine|engine]] (layouts) — aqui só existe a lógica de gravação. É chamado **duas vezes por frame** a partir de `main.odin`, e guarda uma exceção: `voxel_render_pipeline_create`, que roda uma única vez no init.

---

## Constante

| Símbolo | Valor | Papel |
| --- | --- | --- |
| `PUSH_CONSTANT_STAGES_GRAPHICS` | `{.MESH_EXT, .FRAGMENT}` | Estágios dos push constants na pipeline gráfica (o compute usa só `.COMPUTE`). Deve espelhar os `push_constant` de [[ref-shaders|render.slang]]. |

Se "push constants" é termo novo: são um bloco pequeno de dados (aqui, 92 bytes) que a CPU grava direto no command buffer com um único comando, sem precisar de buffer nem descriptor — o caminho mais rápido de passar dados por frame (matriz VP, posição da câmera, offsets do ring). Veremos o comando exato (`CmdPushConstants`) mais abaixo.

---

## Quando roda (frame N, na main)

Ambas as procedures de gravação são chamadas dentro da zona `render_record` de `main.odin`, e a ordem importa — memorize a linha do tempo:

1. `BeginCommandBuffer`, e as transições de layout da swapchain/depth para `COLOR/DEPTH_ATTACHMENT_OPTIMAL`.
2. **`voxel_render_prepare(cmd, vp, camera.position, visible_count, frame_index, edit_job_count)`** — `main.odin:335`, ainda **fora** do render pass.
3. `CmdBeginRendering` + label `render_pass`.
4. **`voxel_render_record(cmd, vp, camera.position, visible_count, frame_index)`** — `main.odin:347`, agora **dentro** do render pass.
5. `CmdEndRendering`, barreira para `PRESENT_SRC_KHR`, submit.

A separação existe porque Vulkan exige que compute e transições fiquem fora do render pass; só o draw propriamente dito pode estar dentro.

**Sincronização de entrada** (feita por quem chama, fora deste módulo, mas é contrato de entendimento): o submit gráfico espera a `computeTimelineSemaphore` no valor do publish (`compute_wait_value`) com `stageMask = {.COMPUTE_SHADER, .MESH_SHADER_EXT}` (`main.odin:382-387`). Em termos de tutorial: *antes de gravar qualquer coisa, a main garante que a fila de compute já terminou os lotes de geração/pack daquele mundo*. Por isso o builder — o primeiro a ler a ocupação dos chunks — nunca lê dados em voo; e o mesh shader lê os mesmos dados, então o mesmo wait cobre os dois. É a [[ADR-B10-fila-trabalho-global|ADR-B10]] consumida na prática (sem task shader, o primeiro toque na ocupação mudou de estágio). Depois, o submit sinaliza a `timelineSemaphore` gráfica no valor do frame — é o que a worker usa para saber que o ring de 2 frames pode ser reescrito. Detalhes em [[sistema-renderizacao]] e [[sistema-streaming-mundo]].

`voxel_render_pipeline_create` é a exceção já anunciada: roda **uma vez** no init, como último passo dos pipelines dentro de `voxel_gpu_init` ([[ref-voxel-gpu]]).

---

## `voxel_render_pipeline_create` — pipeline gráfica mesh/fragment

Cria `voxel_gpu.mesh_pipeline` (destruída em `voxel_gpu_destroy`). A configuração é deliberadamente mínima — quase tudo foi movido para o shader:

- **Estágios**: mesh `build_brick_mesh` + fragment `shade_voxel`, ambos do `render_shader_module` ([[ref-shaders]]). Sem estágio task/vértice — a geometria é fabricada no mesh shader (VS-02, ADR-B10).
- **Dynamic rendering**: `pNext = PipelineRenderingCreateInfo` com 1 attachment de cor (`app.presentation.format`) e depth (`app.depthBuffer.format`). Uma pausa para definir o termo: **dynamic rendering** é a extensão do Vulkan 1.4 que permite renderizar **sem um render pass estático** pré-compilado — quem define formatos e attachments é a struct de criação, e o `RenderingInfo` é montado por frame na main. É o que possibilita `CmdBeginRendering`/`CmdEndRendering` em vez de `CmdBeginRenderPass` clássico.
- **Rasterização**: `polygonMode = FILL`, `cullMode = {}` (**NONE**) — o culling por face é por tags no mesh shader (`compute_visible_face_mask`), não por winding (regra 5 do AGENTS.md: nunca assumir culling direcional). `lineWidth = 1.0`.
- **Multisample**: 1 amostra. **Depth**: teste + escrita, `LESS`. **Blend**: write-mask RGBA, sem blending (saída opaca, alpha-test no fragment — VS-14).
- **Dynamic states**: viewport e scissor — setados por frame em `voxel_render_record`.
- **Layout**: `app.graphicsPipelineLayout` (push constants `PUSH_CONSTANTS_SIZE = 92`, VS-08).

---

## `voxel_render_prepare` — edições → builder → finalize → barreiras

Esta é a procedure mais densa do módulo: ela grava **compute dentro do command buffer gráfico** — os pipelines `edit_pipeline`, `build_work_queue_pipeline` e `finalize_work_queue_pipeline` executam na fila gráfica, em série com o draw. Parâmetros: `vp` e `camera_position` (entram nos push constants), `visible_count` (do último publish consumido — ver [[visao-geral]]), `frame_index` (`app.frameIndex`, seleciona o slot do ring de 2 frames) e `edit_job_count` (edições pendentes do flush E1, journal descrito em [[sistema-edicao-eventos]]).

**Early-out**: `visible_count == 0 && edit_job_count == 0` → retorna sem gravar nada (`voxel_render.odin:90`).

### 1. Descriptor set + push constants (compute)

Bind do descriptor set shared no `computePipelineLayout` com `dynamic_offset = 0`, seguido de `CmdPushConstants` com `VoxelPushConstants` completos (`voxel_render.odin:100-101`): `view_projection_matrix`, `camera_position`, `visible_chunk_offset = frame_index × visible_capacity`, `edit_job_offset = frame_index × MAX_EDIT_JOBS_PER_FLUSH`, `visible_chunk_capacity`. É a mesma struct de 92 B usada pelo gráfico; os computes consomem só os campos de que precisam. Repare que os offsets por `frame_index` são *a* razão de existir o ring: cada frame usa sua fatia dos buffers sem tocar na do vizinho.

### 2. Edições pendentes (se `edit_job_count > 0`) — `voxel_render.odin:103-135`

- `tracing_gpu_record_context` — contexto gráfico Tracy GPU (VS-16, REQ-GPU-02/03): resets pendentes e re-sync entram **uma vez por command buffer**; por isso a chamada fica aqui e é replicada no ramo `edit_job_count == 0` (linhas 139-141) quando não há edições.
- Telemetria: timestamps (slot 2→3 do gfx pool), label `apply_voxel_edits` + zone Tracy `apply_edits_record` (VS-05).
- Bind de `edit_pipeline` + `CmdDispatch(edit_job_count, 1, 1)` — um workgroup por job de edição do flush.
- **Barreira**: `MemoryBarrier2` compute→compute (`SHADER_WRITE → SHADER_READ`). Primeira barreira do documento, então vale a mini-introdução: uma **memory barrier** no Vulkan é o comando que diz "toda escrita feita antes de mim, no escopo que eu declaro, fica visível para as leituras feitas depois de mim, nos estágios que eu declaro". Sem ela, a GPU poderia executar os dois dispatches em paralelo e o builder leria lixo. Aqui usa-se `MemoryBarrier2` (e não `BufferMemoryBarrier2`) porque a edição toca **vários recursos ao mesmo tempo** (scratch/pools) — a barreira de memória genérica cobre todos de uma vez.

**Contrato dos buffers**: `edit_jobs` (binding 13) e `voxel_edits` (14), host-mapped, já preenchidos pela CPU antes do frame; `edit_results` (15) é feedback para 2 frames depois (não tocado aqui).

### 3. Reset da fila de trabalho (`voxel_render.odin:137-164`)

- Early-out se `visible_count == 0` (edições aplicadas, mas nada a desenhar — não faz sentido montar pauta vazia).
- `CmdFillBuffer` zera as `WORK_QUEUE_STATE_WORDS` (8) words do **slot do ring do frame** — contador de append (word 0), overflow (word 1) e o comando indireto (`x` na word 2). Offset: `frame_index × work_queue_slot_words × 4`.
- **Barreira**: `BufferMemoryBarrier2` `CLEAR/TRANSFER_WRITE → COMPUTE_SHADER/{READ,WRITE}` no trecho de estado. Aqui sim a barreira é de **buffer**: só aquele trecho do `work_queue` importa. Só as words de estado são zeradas — os itens são sobrescritos pelo builder.

**Contrato do buffer**: `work_queue` (binding 17), ring de `NUM_FRAMES_IN_FLIGHT` slots; uso `INDIRECT_BUFFER`. Este slot só pode ser reescrito porque a timeline gráfica do frame N−2 já confirmou o consumo (sincronização fora deste módulo — o ring de 2 frames, já apresentado em [[visao-geral]]).

### 4. Builder (`voxel_render.odin:166-193`)

- Telemetria: timestamps 4→5, label/zone `build_work_queue`.
- Bind de `build_work_queue_pipeline` + `CmdDispatch(visible_count, 1, 1)` — **1 workgroup por chunk visível**; cada workgroup de 128 threads faz culling vazio → frustum por brick → oclusão e anexa itens `(visible_index 16b | brick 10b | parte 2b | subdivisão 2b)` na fila (VS-06, VS-09 — o formato do item está explicado em [[sistema-renderizacao]]).
- **Barreira**: `SHADER_WRITE → SHADER_READ` no **slot inteiro** (`work_queue_slot_words` words) — faz visível a fila fechada para o finalize.

**Contrato dos buffers**: lê `visible_chunks` (binding 7, host-mapped, montado pela CPU a cada frame com `VisibleChunk` + `neighbor_slots[6]`), `chunk_headers` (4), `occupancy_pool` (2) e `chunk_result_flags` (18); escreve `work_queue` (17). E lembre do topo do documento: a ocupação só é legível porque o submit espera a timeline de compute do publish.

### 5. Finalize (`voxel_render.odin:195-222`)

- Telemetria: timestamps 6→7, label/zone `finalize_work_queue`.
- Bind de `finalize_work_queue_pipeline` + `CmdDispatch(1, 1, 1)` — uma única thread fecha o comando indireto: grava `x = min(append_count, work_item_capacity)` (com clamp; fila vazia vira `x = 0`, no-op) e propaga a word de overflow.
- **Barreira final**: `SHADER_WRITE → {DRAW_INDIRECT, MESH_SHADER_EXT}/{INDIRECT_COMMAND_READ, SHADER_READ}` no slot inteiro. Atenção aos dois estágios de leitura: a mesma memória será lida como **comando indireto** (o `x` na word 2, lido pelo estágio que interpreta o draw) e como **storage** (os itens, lidos pelo mesh shader) — por isso a barreira declara os dois.

---

## `voxel_render_record` — bind + draw indireto

Roda **dentro do render pass** (`CmdBeginRendering` já aberto pela main — foi por isso que o passo foi separado de `prepare`). Early-out se `visible_count == 0` (`voxel_render.odin:232`).

1. **Viewport/scissor dinâmicos**: cobrem a janela inteira (`app.presentation.width/height`).
2. **Bind da pipeline**: `voxel_gpu.mesh_pipeline` (a gráfica, criada no init).
3. **Descriptor set gráfico**: mesmo set shared, agora no `graphicsPipelineLayout`, com `highlight_offset = target_highlight_alignment × frame_index` — offset dinâmico do UBO `target_highlight` (binding 21, VS-20): o slot do ring do frame seleciona o voxel-alvo publicado pela física.
4. **Push constants**: `VoxelPushConstants` nos estágios `PUSH_CONSTANT_STAGES_GRAPHICS` (mesh + fragment). Note que `edit_job_offset` fica zero aqui — o gráfico não usa edições.
5. **Draw indireto** (`voxel_render.odin:263-276`): telemetria timestamps 8→9, label/zone `draw_mesh`, e
   `vk.CmdDrawMeshTasksIndirectEXT(work_queue, state_offset + WORK_QUEUE_INDIRECT_X_WORD × 4, drawCount = 1, stride = 12)` — **um único comando indireto** cujo `x` é a contagem de itens (clamped pelo finalize). DrawCount é 1, não a contagem: `CmdDrawMeshTasksIndirectCountEXT` teria semântica de N comandos (o cuidado registrado na ADR-B10). O mesh shader consome os itens por `SV_GroupID`.

**Contrato do buffer**: o mesmo slot do ring do `work_queue` preparado por `voxel_render_prepare` — a barreira final de lá já ordena compute→draw. O mesh shader ainda relê `visible_chunks`, `chunk_headers`, `occupancy_pool`, `material_plane_pool` (3), `mesh_templates` (10), `template_vertices` (11), `template_triangles` (12), `template_uvs` (19), `block_registry` (6) e as texturas (8/9) — todos imutáveis durante o frame.

---

## Helpers privados

**Este módulo não tem helpers privados** — são exatamente as três procedures públicas acima mais a constante `PUSH_CONSTANT_STAGES_GRAPHICS`. Todo o trabalho auxiliar (telemetria, tracing, contratos de buffer) vive nos módulos vizinhos: [[ref-physics-tracing|telemetry + tracing]] (timestamps/labels/zones) e [[ref-voxel-gpu|voxel_gpu]] (recursos).

---

## Tabela rápida — telemetria por passagem (VS-05)

| Passagem | Label | Timestamps (gfx pool) | Zone Tracy |
| --- | --- | --- | --- |
| Edições | `apply_voxel_edits` | 2 → 3 | `apply_edits_record` |
| Builder | `build_work_queue` | 4 → 5 | `builder_record` |
| Finalize | `finalize_work_queue` | 6 → 7 | `finalize_record` |
| Draw mesh | `draw_mesh` | 8 → 9 | `mesh_draw_record` |

(Fechamento do frame com timestamp 0 e total em `main.odin`; passagens da fila de compute — `generate`, `pack` — são gravadas pela worker.)

---

## Vizinhos

- [[ref-voxel-gpu]] — `mesh_pipeline`, `work_queue`, `visible_chunks`, `target_highlight_ubo`, pipelines de compute.
- [[ref-shaders]] — `render.slang`: entry points `build_work_queue`, `finalize_work_queue`, `build_brick_mesh`, `shade_voxel`; `common.slang`: layouts e push constants.
- [[ref-engine]] — `app` (layouts, presentation, depthBuffer), `VoxelPushConstants`, `PUSH_CONSTANTS_SIZE`.
- [[ref-voxel-types]] — `WORK_QUEUE_STATE_WORDS`, `WORK_QUEUE_INDIRECT_X_WORD`, `VisibleChunk`.
- Specs: [[VS-02-task-mesh-templates|VS-02]] (templates + fila global/ADR-B10), [[VS-06-culling-frustum|VS-06]] (frustum no builder), [[VS-20-gameplay-selecao-construcao-pulo|VS-20]] (highlight), [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (faces/NEAREST), [[VS-05-telemetria-profiling|VS-05]] (labels/timestamps).
- Narrativa: [[sistema-renderizacao]] (por que existe e como se coordena), [[visao-geral]] (pipeline de um frame).
