---
id: SISTEMA-RENDERIZACAO
titulo: Renderização
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Renderização

Bem-vindo à renderização. Este documento responde, em ordem: **o que** a GPU desenha (geometria como dado, não como malha), **como** ela descobre o que desenhar (a fila de trabalho global), **como** monta a geometria de cada bloco (o mesh shader) e **como** pinta cada pixel (o fragment). Este é a visão de **Sistema**: para o quadro macro das três threads e dos cinco passos por frame, leia primeiro [[visao-geral]]; para os contratos struct-a-struct (Slang e Odin), a Referência cobre em [[ref-voxel-render]] e [[ref-shaders]].

## O ponto de partida: geometria não se guarda, se fabrica

A primeira coisa que você precisa entender é o que **não** existe neste motor: mesh caches. Você não vai encontrar arrays de vértices prontos na VRAM. A renderização nasceu de uma decisão arquitetural (spec [[VS-02-task-mesh-templates|VS-02]], historia completa nos links do fim do documento): **a geometria não é armazenada, é gerada por mesh shader a cada frame, a partir de dicionários**.

Por que não guardar a malha pronta? Porque a malha de um voxel é previsível a partir de duas coisas baratas de guardar: qual bloco ocupa aquele espaço e qual template de malha desse bloco. Guardar a malha pronta triplicaria a memória de vídeo com dados que se derivam em microssegundos, e ainda sairia errada assim que alguém removesse um voxel vizinho (a face escondida teria que ser regenerada de qualquer jeito). Guardando dicionários, edição = escrever um id na paleta; a geometria se corrige sozinha no próximo frame, porque ela nunca era "armazenada" para começar.

Os dois dicionários:

- `BlockDefinition` — "o que é este bloco": qual `MeshTemplate` usa, quais texturas em cada face, flags (transparente, não-sólido) e rotação yaw. Uma struct de **80 B** espelhada byte a byte entre Odin e Slang, descrita no fim do documento (contratos de trabalho).
- `MeshTemplate` — "como este bloco se desenha": pools de vértices/triângulos/UVs, incluindo os templates especiais para plantas, escadas e cantos. Os blocos "especiais" do Minecraft são só templates; nada de geometria hard-coded.

O que a VRAM guarda por chunk, então, é só o **pack comprimido** produzido pelo pipeline de streaming (detalhes em [[sistema-streaming-mundo]]): uma **bitmask de ocupação** (1 bit por voxel: há bloco aqui?), a **paleta** de ids (slot 0 é ar — invariante do AGENTS.md, nunca reciclar) e os **planos de material** para os blocos que têm camadas de material por voxel. Tudo que a GPU precisa para "expandir" isso em malha, o mesh shader sabe fazer.

## Mesh shader e task shader: duas peças, uma foi descartada

Antes de continuar, dois termos da pipeline Vulkan que este motor usa (e um que ele usou e abandonou):

- **Mesh shader** (`src/assets/shaders/render.slang`, entry `build_brick_mesh`): um estágio de Vulkan onde a GPU *produz* vértices e triângulos programaticamente, em vez de consumir buffers pré-gravados. A analogia útil: em vez de ler um livro de geometria, o mesh shader *escreve* o livro a cada frame, cópia por cópia. Neste motor, cada "cópia" é um workgroup que monta a malha de uma fração de brick.
- **Task shader**: um estágio opcional que roda *antes* do mesh shader e decide quantos workgroups de mesh serão emitidos — o "gerente" que distribui tarefas para os "operários". Foi assim que a VS-02 desenhou a renderização: o task shader varria os chunks visíveis e emitia um grupo de mesh por brick.
- **Brick**: a sub-unidade de chunk que a GPU processa. Um chunk de 32³ voxels é dividido em bricks menores; cada brick carrega 1 bit de ocupação por voxel numa word única, o que torna testes de "está vazio?" e "está cheio?" uma única comparação de inteiro. É a granularidade natural tanto do culling quanto da montagem de malha.

Por que o task shader foi eliminado? Na validação visual da VS-02, o **payload** — o mecanismo por que o task shader passa dados (por exemplo, qual brick) ao mesh shader — **provou-se quebrado no driver**: o payload chegava zerado. Em vez de contornar um driver complicado, a [[ADR-B10-fila-trabalho-global|ADR-B10]] trocou o paradigma inteiro por uma **fila de trabalho global**: um compute shader (o *builder*, ver abaixo) pré-seleciona os bricks e grava uma lista explícita de trabalhos num buffer; o draw passa a ser um único comando mesh indireto que consome essa lista. A lição didática: quando o hardware não entrega um canal confiável de dados entre estágios, materialize o canal — um buffer explícito é verificável, depurável e driver-independent.

## A fila de trabalho: a lista do que vale a pena desenhar

A **fila de trabalho** é um buffer device-local (binding 17) que funciona como a pauta do frame: cada entrada diz "renderize a subdivisão tal, da parte tal, do brick tal, do chunk visível tal". Quem escreve nela é o builder; quem lê é o draw.

Três propriedades que vale entender desde já:

1. **Comando único** (`vk.CmdDrawMeshTasksIndirectEXT`, emitido em `voxel_render_record`, `src/engine/voxel_render.odin:267`): a CPU grava *um* comando indireto e aponta para o buffer da fila. A GPU lê o comando, vê quantos workgroups pedir e executa. A CPU não sabe (nem precisa saber) quantos bricks sobreviveram ao culling — por isso existe o passo finalize.
2. **Finalize com clamp**: `finalize_work_queue` (1 thread de compute) fecha o campo `x` do comando indireto com clamp na capacidade. Se a fila ficou vazia (nada visível), `x` vira 0 e o comando é um no-op perfeito. Cuidado que a ADR-B10 registra: `CmdDrawMeshTasksIndirectCountEXT` não serve aqui — sua semântica é "N comandos", não "um comando cujo x = count". Detalhe fácil de errar, fácil de evitar.
3. **Formato do item — u32 no layout `16|10|2|2`**: `visible_index (16b) | brick (10b) | parte (2b) | subdivisão (2b)`. Você não precisa decorar; precisa entender que 16 bits para o índice de chunk limitam a visão prática a `r ≤ 25` (a esfera de raio 25 tem ~65 mil chunks — exatamente o teto do formato). Por que um u32 empacotado em vez de uma struct legível? Porque a fila é lida e escrita milhares de vezes por frame na GPU; empacotar o item inteiro num registrador é a diferença entre um scan rápido e gargalo. Histórico: [[VS-09-visible-index-16-bits|VS-09]], [[ADR-B12-visible-index-16-bits|ADR-B12]]. A capacidade vem do push constant `visible_chunk_capacity`, derivada do INI ([[VS-08-config-ini-provisionamento|VS-08]]).

Por que 16 bits bastam para o índice de chunk mas não para o identificador global? Porque a fila guarda o *índice no array de chunks visíveis do frame*, não a coordenada do mundo. O array visível tem no máximo a capacidade da esfera de visão — um número pequeno e controlado. A coordenada fica no `VisibleChunk`, e o item só aponta para ele.

O **subdivisão** (2 bits, gravada pelo pack, caminho B) é a resposta do motor ao orçamento do mesh shader: um brick cujos blocos têm templates pesados demais para caber num único workgroup é quebrado em até 4 partes × 8 voxels, e a subdivisão diz ao mesh shader qual fração ele monta. Um brick sobrevivente ao culling contribui `1 << subdivisão` itens à fila.

## A sequência no frame (main)

Tudo isso se encaixa em `voxel_render_prepare` (`src/engine/voxel_render.odin:82`), que grava no command buffer gráfico:

1. **Edições pendentes** (se houver): dispatch de `apply_voxel_edits` + barreira compute→compute. Só existe quando a worker fez flush de edições naquele frame (journal E1 — ver [[sistema-edicao-eventos]]).
2. **Reset da fila**: `CmdFillBuffer` zera as 8 words de estado do slot do ring do frame + barreira. Por um ring de 2 frames? Regra de coordenação geral do motor: o slot só é reescrito depois que a timeline gráfica confirma que o uso anterior terminou — sem corrida, sem esperar uma rodada inteira.
3. **Builder** (`build_work_queue`, compute na fila gráfica): 1 workgroup de 128 threads por chunk visível, dispatch com `visible_count`. É a etapa que decide o que entra na pauta; detalhe abaixo.
4. **Finalize** (`finalize_work_queue`, 1 thread): grava o comando indireto com clamp na capacidade, conforme explicado acima.
5. **Barreira** compute → draw indireto/mesh: garante que a fila e o comando estão prontos antes de ler.

Depois `voxel_render_record` liga a pipeline, o UBO de highlight (offset dinâmico por frame, VS-20) e os push constants, e emite o draw indireto. A espera da timeline de compute usa `COMPUTE_SHADER | MESH_SHADER_EXT` — quem primeiro lê a ocupação é o builder (consequência direta da ADR-B10: sem task shader, o primeiro toque na ocupação mudou de estágio).

## O builder: culling vazio → frustum → oclusão

O **builder** é o compute shader `build_work_queue` (`src/assets/shaders/render.slang:9`). Pense nele como um filtro em três camadas: cada camada é mais cara que a anterior, então as ordemamos da mais barata para a mais cara — eliminar cedo o que é trivial de eliminar.

1. **Early-out de chunk por frustum**: os planos do frustum são derivados por Gribb-Hartmann da **mesma** `view_projection_matrix` dos push constants (`frustum_planes_from_vp`, `common.slang:238`). "Mesma" é a palavra que importa: o frustum testado é exatamente o frustum renderizado — não pode haver divergência entre o que o builder cullou e o que a câmera enxerga. O teste (`aabb_outside_frustum`) é conservador p-vertex: só cull se o AABB estiver inteiramente fora de *um* plano. Por conservador? Porque um falso negativo (desenhar algo fora de vista) custa um frame; um falso positivo (cullar algo visível) deixa um buraco no mundo. O teste é uniforme no workgroup — nenhuma thread diverge; chunk fora retorna antes de ler header/ocupação, sem custo de memória.
2. **Culling de vazio**: a word de ocupação do brick = 0 (com a flag `CHUNK_FLAG_EMPTY` do header). Um teste de inteiro contra zero — a bitmask de ocupação existir como word única é exatamente para tornar issto quase de graça.
3. **Culling de frustum por brick**: o mesmo teste de AABB, agora sobre o AABB 4×2×4 do brick individual. Por repetir? Porque um chunk parcialmente visível tem bricks fora do frustum: cullar por chunk desperdiçaria; cullar por voxel custaria demais. Brick é a granularidade certa.
4. **Culling de oclusão** ([[ADR-B2-fronteiras-chunks|B2]]): `is_brick_occluded` só cull bricks **100% ocupados, 100% sólidos, com os 6 vizinhos também 100% sólidos**. Por tão restritivo? Porque testar parcialmente dentro do brick exigiria ler cada voxel e cada vizinho — mais caro que simplesmente desenhar. O caso coberto (bloco sólido enterrado em blocos sólidos) é o comum em cavernas e montanhas.

A escalação: contagem e escrita usam scan exclusivo em groupshared. Thread 0 faz o scan serial e reserva a faixa do chunk com um único `InterlockedAdd` no contador global; a fase de escrita rederiva os itens deterministicamente (cada thread consegue reconstruir o que o scan produziria — sem precisar guardá-lo). Estouro seta a word de overflow e os itens além da capacidade são descartados — clamps tanto no builder quanto no finalize, redundância de propósito.

## O mesh shader: montagem por template

`build_brick_mesh` (`render.slang:125`): 1 workgroup por item da fila (32 threads = `VOXELS_PER_BRICK`), 1 thread por voxel (ou por fração do brick quando subdividido). Cada thread faz três coisas:

- resolve o item por `SV_GroupID` e o chunk por `visible_index`;
- lê o id do bloco na **paleta** (`read_block_identifier`) — paleta é o array que mapeia "posição no brick → id de bloco", comprimido pelo pack; e lê o **template** (`mesh_templates`);
- para templates com `TEMPLATE_FLAG_HAS_FLUSH_FACES`, computa a **máscara de faces visíveis** (`compute_visible_face_mask`). **Culling tags** é o nome que damos a esta ideia: em vez de a rasterização descartar faces por winding (o `CULL_MODE_BACK` clássico), o mesh shader *decide por tag* quais faces emitir — uma face só é emitida se o vizinho não for sólido **e** a câmera estiver do lado de fora do plano da face. Por tag e não por winding? Porque plantas e cantos precisam de regras de visibilidade por vizinho, não por orientação — e porque a rotação yaw dos blocos faria o winding variar. `CULL_MODE_NONE` na pipeline: o culling por face é todo por tags, no mesh shader.
- conta triângulos que sobrevivem ao culling por tag de face (com rotação yaw aplicada via `ROTATED_FACE`).

Scan em groupshared dá os offsets de vértice/triângulo de cada thread; thread 0 chama `SetMeshOutputCounts`. A emissão posiciona os vértices do template com `rotate_vertex_yaw` no canto mundo do voxel e grava `clip_position` com a mesma VP do frustum — de novo, a mesma matriz em toda parte.

**Orçamento garantido por construção** (regra 5 do AGENTS.md): templates limitados a 32 vértices/24 triângulos por voxel, e o pack subdivide qualquer brick que excederia. Por isso a pipeline pode fixar `MESH_VERTEX_MAXIMUM = 256` / `MESH_TRIANGLE_MAXIMUM = 192` por workgroup — e o culling direcional nunca precisa ser *assumido* (o orçamento vale para o pior caso, não para o caso esperado).

**UVs** ([[VS-11-uvs-templates|VS-11]], [[ADR-U1-uvs-templates-malha|ADR-U1]]): templates com pool de UVs (binding 19) emitem a UV do pool; sem pool (`uv_offset == NO_TEMPLATE_UV_OFFSET`) emitem a sentinela `(-1,-1)` e o fragment cai no triplanar — mods procedurais sem unwrap continuam funcionando. Por uma sentinela em vez de um flag separado? Porque a UV já viaja no vertex como está; um valor convencido de "-1" custa zero bytes extras e zero ramificações no mesh shader.

## O fragment: seleção de camada por face

`shade_voxel` (`render.slang:233`) pinta um pixel. Seis passos:

1. **Normal por derivadas de tela** (`ddx`/`ddy` de `world_position`), corrigida por `faceforward` pela câmera. Detalhe sutil que a VS-21 corrigiu: a derivada aponta para *dentro*; sem o sinal, a seleção de face trocava +/− (convenção y-down de Vulkan).
2. **Camada por face** — a "**face selection**": o eixo dominante da normal mundial (maior |componente|; empate determinístico Y, X, Z; sinal escolhe ±) indexa `BlockDefinition.albedo_faces[6]` em ordem `FACE_NORMALS` (+X, −X, +Y, −Y, +Z, −Z). Por eixo dominante e não por face real do triângulo? Porque o mesh shader emite faces alinhadas ao voxel — a normal do triângulo *é* um eixo; extrair o eixo da derivada de tela é mais barato que carregar um atributo de face por vértice. E "topo" é +Y mundial, não eixo local após rotação — a textura de cima de um bloco rotacionado continua sendo a de cima.
3. **Amostragem NEAREST** (sampler único, `maxLod = 0`) — estética pixelada deliberada; texturas decodificadas por stb com flip Y explícito ([[ADR-T5-texturas-stb-face|ADR-T5]]). Com UV amostra a camada por UV; com a sentinela, cai no triplanar sobre posição mundo.
4. **Alpha-test cutout** ([[VS-14-plantas-alpha-test-spawn|VS-14]], [[ADR-P1-plantas-alpha-test-spawn|ADR-P1]]): blocos com `BLOCK_DEFINITION_FLAG_TRANSPARENT` descartam fragmentos com `albedo.a < 0.5` (limiar fixo). **Alpha-test** é o nome da técnica: em vez de blending translúcido (que exigiria ordenar os fragmentos de trás para frente), o pixel é opaco ou não existe — a folha da planta tem borda ou não tem. Sem blending nem ordenação; `CULL_MODE_NONE` permanece (as duas faces das plantas em X são necessárias). A solidez é separada (`NON_SOLID`, bit 1) da ocupação: uma planta ocupa o voxel (você não pode colocar outro bloco ali) mas não é sólida (você atravessa).
5. **Shading**: Lambert com luz direcional fixa + ambiente 0.2 + `emission_color`.
6. **Highlight da mira** ([[VS-20-gameplay-selecao-construcao-pulo|VS-20]]): `floor(world_position)` igual ao voxel-alvo publicado no UBO `target_highlight` (binding 21, offset dinâmico por frame) clareia a cor em 1.4×; `target_valid = 0` (miss/fora da bolha) é bit a bit o caminho antigo — por bit a bit? Para que o shader seja uma única linha de multiplicação, sem branch.

Saída opaca (`alpha = 1`), depth `LESS` com escrita.

## Fronteiras entre chunks (B2)

`VisibleChunk` carrega `neighbor_slots[6]` (mesma ordem de `FACE_NORMALS`), preenchidos pela CPU a cada frame com os slots dos vizinhos `CACHED`/`RENDERABLE` ([[ADR-B2-fronteiras-chunks|B2]]). `resolve_brick_slot` redireciona leituras de ocupação/solidez fora do chunk ao vizinho publicado; vizinho ausente ou em geração (`NEIGHBOR_SLOT_INVALID`) é tratado como ar.

Por tratar "não sei" como ar? Porque é o valor neutro: desenhar uma face a mais (que talvez devesse estar escondida) é visivelmente correto por um frame; *não* desenhar uma face necessária deixaria um buraco. E a geometria é corrigida naturalmente um frame depois, porque é reconstruída on-the-fly — nada para invalidar, nada para marcar sujo. O culling de oclusão e a máscara de faces usam esse mesmo redirecimento (nível de brick e de voxel).

## Contratos de trabalho

- **`BlockDefinition` — 80 B** (std430, espelhado Odin/Slang byte a byte): template, flags, `albedo_faces[6]`, rotação, `emission_color` (float3 alinhado a 16), roughness/metallic. Cresceu 48→72 B na VS-21 (6 faces) e a 80 B pela correção de alinhamento (2026-11-09).
- **`PushConstants` — 92 B**: `view_projection_matrix` (64), `camera_position` (12), `visible_chunk_offset`, `batch_job_offset`, `edit_job_offset`, `visible_chunk_capacity`. Estágios: mesh + fragment no gráfico (compute usa só `.COMPUTE`).
- **Bindings de render**: 6 (`visible_chunks`), 8 (`block_albedo_textures`, sampler 2D array), 17 (`work_queue`), 18 (`chunk_result_flags`), 19 (`template_uvs`), 20 (`mirror_heightmap_ring`), 21 (`target_highlight`, UBO com offset dinâmico por frame). Templates e registry: 10–12 e 7.

## Coordenação

O ring de 2 frames da fila de trabalho só é reescrito após a timeline gráfica confirmar o uso anterior; a main renderiza com o último publish válido da worker e nunca espera uma rodada inteira ([[visao-geral]], [[sistema-streaming-mundo]]). A telemetria GPU (`telemetry_timestamp_begin/end`) e as zones Tracy (`build_work_queue`, `finalize_work_queue`, `draw_mesh`) marcam os quatro passos por frame — se você estiver medindo, é por aí.

## Para ir mais fundo

Specs: [[VS-02-task-mesh-templates|VS-02]] (templates + fila), [[VS-06-culling-frustum|VS-06]] (frustum), [[VS-09-visible-index-16-bits|VS-09]] (item 16 bits), [[VS-11-uvs-templates|VS-11]] (UVs), [[VS-14-plantas-alpha-test-spawn|VS-14]] (alpha-test), [[VS-20-gameplay-selecao-construcao-pulo|VS-20]] (highlight), [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (faces/NEAREST/flip).
ADRs: B10 (fila global), B11 (frustum no builder), B12 (visible_index 16 bits), B2 (fronteiras), U1 (UVs com fallback), P1 (cutout), T5 (stb/flip/NEAREST/6 faces).
Referência: [[ref-voxel-render]] (Odin), [[ref-shaders]] (Slang: bindings, structs, entry points).
