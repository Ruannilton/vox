---
id: REF-SHADERS
titulo: "Referência: shaders Slang (bindings, structs, entry points)"
tipo: referencia
ultima_atualizacao: 2026-11-09
---

# Referência: shaders Slang

Arquivos: `src/assets/shaders/common.slang` (fonte única de verdade de constantes, layouts e helpers — importado por todos os outros), `voxel.slang` (worldgen + pack), `render.slang` (fila de trabalho, mesh e fragment), `edit.slang` (edições E1) e `lib/FastNoiseLite.slang` (ruído da worldgen). Compilação Slang → `bin/*.spv` via `run.bat`; o espelhamento Odin dos contratos está em [[ref-voxel-types]] (asserts de tamanho/offset) e [[ref-voxel-gpu]] (buffers, descriptor set e pipelines).

Contexto: [[visao-geral]], [[sistema-renderizacao]], [[sistema-streaming-mundo]], [[sistema-edicao-eventos]].

---

## `common.slang` — constantes e layouts

### Constantes numéricas

| Símbolo | Valor | Papel |
| --- | --- | --- |
| `CHUNK_SIZE` | 32 | Chunk cúbico; voxel = 1 unidade³ (regra 1). |
| `CHUNK_VOXEL_COUNT` | 32.768 | Voxels por chunk. |
| `BRICK_SIZE` | (4, 2, 4) | Brick de 32 voxels. |
| `VOXELS_PER_BRICK` | 32 | |
| `BRICKS_PER_CHUNK_AXIS` | (8, 16, 8) | |
| `BRICKS_PER_CHUNK` | 1024 | |
| `BRICKS_PER_COARSE_CELL` | (2, 4, 2) | 16 bricks por coarse cell. |
| `COARSE_CELLS_PER_CHUNK` | 64 | Células 4×4×4. |
| `COARSE_WORDS_PER_CHUNK` | 2 | |
| `SUBDIVISION_WORDS_PER_CHUNK` | 64 | 2 bits de subdivisão por brick (caminho B). |
| `OCCUPANCY_WORDS_PER_CHUNK` | 2114 | Layout do pool por slot: `[0..1024)` ocupação por brick, `[1024..1026)` coarse cells, `[1026..1090)` subdivisão (`SUBDIVISION_WORD_BASE`), `[1090..2114)` solidez (`SOLID_WORD_BASE`). |
| `MATERIAL_PLANE_COUNT_MAXIMUM` | 8 | Planos de bits de paleta. |
| `MATERIAL_WORDS_PER_CHUNK` | 8192 | 8 × 1024. |
| `PALETTE_SIZE_MAXIMUM` | 256 | Slot 0 é sempre AR (regra 2 / invariante B3). |
| `BLOCK_PRESENCE_WORDS` / `PACK_THREADS` / `PRESENCE_WORDS_PER_THREAD` | 2048 / 128 / 16 | Cobertura de presença de blocos no pack. |
| `SPECIAL_RECORDS_PER_CHUNK` | 256 | Escape para paleta cheia. |
| `CHUNK_FLAG_EMPTY` / `CHUNK_FLAG_PALETTE_OVERFLOW` | 1 / 2 | Flags do header; chunk com overflow é somente-leitura (regra 6). |
| `MESH_VERTEX_MAXIMUM` / `MESH_TRIANGLE_MAXIMUM` | 256 / 192 | Orçamento mesh shader por subdivisão (regra 5). |
| `MAX_TEMPLATE_VERTICES` / `MAX_TEMPLATE_TRIANGLES` | 32 / 24 | Pior caso por voxel; ×4 (subdivisão máx) = 256/192. |
| `TEMPLATE_FLAG_HAS_FLUSH_FACES` | 1 | Template com faces flush que participam do face-culling. |
| `CULL_FACE_NEVER` | 7 | Triângulo nunca cullado (interior/diagonal). |
| `BLOCK_DEFINITION_FLAG_TRANSPARENT` | 1 | Cutout alpha no fragment (VS-14). |
| `BLOCK_DEFINITION_FLAG_NON_SOLID` | 2 | Ocupado mas não sólido (planta). |
| `NO_TEMPLATE_UV_OFFSET` | 0xFFFFFFFF | Template sem pool de UVs → triplanar (VS-11). |
| `NEIGHBOR_SLOT_INVALID` | 0xFFFFFFFF | Vizinho sem slot publicado. |
| `WORK_QUEUE_STATE_WORDS` | 8 | Header da fila por frame. |
| `WORK_QUEUE_APPEND_COUNT_WORD` / `_OVERFLOW_WORD` / `_INDIRECT_X_WORD` | 0 / 1 / 2 | |
| `MAX_EDITS_PER_FLUSH` / `MAX_EDIT_JOBS_PER_FLUSH` / `MAX_EDITS_PER_CHUNK_PER_FLUSH` | 4096 / 256 / 1024 | |
| `EDIT_HASH_CAPACITY` / `_EMPTY` / `_TOMBSTONE` | 512 / 0xFFFFFFFF / 0xFFFFFFFE | Load factor ≤ 0,5. |
| `EDIT_REFCLAIMED` | 0x80000000 | Refcount reivindicado em fluxo (anti-ABA da alocação). |
| `EDIT_SLOT_NOOP` / `EDIT_SLOT_REJECTED` / `EDIT_COUNTED_FLAG` | 0xFFFFFFFF / 0xFFFFFFFE / 0x80000000 | Sentinelas de `shared_edit_new_slot`. |
| `EDIT_RESULT_*` | 0–3 | Códigos de resultado lidos pela CPU 2 frames depois. |

### Structs (std430, espelhadas em Odin — [[ref-voxel-types]])

| Struct | Layout / asserts Odin | Campos |
| --- | --- | --- |
| `ChunkGenerationJob` | 32 B (`#assert` 32) | `chunk_world_origin` int3 @0, `storage_slot_index` u32 @12, `mirror_ring_slot` i32 @16, padding[3] @20. |
| `ChunkHeader` | 2064 B | `palette_size`, `plane_count`, `special_voxel_count`, `flags` + `palette[256]` + `refcount[256]`. |
| `SpecialVoxelRecord` | 12 B | `voxel_index`, `shape_and_orientation`, `block_identifier`. |
| `BlockDefinition` | 80 B | `mesh_template_index` @0, `pbr_texture_index` @4, `flags` @8, `albedo_faces[6]` @12 (ordem `FACE_NORMALS`, camada por face VS-21), `rotation` @36, padding @40–44, `emission_color` float3 @48 (alinhado a 16), `base_roughness` @60, `base_metallic` @64, padding @68–76. |
| `MeshTemplate` | 32 B | `vertex_offset`, `vertex_count` (≤32), `triangle_offset`, `triangle_count`, `worst_case_tris`, `flags` (bit 0 = flush faces), `uv_offset` (VS-11; `NO_TEMPLATE_UV_OFFSET` = sem pool), padding. |
| `PushConstants` | 92 B (ver abaixo) | |
| `VisibleChunk` | 48 B | `chunk_world_origin` int3, `storage_slot_index`, `neighbor_slots[6]` (ordem `FACE_NORMALS`), padding[2]. |
| `EditChunkJob` | 16 B | `storage_slot_index`, `first_edit`, `edit_count` (≤1024), padding. |
| `MeshVertex` | saída do mesh shader | `clip_position` (SV_Position), `world_position` (normais por derivadas), `block_id`, `uv` (TEXCOORD0; `(-1,-1)` = sentinela triplanar). 10 componentes, distante do limite de `maxMeshOutputComponents`. |
| `TargetHighlight` (binding 21) | 16 B, UBO | `target_voxel` int3 + `target_valid` (VS-20). |

### Push constants — `PushConstants`, 92 B

| Campo | Offset (B) | Tamanho | Uso |
| --- | --- | --- | --- |
| `view_projection_matrix` (column_major float4x4) | 0 | 64 | Frustum (VS-06) e transformação de vértices; mesma matriz nos dois caminhos. |
| `camera_position` (float3) | 64 | 12 | Face-visível por voxel e correção de sinal da normal. |
| `visible_chunk_offset` | 76 | 4 | Índice-base do ring de visíveis do frame em voo. |
| `batch_job_offset` | 80 | 4 | Índice-base do lote de jobs de geração/edição. |
| `edit_job_offset` | 84 | 4 | Índice-base dos `EditChunkJob`. |
| `visible_chunk_capacity` | 88 | 4 | Capacidade do frame (VS-08, REQ-CFG-06); usado para derivar o slot do ring da fila. |

Assert Odin: `#assert(size_of(VoxelPushConstants) == 92)` em `src/engine/voxel_types.odin:210`.

### Bindings 0–21 (set 0; escritos em `voxel_gpu_init`, [[ref-voxel-gpu]])

| B | Buffer (recurso) | Tipo | Quem escreve → quem lê |
| --- | --- | --- | --- |
| 0 | `scratch_dense` | RW u32 | `generate_voxels` → `pack_chunk` (grid denso x-contíguo, regra 7). |
| 1 | `generation_jobs` (host-mapped) | RO `ChunkGenerationJob` | CPU → `generate_voxels`, `pack_chunk`. |
| 2 | `occupancy_pool` | RW u32 | `pack_chunk`/`edit` → `build_work_queue`, `build_brick_mesh` (ocupação/coarse/subdivisão/solidez). |
| 3 | `material_plane_pool` | RW u32 | `pack_chunk`/`edit` → `build_brick_mesh` (decode de paleta). |
| 4 | `chunk_headers` | RW `ChunkHeader` | `pack_chunk`/`edit` → mesh, edits, debug readback. |
| 5 | `special_voxel_records` | RW `SpecialVoxelRecord` | `pack_chunk` (paleta cheia) → consumidores de especiais. |
| 6 | `visible_chunks` (host-mapped) | RO `VisibleChunk` | CPU (frame) → `build_work_queue`, `build_brick_mesh`. |
| 7 | `block_registry` | RO `BlockDefinition` | CPU (init, assets/fallback) → `pack_chunk`, `edit`, mesh, fragment. |
| 8 | `albedo_palette_image` + sampler | `Sampler2DArray` | CPU (upload) → `shade_voxel` (UV/triplanar). |
| 9 | `pbr_dummy_image` + sampler | `Sampler2DArray` | CPU → placeholder PBR (ADR-B7, dummy nesta fatia). |
| 10 | `mesh_templates` | RO `MeshTemplate` | CPU → `pack_chunk`, `edit`, mesh. |
| 11 | `template_vertices` | RO float4 | CPU → mesh (posições locais, stride 16 B). |
| 12 | `template_triangles` | RO u32 packed | CPU → mesh (índices 3×8 bits + face 3 bits). |
| 13 | `edit_jobs` (host-mapped) | RO `EditChunkJob` | CPU → `apply_voxel_edits`. |
| 14 | `voxel_edits` (host-mapped) | RO u32 packed | CPU → `apply_voxel_edits`. |
| 15 | `edit_results` (host-mapped) | RW u32 | `apply_voxel_edits` → CPU (ring, lida 2 frames depois). |
| 16 | `mirror_export_ring` (host-mapped) | RW u16 | `generate_voxels` → CPU/mirror. 1 claim = 1 slot; só o handler de conclusão libera (regra 4). |
| 17 | `work_queue` | RW u32 | `build`/`finalize_work_queue` → `build_brick_mesh` (dispatch indireto). |
| 18 | `chunk_result_flags` (host-mapped) | RW u32 | `pack_chunk` → CPU (pós-timeline do lote, VS-10). |
| 19 | `template_uvs` | RO float2 | CPU → mesh (UVs, stride 8 B; VS-11). |
| 20 | `mirror_heightmap_ring` (host-mapped) | RW u16 | `generate_voxels` → CPU/mirror (mesmo índice de slot do 16, VS-13). |
| 21 | `target_highlight_ubo` (host-mapped, UBO dinâmico) | RO `TargetHighlight` | CPU (1×/frame) → `shade_voxel` (VS-20). |

---

## Helpers de `common.slang` (cada função)

- **`work_queue_base_words()`** — base do slot do ring da fila do frame em voo: `(visible_chunk_offset / visible_chunk_capacity) × (WORK_QUEUE_STATE_WORDS + visible_chunk_capacity × BRICKS_PER_CHUNK)`. Derivação pura do push constant (VS-08).
- **Helpers de índice — três layouts distintos (regra 7):**
  - `brick_index_from_coordinate` / `brick_coordinate_from_index` — índice de brick: `x + 8(z + 8y)` (linear).
  - `bit_index_from_local_coordinate` / `local_coordinate_from_bit_index` — bit dentro do brick (4×2×4): `x + 4(z + 4y)`.
  - `dense_index_from_coordinate` / `coordinate_from_dense_index` — **scratch GPU x-contíguo**: `x \| z<<5 \| y<<10`. Usado entre `generate_voxels` e `pack_chunk` e na decodificação de edições.
  - `mirror_index_from_coordinate` — **mirror y-contíguo**: `y \| z<<5 \| x<<10`. Não misturar com o denso.
  - `coarse_cell_index_from_brick_coordinate` — brick → célula 4×4×4.
- **Occupancy/solid:** `read_brick_occupancy` e `read_brick_solidity` leem o pool com clamp de coordenada fora do chunk (retornam 0); `is_voxel_solid_local` testa o bit de solidez no brick local.
- **`resolve_brick_slot` / `read_brick_solidity_b2` (redirecionamento B2)** — resolve (slot, coord local) de um brick vizinho entre chunks a partir de `neighbor_slots[6]`; falso se o vizinho não tem slot. `read_brick_solidity_b2` retorna 0 nesse caso. Anti-ABA de vizinho é coord+geração no host (regra 3).
- **`brick_voxels_all_solid`** — word de solidez == 0xFFFFFFFF.
- **`is_brick_occluded`** — um brick só é ocultado se ocupação cheia (0xFFFFFFFF), todos os voxels sólidos **e** os 6 bricks vizinhos (via B2) também cheios e sólidos; vizinho sem slot → não ocultado (conservador).
- **`block_is_solid(block_id)`** — id 0 (AR) nunca é sólido; `NON_SOLID` (planta) também não. Solidez é propriedade do tipo de bloco.
- **`is_voxel_solid(slot, coord, neighbor_slots)`** — solidez pré-calculada por bit (sem decodificar paleta): redireciona coordenadas fora do chunk ao vizinho (B2 em nível de voxel); sem vizinho → não sólido.
- **`compute_visible_face_mask`** — para cada face cujo vizinho **não** é sólido, testa se a câmera está do lado da face (plano no eixo dominante); máscara bit por face (`1<<face_index`).
- **`frustum_planes_from_vp`** — Gribb-Hartmann sobre a **mesma** VP que transforma vértices (o frustum testado é o renderizado, REQ-CULL-01). Convenção Vulkan (z_ndc ∈ [0,1]), ordem left/right/bottom/top/near/far, planos normalizados. Atenção documentada: `vp[i]` é a **linha** i (indexação HLSL) — sem transposição; a versão que transpunha culpava geometria visível.
- **`aabb_outside_frustum`** — p-vertex clássico (REQ-CULL-04): só culla se o AABB está inteiramente fora de um único plano; AABBs que intersectam nunca são culados.
- **`pack_work_item` / decode (VS-09, REQ-WID-01)** — item de 32 bits: `visible_index(16) | brick_index(10) | part(2) | subdivision(2)`; decodificado no início do mesh shader.
- **`rotate_vertex_yaw`** — rotação yaw por quadrantes (r=1: `(x,z) → (z, 1−x)`); `ROTATED_FACE[24]` mapeia face cullada pela mesma rotação.
- **`triangle_survives_culling`** — face do triângulo nos 3 bits altos; `CULL_FACE_NEVER` sempre passa; senão aplica `ROTATED_FACE[rotation*6 + face]` contra a máscara de faces visíveis.
- **`read_block_identifier` / `read_palette_index_at`** — decodificam o índice de paleta varrendo `plane_count` planos de bits (bit do brick em cada plano) e indexam `header.palette[]` com clamp em `palette_size` (clamp defensivo; AR=0 fora do alcance).
- **`sample_triplanar_albedo` (render.slang)** — projeção triplanar: pesos `|n|` normalizados, amostra `zy/xz/xy` da camada do bloco, combinação ponderada. Fallback quando UV é a sentinela.

---

## `voxel.slang` — worldgen e pack

### `generate_voxels` — compute, `numthreads(8,8,8)`

- **Thread mapping:** cada grupo = fatia 8×8×8×4 (4 chunks em z por dispatch); `chunk_in_batch = tid.z / 32`, `local_z = tid.z % 32`. Cada thread gera **um voxel**; coord local `(tid.x, tid.y, local_z)`.
- **Groupshared:** `heights_gs[8][8]` (128 B/workgroup) — altura de coluna calculada 1× pelas threads com `local_id.y == 0` (64/workgroup), depois de barrier todas leem (VS-13, equivalência bit a bit com o caminho antigo).
- **Fases:** (1) ruído 2D OpenSimplex2 (freq 0.02, ×10) + Perlin (freq 0.07, ×5) → `height = 32 + h1 + h2`; (2) export do heightmap no ring 20 (topo **sólido** local, `0xFFFF` = coluna vazia — planta não conta, VS-14); (3) classificação do voxel: acima da altura → planta (id 4) se `y == height+1` e `plant_spawns(x,z)`, senão AR; `y < height−8` → pedra (3); `y < height` → terra (2); `y == height` → grama (1); (4) escrita no scratch denso (binding 0, índice x-contíguo) e no ring do mirror (binding 16, índice y-contíguo) quando `mirror_ring_slot >= 0`.
- **Invariantes:** `plant_spawns` é wang hash pura de (x,z) mundial — fronteira entre chunks nasce igual dos dois lados; probabilidade 10%.

### `pack_chunk` — compute, `numthreads(128,1,1)`, 1 workgroup por chunk

Groupshared: `shared_block_presence[2048]`, `shared_presence_prefix[2048]`, `shared_block_partials[128]`, `shared_palette_blocks[256]`, `shared_palette_size`, `shared_refcount[256]`.

Fases (todas com `GroupMemoryBarrierWithGroupSync` entre elas):

1. **Init** — zera presença/refcounts/partials, zera coarse+subdivisão no pool.
2. **Passagem por brick (8 steps)** — cada thread processa 8 bricks: monta word de ocupação e word de **solidez** (bit ligado se o bloco não é `NON_SOLID`; planta ocupa mas não é sólida), marca presença global dos blocos, acumula vértices/triângulos por part (8 voxels cada) e decide a **subdivisão**: total > 256v/192t → 1; pior metade também estoura → 2 (regra 5 — garantia por subdivisão, sem culling direcional assumido). Grava occupancy/solidity e o campo de 2 bits de subdivisão.
3. **Coarse cells** — `InterlockedOr` no bit da coarse cell para todo brick ocupado.
4. **Prefixo de presença** — parciais por thread, scan serial pela thread 0, prefixo running por thread (`palette_rank_of_block` = prefixo da word + popcount abaixo do bit).
5. **Header** — thread 0: `palette_count = min(distintos, 255) + 1` (slot 0 = AR, regra 2), `plane_count = ceil(log2)`, flags `EMPTY`/`PALETTE_OVERFLOW`; escreve header e `chunk_result_flags[slot]` (VS-10).
6. **Paleta** — espalha blocos presentes por rank em `shared_palette_blocks` e copia para o header.
7. **Planos** — zera `plane_count × 1024` words do pool de material.
8. **Codificação voxel a voxel (256 steps)** — rank+1 = índice de paleta; se exceder a paleta, grava `SpecialVoxelRecord` (escape); senão `InterlockedOr` do bit nos planos correspondentes ao índice e refcount++.
9. **Refcount do AR** — `refcount[0] = CHUNK_VOXEL_COUNT − sólidos` e cópia final dos refcounts para o header.

---

## `render.slang` — fila de trabalho, mesh, fragment

### `build_work_queue` — compute, `numthreads(128,1,1)`, 1 grupo por chunk visível

Groupshared: `shared_item_offsets[1024]`, `shared_chunk_item_total`, `shared_chunk_item_base`.

1. **Early-out de chunk** (REQ-CULL-02, teste uniforme): fora do frustum → return; `CHUNK_FLAG_EMPTY` → return.
2. **Seleção por brick** (REQ-CULL-03, ordem vazio → frustum → oclusão): para cada um dos 8 bricks da thread, `item_count = 1 << subdivisão` se passar; grava count em `shared_item_offsets`.
3. **Scan serial** pela thread 0 → offset de cada brick no lote do chunk.
4. **Alocação global:** thread 0 faz `InterlockedAdd` no `APPEND_COUNT` do ring do frame; marca `OVERFLOW` se extrapolar a capacidade.
5. **Emissão:** cada brick sobrevivente emite `parts` itens `pack_work_item(...)` em posições `base + offset + part`, guardadas pela capacidade.

### `finalize_work_queue` — compute, `numthreads(1,1,1)`

Grava os 3 words de dispatch indireto: X = `min(append_count, capacidade × 1024)`, Y = Z = 1.

### `build_brick_mesh` — mesh shader, `numthreads(32,1,1)`

- **Thread mapping:** 32 threads = até 32 voxels do brick; com subdivisão `s`, `voxels_in_group = 32 >> s` e threads excedentes ficam inativas (`active = local_id.x < voxels_in_group`); `voxel_slot = part × voxels_in_group + local_id.x` seleciona o subconjunto do brick.
- **Decode do item** (16|10|2|2) → `visible_index`, `brick_idx`, `part`, `subdivision_log2`.
- **Contagem por thread:** decodifica `block_id` via planos de material; se o template tem triângulos: com `HAS_FLUSH_FACES`, computa `face_mask` (visível pela câmera e com vizinho não-sólido via B2); conta triângulos que sobrevivem ao culling; `t_cnt > 0 → v_cnt = vertex_count`.
- **Scan serial** (thread 0, 32 entradas) → offsets de vértice/triângulo e totais; `SetMeshOutputCounts(total_v, total_t)`. Limites 256v/192t garantidos pela subdivisão decidida no pack/edit (regra 5).
- **Emissão de vértices:** posição local rotacionada (`rotate_vertex_yaw` por `def.rotation`), + `voxel_min_world`, clip via VP; `uv = template_uvs[uv_offset + i]` ou sentinela `(-1,-1)` (sem pool → triplanar, VS-11).
- **Emissão de triângulos:** índices 3×8 bits + offset do primeiro vértice; reaplica o culling com a `face_mask` compartilhada.

### `shade_voxel` — fragment

1. Normal por derivadas de tela (`ddx/ddy` de `world_position`); correção de sinal por `faceforward` pela câmera (Vulkan y-down aponta para dentro — sem correção o topo recebia a face errada, VS-21).
2. **Face por eixo dominante** (REQ-TEX-06): maior `|componente|`; empate determinístico Y, X, Z; sinal escolhe ±; seleciona `albedo_faces[face_index]` (camada por face em `FACE_NORMALS`).
3. **Amostragem:** com UV (`uv.x >= 0`) amostra por UV; com a sentinela, triplanar.
4. **Alpha-test** (REQ-PLT-01): bloco `TRANSPARENT` descarta `albedo.a < 0.5` — cutout opaco, sem blending (CULL_MODE_NONE permanece).
5. Shading Lambert + ambiente 0.2 + `emission_color` (campos PBR `base_roughness`/`base_metallic` e binding 9 ainda não usados no shading — dummy ADR-B7).
6. **Realce do alvo** (VS-20): `target_valid && floor(world_position) == target_voxel` → `color × 1.4`.

---

## `edit.slang` — `apply_voxel_edits` (E1)

Compute, `numthreads(128,1,1)`, 1 grupo por `EditChunkJob` (chunk tocado no flush). Groupshared: cópia da paleta/refcount, hash aberto de 512 buckets (chave → slot), arrays por edição (`new_slot`, `old_index`), dirty bricks, e escalares de estado.

**Hash:** `edit_hash_bucket` (multiplicativo, máscara 511); `edit_hash_reserve` (reserva com `InterlockedCompareExchange`, probing linear que ignora tombstones); `edit_hash_tombstone`; `edit_hash_wait_slot` (spin ≤ 4096 até a publicação do slot). Proprietário do bucket aloca via `edit_alloc_slot`: varre slots com refcount 0, marca `EDIT_REFCLAIMED`, limpa o hash do bloco antigo, publica `hash_slot` **antes** de liberar o claim (ordem que evita ABA), sem slot → `EDIT_SLOT_REJECTED`. `edit_claim_slot`/`edit_resolve_slot` resolvem com retries defensivos (contenção patológica → rejeitado).

**Fases do entry point:**

- **Fase 0 — cache do header:** copia paleta/refcount para shared (normalizando slots mortos para 0), zera hash e dirty bricks. Se `PALETTE_OVERFLOW` (regra 6: somente-leitura), rejeita todas as edições com `EDIT_RESULT_REJECTED_OVERFLOW` e sai. Depois publica os slots vivos existentes no hash.
- **Fase 1 — resolve:** por edição (`voxel_index` 15 bits | `new_block` 16 bits): lê índice de paleta antigo pelos planos, NOOP se bloco igual; senão resolve/aloca slot para o bloco novo (flag `EDIT_COUNTED_FLAG` marca refcount já contado).
- **Crescimento de planos:** se `palette_size` exigir mais planos, zera as words novas e atualiza `plane_count`.
- **Fase 2 — aplica:** por edição, flipa bits nos planos (`InterlockedOr/And`), atualiza occupancy e a word de **solidez** via `block_is_solid`, marca brick sujo, ajusta refcounts (novo +1 se não contado, antigo −1), escreve `EDIT_RESULT_APPLIED`.
- **Fechamento:** OR da occupancy → flag `EMPTY`; recompute das coarse cells (64 threads × 16 bricks); cópia dos refcounts de volta ao header (claim interrompido → 0, defensivo); thread 0 atualiza flags/`palette_size`/`plane_count`; **redecisão da subdivisão só dos bricks sujos** (mesma regra 256v/192t do pack), reescrita atômica dos 2 bits.

---

## `lib/FastNoiseLite.slang`

Port Slang da FastNoiseLite (Auburn/FastNoise). Funções usadas pelo motor:

- `fnlCreateState(seed = 1337)` — cria o estado com defaults (único construtor válido, por nota do próprio header).
- `fnlGetNoise2D(state, x, y)` — amostra ruído 2D com o estado.
- Campos configurados: `frequency` e `noise_type` (`FNL_NOISE_OPENSIMPLEX2`, `FNL_NOISE_PERLIN`).

**Estado por valor:** `fnlGetNoise2D` recebe `fnl_state` **por valor** — a struct não é modificada pela amostragem; apenas `fnlDomainWarp*` recebe `inout`. Isso permite criar o estado uma vez por coluna (VS-13, REQ-GEN-02) e reusá-lo; `fnlGetNoise3D` e domain warp existem na lib mas não são usados pelo motor hoje.

---

## Espelhamento Odin — onde cada contrato é assertido

| Contrato | Onde |
| --- | --- |
| Tamanhos/offsets das structs std430 (`ChunkGenerationJob` 32, `ChunkHeader` 2064, `BlockDefinition` 80 com `albedo_faces` @12 e `emission_color` @48, `MeshTemplate` 32, `VisibleChunk` 48, `EditChunkJob` 16, `VoxelPushConstants` 92) | `#assert`s em `src/engine/voxel_types.odin:201–210`. |
| Constantes numéricas (`OCCUPANCY_WORDS_PER_CHUNK`, `MATERIAL_WORDS_PER_CHUNK`, etc.) | Redeclaradas em `src/engine/voxel_types.odin:13–18` e usadas no dimensionamento de buffers em `voxel_gpu.odin` e `config.odin`. |
| Bindings 0–21 e descriptor set | Writes em `voxel_gpu_init` ([[ref-voxel-gpu]] — seção "Descriptor set"); binding 21 como `UNIFORM_BUFFER_DYNAMIC`. |
| Orçamento mesh (256v/192t) e validação de templates | `validate_template` / `validate_template_uvs` (`log.assert`) nos uploads de `voxel_gpu.odin`. |
| Invariante AR (`palette[0] == 0`) | Checado no readback de debug (`debug_readback_validate`) e garantido por construção no pack/edit. |
| Layout y-contíguo do mirror (regra 7) | Índice `y\|z<<5\|x<<10` no shader × `debug_mirror_parity`/`debug_heights_parity` na CPU ([[ref-voxel-gpu]], VS-19). |
| Decode bit a bit do pack | Espelhado em `tools/sim/pack_sim.py` e no readback packed×denso (mesmo scratch GPU, C2). |

---

## Origem (specs e ADRs)

- VS-00 (fundação Vulkan), VS-01 (streaming generate/pack), VS-02 (task/mesh/templates), VS-03 (edição E1), VS-04 (mirror C2), VS-06 (culling/frustum), VS-08 (config/INI), VS-09 (visible index 16 bits), VS-10 (chunks vazios/virtuais), VS-11 (UVs/templates), VS-12 (assets JSON), VS-13 (heightmap/mirror), VS-14 (plantas/alpha-test), VS-20 (gameplay/seleção), VS-21 (texturas/faces) — em `docs/obsidian/especificacoes/`.

## Vizinhos

- [[ref-voxel-types]] — structs e constantes espelhadas com os asserts.
- [[ref-voxel-gpu]] — buffers, descriptor set, pipelines, uploads e debug readback.
- [[sistema-renderizacao]] · [[sistema-streaming-mundo]] · [[sistema-edicao-eventos]] — comportamento integrado.
