# Referência Técnica: Motor de Voxels

**Implementação em Odin e Slang sobre Vulkan 1.4** — estruturas de memória, compressão paralela, pipeline Task/Mesh, templates de malha, edição de voxels e mirror CPU-side

**Versão 3.0 — novembro de 2026** · reflete o código com as correções B1–B4, o Caminho B, o E1 e a especificação C2

## 1. Estruturas de memória na GPU (bitmasking)

Para contornar o limite de VRAM e maximizar o cache L1, abandonamos ponteiros (SVDAG) em favor de matrizes densas de bits. Um chunk de 32³ possui 32.768 voxels e vive num slot fixo pré-alocado do pool — desde a VS-08 o pool é dimensionado em runtime (`resident_slots = ⌈|esfera(unload)| × 1,05⌉`, 4.378 com os defaults — emenda 2026-11-06, era `|esfera(generation)|`; antes: 4.096 fixos). A região de ocupação de cada slot tem **2.114 words** (antes 1.090 — a correção de performance da VS-14 adicionou 1.024 words de solidez):

```
┌ Ocupação dos bricks — 1024 words (1 word = 32 voxels, brick 4×2×4)     words [0..1024)
├ Coarse — 2 words                                                       words [1024..1026)
├ Subdivisão — 64 words (2 bits/brick)                                   words [1026..1090)
├ Solidez — 1024 words (1 bit/voxel; subset da ocupação)                  words [1090..2114)
├ Planos de material — até 8 × 1024 words (bitplane por nível da paleta; palette[0] = AR)
└ ChunkHeader — 2064 B (era 1040 B na v2.0)
    palette_size, plane_count, special_voxel_count, flags, palette[256], refcount[256] — novo no E1
```

*Figura 1 — Layout do slot: ocupação (bricks | coarse | subdivisão | solidez), planos e header — na v3.0 o ChunkHeader tem 2064 B, com o refcount[256] do E1.*

A máscara de ocupação agrupa voxels em bricks de 4×2×4 (32 voxels = 32 bits = 1 word). A máscara de solidez usa o mesmo bit index e exclui `NON_SOLID`; pack fase A e E1 a mantêm, permitindo culling de vizinhos e oclusão sem decodificar paleta/registry. A célula grossa agrupa 8³ voxels num único bit — se zero, o task shader ignora 512 voxels de uma vez. Os 2 bits de subdivisão por brick (Caminho B) dizem ao task shader em quantos mesh groups o brick deve ser fatiado (1, 2 ou 4), conforme o custo geométrico pior-caso computado pelo pack (Seção 3.2).

### 1.1 Decodificação do dicionário (data-driven)

O header do chunk contém uma paleta local. Para descobrir qual bloco existe num voxel, a GPU lê o mesmo bit através dos planos de material e remonta o índice da paleta:

```c
// Slang: extracao do ID do bloco a partir dos planos de bits
uint read_block_identifier(uint slot, ChunkHeader header, int3 coord) {
    uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
    uint bit_idx   = bit_index_from_local_coordinate(coord % BRICK_SIZE);
    uint palette_index = 0;
    for (uint plane = 0; plane < header.plane_count; plane++) {
        uint plane_word = material_plane_pool[slot * MATERIAL_WORDS_PER_CHUNK
                            + plane * BRICKS_PER_CHUNK + brick_idx];
        palette_index |= ((plane_word >> bit_idx) & 1u) << plane;
    }
    return header.palette[min(palette_index, max(header.palette_size, 1u) - 1u)];
}
```

**Invariante (B3):** o slot 0 da paleta é sempre AR — voxels de ar não marcam presença nem bits de plano e decodificam para o índice 0. Sem isso, o mesh shader desenharia geometria no céu.

## 2. Máquina de estados e Chunk Manager (CPU, Odin)

O Odin gerencia o estado lógico de milhares de chunks sobre slots fixos pré-alocados, evitando realocação. A histerese opera como antes: sair do raio de visão (8) mas permanecer no raio de geração (9) apenas rebaixa RENDERABLE → CACHED, economizando trabalho. Na VS-17 o agendamento é um cursor espiral persistente com orçamento de **6 ms por frame** e tick a cada **64 coordenadas**; geração e descarga compartilham as fatias, e a reancoragem enfileira descargas para não criar spike. `promote_visibility` foi fundido a `publish_visible`: uma passada decide CACHED⇄RENDERABLE e grava as entradas visíveis no ring. Na VS-18 essa passada pertence à worker e roda sob demanda (cruzamento, `world_revision` ou bump); a main consome o último publish compatível sem espera entre mudanças, com staleness máximo de dois frames. O slot contém `visible_count`, `published_camera_chunk` e `published_compute_value`. Intake E1 fica na main sob mutex; dedup/journal/staging/feedback ficam na worker. A worker possui arena temporária própria, essencial para não compartilhar o `temp_allocator` que a main limpa por frame. Desde a VS-08 os raios (visão 8, geração 9, descarga 10, simulação 5) e os lotes do worker (16 chunks/lote, 3 lotes em voo) vêm de `vox.ini` — ver §10.

**Estado EMPTY — chunk vazio virtual (VS-10, ADR-V1):** chunk que conclui a geração com `CHUNK_FLAG_EMPTY` e sem edições pendentes não é promovido a CACHED: vira `EMPTY`, um registro no map **sem slot** (`storage_slot_index = SLOT_INDEX_INVALID`), custando só o índice na CPU. O slot volta ao pool no instante da conclusão do pack — o feedback vem do buffer host-visible `chunk_result_flags` (binding 18, `[resident_slots]u32`), escrito pela thread 0 do `pack_chunk` e lido pelo handler de conclusão após a timeline do lote (mesma ordenação e anti-ABA da promoção a CACHED). `EMPTY` nunca é publicado em `visible_chunks`, nunca despacha builder, e seus vizinhos o veem como `NEIGHBOR_SLOT_INVALID` (ar — sem mudança nos shaders de render). Unload além do raio de descarga apenas deleta o registro, sem aposentadoria. Edição com bloco sólido materializa o chunk (aloca slot + tarefa de geração + pendência do E1, com retry por update se o pool estiver seco); ar-em-ar é no-op. Contadores (ativos e slots economizados) são logados a cada 5 s.

### 2.1 Correção B1 — geração por slot, claim atômico e aposentadoria dual

O registro do chunk carrega a geração do slot no momento da alocação; a conclusão de um lote só promove GENERATING → CACHED se (coordenada, slot, geração) baterem exatamente — eliminando o problema ABA (mesmo slot, novo chunk). O descarregamento de um chunk em geração cobre três casos, sempre sob o mesmo mutex de fila:

```odin
// Odin: retire_generating_slot (resumo dos 3 caminhos)
// (a) ainda pendente -> cancela a tarefa e devolve o slot na hora
// (b) ja submetida  -> aposenta contra a TIMELINE DE COMPUTE do lote
//                      (a GPU ainda pode estar escrevendo no slot)
// (c) caminho defensivo -> nenhuma escrita pendente: devolve na hora
for batch in chunk_manager.submitted_batches {
    for task in batch.tasks[:batch.task_count] {
        if task_matches(task, coord, record) {
            append(&chunk_manager.retiring_compute_slots, RetiringComputeSlot{
                record.storage_slot_index, batch.compute_timeline_value })
            return
        }
    }
}
```

O claim é atômico: a worker publica o SubmittedBatch no mesmo trecho crítico (`queue_mutex`) em que retira a tarefa de `pending_tasks`. **Invariante:** toda tarefa está em exatamente um dos conjuntos {pendentes, submetidos} — nunca em ambos, nunca em nenhum.

## 3. A pipeline de geração (compute shaders)

A worker thread despacha lotes de até 16 chunks (B4) via `vkQueueSubmit2`. Cada lote gera um valor de timeline determinístico (número do lote), sinalizado ao final do lote.

### 3.1 Estágio 1: generate_voxels (scratchpad)

Um dispatch de dimensionalidade (4, 4, 4·N) acorda grupos de **8×8×8 threads**; cada thread escreve 1 voxel no scratch denso (131 KB por chunk, 1 uint por voxel). O scratch existe porque o ruído precisa ser avaliado antes da compressão — e será o alvo da futura otimização de fusão.

> **Correção B9 (2026-11-03):** o shader usava `numthreads(4,4,4)` com dispatch (4,4,4·N) — só 16×16×32 voxels por chunk eram escritos (8.192 de 32.768) e os chunks 8..N-1 do lote ficavam zerados. Corrigido para `numthreads(8,8,8)` com `job = thread_id.z / 32`.

### 3.2 Estágio 2: pack_chunk (compressão lock-free) — B3 completo

Um workgroup de 128 threads por chunk (cada thread processa exatamente 8 dos 1.024 bricks) executa as quatro fases da Figura 3 do documento de arquitetura. O coração é o **ranking por scan de prefixo popcount**: depois de marcar a presença de cada ID em 2.048 words compartilhadas, um scan de prefixo (16 words por thread + varredura serial das 128 parciais pela thread 0) dá a cada bloco seu rank na paleta em O(1):

```c
// Slang: rank da paleta sem busca linear
uint palette_rank_of_block(uint block_id) {
    uint word_index = block_id >> 5u;
    uint bit_index  = block_id & 31u;
    uint word = shared_block_presence[word_index];
    return shared_presence_prefix[word_index]
         + countbits(word & ((1u << bit_index) - 1u));
}
// Fase C: indice no plano = rank + 1 (slot 0 reservado ao AR);
// rank >= 255 -> SpecialVoxelRecord + flag CHUNK_FLAG_PALETTE_OVERFLOW
```

**Caminho B:** a Fase A também acumula, por parte de 8 voxels, o custo geométrico pior-caso (vértices e triângulos dos templates) e escolhe a menor subdivisão cujas partes cabem no orçamento do mesh shader — gravada como 2 bits por brick nas words [1026, 1090).

### 3.3 Export denso para o mirror (C2) — novo na v3.0

Quando o job de geração carrega a flag MIRROR (chunk dentro da bolha de simulação), o estágio 1 grava uma segunda saída: o ID de bloco de cada voxel como u16, no **layout y-major** do mirror. O pack não muda — o export é uma ramificação lateral do scratch.

> **Nota de implementação (2026-11-03):** a versão final no código simplificou o fluxo — o generate escreve **direto no `mirror_export_ring` host-visible** (binding 16, 64 slots × 64 KiB = 4 MiB, host-visible + coherent), sem `export_pool` device-local nem `vkCmdCopyBuffer`. A escrita do shader É o readback. Requer a feature `storageBuffer16BitAccess` (formato `RWStructuredBuffer<uint16_t>`).

## 4. Sincronização Vulkan 1.4 (timeline semaphores)

O coração do multithreading: em vez de fences, a CPU diz à GPU «atualize o valor X na linha do tempo quando terminar». Dois semáforos de timeline separam os domínios — **compute** (geração/packing, lotes do worker) e **gráfica** (frames em voo). A aposentadoria dual do B1 consome as duas: slots liberados de chunks em geração aguardam a timeline de compute; slots de chunks desenhados aguardam a timeline gráfica. A espera da timeline de compute no submit gráfico garante a visibilidade de memória da ocupação — incluindo a dos vizinhos (B2). **Novo na v3.0 (E1):** essa espera ganhou o estágio `COMPUTE_SHADER`, para que a edição leia chunks recém-promovidos a CACHED no mesmo frame.

## 5. A pipeline de renderização (task/mesh shaders)

Um único `vkCmdDrawMeshTasksEXT` processa o mundo inteiro. O payload do task shader tem 2.048 entradas (~8,2 KB — abaixo do limite de 16 KB), pois um brick pode gerar até 4 mesh groups (Caminho B).

### 5.1 Task shader — culling hierárquico + subdivisão

```c
// Slang: task shader (por brick selecionado)
uint subd_word   = occupancy_pool[occ_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
uint subdivision = (subd_word >> ((brick_index & 15u) * 2u)) & 3u;
uint parts       = 1u << subdivision; // 1, 2 ou 4 mesh groups
for (uint part = 0; part < parts; part++) {
    uint position;
    InterlockedAdd(shared_selected_brick_count, 1, position);
    if (position < TASK_PAYLOAD_BRICK_CAPACITY) {
        shared_payload.brick_indices[position] =
            brick_index | (part << 10u) | (subdivision << 12u);
    }
}
// ... DispatchMesh(min(count, CAPACIDADE), 1, 1, shared_payload);
```

### 5.2 Mesh shader — emissão genérica por template

O switch hardcoded (CUBO/PLANTA) desapareceu. Cada thread lê o bloco do voxel, resolve o template no dicionário, conta os triângulos que sobrevivem ao culling por tag e emite vértices copiados do pool global (com rotação yaw) somados à origem do voxel:

```c
// Slang: mesh shader (por voxel do grupo)
def   = global_block_registry[block_id];
tmpl  = mesh_templates[def.mesh_template_index];
if (tmpl.triangle_count > 0) {
    if (tmpl.flags & TEMPLATE_FLAG_HAS_FLUSH_FACES) {
        face_mask = compute_visible_face_mask(slot, voxel_coord,
                        payload.chunk_world_origin, cam, payload.neighbor_slots);
    }
    for (t in 0..tmpl.triangle_count)
        if (triangle_survives_culling(template_triangles[tmpl.triangle_offset + t],
                                      def.rotation, face_mask))
            t_cnt++;
    if (t_cnt > 0) v_cnt = tmpl.vertex_count; // voxel todo culpado: 0 vertices
}
// Prefix sum exclusivo (thread 0) -> SetMeshOutputCounts -> emissao
```

Voxels totalmente ocluídos (todos os triângulos culpados) emitem zero vértices — a economia do culling aparece no prefix sum e no SetMeshOutputCounts.

## 6. Caminho B — templates de malha (data-driven)

A tabela de templates é o equivalente geométrico do dicionário de blocos: quatro buffers device-local (bindings 10/11/12/19) — `mesh_templates` (metadados), `template_vertices` (float3 em [0,1]³, stride 16), `template_triangles` (u32 packed) e `template_uvs` (float2 por vértice, stride 8 — VS-11, paralelo e indexado como `template_vertices`).

**Triângulo packed em 32 bits:** 3 índices locais (8 bits cada) + tag de culling (8 bits): `v0 | v1<<8 | v2<<16 | face_culling<<24`.

```odin
// Odin: MeshTemplate (std430, 32 bytes) — espelha o Slang
MeshTemplate :: struct {
    vertex_offset, vertex_count:     u32, // no pool template_vertices
    triangle_offset, triangle_count: u32, // no pool template_triangles
    worst_case_tris:                 u32, // pre-computado no load (orcamento do pack)
    flags:                           u32, // bit 0: HAS_FLUSH_FACES
    uv_offset:                       u32, // no pool template_uvs (VS-11); 0xFFFFFFFF = sem UVs
    padding_1:                       u32,
}
```

### 6.1 Contrato de carga

- **Regra do voxel unitário:** todo voxel ocupa 1 unidade³; vértices do template devem estar em [0,1]³ (rejeitados no load caso contrário). Objetos maiores são divididos em múltiplos voxels-parte no registro.
- **Regra das UVs (VS-11):** quando o template tem pool de UVs (`uv_offset != 0xFFFFFFFF`), todo vértice deve ter UV em [0,1]² — o load rejeita com o índice do template e do vértice (mesmo padrão da regra do voxel unitário). Template sem pool de UVs é válido: o mesh shader emite a sentinela `(-1,-1)` e o fragment usa o triplanar (fallback).
- **Limites por template:** até 32 vértices e 24 triângulos pior-caso. Com esses limites, a subdivisão ×4 (8 voxels/grupo) sempre cabe no orçamento: 8×32 = 256 vértices, 8×24 = 192 triângulos.
- **worst_case_tris** é pré-computado pela CPU: triângulos nunca culpados +, por eixo, max(tris na face+, tris na face−).
- **Tag de culling:** 0..5 = triângulo colado na face do voxel (culpado por vizinho sólido ou câmera atrás do plano); 7 = nunca culpado (interior, diagonais, plantas).
- **Rotação:** `BlockDefinition.rotation` (0..3) aplica yaw de 90° aos vértices e remapeia as tags de culling — orientações não consomem IDs nem templates.

**Built-ins:** índice 0 = vazio (AR, 0 vértices/0 triângulos), 1 = cubo (8 vértices, 12 triângulos, 2 por face), 2 = planta (dois quads cruzados, 4 triângulos com tag 7). O comportamento do cubo é bit a bit idêntico ao código hardcoded anterior (verificado por simulação). **Nota de integração (VS-14, fecha B6):** tags 7 exigem `CULL_MODE_NONE` no pipeline — mantido; a transparência da folhagem é **alpha-test cutout** no fragment (`BlockDefinition.flags` bit 0 = `transparente`: descarte de fragmentos com `albedo.a < 0.5` após a amostragem UV/triplanar), sem blending nem ordenação. O bloco `planta` (id 4) usa a mesh "planta" (duas quads em X, tags 7) + textura RGBA com recorte; o worldgen o spawna na coluna via wang hash `wang(wang(x) ^ z) % 1000 < 100` (10%) no voxel acima da grama. **Emenda 2026-11-07 (pós-validação):** a planta é **não-sólida** — `BlockDefinition.flags` bit 1 `NON_SOLID` (JSON `"solid": false`, separado de `transparent`): ocupa o voxel (renderiza a cruz em X, brick não perde itens) mas não suprime faces de vizinhos, não oclui bricks, não entra no bitmask `solid` do mirror nem move o heightmap (o export é o topo **sólido** = `altura`; colocar/remover planta acima da superfície é no-op para o heights). Contrato de carga: ids 1..4 obrigatórios (campos opcionais `transparent` e `solid` por bloco, bool — tipo errado é rejeitado no load e no validador offline).

**Carga data-driven (VS-12, ADR-A1):** desde a VS-12 os templates, o registry de blocos e o albedo vêm de `assets/blocks.json` (seções `meshes`/`textures`/`blocks`, referências por nome), carregado e validado antes de `CreateEngine` por `src/engine/voxel_assets.odin` e formatado bit a bit nos contratos acima (mesmas regras de validação, agora citando o nome do objeto). As texturas são PNGs de dimensão uniforme (máx. 256×256 nesta fatia), decodificadas com `core:image/png` e enviadas como `Texture2DArray` com uma camada por textura na ordem de definição — o caminho de amostragem (índice de camada + UV) não muda. Com o JSON ausente, o init usa os built-ins desta seção + paleta procedural (fallback com paridade verificada). Validação offline espelhada em `tools/sim/assets_check.py`.

## 7. E1 — edição de voxels bufferizada (novo na v3.0)

Toda edição, de qualquer origem, entra por `request_voxel_edit(world_voxel, block_id)`. Uma fila na CPU faz dedup «última escrita vence» por voxel (`map[[3]i32]int`) e o flush periódico (`EDIT_FLUSH_INTERVAL_MS = 100`; 0 = todo frame; `force_next_flush` para latência mínima) agrupa as edições por chunk e despacha um compute **no command buffer do frame, antes do render pass**, com barreira COMPUTE → TASK|MESH.

### 7.1 Estruturas e ring

```odin
// Odin: lote de edicao por chunk (16B) e edicao packed (u32)
EditChunkJob :: struct { slot, first_edit, count, pad: u32 }
// edicao packed: bits [0..15) = voxel_index (15b, y-major local) | bits [16..32) = block_id

// Ring host-visible de 2 frames (mesmo padrao do visible_chunks):
// binding 13: jobs    8 KiB  (512 EditChunkJob)
// binding 14: edits   32 KiB (8192 edicoes u32)
// binding 15: results 32 KiB (feedback: applied / noop / rejected)
// PushConstants = 92 B (VS-08: + visible_chunk_capacity)
```

Só chunks CACHED/RENDERABLE entram no lote — o flush nunca disputa slot com a geração (preserva o B1). Pedidos sobre chunks GENERATING/ausentes ficam num mapa de pendentes por chunk e reintegram quando o chunk conclui. **Tetos:** 4.096 edições/flush, 256 chunks/flush, 1.024 edições/chunk/flush; o excedente espera o próximo flush.

### 7.2 O shader apply_voxel_edits

Um workgroup de 128 threads por chunk. O coração é a manutenção da **paleta dinâmica** — o ChunkHeader cresceu de 1040 B para 2064 B com o vetor `refcount[256]` (u8 por entrada; o pack conta as referências na Fase C; o slot 0 conta os não-sólidos):

- **Bloco novo no chunk:** aloca um slot de paleta livre por CAS em `refcount == 0` (o slot 0 nunca é reciclado — invariante do B3); se o `plane_count` cresce, os planos novos são zerados antes do primeiro uso; `plane_count` nunca encolhe até uma re-geração.
- **Última remoção de um tipo:** refcount chega a zero e o slot entra num hash de tombstones (512 buckets) para reciclagem preguiçosa.
- **Manutenção estrutural no mesmo passe:** flag EMPTY recalculada (obrigatório limpar — o task shader dá early-out em EMPTY) e os 2 bits de subdivisão (Caminho B) dos bricks sujos são recomputados a partir dos planos.
- **Chunks com `CHUNK_FLAG_PALETTE_OVERFLOW` são somente-leitura:** a edição é rejeitada com código próprio no ring de resultados (lido pela CPU 2 frames depois).

**Validação:** simulação Python bit-a-bit do shader (11 cenários × 7 invariantes: decode==verdade, refcount==recontagem, paleta sem duplicatas, ocupação, coarse, EMPTY, subdivisão==recálculo, crescimento de planos 1→3, reciclagem de slot, paleta cheia rejeita, overflow rejeita, subdivisão ×4→×0, AR ressuscitado 0→1) e da CPU (conversão mundo→chunk com negativos, dedup, pendências, tetos).

## 8. C2 — mirror CPU-side (novo na v3.0)

Infraestrutura genérica de acesso ao mundo pela CPU: um mirror do grid lógico em RAM, otimizado para a consulta «que bloco há em (x,y,z)?». Não replica o formato packed da GPU — é uma segunda materialização da mesma verdade (worldgen + journal de edições do E1), em formato de consulta. Consumidores futuros: física, IA, ferramentas, serialização de save.

### 8.1 ChunkPage — a unidade de armazenamento

```odin
// Odin: pagina do mirror — 32^3 voxels, 1:1 com o slot da GPU
CHUNK :: 32
MirrorState :: enum u8 { PENDING_READBACK, MATERIALIZED, EVICTED }

ChunkPage :: struct {
    coord:    [3]i32,                     // coordenada do chunk
    edit_seq: u32,                        // versao do journal aplicada (paritaria com a GPU)
    state:    MirrorState,
    pending:  [dynamic]Edit,              // edicoes retidas ate a materializacao
    // -- header alinhado a 64B; planos de dados abaixo --
    solid: [CHUNK*CHUNK*CHUNK/32]u32,     // 4 KiB — derivado de BlockDefinition.is_solid
    heights: [CHUNK*CHUNK]u16,             // 2 KiB — VS-13: y do topo sólido da coluna (z-contíguo x|z<<5); 0xFFFF = vazia
    ids:   [CHUNK*CHUNK*CHUNK]u16,        // 64 KiB — grid denso, block ID direto, SEM paleta
}
// total ~70,1 KiB (VS-13; era ~68,1 KiB); pool de paginas de tamanho fixo (O(1), sem fragmentacao,
// ponteiros estaveis p/ leitores concorrentes)
```

Duas decisões de formato: **denso u16, sem paleta** — a CPU jamais mantém uma paleta paralela (a divergência paleta-GPU × paleta-CPU deixa de existir; inclusive chunks em overflow de paleta, somente-leitura na GPU, são editáveis no mirror, com reconciliação pelo feedback do E1); e **indexação y-major** — `idx = y | z<<5 | x<<10` — de modo que a coluna vertical é contígua (64 B = 1 linha de cache). Desde a **VS-13 (2026-11-07)** a página ganhou o **heightmap da coluna**: 1.024 u16 (2 KiB, índice **z-contíguo `x | z<<5`** — deliberadamente diferente do índice y-major do grid, pois é uma matriz 2D de colunas), guardando o y do sólido mais alto de cada coluna (`0xFFFF` = coluna vazia). O journal do E1 o mantém (colocar sólido acima do topo sobe; remover o bloco do topo rescanza a coluna — 32 leituras do bitmask; demais casos inalterados) e a consulta `mirror_height_get(chunk, x, z)` responde em O(1) — a operação «altura do chão» deixa de ser um scan vertical.

**Geração (VS-13):** o `generate_voxels` calcula a altura de cada coluna uma única vez por workgroup — as threads com y-local 0 (64/workgroup) avaliam os dois ruídos (`fnlCreateState` por thread de coluna, OpenSimplex2 @0.02 / Perlin @0.07, mesma expressão `32 + h1 + h2` e mesmas posições mundo) e gravam num `groupshared uint16[8][8]`; após barrier os 512 threads leem a altura da sua coluna e derivam o `block_id` como antes — saída **bit a bit idêntica** (equivalência pura). Avaliações de ruído por chunk caem de 65.536 para 8.192 (8×; as 4 fatias-y de um mesmo (x,z) recalculam a mesma coluna, pois o groupshared é por workgroup e o dispatch/thread mapping ficaram inalterados). As mesmas threads de coluna exportam o topo sólido de cada coluna no ring paralelo do heightmap (binding 20).

### 8.2 Caminho de leitura

```odin
// Odin: resolucao mundo -> pagina (hash map aberto [3]i32 -> ^ChunkPage)
VoxelSample :: struct { id: u16, solid: bool }
VoxelResult :: union { VoxelSample } // nil = desconhecido

voxel_get :: proc "contextless" (w: ^World, pos: [3]i32) -> VoxelResult {
    page := mirror_lookup(w, pos >> 5)
    if page == nil || page.state != .MATERIALIZED do return nil // unknown
    l   := pos & 31
    idx := (u32(l.x)*32 + u32(l.z))*32 + u32(l.y)
    return VoxelSample{ page.ids[idx], bitmask_test(page.solid[:], idx) }
}
```

A API é **tri-state**: dado presente ou «desconhecido» (página ausente / em readback). A política sobre o desconhecido é do consumidor; o mirror apenas expõe `mirror_request(chunk)` para puxar páginas sob demanda. Custo da query de ponto: ~30–40 ciclos de hash + 1–2 loads.

### 8.3 Caminho de escrita (journal dual-apply)

```odin
// Odin: mesma sequencia ordenada que o flush E1 envia a GPU
journal_apply_cpu :: proc (w: ^World, chunk: [3]i32, edits: []Edit) {
    page := mirror_lookup(w, chunk)
    if page == nil do return // fora da bolha: so a GPU recebe
    if page.state == .PENDING_READBACK { append(&page.pending, ..edits); return }
    for e in edits {
        idx := local_index_y_major(e.voxel)
        page.ids[idx] = e.block_id
        bitmask_write(page.solid[:], idx, block_defs[e.block_id].is_solid)
    }
    page.edit_seq += 1 // GPU incrementa o mesmo contador no flush
}
```

Como dedup e ordenação acontecem uma única vez, antes dos dois consumidores, GPU e RAM executam exatamente a mesma sequência — **convergência por construção**. Em build de debug, um hash periódico do denso contra um re-export da GPU com o mesmo `edit_seq` detecta qualquer divergência na hora.

### 8.4 Readback: do compute à página

```
generate_voxels (GPU)                saída secundária: grid denso u16 y-major + heightmap da coluna (só se o job tem mirror_ring_slot)
        ▼
ring host-visible — 64 slots × 64 KiB = 4 MiB (binding 16)   ← a escrita do shader É o readback
ring de heightmap — 64 slots × 2 KiB (binding 20, VS-13)     ← paralelo, mesmo índice de slot
        ▼ (handler de conclusão: WaitSemaphores(0) como acquire host)
ChunkPage (RAM)                      memcpy (+ heights) → MATERIALIZED → replay do pending → aberta p/ consultas (voxel_get / mirror_height_get)
```

*Figura 3 — Fluxo de readback do C2 (versão implementada em 2026-11-03). Latência típica: 1–3 frames; banda: 64 KiB/chunk (irrisório em PCIe); export condicionado à bolha de simulação.*

O export (Seção 3.3) é condicionado à bolha de simulação — chunks fora dela não pagam nem a escrita densa nem a banda de PCIe. Na materialização, as edições retidas em `pending` são reaplicadas antes de a página abrir para leitura — a mesma semântica de pendências que o E1 já usa para chunks em geração.

**Retry e descarte (implementado):** ring cheio ou tarefa já reivindicada → `mirror_service_retries` (todo frame) acopla slot a tarefa pendente ou agenda tarefa `export_only` (fila separada `pending_export_tasks`; worker: 1 por lote, **SEM pack** — repackar apagaria edições do packed). `mirror_forget_chunk` (evicção da bolha/unload) desacopla ring de tarefas pendentes e cancela exports pendentes; exports **EM VOO** são liberados só pelo handler de conclusão — anti-ABA por coord+geração, mesma disciplina do B1 (**nunca liberar slot de ring em voo**).

**Reconciliação de rejeições:** o mirror aplica otimisticamente; se o ring de resultados do E1 reportar a edição como rejeitada (chunk somente-leitura), a página reverte por replay do journal sem aquela edição. **Decisões descartadas:** leitura direta do device-local via Resizable BAR (latência de PCIe no hot path) e dual-execution do worldgen na CPU (exigiria determinismo bit-exato de float entre CPU e GPU).

## 9. Orçamentos e invariantes (resumo)

| Item | Valor |
|---|---|
| Slots de chunk | derivados: `resident_slots = ⌈|esfera(unload)| × 1,05⌉` (4.378 nos defaults — emenda 2026-11-06: retenção até unload + transitório B1) |
| Voxels por chunk | 32³ = 32.768 |
| Brick | 4×2×4 = 32 voxels = 1 word |
| Coarse cell | 8³ voxels = 1 bit (descarte de 512 voxels) |
| Occupancy words por chunk | 2.114 (1024 ocupação + 2 coarse + 64 subdivisão + 1024 solidez) |
| ChunkHeader | 2.064 B (com refcount[256]) |
| Paleta | 8 planos × 256 entradas; **slot 0 = AR**; overflow → flag + SpecialVoxelRecord |
| Task payload | 2.048 entradas ≈ 8,2 KB (< 16 KB) |
| Orçamento mesh shader | 256 vértices / 192 triângulos por grupo — garantido por subdivisão |
| Lote do worker | até `chunks_per_batch` chunks (16) por vkQueueSubmit2 (1 claim = 1 lote = 1 timeline) |
| Flush de edição | 100 ms; tetos 4.096 edições / 256 chunks / 1.024 por chunk |
| ChunkPage (mirror) | ~70,1 KiB (VS-13; era ~68,1), y-major + heightmap 2 KiB z-contíguo, pool derivado: `mirror_pages = ⌈|esfera(simulation)| × 1,5⌉` (773 nos defaults, ~53 MiB) |
| Ring de mirror | `mirror_ring_slots = max(64, 2^⌈lg scratch⌉)` slots × 64 KiB host-visible (binding 16); ring de heightmap paralelo × 2 KiB (binding 20, VS-13) |
| PushConstants | 92 B (com edit_job_offset e visible_chunk_capacity — VS-08) |
| BlockDefinition | 48 B std430 |
| VisibleChunk | 48 B (com neighbor_slots[6]) |

**Pendentes (backlog):** B7 (amostragem PBR real), B8 (distância em i64); B6 fechado pela VS-14 (alpha-test cutout + spawn determinístico; blending/translucidez real, alpha-to-coverage e probabilidade configurável seguem como BLK-29..31); fila de prioridade em heap, Hi-Z/oclusão, LOD, transparência, fusão generate+pack (scratch de 131 KB ida e volta), planos alocados adaptativamente por plane_count, camera-relative rendering, fallback clássico para GPUs sem VK_EXT_mesh_shader, caminho de leitura para SpecialVoxelRecord, persistência do journal em disco (mundo sobreviver ao unload) e camadas derivadas do mirror (navegação, física) quando houver necessidade.

## 10. Configuração e provisionamento runtime (VS-08)

Os parâmetros de streaming/compute deixaram de ser constantes de compilação. `src/engine/config.odin` carrega `vox.ini` (seções `[streaming]`/`[compute]`; `--config <caminho>` sobrescreve o caminho; arquivo ausente → defaults 8/9/10/5, 16, 3 + warning) **antes** de `CreateEngine` — erros de coerência/formato/parse encerram a inicialização com mensagem explicativa, sem criar a janela. As capacidades são sempre **derivadas**: `visible_capacity = |esfera(vision)|` (visíveis publicados por frame e capacidade da fila de trabalho), `resident_slots = ⌈|esfera(unload)| × 1,05⌉` (emenda 2026-11-06, era `|esfera(generation)|` — o conjunto vivo inclui CACHED até unload + transitório de aposentadoria B1; margem de 5% para o transitório, arredondamento `(n×105+99)/100` em u64), `scratch_chunks = batches_in_flight × chunks_per_batch`, `mirror_pages = ⌈|esfera(simulation)| × 1,5⌉`, `mirror_ring_slots = max(64, próxima potência de 2 ≥ scratch_chunks)`. Após o VMA, a soma dos bytes device é confrontada com o budget da heap device-local (VS-05) × 0,9 antes de qualquer buffer do motor ser criado (REQ-CFG-04). O shader conhece a capacidade de visíveis pelo push constant `visible_chunk_capacity` (92 B). O backlog B5 (raio de geração > slots) está absorvido: a bolha de geração cabe nos slots (esfera de unload × 1,05) por construção.

## 10. Bus de eventos de input, gravação e replay (VS-07, novo na v3.0)

Todo input (teclado/mouse/fechamento) e todo comando (`TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `Wait`, `ToggleTelemetry`, `TelemetrySnapshot`) é um evento tipado no módulo `src/engine/events.odin`. Callbacks GLFW são produtores puros (`proc "c"`, sem contexto/alocação) que empurram numa fila anel de 4.096; o loop drena uma vez por frame (após `PollEvents`, antes de `Update`): grava em JSONL (`bin/events/`, flush por linha) e despacha aos handlers por tipo. O conjunto de teclas pressionadas é derivado de `KeyPress`/`KeyRelease` (sem `glfw.GetKey`); `KeyPress{duration}` agenda o release em `t + duration`.

| Item | Valor |
|---|---|
| Fila | 4.096 eventos (anel); overflow descarta com contador + warning único |
| Timestamp | `t = glfw.GetTime() − t0` (t0 no fim da init); dreno compartilha o `t` |
| Replay | `--replay <jsonl>` (fatal pré-janela se inválido), cursor ordenado por `t`, `Wait` hold-until, skips contados, `--exit-after-replay` |
| Flags | `--record <caminho>` / `--no-record` (default grava em `bin/events/`); `--full-teardown` força teardown Vulkan completo |
| Validação | `tools/sim/events_check.py` — schema por tipo, `t` monotônico, exit 0/1 |

## 11. Tracy profiler (CPU zones) — VS-15

Profiling de CPU **opt-in por define de compilação**, via bindings Odin do [oskarnp/odin-tracy](https://github.com/oskarnp/odin-tracy) (v0.14.1) vendored em `vendor/tracy/` com a `tracy.lib` x64. A telemetria VS-05 (CSV/JSON/labels GPU) continua sendo a base, inalterada — Tracy é aditivo.

| Item | Valor |
|---|---|
| Define | `TRACY_ENABLE` (`#config`, default `false`); `run.bat` desligado, `run_tracy.bat` ligado |
| Wrapper | `src/engine/tracing.odin` (CPU/lifetime/locks) + `src/engine/tracing_gpu.odin` (GPU); desligado, toda a API é no-op inline e `TracingIsConnected()` é `false` |
| Link | `bindings.odin` vendored faz `foreign import tracy "tracy.lib"` **só com `TRACY_ENABLE=true`** (desligado usa `system:kernel32`) — o build default não depende da lib |
| Rebuild da lib | `tools\build_tracy_client.bat` (clone `--recurse-submodules` do odin-tracy, client C++ com `-MD` — o `-MT` do upstream colide com o CRT do VMA — e `-DTRACY_MANUAL_LIFETIME -DTRACY_DELAYED_INIT`: o startup do profiler é manual, depois do init Vulkan — ver BLK-37 no backlog) |
| Zones (main) | `frame`, `events_drain`, `engine_update`, `frame_wait`, `render_record`, `present`; sub-zones `service_completions`, `streaming_slice`, `mirror_service`, `publish_visible`, `edit_flush`, `apply_edits_record`, `builder_record`, `finalize_record`, `mesh_draw_record`, `barriers_record`, `drain`, `replay_cursor` |
| Zones (worker) | `worker_iteration`, `claim_batch`, `build_jobs`, `wait_batch_slot`, `submit_batch`; mundo `service_completions`, `streaming_slice`, `mirror_service`, `publish_world` e E1 |
| GPU zones | Contexto 0 (`graphics`): `apply_edits`, `build_work_queue`, `finalize_work_queue`, `draw_mesh`; contexto 1 (`compute`): `generate`, `pack` |
| Call stacks | `run_tracy.bat` passa `-define:TRACY_CALLSTACK=10`; cada zone CPU captura até 10 frames (custo adicional de stack walking e transmissão) |
| Locks | `queue_mutex` e `results_mutex`, anunciados no startup e instrumentados por `tracing_mutex_lock/unlock` |
| Extras | `FrameMark` por frame; threads `main`/`voxel_worker`; `AppInfo` com a config efetiva; plots `visible_chunks`, `work_items`, `empty_chunks` (só quando conectado) |

### Como rodar com a UI Tracy (AC-02, manual)

1. O pacote da UI Tracy (**v0.14.1**) já fica em `tools\tracy\` (`tracy-profiler.exe` + utilitários; não versionado, `*.exe` ignorado pelo git). Se precisar reobter: release oficial em https://github.com/wolfpld/tracy/releases/tag/v0.14.1.
2. Execute `run_tracy.bat` na raiz do repo (abre a UI + compila shaders + `odin build -define:TRACY_ENABLE=true -define:TRACY_CALLSTACK=10` + roda `vox.exe`). Se `vendor\tracy\tracy.lib` estiver ausente, o script aponta `tools\build_tracy_client.bat` e sai com erro.
3. Na UI Tracy, clique em **Connect** (ou aguarde o app aparecer no listen). O profiler sobe logo após o init Vulkan (`TRACY_MANUAL_LIFETIME`), então a janela do app pode aparecer alguns segundos antes da conexão ser possível.
4. Confira: frames no marcador `FrameMark`; sub-zones CPU e call stacks; locks `queue_mutex`/`results_mutex`; timeline GPU com `generate`/`pack` no compute e as quatro passagens na gráfica; plots atualizando por frame.

Sem a UI aberta o client roda desconectado com custo mínimo e o log mostra `Tracy IsConnected()=false`; os plots são pulados (`TracingIsConnected()` guarda a coleta). Memory profiling permanece em BLK-34.

`src/engine/tracing_gpu.odin` mantém uma query pool dedicada por fila, com ring de 4.096 timestamps. Cada zona consome dois IDs distintos (begin/end); coleta gráfica ocorre após `WaitTimelineSemaphore` e compute após a espera do lote. Apenas faixas coletadas são resetadas; pressão no ring omite zonas com warning único, sem overflow. Calibração inicial usa timestamp GPU + `GpuNewContext(period=timestampPeriod)`; re-sync ocorre a cada 60 coletas sem sobrescrever sync pendente. Os emits seguem `TracyVulkan.hpp` e usam a fila serial com lock interno. As pools da telemetria VS-05 são independentes e permanecem inalteradas.

**Captura sem UI:** `tools\tracy\tracy-capture.exe -o sessao.tracy` conecta headless ao app e grava o trace. Para listar cada zona GPU: `tools\tracy\tracy-csvexport.exe -g -u sessao.tracy > gpu.csv`. Salve capturas e exports de análise em `bin/debug/<VERSION_STRING>/tracy/`.

## 13. Física de gameplay — solver CPU sobre o mirror (VS-19, ADR-F1)

Física autoritativa roda **na thread principal**, sobre as APIs mutexadas do mirror C2 (VS-18: a worker continua única dona das mutações). `src/engine/physics.odin` é o módulo único; o algoritmo é espelhado bit a bit por `tools/sim/physics_sim.py` (42 checks).

### 13.1 Tabela física data-driven (REQ-PHY-01)

`PhysicsDefinition` (flags + fricção + restituição, por id de bloco) é exclusivamente CPU-side, carregada do objeto opcional `physics` por bloco em `assets/blocks.json` (`blocking`, `hittable`, `friction` ≥ 0, `restitution` em [0,1]; flags desconhecidas e tipos inválidos são fatais citando o bloco). Defaults: `blocking` = solidez do tipo, `hittable` = true, fricção 0.6, restituição 0. Ar (id 0) nunca bloqueia nem é atingível; a planta (4) é não-bloqueante e atingível. Fallback built-in (`physics_init_builtin`) tem paridade semântica. `BlockDefinition`/std430 de 48 B não mudou e nenhuma propriedade física vai ao shader.

### 13.2 Tempo, corpos e sweep (REQ-PHY-02/03/04)

- Passo fixo `PHYSICS_FIXED_DT` = 1/60 s por acumulador; teto de `PHYSICS_MAX_STEPS_PER_FRAME` = 5 passos/frame (dt de frame clampado em 0.25 s); o excesso é **descartado e contado** (`dropped_steps`) — nunca espiral de morte. Mesmo estado + mesma sequência de inputs ⇒ mesmo resultado (replay best-effort no modelo VS-07).
- Corpo = AABB alinhada à grade (`position` = canto mínimo). O deslocamento do passo resolve **X→Y→Z** em subpassos de ≤ 0,4 voxel (anti-tunneling), com clamp exato na fronteira do voxel: contato zera o componente (restituição da `PhysicsDefinition` quando > 0), preservando os demais — sliding. O bitmask `solid` filtra candidatos; `ids` + tabela resolvem a semântica.
- `grounded` é recalculado por contato real a cada passo (probe de apoio com eps; nada persiste após perder o apoio). Fricção: damping horizontal = `1 - friction·10·dt` ao apoiar (regra determinística documentada). Step-up: só após bloqueio horizontal, com TODA a AABB livre na altura +1 e apoio bloqueante no destino; limite de 1 voxel.

### 13.3 Fast-path de chão (REQ-PHY-05)

`physics_ground_probe` responde o apoio via `ChunkPage.heights` em O(1)/coluna quando: colunas cobertas pela AABB todas conhecidas, topo ≠ 0xFFFF, mesmo chunk no plano XZ e corpo inteiramente acima do topo mais alto. 0xFFFF, travessia de chunk, corpo abaixo do topo (interior/caverna), página ausente ou deslocamento vertical caem no sweep completo — o fast-path nunca elimina testes de teto/paredes e nunca contradiz o sweep (prova de equivalência na sim).

### 13.4 Mundo desconhecido (REQ-PHY-06)

Página ausente/em readback **nunca é interpretada como ar**: o passo inteiro é revertido (sem deslocamento parcial), o corpo congela (`frozen`) e a coordenada entra no map coalescido `pending_requests`, drenado pela worker em `mirror_update_bubble` (`physics_drain_requests` → `mirror_request_page`). Ao materializar, o movimento retoma em passos futuros. O raycast retorna `.UNKNOWN` com a coordenada que bloqueou a consulta.

### 13.5 Raycast DDA tri-state (REQ-PHY-08/09)

`physics_raycast` = Amanatides & Woo sobre coordenadas inteiras do mirror, com distância máxima obrigatória (> 0) e rejeição de direção nula (`.MISS` sem percorrer). A célula da origem é testada primeiro (hit com dist 0 e normal nula quando a origem está dentro de um bloco atingível). O hit decide pela tabela `HITTABLE` sobre `ids` — plantas não-sólidas são atingíveis e vêm antes de um sólido atrás. Resultado: `.HIT` (voxel/id/distância/normal da face) / `.MISS` (só ao esgotar a distância) / `.UNKNOWN` (página ausente antes do limite). Nenhum bitmask `hittable` existe.

### 13.6 Heightmap medido e integração do jogador (REQ-PHY-07/10)

`ChunkPage.heights` (1.024 colunas, índice `x|z<<5`, 0xFFFF = vazia) é **derivado do bitmask `solid` na materialização** (topo sólido real — arcos/flutuantes corretos); o journal E1 mantém as colunas incrementalmente. O ring `mirror_heightmap_ring` (binding 20) continua escrito pelo generate como **reserva futura**, mas o materialize o ignora (emenda do mantenedor, 2026-11-08).

O jogador é um corpo AABB (0,6 × 1,8 × 0,6) criado na main; `update_camera_movement` impõe a velocidade horizontal a partir do input (WASD relativo ao yaw) e `physics_tick` avança os passos na main — a câmera segue o corpo (olhos a 1,62). `TeleportTo` move o corpo junto; clique esquerdo dispara o raycast de seleção. Hooks públicos: `physics_body_create/remove/get`, `physics_tick`, `physics_raycast`.

### 13.7 Instrumentação Tracy

Zones: `physics_tick`, `physics_body_step`, `physics_ground_probe` (com subzone `physics_fastpath_scan`), `physics_freeze`, `physics_raycast`. Plots por frame: `physics_steps`, `physics_bodies`, `physics_contacts`, `physics_voxels`. Hook F7 (debug): `debug_validate_run` (packed×denso) + `debug_heights_parity` (heights × bitmask em todas as páginas) — atenção: esses debugs usam `vkDeviceWaitIdle` com a worker ativa e emitem THREADING warnings conhecidos (padrão pré-existente VS-04/VS-12); não usar em smokes de contagem de VUIDs.

## 12. Versionamento e saídas de debug

`src/version.odin` é a fonte única de `VERSION_MAJOR/MINOR/BUILD` e `VERSION_STRING` (formato `0.1.N`). O arquivo é gerado pelo tooling, mas versionado. O hook `tools/git-hooks/pre-commit`, ativado localmente por `git config core.hooksPath tools/git-hooks`, lê o build atual, incrementa N, reescreve as constantes e executa `git add src/version.odin` antes de cada commit. Não cria commits extras; falhas emitem warning e não bloqueiam o commit. O app loga a versão no startup e a inclui no `AppInfo` do Tracy.

Com cwd em `bin/`, `debug_paths_init` cria `debug/<VERSION_STRING>/` e suas subpastas. Log, telemetria e eventos ficam respectivamente em `log.txt`, `telemetry/` (CSV/JSON) e `events/` (JSONL); captures Tracy ficam em `tracy/`. Futuros smokes/ACs devem procurar esses caminhos versionados em vez dos antigos `bin/telemetry/` e `bin/events/` (históricos antigos permanecem como registrados). `tools/sim/` permanece reservado a ferramentas, não a saídas de runtime.

**Saída (BLK-39):** fast-exit é o padrão porque `vkDestroyDevice` no driver NVIDIA pode bloquear 30–60 s mesmo com as filas ociosas. O app executa `TracingShutdown(false)` — flush CPU do trace, sem coleta final GPU nem APIs Vulkan — e `os.exit(0)`, deixando worker/GLFW/Vulkan para reclaim do SO. `--full-teardown` mantém stop/join, waits, coleta GPU final e todos os destroys; smokes de VUIDs e CI devem usar essa flag para cobrir inclusive o fim do log. O trace fast-exit preserva as zonas até o fim da sessão pelo flush do client.
