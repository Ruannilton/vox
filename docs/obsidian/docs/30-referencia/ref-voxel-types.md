---
id: REF-VOXEL-TYPES
titulo: voxel_types — structs e constantes (contrato Odin↔Slang)
tipo: referencia
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_types.odin` (contrato Odin↔Slang)

Contexto: [[visao-geral]]. Contrato compartilhado entre CPU (Odin) e GPU (Slang) — a fonte única de verdade em `src/engine/voxel_types.odin`, espelhada campo a campo em `src/assets/shaders/common.slang` (ver [[ref-shaders]]). Todo `#assert` de tamanho/offset no Odin deve casar com a reflection do `slangc`; divergência = bug de layout, não aviso. Quem escreve/lê cada campo está indicado por sistema; os seis sistemas são [[sistema-engine-fundacao]], [[sistema-streaming-mundo]], [[sistema-renderizacao]], [[sistema-mirror-fisica]], [[sistema-edicao-eventos]], [[sistema-suporte]].

Ordenação: constantes → structs (GPU-facing primeiro, depois CPU-only) → procs. Specs citadas por código (`VS-XX`).

---

## 1. Constantes

### 1.1 Geometria de chunk e brick

| Constante | Valor | Semântica |
| --- | --- | --- |
| `CHUNK_SIZE` | 32 | Chunk = 32³ voxels (regra 1: voxel sempre 1 unidade³). Espelha `CHUNK_SIZE` (Slang). |
| `CHUNK_VOXEL_COUNT` | 32 768 | Voxels por chunk (`32³`). |
| `BRICKS_PER_CHUNK` | 1024 | Bricks por chunk: 8×16×8 (`BRICKS_PER_CHUNK_AXIS` no Slang). |
| `VOXELS_PER_BRICK` | 32 | Voxels por brick: 4×2×4 (`BRICK_SIZE` no Slang). |

> Os eixos do brick (4, 2, 4) existem **somente** no Slang (`common.slang`); o Odin só carrega os dois totais. As funções de índice (§3) vivem no Slang.

### 1.2 Layout do pool de ocupação (por chunk, em words u32)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `COARSE_WORDS_PER_CHUNK` | 2 | 64 bits de coarse cells (4×4×4 células de 2×4×2 bricks). |
| `SUBDIVISION_WORDS_PER_CHUNK` | 64 | 2 bits de subdivisão por brick (caminho B, VS-01). |
| `OCCUPANCY_WORDS_PER_CHUNK` | 2114 | `2 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK`. |
| `SUBDIVISION_WORD_BASE` | 1026 | Início das words de subdivisão: `BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK`. |
| `SOLID_WORD_BASE` | 1090 | Início das words de solidez: `SUBDIVISION_WORD_BASE + 64`. 1 word de solidez por brick (subset da ocupação; exclui NON_SOLID — VS-14). |

Layout absoluto dentro da word-region de um chunk (binding 2): `[0..1024)` ocupação por brick · `[1024..1026)` coarse · `[1026..1090)` subdivisão · `[1090..2114)` solidez.

### 1.3 Paleta de materiais e registros especiais

| Constante | Valor | Semântica |
| --- | --- | --- |
| `MATERIAL_PLANE_COUNT_MAXIMUM` | 8 | Máximo de planos de material (8 bits de índice de paleta por voxel). |
| `MATERIAL_WORDS_PER_CHUNK` | 8192 | `8 * 1024` words no material plane pool (binding 3). |
| `PALETTE_SIZE_MAXIMUM` | 256 | Entradas máximas da paleta do chunk. Slot 0 é **sempre ar** — nunca reciclado (regra 2). |
| `SPECIAL_RECORDS_PER_CHUNK` | 256 | Máximo de `SpecialVoxelRecord` por chunk. |

### 1.4 Flags de chunk

| Constante | Valor | Semântica |
| --- | --- | --- |
| `CHUNK_FLAG_EMPTY` | 1 | Chunk vazio/virtual — sem alocação real de dados (VS-10). |
| `CHUNK_FLAG_PALETTE_OVERFLOW` | 2 | Paleta estourou; chunk fica **somente-leitura** (regra 6, VS-03). |

### 1.5 Limites do mesh shader e templates (regra 5)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `MESH_VERTEX_MAXIMUM` | 256 | Vértices máximos emitidos por workgroup do mesh shader. |
| `MESH_TRIANGLE_MAXIMUM` | 192 | Triângulos máximos por workgroup. |
| `MAX_TEMPLATE_VERTICES` | 32 | Teto por voxel de template; subdivisão ×4 ⇒ 8·32 = 256. |
| `MAX_TEMPLATE_TRIANGLES` | 24 | Teto por voxel (pior-caso); ×4 ⇒ 8·24 = 192. |
| `TEMPLATE_FLAG_HAS_FLUSH_FACES` | 1 | Bit 0 de `MeshTemplate.flags`: template possui faces de flush (voxel contra vizinho sólido, VS-02). |
| `CULL_FACE_NEVER` | 7 | Face de culling 7 = triângulo nunca culpado (interior/diagonal). Faces 0–5 seguem `FACE_NORMALS` (+X,-X,+Y,-Y,+Z,-Z). |

### 1.6 Flags de bloco (bit 0..1 de `BlockDefinition.flags`, VS-14)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `BLOCK_DEFINITION_FLAG_TRANSPARENT` | 1 | Bit 0 — recorte alpha (folhagem): o fragment descarta `albedo.a < 0.5` (cutout opaco, sem blending). |
| `BLOCK_DEFINITION_FLAG_NON_SOLID` | 2 | Bit 1 — bloco ocupa o voxel mas não é sólido (planta). O bit de ocupação do brick **continua** contendo a planta; a solidez (word de solid no occupancy pool) a exclui. `VoxelSample.solid` e `block_is_solid()` derivam daqui. Emenda 2026-11-07. |

### 1.7 Fila de trabalho e visíveis (VS-06/VS-08)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `NEIGHBOR_SLOT_INVALID` | `max(u32)` | Slot de vizinho ausente ou GENERATING. |
| `WORK_QUEUE_STATE_WORDS` | 8 | Words de estado por slot do ring da fila de trabalho. |
| `WORK_QUEUE_APPEND_COUNT_WORD` | 0 | Índice da word de contagem de appends. |
| `WORK_QUEUE_OVERFLOW_WORD` | 1 | Word de overflow (filtragem com capacidade cheia). |
| `WORK_QUEUE_INDIRECT_X_WORD` | 2 | Word com o X do dispatch indirect. |

Capacidades de visíveis/fila **não** são constantes de compilação (VS-08): vêm do `Config` (raios do INI) e chegam à GPU via `VoxelPushConstants.visible_chunk_capacity`.

### 1.8 Streaming e slots (VS-10)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `SLOT_INDEX_INVALID` | `max(u32)` | Registro EMPTY não possui slot de GPU (REQ-VRT-01). |
| `NEIGHBOR_OFFSETS` | 6 × `ChunkCoordinate` | Offsets de vizinho na ordem de `FACE_NORMALS`: (+1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1). Usado pela filtragem de visíveis na CPU. |

### 1.9 Paletas de textura (VS-21)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `ALBEDO_PALETTE_LAYERS` | 256 | Camadas do Sampler2DArray de albedo. |
| `ALBEDO_PALETTE_LAYER_SIZE` | 16 | Textura da camada é 16×16 (era 4; o sampler NEAREST + UV por face + minificação extrema causavam DEVICE_LOST — correção VS-21; camada = cor sólida). |
| `NO_TEMPLATE_UV_OFFSET` | 0xFFFFFFFF | Template sem pool de UVs; o mesh shader emite a sentinela `float2(-1,-1)` e o fragment cai no triplanar (VS-11). |

### 1.10 Limites do flush de edição (VS-03)

| Constante | Valor | Semântica |
| --- | --- | --- |
| `EDIT_FLUSH_INTERVAL_MS` | 100.0 | Intervalo entre flushes (0 = todo frame). Espelhada no Slang (arrays groupshared). |
| `MAX_EDITS_PER_FLUSH` | 4096 | Edições por flush (16 KiB no ring `voxel_edits`). |
| `MAX_EDIT_JOBS_PER_FLUSH` | 256 | Chunks distintos tocados por flush. |
| `MAX_EDITS_PER_CHUNK_PER_FLUSH` | 1024 | Teto por workgroup/chunk no shader. |

### 1.11 Códigos de resultado da edição

Espelham o Slang; a CPU lê `edit_results` 2 frames após o flush.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `EDIT_RESULT_APPLIED` | 0 | Edição aplicada. |
| `EDIT_RESULT_NOOP` | 1 | Sem efeito (mesmo bloco). |
| `EDIT_RESULT_REJECTED_PALETTE_FULL` | 2 | Paleta cheia — edição rejeitada. |
| `EDIT_RESULT_REJECTED_OVERFLOW` | 3 | Overflow — edição rejeitada. |

---

## 2. Structs

### 2.1 `ChunkCoordinate :: [3]i32`

Coordenada de chunk no mundo (unidades de chunk). Base de todos os índices de chunk na CPU e no push constant.

### 2.2 `ChunkGenerationJob` — 32 B (assert)

Espelha `ChunkGenerationJob` (Slang). Layout (std430):

| Campo | Tipo | Offset | Quem escreve / quem lê |
| --- | --- | --- | --- |
| `chunk_world_origin` | `[3]i32` | 0 | CPU (worker/streaming) preenche; shader de geração (binding 1) lê. |
| `storage_slot_index` | `u32` | 12 | Slot de GPU destino. |
| `mirror_ring_slot` | `i32` | 16 | Slot do ring de export do mirror (-1 = nenhum). |
| `padding` | `[3]u32` | 20 | Alinhamento a 32 B (múltiplo de 16). |

Introduzida em VS-01. Ver [[sistema-streaming-mundo]].

### 2.3 `ChunkHeader` — 2 064 B (assert)

Espelha o Slang. Um header por slot de chunk (binding 4, RW).

| Campo | Tipo | Offset | Semântica / quem escreve |
| --- | --- | --- | --- |
| `palette_size` | `u32` | 0 | Nº de entradas válidas da paleta (≥ 1: slot 0 = ar). Escrito pelo pack (shader) e pelo E1. |
| `plane_count` | `u32` | 4 | Planos de material em uso (≤ 8). |
| `special_voxel_count` | `u32` | 8 | Nº de registros especiais do chunk. |
| `flags` | `u32` | 12 | `CHUNK_FLAG_EMPTY` / `CHUNK_FLAG_PALETTE_OVERFLOW`. |
| `palette` | `[256]u32` | 16 | Índice → block_id. 1 KiB. |
| `refcount` | `[256]u32` | 1040 | Contagem de uso por entrada (regra 3: alocação por claim). 1 KiB. |

Total: 16 B escalares + 1 KiB paleta + 1 KiB refcounts. Introduzida em VS-01.

### 2.4 `SpecialVoxelRecord` — 12 B

Voxel que exige dado além da paleta (formato/orientação). Array em binding 5.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `voxel_index` | `u32` | Índice denso do voxel (layout x-contíguo, §4). |
| `shape_and_orientation` | `u32` | Forma + orientação packed. |
| `block_identifier` | `u32` | Block id. |

### 2.5 `BlockDefinition` — 80 B (asserts de size e offsets)

Registry global de tipos de bloco (binding 7). Espelha byte a byte o Slang (verificável por `offset_of` + reflection do `slangc`). Layout com offsets (asserts: `albedo_faces` @ 12, `emission_color` @ 48, size 80):

| Offset | Campo | Tipo | Semântica |
| --- | --- | --- | --- |
| 0 | `mesh_template_index` | `u32` | Template de malha do bloco (0 = cubo default). |
| 4 | `pbr_texture_index` | `u32` | Camada de PBR (dummy nesta fatia, ADR-B7). |
| 8 | `flags` | `u32` | Bits `TRANSPARENT` (1) / `NON_SOLID` (2). |
| 12 | `albedo_faces` | `[6]u32` | Camada de albedo por face, ordem `FACE_NORMALS` (+X,-X,+Y,-Y,+Z,-Z). VS-21 (REQ-TEX-05): substituiu `albedo_texture_index` + paddings. |
| 36 | `rotation` | `u32` | Rotação yaw padrão (0–3). |
| 40–44 | `padding_2/3` | `u32` | — |
| 48 | `emission_color` | `[3]f32` | Offset múltiplo de 16 (regra de alinhamento float3 do Slang — correção 2026-11-09: sem isso o shader lia o registry desalinhado). |
| 60 | `base_roughness` | `f32` | — |
| 64 | `base_metallic` | `f32` | — |
| 68–76 | `padding_4/5/6` | `u32` | Fecham 80 B (stride múltiplo de 16). |

Quem escreve: `voxel_assets` carrega `blocks.json` → registry (CPU, host-visible). Quem lê: mesh shader (template/flags/rotation), fragment (albedo_faces/emission/PBR). Introduzida em VS-00/VS-02, revisada em VS-21.

### 2.6 `MeshTemplate` — 32 B (assert)

Pool em binding 10. Layout:

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `vertex_offset` | `u32` | Offset no pool `template_vertices` (binding 11). |
| `vertex_count` | `u32` | ≤ `MAX_TEMPLATE_VERTICES`. |
| `triangle_offset` | `u32` | Offset no pool `template_triangles` (binding 12, packed §3). |
| `triangle_count` | `u32` | — |
| `worst_case_tris` | `u32` | Pior-caso pré-computado no load (`compute_worst_case_tris`) — regra 5 garante 256v/192t por subdivisão. |
| `flags` | `u32` | Bit 0 = `TEMPLATE_FLAG_HAS_FLUSH_FACES`. |
| `uv_offset` | `u32` | Offset no pool `template_uvs` (binding 19); `NO_TEMPLATE_UV_OFFSET` = sem UVs (triplanar). VS-11 (REQ-UV-02). |
| `padding_1` | `u32` | — |

Quem escreve: load de assets (CPU). Quem lê: mesh shader.

### 2.7 `VisibleChunk` — 48 B (assert)

Elemento do array de visíveis (binding 6), produzido pela filtragem CPU por frame.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `chunk_world_origin` | `[3]i32` | Origem mundial do chunk. |
| `storage_slot_index` | `u32` | Slot de GPU. |
| `neighbor_slots` | `[6]u32` | Slots dos vizinhos na ordem `FACE_NORMALS`; `NEIGHBOR_SLOT_INVALID` se ausente ou GENERATING. |
| `padding` | `[2]u32` | — |

Introduzida em VS-01 (fila de trabalho); ver [[sistema-renderizacao]].

### 2.8 `EditChunkJob` — 16 B (assert)

Ring de jobs de edição (binding 13). Um job por chunk tocado no flush.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `storage_slot_index` | `u32` | Chunk alvo. |
| `first_edit` | `u32` | Índice global no ring `voxel_edits`/`edit_results`. |
| `edit_count` | `u32` | ≤ `MAX_EDITS_PER_CHUNK_PER_FLUSH`. |
| `padding` | `u32` | — |

Introduzida em VS-03. Ver [[sistema-edicao-eventos]].

### 2.9 `VoxelPushConstants` — 92 B (assert)

Push constants de voxel.slang/render.slang/edit.slang. Casar com o pipeline layout da VS-00 (88 B + `visible_chunk_capacity`, REQ-CFG-06/VS-08).

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `view_projection_matrix` | `matrix[4,4]f32` | VP column-major (a mesma usada no frustum Gribb-Hartmann, VS-06). |
| `camera_position` | `[3]f32` | — |
| `visible_chunk_offset` | `u32` | Offset no ring de visíveis (base do slot corrente). |
| `batch_job_offset` | `u32` | Offset de jobs de geração. |
| `edit_job_offset` | `u32` | Offset de jobs de edição. |
| `visible_chunk_capacity` | `u32` | Capacidade do ring (derivada de \|esfera(vision)\|, VS-08). |

### 2.10 Structs CPU-only (não espelhadas no Slang)

**`MirrorPageState :: enum u8`** — estado da página do mirror (VS-04):
- `PENDING_READBACK` — export em vôo (ou aguardando slot de ring); leitura desconhecida.
- `MATERIALIZED` — aberta a leituras; atualizada pelo journal do E1.

**`VoxelSample`** — amostra tri-state de gameplay (VS-20):
- `block_id: u16`
- `solid: bool` — derivado do registry (bit NON_SOLID, VS-14 emenda).

**`MirrorChunkPage`** — 71 824 B (assert, VS-13; era 68,14 KiB). Página do mundo na RAM (mirror, regra 7 — ver §4):

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `coord` | `ChunkCoordinate` | Posição do chunk. |
| `edit_seq` | `u32` | Revisão do journal aplicada (paridade com GPU em debug). |
| `state` | `MirrorPageState` | Ver acima. |
| `ring_slot` | `i32` | Slot do ring de export reservado (-1 = nenhum). |
| `pending` | `[dynamic]VoxelEditRequest` | Edições ainda não materializadas. |
| `applied_log` | `[dynamic]VoxelEditRequest` | Journal de aplicadas (E1). |
| `rejected_log` | `[dynamic]VoxelEditRequest` | Journal de rejeitadas. |
| `solid` | `[1024]u32` | 4 KiB — bit por voxel sólido por registry (NON_SOLID exclui planta). |
| `ids` | `[32768]u16` | 64 KiB densos — block_id por voxel, **índice y-contíguo** `y|z<<5|x<<10`. |
| `heights` | `[1024]u16` | Heightmap da coluna (VS-13, REQ-MIR-02): **índice z-contíguo `x|z<<5`**; y do sólido mais alto, 0xFFFF = coluna vazia. |

**`MirrorRingEntry`** — slot do ring de export:
- `used: bool`
- `coord: ChunkCoordinate`
- `generation: u32` — anti-ABA: casa com a geração do slot de GPU no pedido (regra 3: 1 claim = 1 lote = 1 timeline).

---

## 3. Procs

### 3.1 `pack_voxel_edit(voxel_index, block_id) -> u32` (VS-03)

Edição packed: `voxel_index & 0x7FFF` (15 bits, layout denso **x-contíguo** `x|z<<5|y<<10`) | `block_id << 16`. Escrito pela CPU no ring `voxel_edits`; decodificado pelo shader de edição.

### 3.2 `pack_template_triangle(v0, v1, v2, cull_face) -> u32` (VS-02)

Triângulo packed: bits `[0..8)` v0 | `[8..16)` v1 | `[16..24)` v2 | `[24..27)` face de culling (0–5 = `FACE_NORMALS`, 7 = `CULL_FACE_NEVER`). Pool `template_triangles`.

### 3.3 `compute_worst_case_tris(packed_triangles) -> u32`

Pior-caso de triângulos para qualquer direção de câmera: triângulos `CULL_FACE_NEVER` +, por eixo, `max(face+, face-)`. Usado no load para preencher `MeshTemplate.worst_case_tris` (regra 5 — não se assume culling direcional).

### 3.4 `validate_template(vertices, packed_triangles) -> bool` (VS-02)

Validação de carga de template: ≤ 32 vértices, pior-caso ≤ 24 triângulos, e todos os vértices dentro do voxel unitário `[0,1]³` (regra 1).

### 3.5 `validate_template_uvs(template_index, uvs) -> bool` (VS-11, REQ-UV-04a)

UVs, quando presentes, em `[0,1]²`; a sentinela (-1,-1) é interna ao mesh shader e nunca aparece num template. Erro logado nomeia template e vértice.

---

## 4. Os três layouts de índice (regra 7 — não misturar)

Três linearizações diferentes coexistem por propósito:

| Layout | Fórmula | Onde |
| --- | --- | --- |
| **x-contíguo (denso GPU / scratch)** | `x \| z<<5 \| y<<10` | `voxel_edits` (pack_voxel_edit), índice denso lido pelos shaders (`dense_index_from_coordinate` no Slang). |
| **y-contíguo (mirror)** | `y \| z<<5 \| x<<10` | `MirrorChunkPage.ids` — o mundo na RAM. |
| **z-contíguo (heightmap)** | `x \| z<<5` | `MirrorChunkPage.heights` e `mirror_heightmap_ring` (binding 20, VS-13) — por coluna (x,z). |

E os índices de brick (Slang): `brick_index = x + 8*(z + 8*y)`; bit dentro do brick: `x + 4*(z + 4*y)` (4×2×4).

## 5. Invariantes

- Todo `#assert` de tamanho/offset em `voxel_types.odin:201-210` é verificado em toda compilação — são o contrato executável Odin↔Slang.
- Slot 0 da paleta é ar, sempre (regra 2); `block_id 0` nunca é sólido (`block_is_solid` no Slang).
- `CHUNK_FLAG_PALETTE_OVERFLOW` ⇒ chunk somente-leitura (regra 6).
- Registry 80 B e stride múltiplo de 16 — adicionar campos exige reespelhar o Slang e revisitar os offsets (regressão 2026-11-09).
