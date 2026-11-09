---
id: SISTEMA-RENDERIZACAO
titulo: Renderização
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Renderização

Como o motor desenha o mundo: a decisão de geometria-como-dado, a fila de trabalho global, o mesh shader que monta a malha on-the-fly e o fragment que a pinta. Contexto macro: [[visao-geral]]. Detalhe de structs/procs: [[ref-voxel-render]] (Odin), [[ref-shaders]] (Slang: bindings, structs, entry points).

## Por que data-driven

A renderização nasceu de uma decisão arquitetural ([[VS-02-task-mesh-templates|VS-02]]): **a geometria não é armazenada, é gerada por mesh shader a cada frame a partir de dicionários** — `BlockDefinition` (mesh template + texturas por face + flags + rotação) e `MeshTemplate` (pools de vértices/triângulos/UVs). O que a VRAM guarda por chunk é só o comprimido do pack: bitmask de ocupação, paleta de ids (slot 0 = ar) e planos de material ([[sistema-streaming-mundo]]).

Na validação visual da VS-02, o transporte da seleção por **payload task→mesh** provou-se quebrado no driver (o payload chegava zerado). A [[ADR-B10-fila-trabalho-global|ADR-B10]] substituiu o estágio task por uma **fila de trabalho global**: um builder compute anexa itens `(chunk visível, brick, parte, subdivisão)` num buffer device-local e o draw é mesh indireto de **comando único** (`vk.CmdDrawMeshTasksIndirectEXT`, `voxel_render_record` em `src/engine/voxel_render.odin:267`). O `finalize_work_queue` fecha o `x` do comando indireto com clamp — fila vazia vira `x = 0` (no-op). Cuidado registrado na ADR: `CmdDrawMeshTasksIndirectCountEXT` tem semântica de N comandos, não de "um comando com x = count".

## A sequência no frame (main)

`voxel_render_prepare` grava no command buffer gráfico (`src/engine/voxel_render.odin:82`):

1. **Edições pendentes** (se houver): dispatch de `apply_voxel_edits` + barreira compute→compute.
2. **Reset da fila**: `CmdFillBuffer` zera as 8 words de estado do slot do ring do frame + barreira.
3. **builder** (`build_work_queue`, compute na fila gráfica): 1 workgroup de 128 threads por chunk visível, dispatch com `visible_count`.
4. **finalize** (`finalize_work_queue`, 1 thread): grava o comando indireto com clamp na capacidade.
5. Barreira compute → draw indireto/mesh.

Depois `voxel_render_record` liga a pipeline, o UBO de highlight (offset dinâmico por frame, VS-20) e os push constants, e emite o draw indireto. A espera da timeline de compute usa `COMPUTE_SHADER | MESH_SHADER_EXT` — quem primeiro lê a ocupação é o builder (consequência da ADR-B10).

## O builder: culling vazio → frustum → oclusão

`build_work_queue` (`src/assets/shaders/render.slang:9`) seleciona quais bricks entram na fila, na ordem [[VS-06-culling-frustum|VS-06]]:

1. **Early-out de chunk**: planos do frustum derivados por Gribb-Hartmann da **mesma** `view_projection_matrix` dos push constants (`frustum_planes_from_vp`, `common.slang:238`) — o frustum testado é exatamente o renderizado. Teste conservador p-vertex (`aabb_outside_frustum`): só cull se o AABB estiver inteiramente fora de um plano. Uniforme no workgroup, sem divergência; chunk fora retorna antes de ler header/ocupação.
2. **Culling de vazio**: word de ocupação do brick = 0 (e flag `CHUNK_FLAG_EMPTY` do header).
3. **Culling de frustum por brick**: mesmo teste sobre o AABB 4×2×4 do brick.
4. **Culling de oclusão** ([[ADR-B2-fronteiras-chunks|B2]]): `is_brick_occluded` — só cull bricks 100% ocupados, 100% sólidos, com os 6 vizinhos também 100% sólidos.

Brick sobrevivente contribui `1 << subdivisão` itens (subdivisão de 2 bits gravada pelo pack, caminho B — até 4 partes × 8 voxels). Contagem e escrita usam scan exclusivo em groupshared: thread 0 faz o scan serial e reserva a faixa do chunk com um único `InterlockedAdd` no contador global; a fase de escrita rederiva os itens deterministicamente. Estouro seta a word de overflow e os itens além da capacidade são descartados (clamps tanto no builder quanto no finalize).

Os itens são **u32** no layout `16|10|2|2` — `visible_index (16b) | brick (10b) | parte (2b) | subdivisão (2b)` ([[VS-09-visible-index-16-bits|VS-09]], [[ADR-B12-visible-index-16-bits|ADR-B12]]). O limite prático de formato é `vision ≤ 25` (esfera de r=25 ≈ 65 mil visíveis); a capacidade vem do push constant `visible_chunk_capacity`, derivada do INI ([[VS-08-config-ini-provisionamento|VS-08]]).

## O mesh shader: montagem por template

`build_brick_mesh` (`render.slang:125`): 1 workgroup por item (32 threads = `VOXELS_PER_BRICK`), 1 thread por voxel (ou por fração do brick quando subdividido). Cada thread:

- resolve o item por `SV_GroupID` e o chunk por `visible_index`;
- lê o id do bloco na paleta (`read_block_identifier`) e o template (`mesh_templates`);
- para templates com `TEMPLATE_FLAG_HAS_FLUSH_FACES`, computa a **máscara de faces visíveis** (`compute_visible_face_mask`): face emitida só se o vizinho não for sólido **e** a câmera estiver do lado de fora do plano da face;
- conta triângulos que sobrevivem ao culling por tag de face (com rotação yaw aplicada via `ROTATED_FACE`).

Scan em groupshared dá os offsets de vértice/triângulo de cada thread; thread 0 chama `SetMeshOutputCounts`. A emissão posiciona os vértices do template com `rotate_vertex_yaw` no canto mundo do voxel e grava `clip_position` com a mesma VP do frustum.

**Orçamento garantido por construção** (regra 5): templates limitados a 32 vértices/24 triângulos por voxel, e o pack subdivide qualquer brick que excederia — por isso a pipeline pode fixar `MESH_VERTEX_MAXIMUM = 256` / `MESH_TRIANGLE_MAXIMUM = 192` por workgroup e o culling direcional nunca precisa ser assumido. A rasterização usa `CULL_MODE_NONE`: o culling por face é por tags no mesh shader, não por winding.

**UVs** ([[VS-11-uvs-templates|VS-11]], [[ADR-U1-uvs-templates-malha|ADR-U1]]): templates com pool de UVs (binding 19) emitem a UV do pool; sem pool (`uv_offset == NO_TEMPLATE_UV_OFFSET`) emitem a sentinela `(-1,-1)` e o fragment cai no triplanar — mods procedurais sem unwrap continuam funcionando.

## O fragment: seleção de camada por face

`shade_voxel` (`render.slang:233`):

1. **Normal por derivadas de tela** (`ddx`/`ddy` de `world_position`), corrigida por `faceforward` pela câmera (a derivada aponta para dentro; sem o sinal, a seleção de face trocava +/− — correção da VS-21 para a convenção y-down de Vulkan).
2. **Camada por face** ([[VS-21-texturas-nearest-flip-stb-faces|VS-21]], [[ADR-T5-texturas-stb-face|ADR-T5]]): eixo dominante da normal mundial (maior |componente|; empate determinístico Y, X, Z; sinal escolhe ±) indexa `BlockDefinition.albedo_faces[6]` em ordem `FACE_NORMALS` (+X, −X, +Y, −Y, +Z, −Z). "Topo" é +Y mundial, não eixo local após rotação.
3. **Amostragem NEAREST** (sampler único, `maxLod = 0`) — estética pixelada deliberada; texturas decodificadas por stb com flip Y explícito ([[ADR-T5-texturas-stb-face|ADR-T5]]). Com UV amostra a camada por UV; com a sentinela, cai no triplanar sobre posição mundo.
4. **Alpha-test cutout** ([[VS-14-plantas-alpha-test-spawn|VS-14]], [[ADR-P1-plantas-alpha-test-spawn|ADR-P1]]): blocos com `BLOCK_DEFINITION_FLAG_TRANSPARENT` descartam fragmentos com `albedo.a < 0.5` (limiar fixo). Cutout opaco — sem blending nem ordenação; `CULL_MODE_NONE` permanece (as duas faces das plantas em X são necessárias). A solidez é separada (`NON_SOLID`, bit 1) da ocupação.
5. **Shading**: Lambert com luz direcional fixa + ambiente 0.2 + `emission_color`.
6. **Highlight da mira** ([[VS-20-gameplay-selecao-construcao-pulo|VS-20]]): `floor(world_position)` igual ao voxel-alvo publicado no UBO `target_highlight` (binding 21, offset dinâmico por frame) clareia a cor em 1.4×; `target_valid = 0` (miss/fora da bolha) é bit a bit o caminho antigo.

Saída opaca (`alpha = 1`), depth `LESS` com escrita.

## Fronteiras entre chunks (B2)

`VisibleChunk` carrega `neighbor_slots[6]` (mesma ordem de `FACE_NORMALS`), preenchidos pela CPU a cada frame com os slots dos vizinhos `CACHED`/`RENDERABLE` ([[ADR-B2-fronteiras-chunks|ADR-B2]]). `resolve_brick_slot` redireciona leituras de ocupação/solidez fora do chunk ao vizinho publicado; vizinho ausente ou em geração (`NEIGHBOR_SLOT_INVALID`) é tratado como ar — a geometria é corrigida naturalmente um frame depois, porque é reconstruída on-the-fly. O culling de oclusão e a máscara de faces usam esse mesmo redirecionamento (nível de brick e de voxel).

## Contratos de trabalho

- **`BlockDefinition` — 80 B** (std430, espelhado Odin/Slang byte a byte): template, flags, `albedo_faces[6]`, rotação, `emission_color` (float3 alinhado a 16), roughness/metallic. Cresceu 48→72 B na VS-21 (6 faces) e a 80 B pela correção de alinhamento (2026-11-09).
- **`PushConstants` — 92 B**: `view_projection_matrix` (64), `camera_position` (12), `visible_chunk_offset`, `batch_job_offset`, `edit_job_offset`, `visible_chunk_capacity`. Estágios: mesh + fragment no gráfico (compute usa só `.COMPUTE`).
- **Bindings de render**: 6 (`visible_chunks`), 8 (`block_albedo_textures`, sampler 2D array), 17 (`work_queue`), 18 (`chunk_result_flags`), 19 (`template_uvs`), 20 (`mirror_heightmap_ring`), 21 (`target_highlight`, UBO com offset dinâmico por frame). Templates e registry: 10–12 e 7.

## Coordenação

O ring de 2 frames da fila de trabalho só é reescrito após a timeline gráfica confirmar o uso anterior; a main renderiza com o último publish válido da worker e nunca espera uma rodada inteira ([[visao-geral]], [[sistema-streaming-mundo]]). A telemetria GPU (`telemetry_timestamp_begin/end`) e as zones Tracy (`build_work_queue`, `finalize_work_queue`, `draw_mesh`) marcam os quatro passos por frame.

## Genealogia

- Specs: [[VS-02-task-mesh-templates|VS-02]] (templates + fila), [[VS-06-culling-frustum|VS-06]] (frustum), [[VS-09-visible-index-16-bits|VS-09]] (item 16 bits), [[VS-11-uvs-templates|VS-11]] (UVs), [[VS-14-plantas-alpha-test-spawn|VS-14]] (alpha-test), [[VS-20-gameplay-selecao-construcao-pulo|VS-20]] (highlight), [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (faces/NEAREST/flip).
- ADRs: B10 (fila global), B11 (frustum no builder), B12 (visible_index 16 bits), B2 (fronteiras), U1 (UVs com fallback), P1 (cutout), T5 (stb/flip/NEAREST/6 faces).
