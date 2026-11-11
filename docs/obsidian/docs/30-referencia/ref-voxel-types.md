---
id: REF-VOXEL-TYPES
titulo: voxel_types — structs e constantes (contrato Odin↔Slang)
tipo: referencia
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_types.odin` (contrato Odin↔Slang)

Antes de qualquer tabela, vale entender **o que é um contrato espelhado** — porque é o padrão que organiza este arquivo inteiro.

Você já viu em [[visao-geral]] que o motor tem dois mundos: a CPU (Odin) e a GPU (Slang). Para a GPU trabalhar sobre os dados do mundo, ambos precisam concordar, byte a byte, sobre como cada struct está disposta na memória: qual campo vem primeiro, quantos bytes ele ocupa, qual o offset do próximo. Se a CPU gravar um `u32` onde a GPU espera um `f32`, ou se um campo andar 4 bytes para a esquerda, o shader lê lixo — e o bug é silencioso: nenhum crash, só voxels errados na tela.

A solução deste projeto é o **espelhamento com prova**: o arquivo `src/engine/voxel_types.odin` é a *fonte única de verdade*. Cada constante e cada struct dele é reescrita campo a campo em `src/assets/shaders/common.slang` (o shader correspondente está em [[ref-shaders]]). E o Odin contém **`#assert`s de tamanho e offset** — verificações executadas em toda compilação — que garantem que o layout Odin casa com o que o compilador Slang (`slangc`) reporta via reflection. Ou seja: o contrato não é um comentário que pode apodrecer; ele é *provado* a cada build. Se alguém mudar um campo e esquecer de reespelhar, a compilação quebra — e é isso que transforma "divergência de layout" de bug sutil em erro de build.

Regra prática para mexer aqui: **toda mudança de layout exige reespelhar o Slang e revisitar os asserts**. Houve uma regressão real em 2026-11-09 (registry desalinhado lido pelo shader) por causa de um campo que perdeu o alinhamento de 16 bytes — o §5 lista os invariantes que evitam repetir isso.

Quem escreve e quem lê cada campo está indicado por sistema; os seis sistemas são [[sistema-engine-fundacao]], [[sistema-streaming-mundo]], [[sistema-renderizacao]], [[sistema-mirror-fisica]], [[sistema-edicao-eventos]], [[sistema-suporte]].

Ordenação: constantes → structs (GPU-facing primeiro, depois CPU-only) → procs. Specs citadas por código (`VS-XX`); a genealogia de cada uma está em `../especificacoes/`.

---

## 1. Constantes

### 1.1 Geometria de chunk e brick

*Por que existe:* o mundo é infinito e regenerável, mas a GPU opera sobre blocos fixos de trabalho. Este contrato fixa o tamanho desses blocos para CPU e GPU — quem consome é todo o resto do arquivo: os pools de dados por chunk (§1.2), os índices de brick (§4) e o orçamento do mesh shader (§1.5) derivam destes números.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `CHUNK_SIZE` | 32 | Chunk = 32³ voxels (regra 1 do `AGENTS.md`: voxel sempre 1 unidade³). Espelha `CHUNK_SIZE` (Slang). |
| `CHUNK_VOXEL_COUNT` | 32 768 | Voxels por chunk (`32³`). |
| `BRICKS_PER_CHUNK` | 1024 | Bricks por chunk: 8×16×8 (`BRICKS_PER_CHUNK_AXIS` no Slang). |
| `VOXELS_PER_BRICK` | 32 | Voxels por brick: 4×2×4 (`BRICK_SIZE` no Slang). |

> Os eixos do brick (4, 2, 4) existem **somente** no Slang (`common.slang`); o Odin só carrega os dois totais. As funções de índice (§3) vivem no Slang.

### 1.2 Layout do pool de ocupação (por chunk, em words u32)

*Por que existe:* a VRAM guarda o mundo *packed* (compacto), não denso — em vez de um id por voxel, cada chunk vive como bitmask de ocupação por brick + coarse + subdivisão + solidez. Este contrato diz *onde cada uma dessas regiões começa* dentro da word-region do chunk, para que pack (compute) e mesh shader calculem o mesmo endereço. Quem grava é o passo de pack ([[sistema-renderizacao]]); quem lê é o mesh shader e o builder da fila de trabalho.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `COARSE_WORDS_PER_CHUNK` | 2 | 64 bits de coarse cells (4×4×4 células de 2×4×2 bricks). |
| `SUBDIVISION_WORDS_PER_CHUNK` | 64 | 2 bits de subdivisão por brick (caminho B, VS-01). |
| `OCCUPANCY_WORDS_PER_CHUNK` | 2114 | `2 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK`. |
| `SUBDIVISION_WORD_BASE` | 1026 | Início das words de subdivisão: `BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK`. |
| `SOLID_WORD_BASE` | 1090 | Início das words de solidez: `SUBDIVISION_WORD_BASE + 64`. 1 word de solidez por brick (subset da ocupação; exclui NON_SOLID — VS-14). |

Layout absoluto dentro da word-region de um chunk (binding 2): `[0..1024)` ocupação por brick · `[1024..1026)` coarse · `[1026..1090)` subdivisão · `[1090..2114)` solidez.

### 1.3 Paleta de materiais e registros especiais

*Por que existe:* dentro de um chunk, cada voxel guarda só um índice de 8 bits na paleta — é a compressão que permite o mundo packed. Este contrato fixa os tetos de paleta e planos de material, e reserva o slot 0 para ar (regra 2). Quem mantém a paleta é o header do chunk (§2.3), escrito pelo pack e pelo flush de edição ([[sistema-edicao-eventos]]).

| Constante | Valor | Semântica |
| --- | --- | --- |
| `MATERIAL_PLANE_COUNT_MAXIMUM` | 8 | Máximo de planos de material (8 bits de índice de paleta por voxel). |
| `MATERIAL_WORDS_PER_CHUNK` | 8192 | `8 * 1024` words no material plane pool (binding 3). |
| `PALETTE_SIZE_MAXIMUM` | 256 | Entradas máximas da paleta do chunk. Slot 0 é **sempre ar** — nunca reciclado (regra 2). |
| `SPECIAL_RECORDS_PER_CHUNK` | 256 | Máximo de `SpecialVoxelRecord` por chunk. |

### 1.4 Flags de chunk

*Por que existe:* dois estados do chunk precisam viajar junto com os dados na GPU (o header carrega esses bits), porque consomem decisões diferentes do pipeline: um chunk vazio não deve ser renderizado, e um chunk com paleta estourada não pode ser editado.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `CHUNK_FLAG_EMPTY` | 1 | Chunk vazio/virtual — sem alocação real de dados (VS-10). |
| `CHUNK_FLAG_PALETTE_OVERFLOW` | 2 | Paleta estourou; chunk fica **somente-leitura** (regra 6, VS-03). |

### 1.5 Limites do mesh shader e templates (regra 5)

*Por que existe:* o mesh shader (passo 4 da renderização, [[sistema-renderizacao]]) tem um orçamento fixo de saída por trabalho. Estes tetos garantem que *nenhum* brick exceda o orçamento — a subdivisão ×4 divide qualquer template no máximo permitido. Quem verifica isso na carga é `validate_template` (§3.4); quem pré-computa o pior-caso é `compute_worst_case_tris` (§3.3).

| Constante | Valor | Semântica |
| --- | --- | --- |
| `MESH_VERTEX_MAXIMUM` | 256 | Vértices máximos emitidos por workgroup do mesh shader. |
| `MESH_TRIANGLE_MAXIMUM` | 192 | Triângulos máximos por workgroup. |
| `MAX_TEMPLATE_VERTICES` | 32 | Teto por voxel de template; subdivisão ×4 ⇒ 8·32 = 256. |
| `MAX_TEMPLATE_TRIANGLES` | 24 | Teto por voxel (pior-caso); ×4 ⇒ 8·24 = 192. |
| `TEMPLATE_FLAG_HAS_FLUSH_FACES` | 1 | Bit 0 de `MeshTemplate.flags`: template possui faces de flush (voxel contra vizinho sólido, VS-02). |
| `CULL_FACE_NEVER` | 7 | Face de culling 7 = triângulo nunca culpado (interior/diagonal). Faces 0–5 seguem `FACE_NORMALS` (+X,-X,+Y,-Y,+Z,-Z). |

### 1.6 Flags de bloco (bit 0..1 de `BlockDefinition.flags`, VS-14)

*Por que existe:* blocos são dados (`assets/blocks.json`), então o que um bloco *é* em termos de renderização e física precisa caber em bits dentro do `BlockDefinition` (§2.5), que a GPU lê por voxel. Estes dois bits separam "ocupa o voxel" de "é sólido" e de "precisa de alpha-test" — consumidos pelo fragment (alpha) e pela word de solidez (§1.2). Emenda de 2026-11-07.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `BLOCK_DEFINITION_FLAG_TRANSPARENT` | 1 | Bit 0 — recorte alpha (folhagem): o fragment descarta `albedo.a < 0.5` (cutout opaco, sem blending). |
| `BLOCK_DEFINITION_FLAG_NON_SOLID` | 2 | Bit 1 — bloco ocupa o voxel mas não é sólido (planta). O bit de ocupação do brick **continua** contendo a planta; a solidez (word de solid no occupancy pool) a exclui. `VoxelSample.solid` e `block_is_solid()` derivam daqui. Emenda 2026-11-07. |

### 1.7 Fila de trabalho e visíveis (VS-06/VS-08)

*Por que existe:* a fila de trabalho é um ring na GPU que o builder (compute na fila gráfica) enche com itens de desenho e o mesh shader esvazia. Estas words de estado são o protocolo de append entre eles — e o dispatch indireto lê o X direto da fila, sem volta pela CPU.

| Constante | Valor | Semântica |
| --- | --- | --- |
| `NEIGHBOR_SLOT_INVALID` | `max(u32)` | Slot de vizinho ausente ou GENERATING. |
| `WORK_QUEUE_STATE_WORDS` | 8 | Words de estado por slot do ring da fila de trabalho. |
| `WORK_QUEUE_APPEND_COUNT_WORD` | 0 | Índice da word de contagem de appends. |
| `WORK_QUEUE_OVERFLOW_WORD` | 1 | Word de overflow (filtragem com capacidade cheia). |
| `WORK_QUEUE_INDIRECT_X_WORD` | 2 | Word com o X do dispatch indirect. |

Capacidades de visíveis/fila **não** são constantes de compilação (VS-08): vêm do `Config` (raios do INI) e chegam à GPU via `VoxelPushConstants.visible_chunk_capacity`.

### 1.8 Streaming e slots (VS-10)

*Por que existe:* um slot de GPU é um recurso finito reivindicado e liberado com anti-ABA (regras 3 e 4 do `AGENTS.md`). Estas constantes são as sentinelas que marcam "sem slot" e a tabela de direções usada pela filtragem de visíveis na CPU para achar os vizinhos de cada chunk. Consumidores: o streaming ([[sistema-streaming-mundo]]) e a filtragem CPU que produz `VisibleChunk` (§2.7).

| Constante | Valor | Semântica |
| --- | --- | --- |
| `SLOT_INDEX_INVALID` | `max(u32)` | Registro EMPTY não possui slot de GPU (REQ-VRT-01). |
| `NEIGHBOR_OFFSETS` | 6 × `ChunkCoordinate` | Offsets de vizinho na ordem de `FACE_NORMALS`: (+1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1). Usado pela filtragem de visíveis na CPU. |

### 1.9 Paletas de textura (VS-21)

*Por que existe:* as texturas dos blocos vivem em um `Sampler2DArray` na GPU — cada `BlockDefinition.albedo_faces` (§2.5) aponta uma camada. Estes tetos fixam o array, e a sentinela de UV diz ao mesh shader quando um template não tem UVs (o fragment cai no triplanar, VS-11).

| Constante | Valor | Semântica |
| --- | --- | --- |
| `ALBEDO_PALETTE_LAYERS` | 256 | Camadas do Sampler2DArray de albedo. |
| `ALBEDO_PALETTE_LAYER_SIZE` | 16 | Textura da camada é 16×16 (era 4; o sampler NEAREST + UV por face + minificação extrema causavam DEVICE_LOST — correção VS-21; camada = cor sólida). |
| `NO_TEMPLATE_UV_OFFSET` | 0xFFFFFFFF | Template sem pool de UVs; o mesh shader emite a sentinela `float2(-1,-1)` e o fragment cai no triplanar (VS-11). |

### 1.10 Limites do flush de edição (VS-03)

*Por que existe:* edições do jogador não vão à GPU uma a uma — acumulam num ring e são enviadas em lote a cada intervalo, para não explodir a submissão. Estes tetos dimensionam o ring `voxel_edits` e o array de jobs de edição (§2.8). Quem consome é o journal E1 e o shader de edição ([[sistema-edicao-eventos]]).

| Constante | Valor | Semântica |
| --- | --- | --- |
| `EDIT_FLUSH_INTERVAL_MS` | 100.0 | Intervalo entre flushes (0 = todo frame). Espelhada no Slang (arrays groupshared). |
| `MAX_EDITS_PER_FLUSH` | 4096 | Edições por flush (16 KiB no ring `voxel_edits`). |
| `MAX_EDIT_JOBS_PER_FLUSH` | 256 | Chunks distintos tocados por flush. |
| `MAX_EDITS_PER_CHUNK_PER_FLUSH` | 1024 | Teto por workgroup/chunk no shader. |

### 1.11 Códigos de resultado da edição

*Por que existe:* a GPU é a autoridade sobre se uma edição coube (a paleta pode estar cheia), então ela devolve um código por edição — que a CPU só lê 2 frames depois, quando o ring já está livre. Estes códigos são a resposta binária "aplicada / rejeitada" do pipeline de edição.

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

*O que é e por quê:* a "placa" de endereço do mundo. Todo chunk — no mapa da worker, no mirror, no push constant — é identificado por uma coordenada de chunk em unidades de 32 voxels. É o tipo base sobre o qual os anti-ABA por coord+geração (regra 3) se apoiam.

Coordenada de chunk no mundo (unidades de chunk). Base de todos os índices de chunk na CPU e no push constant.

### 2.2 `ChunkGenerationJob` — 32 B (assert)

*Quem usa:* a worker (streaming) preenche um job por chunk a gerar; o shader de geração (binding 1) lê. É o bilhete de entrada do lote de compute (1 claim = 1 lote, regra 3).

Espelha `ChunkGenerationJob` (Slang). Layout (std430):

| Campo | Tipo | Offset | Quem escreve / quem lê |
| --- | --- | --- | --- |
| `chunk_world_origin` | `[3]i32` | 0 | CPU (worker/streaming) preenche; shader de geração (binding 1) lê. |
| `storage_slot_index` | `u32` | 12 | Slot de GPU destino. |
| `mirror_ring_slot` | `i32` | 16 | Slot do ring de export do mirror (-1 = nenhum). |
| `padding` | `[3]u32` | 20 | Alinhamento a 32 B (múltiplo de 16). |

Introduzida em VS-01. Ver [[sistema-streaming-mundo]].

### 2.3 `ChunkHeader` — 2 064 B (assert)

*Quem usa:* um header por slot de chunk (binding 4, RW). O pack (compute) grava a paleta ao comprimir o chunk; o flush de edição (E1) atualiza-a depois. Mesh shader e edição leem — é a página de rosto do chunk na GPU.

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

*Quem usa:* voxels cujo formato não cabe na paleta (ex.: orientação) ganham um registro próprio neste array (binding 5), indexado a partir do header. Lido por quem precisa do dado além do id.

Voxel que exige dado além da paleta (formato/orientação). Array em binding 5.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `voxel_index` | `u32` | Índice denso do voxel (layout x-contíguo, §4). |
| `shape_and_orientation` | `u32` | Forma + orientação packed. |
| `block_identifier` | `u32` | Block id. |

### 2.5 `BlockDefinition` — 80 B (asserts de size e offsets)

*Quem usa:* o registry global de tipos de bloco (binding 7) — a tabela que traduz "id de bloco" em malha, texturas e física. `voxel_assets` carrega `blocks.json` nela (CPU, host-visible); mesh shader lê template/flags/rotation e fragment lê albedo_faces/emissão/PBR. É a struct que teve a regressão de alinhamento de 2026-11-09, por isso os asserts de offset abaixo importam tanto.

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

*Quem usa:* a malha de um bloco customizado (dado, não código — lembre da visão geral). O load de assets preenche este pool (binding 10) apontando para os pools de vértices/triângulos/UVs; o mesh shader monta a geometria a partir daqui a cada frame.

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

*Quem usa:* a filtragem CPU produz um elemento deste array (binding 6) por frame, para cada chunk visível — com os slots dos vizinhos, que o mesh shader precisa para decidir faces de contorno. É a ponte entre o publish da worker e o draw.

Elemento do array de visíveis (binding 6), produzido pela filtragem CPU por frame.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `chunk_world_origin` | `[3]i32` | Origem mundial do chunk. |
| `storage_slot_index` | `u32` | Slot de GPU. |
| `neighbor_slots` | `[6]u32` | Slots dos vizinhos na ordem `FACE_NORMALS`; `NEIGHBOR_SLOT_INVALID` se ausente ou GENERATING. |
| `padding` | `[2]u32` | — |

Introduzida em VS-01 (fila de trabalho); ver [[sistema-renderizacao]].

### 2.8 `EditChunkJob` — 16 B (assert)

*Quem usa:* o flush de edição agrupa as edições do ring por chunk e emite um job destes (binding 13) por chunk tocado — o shader de edição dispatcha um workgroup por job e aplica só a fatia do ring indicada.

Ring de jobs de edição (binding 13). Um job por chunk tocado no flush.

| Campo | Tipo | Semântica |
| --- | --- | --- |
| `storage_slot_index` | `u32` | Chunk alvo. |
| `first_edit` | `u32` | Índice global no ring `voxel_edits`/`edit_results`. |
| `edit_count` | `u32` | ≤ `MAX_EDITS_PER_CHUNK_PER_FLUSH`. |
| `padding` | `u32` | — |

Introduzida em VS-03. Ver [[sistema-edicao-eventos]].

### 2.9 `VoxelPushConstants` — 92 B (assert)

*Quem usa:* os três shaders de voxel recebem estes push constants a cada dispatch — matriz de câmera, offsets dos rings e a capacidade de visíveis que vem do INI (VS-08). É o único canal CPU→GPU que muda todo frame sem ser um buffer.

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

Estas structs nunca cruzam para a GPU — por isso não precisam de espelho nem de asserts. Vivem só no lado Odin.

**`MirrorPageState :: enum u8`** — estado da página do mirror (VS-04). O mirror é a cópia densa do mundo na RAM, mantida pela worker ([[sistema-mirror-fisica]]); este enum diz se a página ainda está esperando o export da GPU ou já pode ser lida:
- `PENDING_READBACK` — export em vôo (ou aguardando slot de ring); leitura desconhecida.
- `MATERIALIZED` — aberta a leituras; atualizada pelo journal do E1.

**`VoxelSample`** — amostra tri-state de gameplay (VS-20). É o que uma query de mundo devolve para física e mira — block id mais a resposta "é sólido?", derivada do registry:
- `block_id: u16`
- `solid: bool` — derivado do registry (bit NON_SOLID, VS-14 emenda).

**`MirrorChunkPage`** — 71 824 B (assert, VS-13; era 68,14 KiB). Página do mundo na RAM (mirror, regra 7 — ver §4). É a estrutura que física, IA e queries leem com resposta O(1):

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

**`MirrorRingEntry`** — slot do ring de export. Cada export denso da GPU ocupa um slot destes até a worker consumi-lo; a geração emparelhada com a coordenada é o anti-ABA que impede de processar um export velho como se fosse novo (regra 3: 1 claim = 1 lote = 1 timeline):
- `used: bool`
- `coord: ChunkCoordinate`
- `generation: u32` — anti-ABA: casa com a geração do slot de GPU no pedido (regra 3: 1 claim = 1 lote = 1 timeline).

---

## 3. Procs

Todas as procs desta seção são helpers de empacotamento/validação do lado CPU — transformam dados confortáveis (edições, templates) no formato packed que a GPU espera, ou verificam os limites que a regra 5 impõe.

### 3.1 `pack_voxel_edit(voxel_index, block_id) -> u32` (VS-03)

*Para que:* compactar uma edição em uma única word do ring `voxel_edits`, que a CPU grava e o shader de edição decodifica. Repare que o índice aqui é **x-contíguo** (§4) — diferente do mirror.

Edição packed: `voxel_index & 0x7FFF` (15 bits, layout denso **x-contíguo** `x|z<<5|y<<10`) | `block_id << 16`. Escrito pela CPU no ring `voxel_edits`; decodificado pelo shader de edição.

### 3.2 `pack_template_triangle(v0, v1, v2, cull_face) -> u32` (VS-02)

*Para que:* triângulos de template ocupam 1 word no pool `template_triangles` — três índices de vértice de 8 bits mais a face de culling, que o mesh shader usa para eliminar faces internas.

Triângulo packed: bits `[0..8)` v0 | `[8..16)` v1 | `[16..24)` v2 | `[24..27)` face de culling (0–5 = `FACE_NORMALS`, 7 = `CULL_FACE_NEVER`). Pool `template_triangles`.

### 3.3 `compute_worst_case_tris(packed_triangles) -> u32`

*Para que:* antes de aceitar um template, o load precisa saber quantos triângulos ele pode emitir no *pior* ângulo de câmera — porque a regra 5 proíbe assumir culling direcional. O resultado vira `MeshTemplate.worst_case_tris` e alimenta a decisão de subdivisão.

Pior-caso de triângulos para qualquer direção de câmera: triângulos `CULL_FACE_NEVER` +, por eixo, `max(face+, face-)`. Usado no load para preencher `MeshTemplate.worst_case_tris` (regra 5 — não se assume culling direcional).

### 3.4 `validate_template(vertices, packed_triangles) -> bool` (VS-02)

*Para que:* guarda da carga — um template que exceda os tetos ou tenha vértices fora do voxel unitário quebraria o orçamento do mesh shader ou a regra 1. Rejeita na hora, com erro.

Validação de carga de template: ≤ 32 vértices, pior-caso ≤ 24 triângulos, e todos os vértices dentro do voxel unitário `[0,1]³` (regra 1).

### 3.5 `validate_template_uvs(template_index, uvs) -> bool` (VS-11, REQ-UV-04a)

*Para que:* quando um template tem pool de UVs, cada vértice precisa de UV em `[0,1]²`; a sentinela (-1,-1) é reservada ao mesh shader para o caso sem-UVs e nunca pode vir de dado. Esta validação garante isso no load.

UVs, quando presentes, em `[0,1]²`; a sentinela (-1,-1) é interna ao mesh shader e nunca aparece num template. Erro logado nomeia template e vértice.

---

## 4. Os três layouts de índice (regra 7 — não misturar)

*Por que três:* cada consumidor tem uma ordem de varredura diferente, e a ordem certa para um é a errada para outro. O scratch GPU varre x primeiro (coalescência dos shaders); o mirror varre y primeiro (colunas verticais, amigas do heightmap e da física); o heightmap varre por coluna (x,z). Reescrever um array com a ordem errada não dá erro de compilação — dá voxels trocados. Por isso a regra 7 é "não misturar", e por isso esta tabela existe.

Três linearizações diferentes coexistem por propósito:

| Layout | Fórmula | Onde |
| --- | --- | --- |
| **x-contíguo (denso GPU / scratch)** | `x \| z<<5 \| y<<10` | `voxel_edits` (pack_voxel_edit), índice denso lido pelos shaders (`dense_index_from_coordinate` no Slang). |
| **y-contíguo (mirror)** | `y \| z<<5 \| x<<10` | `MirrorChunkPage.ids` — o mundo na RAM. |
| **z-contíguo (heightmap)** | `x \| z<<5` | `MirrorChunkPage.heights` e `mirror_heightmap_ring` (binding 20, VS-13) — por coluna (x,z). |

E os índices de brick (Slang): `brick_index = x + 8*(z + 8*y)`; bit dentro do brick: `x + 4*(z + 4*y)` (4×2×4).

## 5. Invariantes

- Todo `#assert` de tamanho/offset em `voxel_types.odin:201-210` é verificado em toda compilação — são o contrato executável Odin↔Slang anunciado na abertura.
- Slot 0 da paleta é ar, sempre (regra 2); `block_id 0` nunca é sólido (`block_is_solid` no Slang).
- `CHUNK_FLAG_PALETTE_OVERFLOW` ⇒ chunk somente-leitura (regra 6).
- Registry 80 B e stride múltiplo de 16 — adicionar campos exige reespelhar o Slang e revisitar os asserts (regressão 2026-11-09).

---

*Para ir mais fundo:* os bindings citados em cada struct são detalhados em [[ref-shaders]]; o ciclo de vida dos slots e claims em [[sistema-streaming-mundo]]; o mirror e suas páginas em [[sistema-mirror-fisica]]; o journal e o flush em [[sistema-edicao-eventos]].
