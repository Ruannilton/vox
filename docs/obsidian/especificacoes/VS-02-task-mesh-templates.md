---
id: VS-02
titulo: Task/mesh e templates
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-01
bloqueada_por: []
requisitos: [REQ-VIS-01, REQ-VIS-02, REQ-VIS-03, REQ-VIS-04, REQ-MESH-01, REQ-MESH-02, REQ-MESH-03, REQ-MESH-04, REQ-SHADE-01, REQ-SHADE-02, REQ-SHADE-03, REQ-SHADE-04, REQ-PIPE-01, REQ-PIPE-02, REQ-PIPE-03, REQ-PIPE-04, REQ-SIM-03]
ultima_atualizacao: 2026-11-04
---

# VS-02 — Task/mesh e templates

## Objetivo

Renderizar os chunks materializados por VS-01 com task/mesh shaders, fronteiras entre chunks corrigidas (B2), geometria genérica orientada por templates (Caminho B) e shading Lambert + emissão sobre albedo de cor sólida por bloco.

## Rastreabilidade

- GOAL: [Arquitetura — Etapas 4 e 5](../../arquitetura.md) e [Manual Técnico — Pipeline de renderização e Caminho B](../../manual-tecnico.md).
- Referência: entry points `build_brick_mesh` (mesh) e `shade_voxel` (fragment) em `docs/examples/voxel.slang`; publicação de `visible_chunks`, `neighbor_slots` e o submit gráfico com espera da timeline de compute em `docs/examples/voxel.odin`. O transporte por payload task→mesh da referência foi substituído pela fila de trabalho global ([[ADR-B10-fila-trabalho-global|ADR-B10]]).
- Decisões: [[ADR-B2-fronteiras-chunks|ADR-B2]], [[ADR-B6-culling-alpha-test|ADR-B6]], [[ADR-B7-pbr|ADR-B7]], [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]] e [[ADR-B10-fila-trabalho-global|ADR-B10]].
- Fundação: [[VS-01-streaming-generate-pack|VS-01]] fornece chunks `RENDERABLE` com ocupação, paleta, planos, headers e subdivisão por brick prontos; templates built-in (ar/cubo/planta) e dicionário de blocos já carregados nos bindings 7 e 10–12; `highest_completed_compute_value` publicado pelo handler de conclusão.

## Requisitos

### Visibilidade e publicação

- **REQ-VIS-01** — `visible_chunks` reconstruído pela CPU a cada frame num ring de `NUM_FRAMES_IN_FLIGHT` (2) posições, `VisibleChunk` de 48 B por entrada, capacidade 4.096 por posição (`MAXIMUM_VISIBLE_CHUNKS`). Somente chunks `RENDERABLE` são publicados, até a capacidade; excedentes esperam o frame seguinte sem falhar.
- **REQ-VIS-02** — Fronteiras (ADR-B2): `neighbor_slots[6]` preenchidos por frame na ordem de `FACE_NORMALS` (+X, −X, +Y, −Y, +Z, −Z). Vizinho ausente ou `GENERATING` recebe `NEIGHBOR_SLOT_INVALID` (`0xFFFFFFFF`) e é tratado como ar pelo shader; a geometria se autocorrige no frame em que o vizinho concluir. O shader redireciona leituras de ocupação fora do chunk ao vizinho correspondente (`is_voxel_solid`).
- **REQ-VIS-03** — O submit gráfico espera a timeline de compute com o valor `highest_completed_compute_value` (lido sem bloqueio) nos estágios `COMPUTE_SHADER | MESH_SHADER_EXT`: a ocupação publicada pelos lotes concluídos é visível antes do builder da fila de trabalho (compute na fila gráfica) e do mesh shader. Quando o valor é 0, a espera é omitida.
- **REQ-VIS-04** — Culling de vazio: o builder da fila de trabalho retorna sem anexar itens para chunks com `CHUNK_FLAG_EMPTY`; bricks com word de ocupação zero são pulados. Culling de oclusão: brick cheio (32/32 voxels sólidos) com os 6 bricks vizinhos cheios — consultados com redirecionamento B2 pelos `neighbor_slots`, vizinho inválido = conservador (não culpa) — não tem face exposta e é pulado. ~~Culling de frustum por brick fica no backlog~~ **Backlog resolvido pela [[VS-06-culling-frustum|VS-06]] (2026-11-06)**: planos derivados na GPU no builder (Gribb-Hartmann sobre a `view_projection_matrix`), early-out de chunk e culling por brick com p-vertex (REQ-CULL-01..05), conforme [[ADR-B11-culling-frustum|ADR-B11]].

### Task/mesh e templates (Caminho B)

- **REQ-MESH-01** — Builder da fila de trabalho (compute `[numthreads(128,1,1)]` na fila gráfica, gravado antes do render pass), um workgroup por chunk visível (`group_id.x` indexa `visible_chunks` a partir de `visible_chunk_offset`). Seleciona grupos `(brick | parte | subdivisão)` e anexa **itens de 32 bits** (`visible_index 16b | brick 10b | parte 2b | subdivisão 2b` — layout VS-09/[[ADR-B12-visible-index-16-bits|ADR-B12]], antes 12|10|2|2) no buffer global `work_queue` (binding 17): um `InterlockedAdd` por chunk sobre o contador de append, scan exclusivo local em groupshared para os offsets por brick e rederivação determinística na fase de escrita. Um segundo compute de 1 thread (`finalize_work_queue`) fecha o comando indireto com `x = min(append_count, visible_chunk_capacity × BRICKS_PER_CHUNK)` (push constant, VS-08), `y = z = 1`; overflow é sinalizado numa word de estado dedicada, nunca silencioso. A capacidade da fila (visíveis × 1.024 bricks) cobre por construção o caso dos templates atuais, que nunca subdividem.
- **REQ-MESH-02** — Mesh shader `[numthreads(32,1,1)]`, topologia triângulo, `MESH_VERTEX_MAXIMUM = 256` / `MESH_TRIANGLE_MAXIMUM = 192` por grupo, garantidos por construção (subdivisão gravada pelo pack — regra 5 do AGENTS.md, sem depender de culling direcional). Prefixo exclusivo de vértices/triângulos por voxel e `SetMeshOutputCounts` com os totais.
- **REQ-MESH-03** — Emissão orientada a template: vértices em `[0,1]³` transladados para o voxel; rotação yaw em passos de 90° (`rotate_vertex_yaw`, `ROTATED_FACE`); tags de culling 0–5 testadas contra a `face_mask` do voxel (vizinho sólido via B2 + câmera do lado de fora do plano); tag 7 (`CULL_FACE_NEVER`) nunca é culpada. Voxel sem triângulo sobrevivente não emite vértices.
- **REQ-MESH-04** — `MeshVertex` carrega `clip_position` (VP × mundo), `world_position`, `block_id` e `uv` (float2, `TEXCOORD0` — 10 componentes de saída; VS-11); o fragment resolve o `BlockDefinition` pelo `block_id`. `uv = (-1,-1)` (sentinela, emitida quando o template não tem pool de UVs) seleciona o triplanar no fragment.

### Shading

- **REQ-SHADE-01** — Lambert + emissão (ADR-B7): luz direcional fixa + ambiente, `final = albedo × (ambiente + difusa) + emission_color`.
- **REQ-SHADE-02** — Normais por derivadas espaciais (`dFdx`/`dFdy` da posição mundo), sem atributo de normal na malha.
- **REQ-SHADE-03** — Albedo por camada de `block_albedo_textures` (binding 8). O array de texturas é **gerado proceduralmente no init** como paleta de cores sólidas (uma camada por entrada de albedo: grama verde, terra marrom, pedra cinza…), sem arquivos de asset. O caminho índice → textura → **UV** é o definitivo; o triplanar (projeção pela posição mundo) passa a ser **fallback** para templates sem pool de UVs (sentinela `uv = (-1,-1)`) — emenda VS-11 (ADR-U1). Texturas reais futuras só trocam a carga.
- **REQ-SHADE-04** — `base_roughness`/`base_metallic` permanecem no contrato de dados sem consumo pelo fragment (ADR-B7); binding 9 (`block_pbr_textures`) recebe uma textura dummy do mesmo tipo e não é amostrado.

### Pipeline e recursos

- **REQ-PIPE-01** — Pipeline gráfica mesh+fragment (mesh-only, EXT_mesh_shader, features já habilitadas na VS-00) com dynamic rendering: formato de cor da swapchain, depth test/write habilitados, sem vertex input, `cullMode = NONE` (o culling direcional acontece no shader por tags; a correção visual completa de plantas — alpha-test — permanece adiada pela ADR-B6).
- **REQ-PIPE-02** — Revisão do contrato de descritores da VS-00: bindings 8 e 9 passam de `STORAGE_BUFFER` (dummy) para `COMBINED_IMAGE_SAMPLER`; stage flags já cobrem task/mesh/fragment. Demais bindings inalterados. A revisão é registrada no histórico da VS-00 na implementação.
- **REQ-PIPE-03** — Um `vkCmdDrawMeshTasksIndirectEXT` por frame dentro do render pass existente, com **um único** `VkDrawMeshTasksIndirectCommandEXT` lido do estado do `work_queue` (`x` = contagem de itens com clamp do finalize, `y = z = 1`; fila vazia ⇒ `x = 0`, no-op). **Não** usar a variante `IndirectCount`: ela executaria N comandos de 12 B lidos da região de itens (derrubou o dispositivo na integração — ver histórico). Frame sem visíveis não despacha. `visible_chunk_offset = frame_atual × MAXIMUM_VISIBLE_CHUNKS`.
- **REQ-PIPE-04** — Viewport e scissor dinâmicos acompanhando a swapchain; recriação da swapchain (resize/minimizar) não exige recriar a pipeline.

### Simulação

- **REQ-SIM-03** — Antes da integração dos shaders de renderização, simulação Python em `tools/sim/` cobrindo: orçamento por grupo (≤ 256 v/192 t com subdivisões ×1/×2/×4), seleção de bricks e estouro do payload, `face_mask` com redirecionamento B2 (vizinho sólido suprime a face), fronteira entre dois chunks sólidos sem faces internas duplicadas, rotação yaw 0–3 consistente com `ROTATED_FACE`.

## Escopo

- Publicação de chunks visíveis e seis vizinhos.
- Culling coarse/brick (via flags e words de ocupação) e fila de trabalho global builder→mesh (substituindo o payload de task shader, ADR-B10).
- Templates, vértices, triângulos packed, rotação e tags de culling.
- Subdivisão de bricks e garantia dos orçamentos de hardware.
- Built-ins de ar, cubo e planta como dados de geometria (carregados na VS-01).
- Shading Lambert + emissão, com triplanar e normais por derivadas.
- Albedo por cor sólida por tipo de bloco: textura de paleta gerada proceduralmente no init (ex.: grama verde, terra marrom), sem arquivos de asset; o caminho índice→textura→triplanar permanece o definitivo.

## Não escopo

- Edição, mirror, LOD, Hi-Z e transparência.
- Correção visual B6 de plantas: alpha-test fica para trabalho posterior (`cullMode = NONE` já adotado na pipeline).
- PBR e amostragem de roughness/metallic, adiados pela ADR-B7.
- Arquivos de textura reais: o albedo é uma paleta de cores sólidas gerada em código (decisão de escopo registrada em 2026-11-04).
- Culling de frustum por brick e otimizações de visibilidade (backlog — frustum resolvido pela VS-06; demais otimizações permanecem em backlog).

## Dependências

- [[VS-01-streaming-generate-pack|VS-01]] concluída e verificada (chunks `RENDERABLE`, headers, ocupação com subdivisão, templates e dicionário nos bindings 7/10–12).
- [[ADR-B6-culling-alpha-test|ADR-B6]] e [[ADR-B7-pbr|ADR-B7]] aceitas e incorporadas; não há bloqueio de decisão.

## Interfaces e recursos

### Contratos novos (common.slang, espelhados no Odin)

| Contrato | Layout | Observação |
| --- | --- | --- |
| `VisibleChunk` | 48 B: `chunk_world_origin[3]i32`, `storage_slot_index` u32, `neighbor_slots[6]` u32, `padding[2]` u32 | Binding 6; escrito pela CPU por frame |
| Item da fila de trabalho | u32: `visible_index (16b) \| brick (10b)<<16 \| parte (2b)<<26 \| subdivisão (2b)<<28` (VS-09; antes 12\|10\|2\|2) | Binding 17; escrito pelo builder, decodificado pelo mesh shader |
| Estado do `work_queue` | 8 words por slot do ring: append_count, overflow, x/y/z do comando indireto (+3 reservadas) | Zerado por `vkCmdFillBuffer` a cada frame; base = `frame % 2` × `WORK_QUEUE_SLOT_WORDS` |
| `MeshVertex` | `clip_position` float4, `world_position` float3, `block_id` u32, `uv` float2 (VS-11) | Saída do mesh shader |
| Constantes | `NEIGHBOR_SLOT_INVALID`, `FACE_NORMALS`, `ROTATED_FACE`, `CULL_FACE_NEVER = 7`, `WORK_ITEM_CAPACITY = 4.194.304`, `WORK_QUEUE_STATE_WORDS = 8`, `WORK_QUEUE_SLOT_WORDS` | Compartilhadas Odin↔Slang |

### Recursos e proprietários

- **`visible_chunks`** (binding 6): ring de 2 × 4.096 × 48 B (384 KiB), host-visible, escrito pela thread principal antes do submit gráfico do frame; a posição `frame % 2` só é regravada após a espera de frames em voo (mesmo padrão do ring de jobs da VS-01).
- **Textura de paleta de albedo** (binding 8): `Texture2DArray` RGBA8, uma camada por entrada de albedo do dicionário, cada camada uma cor sólida; sampler linear com wrap `REPEAT`. Gerada em código no init via staging; destruída com o motor.
- **Dummy PBR** (binding 9): textura 1×1 do mesmo tipo, presente só para validar o descriptor; não amostrada.
- **`work_queue`** (binding 17): ring de 2 × (8 words de estado + 4.194.304 itens) × 4 B (≈ 32 MiB), device-local (`STORAGE | INDIRECT | TRANSFER_DST | TRANSFER_SRC`); o builder anexa itens e o finalize fecha o comando indireto, ambos compute na fila gráfica gravados antes do render pass; o estado do slot do frame é zerado por `vkCmdFillBuffer` e o slot só é reusado após a espera da timeline gráfica (mesmo padrão do ring de visíveis).
- **Pipeline mesh**: criada no init do motor de voxels (mesh+fragment do `voxel.spv`, mesh-only), layout `graphicsPipelineLayout` da VS-00, push constants de 88 B (`view_projection_matrix`, `camera_position`, `visible_chunk_offset`).

### Sequência do frame (integração)

```
ve_update (streaming + conclusões)            [thread principal]
publicar visible_chunks do frame (REQ-VIS-01/02)
aguardar frame em voo / adquirir imagem
command buffer do frame:                      [se visible_count > 0]
  fill do estado do work_queue (32 B) → barreira transfer→compute
  dispatch build_work_queue(visible_count) → barreira compute→compute
  dispatch finalize_work_queue(1) → barreira compute→mesh|draw_indirect
  barreiras de layout → CmdBeginRendering
  bind pipeline mesh + descriptor set + push constants
  CmdDrawMeshTasksIndirectEXT(1 comando: x = itens, y = z = 1)
  CmdEndRendering → barreira de present
submit gráfico: espera timeline de compute (COMPUTE|MESH, REQ-VIS-03)
              + semáforo de aquisição; sinaliza present + timeline gráfica
```

### Comportamento quando limites são atingidos

- Sem chunks `RENDERABLE`: frame renderiza só o clear; nenhum draw é emitido.
- Visíveis > 4.096: excedentes aguardam frames seguintes (raio 8 ⇒ 2.109 chunks máximo teórico — a capacidade não é atingida por construção).
- Fila de trabalho: capacidade global = 4.096 visíveis × 1.024 bricks; os templates atuais nunca subdividem, então o caso é coberto por construção. Overflow (só possível com templates futuros que subdividam) acende a word de overflow do estado e o finalize faz o clamp do draw — itens excedentes são descartados com sinal explícito, nunca silencioso. O culling de oclusão de bricks cheios (REQ-VIS-04) reduz drasticamente o caso comum de chunks sólidos.
- Vizinho em geração: faces de fronteira emitidas contra "ar" no frame corrente e corrigidas na conclusão do vizinho (ADR-B2).

## Cenários

### Cenário de sucesso

- **Dado** a bolha materializada (VS-01) e a câmera dentro do terreno.
- **Quando** frames avançam.
- **Então** os chunks `RENDERABLE` são publicados com vizinhos, o builder anexa os itens de trabalho na fila global e o draw indireto despacha um workgroup de mesh por item, e o terreno aparece com cores sólidas por bloco, Lambert + emissão e depth correto — sem erros de validation.

### Fronteira entre chunks (B2)

- **Dado** dois chunks sólidos adjacentes.
- **Quando** o mesh shader avalia voxels na face de fronteira.
- **Então** a leitura redirecionada à ocupação do vizinho suprime as faces internas dos dois lados — nenhuma face duplicada é emitida (verificado na simulação e no smoke visual).

### Vizinho ausente ou em geração

- **Dado** um chunk `RENDERABLE` cuja vizinhança tem slot `GENERATING` ou inexistente.
- **Quando** o frame é renderizado.
- **Então** o vizinho é tratado como ar (faces de fronteira aparecem temporariamente) e a geometria se corrige no frame da conclusão, sem reciclagem de slot em voo (aposentadoria gráfica da ADR-B1 protege os slots publicados).

### Orçamento por construção

- **Dado** bricks com os templates mais pesados (planta em todos os voxels).
- **Quando** a subdivisão gravada pelo pack é aplicada.
- **Então** nenhum grupo despachado excede 256 vértices ou 192 triângulos — verificado pela simulação (REQ-SIM-03) e pela ausência de erros de validação no smoke test.

### Dados-limite

- Chunk `CHUNK_FLAG_EMPTY`: builder retorna sem anexar itens.
- Brick vazio: pulado pela word de ocupação.
- Todos os bricks pesados: a fila comporta o caso por construção; overflow sinalizado na word de estado com clamp do draw.
- Rotação yaw 0–3: faces de culling remapeadas por `ROTATED_FACE` permanecem consistentes.

### Falhas e concorrência

- Recriação de swapchain (resize/minimizar): frame pulado pelo caminho da VS-00; viewport/scissor dinâmicos seguem o novo tamanho sem recriar a pipeline.
- Compute atrasado: a espera da timeline no submit garante que o builder e o mesh nunca leiam ocupação de lotes não sinalizados.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-02-AC-01 | Nenhum grupo excede 256 vértices ou 192 triângulos por construção | Simulação de orçamento (REQ-SIM-03) cobrindo todos os templates × subdivisões + smoke test com validation layers sem erros de mesh shader | Verificado — `tools/sim/render_sim.py`: 210 checks OK (orçamento ≤ 256 v/192 t garantido pela subdivisão gravada pelo pack, todos os templates × subdivisões ×1/×2/×4); smoke tests com `VK_LAYER_KHRONOS_validation` sem nenhum erro de mesh shader |
| VS-02-AC-02 | Fronteiras entre chunks não emitem faces internas duplicadas | Simulação da cena de dois chunks sólidos adjacentes (faces internas = 0) + inspeção visual no smoke test | Verificado — `render_sim.py`: dois chunks sólidos adjacentes com 0 faces internas duplicadas; `ve_publish_visible` preenche `neighbor_slots[6]` na ordem de `FACE_NORMALS` e redireciona leituras via `is_voxel_solid`. Inspeção visual (correção pós-validação 3): terreno contínuo sem costuras, buracos ou z-fighting entre chunks nas capturas de tela |
| VS-02-AC-03 | Templates obedecem ao voxel unitário e às regras de rotação/culling | Testes de contrato na simulação: vértices em `[0,1]³`, yaw 0–3 vs `ROTATED_FACE`, tag 7 nunca culpada, tags 0–5 contra `face_mask` | Verificado — `render_sim.py`: 210 checks cobrindo vértices em `[0,1]³`, yaw 0–3 consistente com `ROTATED_FACE`, `CULL_FACE_NEVER` (tag 7) nunca culpada e tags 0–5 contra `face_mask` com vizinho sólido (B2) |
| VS-02-AC-04 | O terreno é apresentado com Lambert + emissão e albedo de cor sólida por bloco; PBR e alpha-test não são exigidos nesta fatia | Smoke test visual com validation layers (sem erros) + registro de screenshot ou descrição da cena no histórico | Verificado — smoke test com screenshots (correção pós-validação 3, ver histórico): terreno sólido e estável ao redor da câmera (duas capturas idênticas a 10 s de intervalo), plano de grama completo também em vista top-down, draw indireto sobre fila de trabalho com 67.204 itens (estado confirmado por readback: append = x = 67.204, y = z = 1, overflow = 0), 2.109 chunks visíveis, timeline de compute 132/132, zero erros de validation; readbacks da VS-01 íntegros |

## Tarefas da especificação

- [x] Vincular todos os requisitos do GOAL (REQ-VIS/MESH/SHADE/PIPE/SIM acima).
- [x] Formalizar payload, bindings e contratos de carga.
- [x] Definir cenários de culling, fronteira e orçamento.
- [x] Incorporar ADR-B6: correção visual de plantas adiada.
- [x] Incorporar ADR-B7: Lambert + emissão nesta fatia; PBR posterior.
- [x] Submeter à revisão e obter aprovação. — aprovada pelo mantenedor em 2026-11-04.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-02-IMPL-01 — Contratos de renderização no `common.slang`** (REQ-VIS-02, REQ-MESH-01..04; AC-03). Adicionar `VisibleChunk`, `TaskPayload`, `MeshVertex`, `NEIGHBOR_SLOT_INVALID`, `FACE_NORMALS`, `ROTATED_FACE`, `CULL_FACE_NEVER`, `TASK_PAYLOAD_BRICK_CAPACITY` e os helpers (`is_voxel_solid` com redirecionamento, `compute_visible_face_mask`, `rotate_vertex_yaw`, `triangle_survives_culling`); espelhar no Odin com `#assert` de tamanhos; declarar bindings 6/8/9.
2. **VS-02-IMPL-02 — Simulação de renderização** (REQ-SIM-03; AC-01, AC-02, AC-03). `tools/sim/render_sim.py`: orçamento por grupo com subdivisões, seleção de bricks e estouro de payload, `face_mask` com vizinho sólido, dois chunks adjacentes sem faces duplicadas, yaw 0–3 vs `ROTATED_FACE`, tag 7.
3. **VS-02-IMPL-03 — Shaders task/mesh/fragment** (REQ-MESH-01..04, REQ-SHADE-01..03, REQ-VIS-04; AC-01, AC-04). Portar `select_bricks`, `build_brick_mesh` e `shade_voxel` (triplanar + Lambert + emissão + normais por derivadas) para `src/assets/shaders/voxel.slang`; compilar com `run.bat` sem avisos.
4. **VS-02-IMPL-04 — Descritores 8/9 e textura de paleta procedural** (REQ-PIPE-02, REQ-SHADE-03/04; AC-04). Bindings 8/9 → `COMBINED_IMAGE_SAMPLER` (pool e layout); `Texture2DArray` RGBA8 de cores sólidas por bloco + sampler; dummy PBR; registrar a revisão do contrato no histórico da VS-00.
5. **VS-02-IMPL-05 — Publicação de `visible_chunks`** (REQ-VIS-01/02; AC-02). Buffer ring 2 × 4.096 host-visible; `ve_publish_visible` na thread principal preenche entradas e `neighbor_slots` (somente vizinhos `CACHED`/`RENDERABLE`; `NEIGHBOR_SLOT_INVALID` caso contrário).
6. **VS-02-IMPL-06 — Pipeline mesh e integração do draw** (REQ-PIPE-01/03/04, REQ-VIS-03; AC-04). Pipeline task+mesh+fragment com dynamic rendering e depth; draw no command buffer do frame; espera da timeline de compute (`highest_completed_compute_value`) nos estágios TASK|MESH no submit gráfico; viewport/scissor dinâmicos.
7. **VS-02-IMPL-07 — Dicionário com albedo por camada** (REQ-SHADE-03; AC-04). Blocos do worldgen (grama/terra/pedra) recebem `albedo_texture_index` apontando para as camadas da paleta procedural; emissão zero.
8. **VS-02-IMPL-08 — Evidências e fechamento** (AC-01..04). Smoke test visual com validation layers, cenário de fronteira, resize/minimizar; registrar evidências nos ACs, atualizar tracking e commitar com o nome da spec.

## Questões abertas

- Dimensões exatas da textura de paleta (proposta: 4×4 texels por camada, uma camada por entrada de albedo): fixadas na implementação e registradas aqui. Não bloqueia a aprovação.
- Tratamento de gama da swapchain (cor em espaço linear vs sRGB): adiado; a fatia valida o caminho de dados, não a fidelidade de cor. Não bloqueia a aprovação.

## Histórico

- 2026-11-03 — Rascunho estrutural criado.
- 2026-11-04 — ADR-B6 e ADR-B7 incorporadas; bloqueios de decisão removidos, spec permanece em rascunho.
- 2026-11-04 — Escopo de albedo definido com o mantenedor: sem arquivos de textura nesta fatia; paleta de cores sólidas por bloco gerada proceduralmente no init, preservando o caminho índice→textura→triplanar.
- 2026-11-04 — Elaboração completa: 17 requisitos (VIS/MESH/SHADE/PIPE/SIM), contratos de renderização, sequência do frame, cenários e validação dos ACs. Aprovada pelo mantenedor; tarefas VS-02-IMPL-01..08 derivadas.
- 2026-11-04 — Implementação concluída (IMPL-01..08): contratos de renderização no `common.slang` com espelho Odin (`#assert(size_of(VisibleChunk) == 48)`); `tools/sim/render_sim.py` com 191 checks; `select_bricks`/`build_brick_mesh`/`shade_voxel` em `voxel.slang` (Slang → SPIR-V validado com `spirv-val`); bindings 8/9 revisados de `STORAGE_BUFFER` para `COMBINED_IMAGE_SAMPLER` (REQ-PIPE-02 — revisão do contrato da VS-00 registrada também no histórico da VS-00); paleta de albedo procedural RGBA8 (256 camadas 4×4: grama verde, terra marrom, pedra cinza) + dummy PBR 1×1; ring `visible_chunks` host-visible 2 × 4.096 × 48 B; pipeline task+mesh+fragment com dynamic rendering, depth LESS, `cullMode = NONE` e viewport/scissor dinâmicos; submit gráfico esperando a timeline de compute nos estágios TASK|MESH; dicionário com `albedo_texture_index` por camada.
- 2026-11-04 — Bugs corrigidos durante a integração: (1) `for coord, &record in map` não persiste a escrita neste toolchain — mutação passou a ser via ponteiro por índice (`&ve.active_chunks[coord]`, com NOTE no código); (2) a promoção CACHED⇄RENDERABLE da VS-01 só rodava na mudança de chunk da câmera — `ve_update` reestruturado para rodá-la todo frame (registrado no histórico da VS-01).
- 2026-11-04 — Validação verificada: evidências nos ACs acima. Ressalvas: a aparência final da cena (cores por bloco, enquadramento da câmera) não foi conferida por humano/screenshot — validação visual pendente via `run.bat`; ~7 fps com 2.109 chunks visíveis nesta configuração (desempenho não é critério desta fatia); shutdown do smoke test por sinal externo (join da worker não exercitado); race benigno conhecido do file logger permanece no backlog desde a VS-01.
- 2026-11-04 — Correção pós-validação (defeito encontrado na inspeção visual humana): chunks totalmente sólidos (todo o subsolo de pedra) geram 1.024 bricks × 4 partes = 4.096 grupos, mas o payload comportava 2.048 — os excedentes eram descartados e a ordem não-determinística do `InterlockedAdd` mudava o conjunto descartado a cada frame (sintomas: faces parciais, blocos piscando). Correções: (1) entradas do payload empacotadas 2×14 bits por word — capacidade 4.096 = pior caso exato, payload inalterado em ≈ 8,2 KiB, sem tipos de 16 bits; (2) culling de oclusão no task shader (brick cheio + 6 vizinhos cheios via B2 → pulado; chunk sólido isolado cai de 4.096 para 520 grupos). Contratos atualizados: REQ-VIS-04, REQ-MESH-01, tabela `TaskPayload`. Evidências: `render_sim.py` estendido (202 checks, incl. empacotamento, oclusão conservadora com vizinho inválido e geometria preservada nos bricks culpados ×6 câmeras), `spirv-val` limpo, smoke test de 45 s com validation layers sem erros (2.109 visíveis, timeline de compute 132/132, readback da VS-01 íntegro).
- 2026-11-04 — Correção pós-validação 2 (diagnosticada com captura RenderDoc/Nsight do mantenedor: faces malformadas em "barbatanas", chunks aparentemente ausentes): `template_vertices` era declarado `StructuredBuffer<float3>` no shader (stride std430 = **16 B**) mas a CPU gravava os vértices compactados a 12 B — do vértice 1 em diante o shader lia floats desalinhados, deformando toda face. Correção: binding 11 passa a `StructuredBuffer<float4>` (xyz usado, w ignorado), upload com stride 16 B e buffer de 16 KiB; comentário de contrato no `common.slang`. Verificado na captura que todos os demais layouts (VisibleChunk 48 B, ChunkHeader 2.064 B, BlockDefinition 48 B, MeshTemplate 32 B, SpecialVoxelRecord 12 B) casavam com os strides do SPIR-V — o defeito era exclusivo dos vértices. Evidências: readback de regressão de `template_vertices` adicionado ao `debug_readback_validate` (16 vértices == built-ins), `spirv-val` limpo, smoke test de 40 s sem erros de validation.
- 2026-11-04 — Correção pós-validação 3 (defeito encontrado na inspeção visual humana: voxels piscando e a geometria inteira renderizada num único local, com z-fighting intermitente): o payload task→mesh chegava **sempre zerado** ao mesh shader neste ambiente (NVIDIA RTX 3050 Laptop, driver Vulkan 1.4.351, slangc 2026.17) — provado por experimentos com payload constante, payloads de 8 e 2.048 words e ambos os atributos de estágio, com SPIR-V correto sob `spirv-dis`/`spirv-val`; um pipeline mesh-only de diagnóstico lendo `visible_chunks` por `SV_GroupID` renderizou a cena corretamente, isolando o defeito no transporte pelo payload. Correção ([[ADR-B10-fila-trabalho-global|ADR-B10]]): eliminados o task shader e o payload; um builder compute na fila gráfica (mesma seleção: ocupação + oclusão B2 + subdivisão) anexa itens de 32 bits num buffer global `work_queue` (binding 17, ring de 2 slots com 8 words de estado), um finalize de 1 thread fecha o `x` do comando indireto com clamp, e o draw passa a `vkCmdDrawMeshTasksIndirectEXT` com um único comando (a variante IndirectCount executaria N comandos lidos da região de itens — derrubou o dispositivo com `ERROR_DEVICE_LOST` na primeira integração). Contratos atualizados: REQ-VIS-03/04, REQ-MESH-01, REQ-PIPE-01/03, tabela de contratos, recursos, sequência do frame, cenários e ACs. Evidências: `render_sim.py` reescrito para o modelo de fila (210 checks), `spirv-val` limpo, readback do estado da fila (append = x = 67.204, y = z = 1, overflow = 0, itens decodificados corretamente) e screenshots com a câmera travada: terreno sólido e estável (duas capturas idênticas a 10 s de intervalo), plano de grama completo ao redor da câmera e vista top-down integralmente coberta; zero erros de validation; readbacks da VS-01 íntegros.
- 2026-11-06 — **Backlog REQ-VIS-04 resolvido pela [[VS-06-culling-frustum|VS-06]]**: o TODO de frustum no `build_work_queue` foi implementado (planos Gribb-Hartmann derivados na GPU no builder, early-out de chunk e culling por brick com p-vertex, ordem vazio → frustum → oclusão), sem alterar nenhum contrato desta spec. Requisito e não escopo atualizados com referência cruzada; detalhes e evidências na VS-06 e na [[ADR-B11-culling-frustum|ADR-B11]].
- 2026-11-06 — **Contrato do item da fila ampliado pela [[VS-09-visible-index-16-bits|VS-09]]** ([[ADR-B12-visible-index-16-bits|ADR-B12]]): `visible_index` passou de 12 para 16 bits — novo layout `visible_index (16b) | brick (10b)<<16 | parte (2b)<<26 | subdivisão (2b)<<28` (30 bits usados, 2 de reserva). Atualizados REQ-MESH-01 e a tabela de contratos acima; pontos de código: `pack_work_item` (`common.slang`) e decode no `build_brick_mesh` (`render.slang`), com o espelho em `tools/sim/render_sim.py`. Nenhuma mudança em bindings, push constants ou estruturas de memória. Evidências na VS-09.
- 2026-11-06 — **Emenda da [[VS-11-uvs-templates|VS-11]]** ([[ADR-U1-uvs-templates-malha|ADR-U1]]): o albedo migra de "sempre triplanar" para "caminho índice→textura→**UV por vértice** do template, com triplanar como **fallback** por sentinela". REQ-SHADE-03 e REQ-MESH-04 (acima) e a tabela de contratos (`MeshVertex` ganha `uv` float2/`TEXCOORD0`, 10 componentes de saída) atualizados; `MeshTemplate` ganha `uv_offset` (reusa um padding, 32 B inalterados) e o set 0 ganha o binding 19 (`template_uvs`, `StructuredBuffer<float2>`, stride 8 B — revisão registrada também no histórico da VS-00). Geometria, culling, orçamento (256v/192t), edição e fila de trabalho inalterados — UV é atributo de saída. Detalhes e evidências (sims, paridade pixel a pixel, validação de carga) na VS-11.
- 2026-11-06 — **Fim do hardcode de blocos/templates ([[VS-12-assets-json|VS-12]], [[ADR-A1-assets-json|ADR-A1]]):** o carregamento de templates, registry e albedo é **data-driven** via `assets/blocks.json` (malhas reaproveizáveis por nome, PNG única por bloco em camadas de `Texture2DArray`, blocos com refs por nome) — `upload_builtin_templates`/`upload_block_registry`/`upload_palette_textures` viram **fallback** quando o JSON está ausente (warning + paridade total, verificada pixel a pixel na VS-12). Os built-ins e a paleta procedural permanecem no código exclusivamente como esse fallback; validações de carga (unitário, limites, UVs) foram reaproveitadas pelo loader com nome de objeto na mensagem. Detalhes e evidências na VS-12.
- 2026-11-08 — **Nota semântica planejada pela [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (ADR-T5 pendente):** `BlockDefinition.padding_2` passa a `albedo_texture_top` (camada +Y mundial ou `0xFFFFFFFF`), e o fragment escolhe top quando `normal.y > 0,5`. O registry continua 48 B/std430, com offsets e bindings inalterados; `padding_3` permanece reservado.

- 2026-11-09 — **Emenda VS-21 consumada (REQ-TEX-05):** `BlockDefinition` passa de **48 B para 72 B** com `albedo_faces[6]` em ordem `FACE_NORMALS` (+X,−X,+Y,−Y,+Z,−Z) no lugar de `albedo_texture_index` + paddings, com `padding_4` de alinhamento; `#assert(size_of(BlockDefinition) == 72)` e espelho Slang atualizados; stride do buffer do registry deriva de `size_of` (capacidade inalterada em 256 entradas).

- 2026-11-09 — **Correção de emenda VS-21:** o registry efetivo é de **80 B** (não 72): o fechamento original com 72 B não espelhava o Slang (float3 alinhado a 16 → emission em 48, stride 96) e foi corrigido com layout de 80 B nos dois lados, `#assert(size_of/offset_of)` e verificação pela reflection do slangc. Stride do buffer deriva de `size_of`.
