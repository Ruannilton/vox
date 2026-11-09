---
id: REF-VOXEL-GPU
titulo: "Referência: voxel_gpu — repositório de recursos GPU"
tipo: referencia
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_gpu` — repositório de recursos GPU

Módulo: `src/engine/voxel_gpu.odin` (package `engine`). Contém o acervo de buffers, imagens, pipelines e o descriptor set **shared** que alimenta todo o pipeline de voxels (worldgen, pack, edição, mesh, fragment). É o "inventário" do motor: ele não orquestra trabalho (isso é [[ref-voxel-engine-worker|voxel_engine/worker]]) nem desenha (isso é [[ref-voxel-render|voxel_render]]) — ele **cria, carrega e nomeia** os recursos.

Contexto: [[visao-geral]], [[sistema-engine-fundacao]], [[sistema-renderizacao]], [[sistema-suporte]].

---

## Constantes e dados built-in

| Símbolo | Valor | Papel |
| --- | --- | --- |
| `BLOCK_REGISTRY_CAPACITY` | 256 | Capacidade fixa do `block_registry` (256 definições de bloco). |
| `MESH_TEMPLATE_CAPACITY` | 256 | Capacidade fixa do `mesh_templates`. |
| `BUILTIN_CUBE_VERTICES` | `[24][3]f32` | Cubo built-in: 24 vértices (4 por face), UV implícito `[0,1]²` por face (correção VS-21 — a projeção planar da VS-11 deixava U/V constantes nas laterais). |
| `BUILTIN_CUBE_TRIANGLES` | `[12][4]u32` | 12 triângulos do cubo; o 4º componente é o índice de face (0–5, ordem `FACE_NORMALS`) usado na triagem de faces ocultas. Winding outward corrigido na VS-21 (+X e −Z). |
| `BUILTIN_PLANT_VERTICES` | `[8][3]f32` | Planta built-in: 2 quads diagonais em cruz. |
| `BUILTIN_PLANT_TRIANGLES` | `[4][4]u32` | 4 triângulos da planta; índice de face = `CULL_FACE_NEVER` (sempre desenhada, sem culling por face). |

---

## `VoxelGpu` — a struct central

Instância global única `voxel_gpu: VoxelGpu`. Todos os campos são criados em `voxel_gpu_init` e destruídos em `voxel_gpu_destroy`.

### Buffers

| Campo | Binding | Uso / por que existe |
| --- | --- | --- |
| `scratch` | 0 | Grid denso u32 de trabalho (`config.scratch_chunks × 32768`). Alvo do `generate_voxels` e fonte do `pack_chunk`. Layout **x-contíguo** (diferente do mirror y-contíguo — regra 7 do AGENTS.md). |
| `generation_jobs` (host-mapped) | 1 | Um `ChunkGenerationJob` por chunk em geração; a CPU escreve e a compute consome. Mapeado (`generation_jobs_mapped`). |
| `occupancy_pool` | 2 | Bitmask de ocupação por slot residente (`config.resident_slots × OCCUPANCY_WORDS_PER_CHUNK`). `TRANSFER_SRC/DST` — fonte de readback de debug e exportação. |
| `material_plane_pool` | 3 | Planos de bits de paleta por slot (`MATERIAL_WORDS_PER_CHUNK` words). Codificação packed que o mesh shader decodifica. |
| `chunk_headers` | 4 | Um `ChunkHeader` por slot (paleta, `plane_count`, flags). |
| `special_voxel_records` | 5 | Registros de voxels especiais por slot (`SPECIAL_RECORDS_PER_CHUNK`). |
| `block_registry` | 6 | 256 `BlockDefinition` (template de mesh, faces de albedo, flags). `TRANSFER_DST` — preenchido uma vez no init. |
| `visible_chunks` (host-mapped) | 7 | Lista de chunks visíveis por frame em voo (`NUM_FRAMES_IN_FLIGHT × config.visible_capacity`); a CPU monta o frame e a compute consome. |
| `mesh_templates` | 10 | 256 `MeshTemplate` (offsets de vértices/triângulos/UVs, `worst_case_tris`, flags). |
| `template_vertices` | 11 | Pool de vértices dos templates (stride 16 B, `float4` std430). |
| `template_triangles` | 12 | Pool de triângulos packed (`pack_template_triangle`: índices + face). |
| `template_uvs` | 19 | Pool de UVs paralelo a `template_vertices`, indexado por `MeshTemplate.uv_offset` (VS-11). `TRANSFER_SRC` para o readback de validação (VS-12). |
| `work_queue` | 17 | Fila de trabalho indireta por frame em voo (`NUM_FRAMES_IN_FLIGHT × config.work_queue_slot_words`). `INDIRECT_BUFFER` — consumida pelo draw mesh. |
| `edit_jobs` (host-mapped) | 13 | `EditChunkJob` por flush (`NUM_FRAMES_IN_FLIGHT × MAX_EDIT_JOBS_PER_FLUSH`). |
| `voxel_edits` (host-mapped) | 14 | Edições voxel a voxel (`MAX_EDITS_PER_FLUSH` por frame). |
| `edit_results` (host-mapped) | 15 | Feedback por edição. `HOST_ACCESS_RANDOM` — a CPU lê o resultado **2 frames depois**. |
| `mirror_export_ring` (host-mapped) | 16 | Ring de exportação denso u16 (`config.mirror_ring_slots × 32768`). 1 claim = 1 slot; só o handler de conclusão libera (regra 4). |
| `mirror_heightmap_ring` (host-mapped) | 20 | Ring paralelo de heightmaps u16 (1.024 por slot, 2 KiB); **mesmo índice de slot** do ring denso (VS-13). |
| `chunk_result_flags` (host-mapped) | 18 | Flags de resultado do pack por slot residente (VS-10). `HOST_ACCESS_RANDOM` — CPU lê após a timeline do lote (B1). |
| `target_highlight_ubo` (host-mapped) | 21 | UBO dinâmico do realce de alvo (VS-20). `NUM_FRAMES_IN_FLIGHT` slots com stride `target_highlight_alignment` (≥ `minUniformBufferOffsetAlignment`); o offset do slot vem do bind por frame. |
| `dummy_buffer` | — | Buffer de 16 B sem binding — placeholder para writes/binds que precisam de um handle válido. |

### Imagens e sampler

| Campo | Binding | Papel |
| --- | --- | --- |
| `albedo_palette_image` (+ allocation/view) | 8 | `Texture2DArray` R8G8B8A8: uma camada por textura de albedo (ordem de definição no JSON) ou as camadas de paleta procedural do fallback (VS-12). Uso `SAMPLED | TRANSFER_DST | TRANSFER_SRC` (o `SRC` é para o readback de paridade, VS-21). |
| `pbr_dummy_image` (+ allocation/view) | 9 | Textura 1×1 preta que ocupa o slot PBR do layout — o caminho de amostragem PBR existe sem custo real. |
| `texture_sampler` | 8/9 | `NEAREST` sem mipmaps (texel nítido, `maxLod = 0`), `REPEAT` nos 3 eixos (VS-21, REQ-TEX-03). |

### Vulkan "plumbing"

| Campo | Papel |
| --- | --- |
| `descriptor_pool` / `descriptor_set` | Pool com `maxSets = 1` e o único descriptor set do módulo, compartilhado por todos os pipelines. |
| `shader_module` | `voxel.spv` — entry points `generate_voxels` e `pack_chunk`. |
| `edit_shader_module` | `edit.spv` — entry point `main`. |
| `render_shader_module` | `render.spv` — entry points compute `build_work_queue`/`finalize_work_queue` e gráficos `build_brick_mesh`/`shade_voxel`. |
| `generation_pipeline` | Compute `generate_voxels` (worldgen no scratch). |
| `packing_pipeline` | Compute `pack_chunk` (scratch denso → occupancy/planos/header). |
| `build_work_queue_pipeline` | Compute `build_work_queue` (monta a fila indireta do frame). |
| `finalize_work_queue_pipeline` | Compute `finalize_work_queue`. |
| `edit_pipeline` | Compute `main` do `edit.spv` (aplica edições). |
| `mesh_pipeline` | Pipeline gráfico mesh/fragment criado por `voxel_render_pipeline_create()` (ver [[ref-voxel-render]]). |
| `compute_command_pool` | Pool da família compute, flags `TRANSIENT | RESET_COMMAND_BUFFER`. |
| `compute_command_buffers` | `[config.batches_in_flight]` (VS-08, REQ-CFG-05). O **índice 0** é reusado como command buffer one-shot de staging/upload/readback no init e nos debugs. |

---

## `voxel_gpu_init` — ordem e por quê

1. **Command pool + buffers** (`config.batches_in_flight`, VS-08) — precisam existir antes de tudo porque os uploads de assets usam `compute_command_buffers[0]`.
2. **Criação de todos os buffers** — tamanhos derivados do `Config` (VS-08); host-mapped onde a CPU escreve/lê diretamente. `target_highlight_alignment` = `max(256, minUniformBufferOffsetAlignment)`.
3. **Upload de assets com fallback built-in** — se `voxel_assets.loaded` (VS-12): `upload_asset_templates` + `upload_asset_registry` + `upload_asset_textures`; senão: `upload_builtin_templates` + `upload_block_registry` + `upload_palette_textures`. Paridade total entre os dois caminhos.
4. **Módulos de shader + pipelines** — assets antes, pipelines depois; `voxel_render_pipeline_create()` por último dos pipelines.
5. **Descriptor pool/set** — pool com 3 `poolSizes` (STORAGE × `DESCRIPTOR_SET_BINDING_COUNT`, COMBINED_IMAGE_SAMPLER × 2, UNIFORM_BUFFER_DYNAMIC × 1) e writes (ver abaixo).
6. **Telemetria de nomes** — `telemetry_name_object` em buffers e pipelines (VK_EXT_debug_utils, via [[ref-physics-tracing|telemetry]]).
7. **`debug_texture_parity()`** — validação da textura ao final do init, com device recém-populado.

## `voxel_gpu_destroy` — ordem inversa

Descriptor pool → pipelines (mesh, edit, finalize, build, pack, generate) → módulos de shader → free/destroy do command pool → sampler → views/imagens VMA → **todos os buffers na ordem inversa da criação** → zera a struct global. Invariante: nenhum trabalho em voo (chamado no shutdown do engine).

---

## Helper de buffer e staging/upload

| Proc | Visibilidade | Contrato |
| --- | --- | --- |
| `gpu_buffer_create` | package (`gpu_buffer.odin`) | Cria `GpuBuffer` device-local via VMA (`usage = .AUTO`, sem flags). |
| `gpu_buffer_destroy` | package | `vma.DestroyBuffer` + zera a struct; no-op se handle vazio. |
| `gpu_buffer_create_host` | privada | Wrapper de `gpu_buffer_create_host_flags` com `HOST_ACCESS_SEQUENTIAL_WRITE | .MAPPED`. |
| `gpu_buffer_create_host_flags` | privada | Cria buffer mapeado com flags VMA arbitrárias; retorna o ponteiro mapeado (`info.pMappedData`). |
| `upload_to_device_buffer` | privada | Staging host-mapped → `CmdCopyBuffer` → submit na fila compute → `DeviceWaitIdle`. Caminho síncrono de upload; usado no init e nos readbacks. |
| `gpu_image_2d_array_create` | privada | `R8G8B8A8_UNORM`, 1 mip, `OPTIMAL`, uso `SAMPLED|TRANSFER_DST|TRANSFER_SRC`. Se as famílias graphics/compute diferirem, `sharingMode = .CONCURRENT` com as duas famílias. |
| `gpu_image_2d_array_view_create` | privada | View `D2_ARRAY` sobre todas as camadas. |
| `upload_to_device_image` | privada | Staging → barrier `UNDEFINED→TRANSFER_DST_OPTIMAL` → `CmdCopyBufferToImage` → barrier `→SHADER_READ_ONLY_OPTIMAL` → submit + `DeviceWaitIdle`. |
| `load_shader_module` | privada | Lê arquivo `.spv` do disco e cria o `vk.ShaderModule`. |

Todos os uploads/readbacks de debug usam `compute_command_buffers[0]` com `ONE_TIME_SUBMIT` e espera síncrona (`DeviceWaitIdle`/`QueueWaitIdle`) — código de init/validação, não de hot path.

---

## Upload de assets e fallback built-in

Duas famílias mutuamente exclusivas, selecionadas por `voxel_assets.loaded` (VS-12):

**Assets (`assets/blocks.json` presente):**
- `upload_asset_templates` — templates, vértices (stride 16), triângulos e UVs do JSON para os pools 10–12 e 19.
- `upload_asset_registry` — `voxel_assets.registry` (array de 256 `BlockDefinition`) para o binding 6.
- `upload_asset_textures` — cria a `Texture2DArray` de albedo (uma camada por textura, ordem de definição), o dummy PBR 1×1 e o sampler; sobe `texture_pixels` já flipado. Zone Tracy `assets_texture_decode`. Caminho de amostragem (índice de camada + UV) idêntico ao do fallback — **zero mudança de shader** (REQ-AST-03/05).

**Fallback built-in (paridade total com o JSON):**
- `upload_builtin_templates` — 3 templates: índice 0 = AR (`NO_TEMPLATE_UV_OFFSET`, nada emite), 1 = cubo (24 vértices, 12 triângulos, `TEMPLATE_FLAG_HAS_FLUSH_FACES`), 2 = planta (8 vértices, 4 triângulos). Monta os arrays de vértices/UVs (cubo 24 + planta 8 = 32) e triângulos packed (12 + 4 = 16), validando tudo com `validate_template` / `validate_template_uvs` (`log.assert`).
- `upload_block_registry` — registry procedual: 1 = grama (cubo, top = camada 1 grama, demais faces camada 2 terra, ordem `FACE_NORMALS`), 2 = terra, 3 = pedra, 4 = planta (template cruz, `TRANSPARENT | NON_SOLID`, camada 4 — VS-14).
- `upload_palette_textures` — paleta procedural `ALBEDO_PALETTE_LAYER_SIZE² × ALBEDO_PALETTE_LAYERS` camadas: 0 preto (AR), 1 grama, 2 terra, 3 pedra, 4 planta; mais o dummy PGR preto 1×1.

---

## Descriptor set — writes por binding

Único set, layout `app.descriptorSetLayout`, pool `maxSets = 1`. Escrita uma vez no init:

- **Bindings 0–7, 10–20**: `STORAGE_BUFFER`, `range = WHOLE_SIZE`, escritos em loop sobre `binding_buffers` (pulando 8/9 e 21).
- **Binding 8**: `COMBINED_IMAGE_SAMPLER` com `albedo_palette_view` + sampler.
- **Binding 9**: `COMBINED_IMAGE_SAMPLER` com `pbr_dummy_view` + sampler.
- **Binding 21**: `UNIFORM_BUFFER_DYNAMIC`, `range = target_highlight_alignment` (stride do slot; o offset do frame vem do bind dinâmico no command buffer gráfico — VS-20).

Um único `vk.UpdateDescriptorSets` aplica todas as writes. O layout e os bindings espelham [[ref-shaders|common.slang]], fonte única de verdade dos layouts.

---

## Pipelines

| Pipeline | Módulo / entry point | Papel |
| --- | --- | --- |
| `generation_pipeline` | `voxel.spv` / `generate_voxels` | Worldgen GPU: escreve o grid denso no `scratch`. |
| `packing_pipeline` | `voxel.spv` / `pack_chunk` | Compacta scratch → occupancy + planos de material + header por slot. |
| `build_work_queue_pipeline` | `render.spv` / `build_work_queue` | Monta a fila de trabalho indireta do frame a partir dos chunks visíveis. |
| `finalize_work_queue_pipeline` | `render.spv` / `finalize_work_queue` | Finaliza a fila (contagens/offsets) após o build. |
| `edit_pipeline` | `edit.spv` / `main` | Aplica o lote de edições (jobs + voxel_edits → edit_results). |
| `mesh_pipeline` | `render.spv` / `build_brick_mesh` + `shade_voxel` | Pipeline gráfico mesh/fragment; criado em `voxel_render_pipeline_create` ([[ref-voxel-render]]), destruído aqui. |

Todos os computes usam `app.computePipelineLayout` — o mesmo layout do descriptor set acima.

---

## Debug readback e paridade

Validações síncronas (staging + copy + wait) disparadas no init ou sob demanda. O **F7** (`key_handler` em `main.odin`) chama `debug_validate_run` + `debug_heights_parity` (VS-19, AC-04).

| Proc | Visibilidade | O que valida |
| --- | --- | --- |
| `debug_readback_validate` | privada | Escolhe um chunk concluído (preferência: página `MATERIALIZED` na faixa y ≤ 0) e faz dois readbacks. **(a)** `template_vertices` (+ `template_uvs` quando há assets) contra os dados-fonte (JSON ou built-ins — VS-12). **(b)** Header + occupancy + planos do slot; se a página do mirror está `MATERIALIZED`, decodifica o packed voxel a voxel (mesmo decode bit a bit de `tools/sim/pack_sim.py`) e compara com o grid denso u16 do mirror, incluindo o bit sólido (mirror exclui planta — VS-14). Sem página, só invariantes estruturais. Checa também o **invariante AR**: `palette[0] == 0`. A CPU nunca reproduz o worldgen — a comparação é sempre packed×denso, ambos derivados do mesmo scratch GPU (C2). |
| `debug_texture_parity` | package | Readback da `albedo_palette_image` (barrier `SHADER_READ_ONLY_OPTIMAL → TRANSFER_SRC_OPTIMAL → …` de volta) e comparação byte a byte com `voxel_assets.texture_pixels` (flip incluído — VS-21, AC-01/AC-04). Executada ao final de todo `voxel_gpu_init`. Sem assets, checagem estrutural apenas (pula). |
| `debug_texture_validate` | package | Ponto de entrada público: apenas chama `debug_texture_parity`. |
| `debug_validate_run` | package | Ponto de entrada público da validação packed×denso (a rotina é privada deste arquivo); usada pelo hook F7. |
| `debug_readback_decode_voxels` | privada | Readback de header+planos e log do id decodificado de voxels locais específicos (diagnóstico pontual). |
| `debug_mirror_parity` | privada | Mesma decodificação packed, comparando os 32.768 voxels do chunk contra a página do mirror (índice y-contíguo, regra 7). |
| `debug_heights_parity` | package — em `voxel_mirror.odin` | Varredura CPU-only em todas as páginas `MATERIALIZED`: `heights[x\|z<<5]` deve ser o topo sólido derivado do bitmask de sólidos (0xFFFF se coluna vazia). Acionada pelo F7 ao lado de `debug_validate_run`. |

---

## Telemetria de nomes

Ao final do init, `telemetry_name_object` ([[ref-physics-tracing|telemetry.odin]], VK_EXT_debug_utils) nomeia os handles para o renderdoc/validation layer/Tracy GPU:

- **Buffers**: `scratch_dense`, `occupancy_pool`, `material_plane_pool`, `chunk_headers`, `visible_chunks`, `work_queue`, `edit_jobs`, `voxel_edits`, `edit_results`, `mirror_export_ring`, `mirror_heightmap_ring`, `chunk_result_flags`, `template_uvs`, `target_highlight_ubo`.
- **Pipelines**: `pipeline_generate`, `pipeline_pack`, `pipeline_apply_voxel_edits`, `pipeline_build_work_queue`, `pipeline_finalize_work_queue`, `pipeline_mesh_draw`.

Note que `generation_jobs`, `mesh_templates`, `template_vertices`, `template_triangles`, `block_registry`, `special_voxel_records`, `voxel_edits` (parcial) e `dummy_buffer` **não** recebem nome — ao adicionar um buffer novo, siga a lista acima ou a estenda conscientemente.

---

## Vizinhos

- [[ref-engine]] — `app` (device, filas, VMA, layouts), `vk_check`.
- [[ref-voxel-types]] — `ChunkGenerationJob`, `EditChunkJob`, `VisibleChunk`, `ChunkHeader`, `MeshTemplate`, `BlockDefinition` e as constantes de words por chunk.
- [[ref-voxel-render]] — criação/uso do `mesh_pipeline` e da fila de trabalho.
- [[ref-assets-config-events]] — `voxel_assets`, `config` (dimensionamento VS-08).
- [[ref-shaders]] — bindings 0–21 espelhados em `common.slang`.
