package voxel_engine

import "core:math"
import "core:sync"
import "core:thread"
import "core:time"
import vulkan "vendor:vulkan"

// ============================================================================
// CORREÇÃO B1 — CICLO DE VIDA DOS SLOTS (RACE CONDITIONS)
// ----------------------------------------------------------------------------
// Problema original: ao descarregar um chunk em GENERATING, o slot voltava
// imediatamente para free_storage_slots enquanto a GPU ainda podia:
//   (i)   ter o lote de compute em voo escrevendo nesse slot;
//   (ii)  ter a tarefa parada em pending_tasks, prestes a ser submetida;
//   (iii) ao concluir o lote, promover para CACHED um chunk recriado na mesma
//         coordenada com OUTRO slot (problema ABA).
//
// Solução (3 mecanismos):
//   1. GERAÇÃO POR SLOT: slot_generations[] é incrementado a cada alocação e
//      a geração viaja em GenerationTask / ChunkRecord / SubmittedBatch. A
//      conclusão só promove GENERATING -> CACHED se (coordenada, slot,
//      geração) baterem exatamente.
//   2. CLAIM ATÔMICO: o worker publica o SubmittedBatch no MESMO trecho
//      crítico (queue_mutex) em que retira a tarefa de pending_tasks.
//      Invariante: toda tarefa está em EXATAMENTE um dos conjuntos
//      {pending_tasks, submitted_batches} — nunca em ambos, nunca em nenhum.
//   3. APOSENTADORIA DUAL: slots de chunks GENERATING descarregados são
//      liberados contra a TIMELINE DE COMPUTE do lote que os referencia;
//      slots CACHED/RENDERABLE continuam aposentando pela timeline gráfica.
//
// ============================================================================
// CORREÇÃO B2 — FRONTEIRAS DE CHUNK (FACES EM DOBRO)
// ----------------------------------------------------------------------------
// Problema original: is_voxel_solid (Slang) tratava coordenadas fora do chunk
// como ar, então uma face interna entre dois chunks sólidos adjacentes era
// emitida DUAS vezes (uma por chunk) — o dobro de trabalho em toda fronteira.
//
// Solução: VisibleChunk carrega os slots dos 6 vizinhos de face, preenchidos
// pela CPU a cada frame (visible_chunks é reconstruído por frame, logo os
// slots nunca ficam obsoletos). O mesh shader redireciona leituras de
// fronteira para a ocupação real do vizinho.
//
// Por que é seguro:
//  - Só publicamos slots de vizinhos CACHED/RENDERABLE: slot em GENERATING
//    pode estar sendo escrito pela fila de compute agora (lixo -> marca INVÁLIDO).
//  - A aposentadoria pela timeline gráfica (correção B1) garante que um vizinho
//    descarregado não tem o slot reciclado enquanto este frame estiver em voo.
//  - A espera da timeline de compute no submit (TASK|MESH stage) garante a
//    visibilidade de memória da ocupação do vizinho.
// Transiente: vizinho ausente/gerando é tratado como ar e a face é emitida;
// como a geometria é refeita a cada frame, ela desaparece sozinha no frame em
// que o vizinho concluir — sem dirty flags, sem re-mesh agendado.
//
// ============================================================================
// CORREÇÃO B4 — BATCHING REAL DE COMPUTE
// ----------------------------------------------------------------------------
// Problema original: a estrutura SubmittedBatch comportava 16 tarefas, mas o
// worker submetia 1 chunk por vkQueueSubmit2 — o custo fixo de submissão
// dominava o streaming.
//
// Solução: o worker drena até MAXIMUM_CHUNKS_PER_BATCH tarefas por claim, em
// ordem de prioridade (mais próximas da câmera primeiro), grava todos os jobs
// no ring e despacha generate com (4, 4, 4*N) e pack com (N, 1, 1) — os
// shaders já resolvem o índice do job por group_id (NADA mudou no Slang).
// Os invariantes do B1 seguem intactos: um claim = um lote = um valor de
// timeline, e cancelamento/conclusão já varrem tasks[:task_count].
// ============================================================================

// ============================================================================
// CAMINHO B — TEMPLATES DE MALHA (VOXELS COM MALHAS DIFERENTES, DATA-DRIVEN)
// ----------------------------------------------------------------------------
// A geometria de um bloco deixa de ser hardcoded (CUBE/PLANT) e vira dado:
// BlockDefinition.mesh_template_index aponta para uma tabela global de
// MeshTemplate em SSBO (vértices + triângulos packed), preenchida pela CPU
// no load — mods registram novos templates sem tocar nos shaders.
//
// REGRA DA ENGINE (tamanho único de voxel):
//   Todo voxel ocupa exatamente 1 unidade^3. Os vértices de um template
//   vivem em [0,1]^3 (validado no load). Se um objeto precisa de mais
//   espaço (porta, cama, mesa), ele é dividido em MÚLTIPLOS VOXELS, cada
//   um com seu próprio template-parte — a composição é feita no mundo,
//   nunca esticando um voxel.
//
// Garantia de orçamento (256 verts / 192 tris por mesh group):
//   Como o custo por voxel agora é variável, o pack soma o pior-caso de
//   cada brick e grava 2 bits de SUBDIVISÃO por brick na região de ocupação
//   (words [1026..1090)). O task shader despacha 1, 2 ou 4 mesh groups por
//   brick conforme o custo — bricks pesados usam grupos menores de voxels.
//   Contrato de carga: templates com <= 32 verts e <= 24 tris pior-caso;
//   com isso a subdivisão x4 (8 voxels/grupo) sempre cabe no orçamento.
//
// Culling por triângulo: cada triângulo do template carrega uma "face de
// culling" (0..5 colado na face do voxel -> some com vizinho sólido ou
// câmera atrás; 7 = nunca culpado). Rotação yaw (BlockDefinition.rotation,
// passos de 90°) é aplicada aos vértices e às faces de culling no shader —
// orientações não consomem IDs de bloco nem templates extras.
// ============================================================================

// ============================================================================
// E1 — EDIÇÃO DE VOXELS (ALTERAÇÕES BUFFERIZADAS, APLICADAS EM INTERVALOS)
// ----------------------------------------------------------------------------
// A origem das alterações (input, física, IA...) não importa: tudo vira um
// VoxelEditRequest em coordenada de MUNDO via request_voxel_edit(). A CPU
// acumula os pedidos numa fila com dedup "última escrita vence" por voxel e,
// a cada EDIT_FLUSH_INTERVAL_MS (ou sob demanda), despacha o lote para a GPU:
//
//   1. Pedidos cujo chunk está CACHED/RENDERABLE viram (slot, voxel, bloco)
//      e são agrupados por chunk (1 EditChunkJob = 1 workgroup no shader
//      apply_voxel_edits). Pedidos cujo chunk está GENERATING ou ausente
//      ficam em pending_edits na CPU — aplicados quando o chunk ficar pronto
//      (geração recomeça o terreno do zero; a edição cai DEPOIS do pack).
//   2. O flush grava jobs+edições num ring host-visible (2 slots de frame,
//      mesmo padrão do visible_chunks) e despacha o compute NO COMMAND
//      BUFFER DO FRAME, antes do draw, com barreira COMPUTE->TASK|MESH.
//   3. O shader atualiza planos de material, paleta (alocação/reciclagem de
//      slots por refcount — o pack passou a manter refcounts no ChunkHeader),
//      ocupação brick+coarse, flag EMPTY e os 2 bits de subdivisão (Caminho
//      B) dos bricks sujos. Resultado por edição vai para edit_results (a
//      CPU lê o slot do ring 2 frames depois, já protegido pela timeline).
//
// Por que NÃO precisa de re-mesh/dirty flag: a malha é reconstruída on-the-
// -fly a cada frame a partir da ocupação+paleta, e o culling de fronteira
// (B2) lê a ocupação do vizinho ao vivo — um bloco removido na fronteira
// revela a face do vizinho no próprio frame, sem trabalho extra.
//
// Limites do lote: MAX_EDITS_PER_FLUSH edições, MAX_EDIT_JOBS_PER_FLUSH
// chunks e MAX_EDITS_PER_CHUNK_PER_FLUSH por chunk por flush; o excedente
// permanece na fila para o próximo intervalo (backpressure natural).
// Chunks com CHUNK_FLAG_PALETTE_OVERFLOW são somente-leitura (rejeitados com
// código próprio) — caso patológico de >255 tipos num chunk.
// ============================================================================

// ============================================================================
// C2 — MIRROR CPU-SIDE (DUPLA MATERIALIZAÇÃO: VRAM P/ RENDER, RAM P/ GAMEPLAY)
// ----------------------------------------------------------------------------
// A verdade do mundo é worldgen + journal de edições (o fluxo do E1). A GPU e
// a RAM são DUAS views materializadas do mesmo journal: o formato packed na
// VRAM (render) e um grid denso u16 na RAM (gameplay: física, IA, saves).
//
//   ChunkPage (~68,1 KiB/chunk): cabeçalho + bitmask `solid`[1024]u32 +
//   `ids`[32768]u16 DENSO — sem paleta na CPU (elimina divergência de paleta;
//   chunk com PALETTE_OVERFLOW continua editável no mirror). Layout y-contíguo
//   (idx = y | z<<5 | x<<10): uma coluna vertical = 64 B = 1 linha de cache.
//
// Fluxo de preenchimento (latência 1-3 frames, fora do caminho quente):
//   1. Chunk dentro da bolha de simulação (RADIUS_SIMULATION, independente da
//      bolha de render) recebe uma ChunkPage PENDING_READBACK + um slot do
//      ring de export (host-visible, binding 16) acoplado à tarefa de geração.
//   2. O generate escreve o denso u16 DIRETO no ring (sem cópia extra: a
//      escrita do shader É o readback — write-combining sequencial).
//   3. Concluído o lote (timeline de compute), a CPU copia ring -> página,
//      faz o replay das edições retidas em page.pending (o export contém só
//      worldgen) e abre a página MATERIALIZED para leitura.
//   4. Daí em diante, TODA edição staged no flush do E1 é aplicada nos dois
//      lados (dupla materialização, mesma ordem, mesmo dedup — convergência
//      por construção; page.edit_seq serve p/ hash de paridade em debug).
//
// Se o ring estava cheio ou a tarefa já tinha sido reivindicada, o chunk fica
// com página PENDING sem slot e mirror_service_retries agenda um RE-EXPORT
// (tarefa export_only: roda só o generate — o pack NÃO pode rodar de novo,
// pois reescreveria o packed a partir do worldgen e apagaria edições).
//
// API de leitura tri-state: voxel_get devolve (amostra, ok) — ok=false quando
// o chunk não tem página ou ela está PENDING_READBACK. A política do
// "desconhecido" (bloquear, chutar, aguardar) é do consumidor; mirror_request
// puxa a página sob demanda. Descarte: sair da bolha evicta a página (o
// journal em pending_edits do E1 sobrevive; reentrada reexporta).
// ============================================================================

// ============================================================================
// SEÇÃO 1: CONSTANTES E LIMITES
// ============================================================================
CHUNK_SIZE :: 32

MAXIMUM_FRAMES_IN_FLIGHT          :: 2
MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT :: 3
MAXIMUM_CHUNKS_PER_BATCH          :: 16

RADIUS_VISION     :: 8
RADIUS_GENERATION :: 12
RADIUS_UNLOAD     :: 16

MAXIMUM_RESIDENT_CHUNKS :: 4096
MAXIMUM_VISIBLE_CHUNKS  :: 4096

// --- DIMENSÕES DA MEMÓRIA DO CHUNK ---
MATERIAL_PLANE_COUNT      :: 8 // Garante 256 blocos únicos por Chunk
BRICKS_PER_CHUNK          :: 1024
MATERIAL_WORDS_PER_CHUNK  :: MATERIAL_PLANE_COUNT * BRICKS_PER_CHUNK
// E1: ChunkHeader cresceu com refcount[256] (u32) por entrada da paleta:
// 16B de escalares + 1024B de paleta + 1024B de refcounts = 2064 bytes.
CHUNK_HEADER_BYTES        :: 2064
// CAMINHO B: +64 words com 2 bits de subdivisão por brick (custo de geometria).
// Layout por chunk: [0..1024) bricks, [1024..1026) coarse, [1026..1090) subdivisão.
OCCUPANCY_WORDS_PER_CHUNK :: BRICKS_PER_CHUNK + 2 + 64
CHUNK_VOXEL_COUNT         :: CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE

// --- E1: EDIÇÃO DE VOXELS ---
EDIT_FLUSH_INTERVAL_MS        :: 100.0 // intervalo entre flushes (0 = todo frame)
MAX_EDITS_PER_FLUSH           :: 4096  // edições por flush (16 KiB no ring)
MAX_EDIT_JOBS_PER_FLUSH       :: 256   // chunks tocados por flush
MAX_EDITS_PER_CHUNK_PER_FLUSH :: 1024  // teto por workgroup (espelha o Slang)
// Códigos de resultado (espelham o Slang; lidos de edit_results 2 frames após o flush)
EDIT_RESULT_APPLIED               :: 0
EDIT_RESULT_NOOP                  :: 1
EDIT_RESULT_REJECTED_PALETTE_FULL :: 2
EDIT_RESULT_REJECTED_OVERFLOW     :: 3

// --- C2: MIRROR CPU-SIDE ---
RADIUS_SIMULATION     :: 5   // bolha de gameplay (independente da bolha de render)
MIRROR_RING_SLOTS     :: 64  // exports em voo: 64 x 64 KiB = 4 MiB host-visible
MIRROR_PAGE_POOL_SIZE :: 768 // páginas fixas (~50 MiB; bolha ~523 chunks + folga)

PUSH_CONSTANT_STAGES :: vulkan.ShaderStageFlags{.COMPUTE, .TASK_EXT, .MESH_EXT, .FRAGMENT}

// ============================================================================
// SEÇÃO 2: TIPOS DE DADOS E DICIONÁRIO PBR (DATA-DRIVEN)
// ============================================================================
ChunkCoordinate :: [3]i32

// CAMINHO B: "geometria" de um bloco é um índice na tabela global de templates
// (SSBO), não mais um enum hardcoded. 0/1/2 são built-ins registrados pela CPU.
MESH_TEMPLATE_AIR   :: 0 // template vazio (0 vértices/0 triângulos)
MESH_TEMPLATE_CUBE  :: 1
MESH_TEMPLATE_PLANT :: 2

// CAMINHO B: template de micro-mesh (std430, 32 bytes). Espelha o Slang.
// REGRA DA ENGINE: todo voxel ocupa 1 unidade^3; vértices do template vivem em
// [0,1]^3 (validado no load). Objetos maiores são divididos em múltiplos
// voxels, cada um com seu próprio template (ex.: porta = 2 voxels empilhados).
//
// Triângulos ficam num pool global de u32, packed:
//   bits [0..8) v0 | [8..16) v1 | [16..24) v2 | [24..27) face de culling
// Face de culling: 0..5 = triângulo colado na face do voxel (some quando o
// vizinho é sólido ou a câmera está atrás); 7 = nunca culpado (interior,
// diagonais, cruzes de planta — requer CULL_MODE_NONE, ver B6).
//
// Contrato de carga (validado pela CPU ao registrar o template):
//   - vertex_count     <= 32  (MAX_TEMPLATE_VERTICES)
//   - worst_case_tris  <= 24  (pré-computado: nunca_culpados +
//                              soma por eixo de max(tris_face+, tris_face-))
// Com esses limites, a subdivisão x4 do pack (8 voxels/grupo) sempre cabe no
// orçamento do mesh shader: 8*32 = 256 vértices, 8*24 = 192 triângulos.
MeshTemplate :: struct {
	vertex_offset:   u32, // no pool global template_vertices ([]f32, xyz por vértice)
	vertex_count:    u32,
	triangle_offset: u32, // no pool global template_triangles ([]u32 packed)
	triangle_count:  u32,
	worst_case_tris: u32,
	flags:           u32, // bit 0: HAS_FLUSH_FACES (tem tris colados em faces)
	padding_0:       u32,
	padding_1:       u32,
}

// Alinhamento std430 perfeito (48 bytes) para upload na GPU
BlockDefinition :: struct {
	mesh_template_index:  u32, // CAMINHO B: índice em MeshTemplate (era geometry_type)
	albedo_texture_index: u32,
	pbr_texture_index:    u32,
	flags:                u32, // Bit 0: Transparente
	emission_color:       [3]f32,
	base_roughness:       f32,
	base_metallic:        f32,
	rotation:             u32, // CAMINHO B: yaw do template em passos de 90° (0..3)
	padding_2:            u32,
	padding_3:            u32,
}

// --- CAMINHO B: CONTRATO DE CARGA DOS TEMPLATES ---
MAX_TEMPLATE_VERTICES  :: 32 // por voxel; subdivisão x4 => 8*32 = 256 verts/grupo
MAX_TEMPLATE_TRIANGLES :: 24 // pior-caso por voxel; subdivisão x4 => 8*24 = 192 tris/grupo
CULL_FACE_NEVER        :: 7

pack_template_triangle :: proc(v0, v1, v2, cull_face: u32) -> u32 {
	return (v0 & 0xFF) | ((v1 & 0xFF) << 8) | ((v2 & 0xFF) << 16) | ((cull_face & 7) << 24)
}

// Pior-caso de triângulos para QUALQUER direção de câmera (supondo vizinhos
// de ar): triângulos nunca culpados +, por eixo, o máximo entre as duas faces.
compute_worst_case_tris :: proc(packed_triangles: []u32) -> u32 {
	never_culled: u32
	face_count: [6]u32
	for tri in packed_triangles {
		face := (tri >> 24) & 7
		if face == CULL_FACE_NEVER {
			never_culled += 1
		} else {
			face_count[face] += 1
		}
	}
	return never_culled +
		max(face_count[0], face_count[1]) +
		max(face_count[2], face_count[3]) +
		max(face_count[4], face_count[5])
}

// Validação no load (chamada ao registrar cada template vindo de mod).
validate_template :: proc(vertices: [][3]f32, packed_triangles: []u32) -> bool {
	if len(vertices) > MAX_TEMPLATE_VERTICES do return false
	if compute_worst_case_tris(packed_triangles) > MAX_TEMPLATE_TRIANGLES do return false
	for v in vertices {
		// Regra da engine: voxel de tamanho único — vértices em [0,1]^3.
		if v.x < 0 || v.x > 1 || v.y < 0 || v.y > 1 || v.z < 0 || v.z > 1 do return false
	}
	return true
}

// --- CAMINHO B: TEMPLATES BUILT-IN (índices 0, 1 e 2) ---
// Índice 0 (AR): template vazio {0, 0, 0, 0, 0, 0} — não emite nada.
// Índice 1 (CUBO): 8 vértices de canto + 12 triângulos, 2 por face.
// Índice 2 (PLANTA): dois quads cruzados na diagonal, 4 triângulos nunca
// culpados. Requer CULL_MODE_NONE no pipeline (ver B6: hoje plantas somem
// vistas por trás — corrigir o rasterizer junto com o alpha test).

// Vértice c do cubo: (c&1, (c>>1)&1, (c>>2)&1)
BUILTIN_CUBE_VERTICES: [8][3]f32 : {
	{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {1, 1, 0},
	{0, 0, 1}, {1, 0, 1}, {0, 1, 1}, {1, 1, 1},
}

// (v0, v1, v2, face) — winding CCW visto de fora; face 0..5 = +X,-X,+Y,-Y,+Z,-Z
BUILTIN_CUBE_TRIANGLES: [12][4]u32 : {
	{1, 3, 7, 0}, {1, 7, 5, 0}, // +X
	{0, 4, 6, 1}, {0, 6, 2, 1}, // -X
	{2, 7, 3, 2}, {2, 6, 7, 2}, // +Y
	{0, 1, 5, 3}, {0, 5, 4, 3}, // -Y
	{4, 5, 7, 4}, {4, 7, 6, 4}, // +Z
	{0, 3, 1, 5}, {0, 2, 3, 5}, // -Z
}

BUILTIN_PLANT_VERTICES: [8][3]f32 : {
	{0, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 0}, // quad diagonal 1
	{1, 0, 0}, {0, 0, 1}, {0, 1, 1}, {1, 1, 0}, // quad diagonal 2
}

BUILTIN_PLANT_TRIANGLES: [4][4]u32 : {
	{0, 1, 2, CULL_FACE_NEVER}, {0, 2, 3, CULL_FACE_NEVER},
	{4, 5, 6, CULL_FACE_NEVER}, {4, 6, 7, CULL_FACE_NEVER},
}

// TODO (integração): criar 3 buffers device-local (mesh_templates,
// template_vertices, template_triangles) nos bindings 10/11/12, subir os
// built-ins no init e registrar os de mods via validate_template +
// compute_worst_case_tris (HAS_FLUSH_FACES = existe tag 0..5).

// TODO (integração E1): criar os 3 buffers do ring de edição (bindings
// 13/14/15: jobs 8 KiB, edits 32 KiB, results 32 KiB — host-visible +
// HOST_COHERENT, mapeados em edit_jobs_mapped/voxel_edits_mapped/
// edit_results_mapped), a edit_pipeline (apply_voxel_edits, compute) e o
// chunk_headers com CHUNK_HEADER_BYTES = 2064 por entrada (refcounts novos).
// Sincronização extra necessária: NENHUMA — o flush roda no command buffer
// do frame, antes do draw, com barreira COMPUTE->TASK|MESH (ver Seção 7).

// TODO (integração C2): criar o ring de export do mirror no binding 16 —
// buffer de MIRROR_RING_SLOTS x CHUNK_VOXEL_COUNT x 2 B = 4 MiB,
// STORAGE_BUFFER | HOST_VISIBLE | HOST_COHERENT, mapeado em
// mirror_export_ring_mapped. Habilitar storageBuffer16BitAccess
// (VK_KHR_16bit_storage / Vulkan 1.1) na criação do device: o Slang declara o
// buffer como RWStructuredBuffer<uint16_t>. Adicionar o binding 16 ao
// descriptor set layout compartilhado (o generate passa a escrever nele).

ChunkState :: enum { GENERATING, CACHED, RENDERABLE }

// CORREÇÃO B1: o registro carrega a geração do slot no momento da alocação.
ChunkRecord :: struct {
	state:              ChunkState,
	storage_slot_index: u32,
	generation:         u32, // Anti-ABA: distingue "mesmo slot, novo chunk"
}

// CORREÇÃO B1: a tarefa carrega a geração para validação no cancelamento
// e na conclusão do lote.
GenerationTask :: struct {
	coordinate:         ChunkCoordinate,
	storage_slot_index: u32,
	generation:         u32,
	// C2: slot do ring de export do mirror reservado p/ esta tarefa
	// (-1 = sem export). Preenchido pela thread principal ao enfileirar.
	mirror_ring_slot:   i32,
	// C2: true = RE-EXPORT (chunk já CACHED; o worker roda só o generate,
	// NUNCA o pack — repackar a partir do scratch apagaria edições já
	// aplicadas no formato packed). Lotes export_only têm 1 tarefa.
	export_only:        bool,
}

SubmittedBatch :: struct {
	compute_timeline_value: u64,
	task_count:             int,
	tasks:                  [MAXIMUM_CHUNKS_PER_BATCH]GenerationTask,
}

// Slot de chunk CACHED/RENDERABLE: pode estar referenciado por frames gráficos
// em voo -> liberar quando a TIMELINE GRÁFICA ultrapassar release_frame_value.
RetiringSlot :: struct {
	storage_slot_index:  u32,
	release_frame_value: u64,
}

// CORREÇÃO B1: slot de chunk descarregado em GENERATING. A fila de compute
// ainda pode escrever nele -> liberar apenas quando a TIMELINE DE COMPUTE
// ultrapassar o valor do lote que o referencia. Não há referência gráfica
// (o chunk nunca chegou a ser RENDERABLE), então a timeline gráfica não
// protegeria nada — e seria tarde demais: o slot seria reusado antes.
RetiringComputeSlot :: struct {
	storage_slot_index:     u32,
	release_timeline_value: u64, // valor da timeline de COMPUTE
}

// C2: 32 bytes (múltiplo de 16) — espelha o Slang. mirror_ring_slot >= 0
// manda o generate exportar o denso u16 p/ o ring do mirror (binding 16).
ChunkGenerationJob :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	mirror_ring_slot:   i32,
	padding:            [3]u32,
}

// CORREÇÃO B2: sentinela compartilhada com o Slang (NEIGHBOR_SLOT_INVALID).
NEIGHBOR_SLOT_INVALID :: max(u32)

// Ordem idêntica ao FACE_NORMALS do Slang: +X, -X, +Y, -Y, +Z, -Z
NEIGHBOR_OFFSETS :: [6]ChunkCoordinate{ {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1} }

// CORREÇÃO B2: 48 bytes (múltiplo de 16) — stride exigido por StructuredBuffer.
// O buffer de visíveis deve ser dimensionado com size_of(VisibleChunk) por entrada.
VisibleChunk :: struct {
	chunk_world_origin: [3]i32,
	storage_slot_index: u32,
	neighbor_slots:     [6]u32, // NEIGHBOR_SLOT_INVALID se ausente ou GENERATING
	padding:            [2]u32,
}
PushConstants      :: struct {
	view_projection_matrix: matrix[4, 4]f32,
	camera_position:        [3]f32,
	visible_chunk_offset:   u32,
	batch_job_offset:       u32,
	edit_job_offset:        u32, // E1: base do ring de EditChunkJob deste frame (88 bytes)
}

// --- E1: EDIÇÃO DE VOXELS ---
// Pedido em coordenada de MUNDO: sobrevive a remapeamentos de slot e a
// descarregamentos — só vira (slot, voxel) no momento do flush.
VoxelEditRequest :: struct {
	world_voxel: [3]i32,
	block_id:    u32,
}

// Espelha o Slang (16 bytes). As edições do job ocupam
// voxel_edits[first_edit .. first_edit + edit_count).
EditChunkJob :: struct {
	storage_slot_index: u32,
	first_edit:         u32,
	edit_count:         u32,
	padding:            u32,
}

EditRingCounts :: struct { job_count: u32, edit_count: u32 }

EditManager :: struct {
	// Fila ativa com dedup "última escrita vence" por voxel de mundo.
	queue:      [dynamic]VoxelEditRequest,
	lookup:     map[[3]i32]int,
	// Pedidos cujo chunk está GENERATING ou fora do raio: reaplicados quando
	// o chunk ficar pronto. (Sem persistência em disco ainda — ver backlog.)
	pending:    map[ChunkCoordinate][dynamic]VoxelEditRequest,
	last_flush: time.Tick,
	force_next_flush: bool,
	// Staging do flush corrente: montado antes da espera frames-in-flight e
	// copiado ao ring depois dela (o slot do ring só é reescrito quando a GPU
	// já terminou o frame de 2 atrás — mesma garantia do visible_chunks).
	staged_jobs:  [dynamic]EditChunkJob,
	staged_edits: [dynamic]u32,
	// Contadores por slot do ring para o readback de edit_results.
	ring_counts: [MAXIMUM_FRAMES_IN_FLIGHT]EditRingCounts,
	// Estatísticas acumuladas do feedback (diagnóstico/gameplay).
	stats_applied:  u64,
	stats_noop:     u64,
	stats_rejected: u64,
	stats_deferred: u64, // ficaram para o próximo flush (tetos do lote)
}

// --- C2: MIRROR CPU-SIDE ---
MirrorPageState :: enum u8 {
	PENDING_READBACK, // export em voo (ou aguardando slot de ring): leitura = unknown
	MATERIALIZED,     // aberta p/ leituras; atualizada pelo journal do E1
}

// Página-espelho de um chunk 32^3 (~68,1 KiB). Denso SEM PALETA: a paleta é
// um detalhe do formato packed de render; na RAM o ID é direto (u16), o que
// elimina qualquer risco de divergência de paleta entre os dois lados e
// mantém chunks com PALETTE_OVERFLOW editáveis aqui (reconciliação via o
// feedback do E1). Layout y-contíguo: idx = y | z<<5 | x<<10 (uma coluna
// vertical = 64 B contíguos = 1 linha de cache; varredura de chão sequencial).
MirrorChunkPage :: struct {
	coord:     ChunkCoordinate,
	edit_seq:  u32, // revisão do journal aplicada (paridade com a GPU em debug)
	state:     MirrorPageState,
	ring_slot: i32, // slot do ring de export reservado p/ o preenchimento (-1 = nenhum)
	// Edições staged p/ a GPU enquanto PENDING_READBACK (o export contém só
	// worldgen). Dedup "última escrita vence"; replay na materialização.
	pending:   [dynamic]VoxelEditRequest,
	solid:     [CHUNK_VOXEL_COUNT / 32]u32, // 4 KiB: derivado de id != 0 (regra da ocupação)
	ids:       [CHUNK_VOXEL_COUNT]u16,      // 64 KiB densos
}

MirrorRingEntry :: struct {
	used:       bool,
	coord:      ChunkCoordinate,
	generation: u32, // anti-ABA: casa com a geração do slot de GPU no pedido
}

MirrorManager :: struct {
	// Pool fixo de páginas (endereços estáveis — o hash guarda ponteiros).
	pool:       []MirrorChunkPage,
	free_pages: [dynamic]u32,
	pages:      map[ChunkCoordinate]^MirrorChunkPage,
	ring:       [MIRROR_RING_SLOTS]MirrorRingEntry,
	// Diagnóstico.
	stats_pages_live:  int,
	stats_pool_misses: u64,
	stats_ring_misses: u64,
}

// ============================================================================
// SEÇÃO 3: CONTEXTO VULKAN (1.4 - TIMELINE SEMAPHORES & SYNC2)
// ============================================================================
VulkanContext :: struct {
	device:         vulkan.Device,
	graphics_queue: vulkan.Queue,
	compute_queue:  vulkan.Queue,

	graphics_timeline: vulkan.Semaphore,
	compute_timeline:  vulkan.Semaphore,
	image_available:   [MAXIMUM_FRAMES_IN_FLIGHT]vulkan.Semaphore,
	render_finished:   [MAXIMUM_FRAMES_IN_FLIGHT]vulkan.Semaphore,

	graphics_command_buffers: [MAXIMUM_FRAMES_IN_FLIGHT]vulkan.CommandBuffer,
	compute_command_buffers:  [MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT]vulkan.CommandBuffer,

	pipeline_layout:     vulkan.PipelineLayout,
	descriptor_set:      vulkan.DescriptorSet,
	generation_pipeline: vulkan.Pipeline,
	packing_pipeline:    vulkan.Pipeline,
	edit_pipeline:       vulkan.Pipeline, // E1: apply_voxel_edits (compute no command buffer do frame)
	mesh_pipeline:       vulkan.Pipeline,

	generation_jobs_mapped: [^]ChunkGenerationJob,
	// CORREÇÃO B2: buffer deve ter size_of(VisibleChunk) = 48 bytes por entrada
	// (2 frames x MAXIMUM_VISIBLE_CHUNKS x 48 B = 384 KiB).
	visible_chunks_mapped:  [^]VisibleChunk,
	// E1: ring host-visible de edição (2 slots de frame; HOST_COHERENT para
	// edit_results dispensar invalidate no readback):
	//   jobs    2 x MAX_EDIT_JOBS_PER_FLUSH x 16 B   = 8 KiB
	//   edits   2 x MAX_EDITS_PER_FLUSH     x 4 B    = 32 KiB
	//   results 2 x MAX_EDITS_PER_FLUSH     x 4 B    = 32 KiB
	edit_jobs_mapped:    [^]EditChunkJob,
	voxel_edits_mapped:  [^]u32,
	edit_results_mapped: [^]u32,
	// C2: ring de export do mirror — host-visible + HOST_COHERENT
	// (MIRROR_RING_SLOTS x CHUNK_VOXEL_COUNT x 2 B = 4 MiB), STORAGE_BUFFER,
	// binding 16. O generate escreve direto aqui (a escrita É o readback);
	// a CPU lê após a timeline do lote + acquire por WaitSemaphores.
	// Requer storageBuffer16BitAccess (Vulkan 1.1 / VK_KHR_16bit_storage).
	mirror_export_ring_mapped: [^]u16,
}

PlatformHooks :: struct {
	should_close:            proc() -> bool,
	update_camera:           proc(camera_position: ^[3]f32, view_projection_matrix: ^matrix[4, 4]f32),
	acquire_swapchain_image: proc(image_available_semaphore: vulkan.Semaphore),
	begin_rendering:         proc(command_buffer: vulkan.CommandBuffer),
	end_rendering:           proc(command_buffer: vulkan.CommandBuffer),
	present_swapchain_image: proc(render_finished_semaphore: vulkan.Semaphore),
}

ChunkManager :: struct {
	// --- Domínio exclusivo da thread principal ---
	active_chunks:          map[ChunkCoordinate]ChunkRecord,
	free_storage_slots:     [dynamic]u32,
	retiring_slots:         [dynamic]RetiringSlot,
	retiring_compute_slots: [dynamic]RetiringComputeSlot, // CORREÇÃO B1
	slot_generations:       []u32,                        // CORREÇÃO B1: [MAXIMUM_RESIDENT_CHUNKS], contador anti-ABA
	last_camera_chunk:      ChunkCoordinate,

	highest_completed_compute_value: u64,

	// --- Domínio de queue_mutex (thread principal <-> worker) ---
	// CORREÇÃO B1: submitted_batches migrou para esta trava. É ela que
	// serializa o "pop + claim" do worker contra o "cancelamento" do
	// descarregamento — é isso que fecha a janela de corrida.
	queue_mutex:           sync.Mutex,
	queue_condition:       sync.Cond,
	pending_tasks:         [dynamic]GenerationTask,
	// C2: re-exports do mirror (export_only) — fila separada p/ não misturar
	// com o dreno por prioridade do B4: o worker reivindica 1 por lote e
	// NUNCA roda o pack nele (o packed já existe e contém edições).
	pending_export_tasks:  [dynamic]GenerationTask,
	submitted_batches:     [dynamic]SubmittedBatch,
	priority_camera_chunk: ChunkCoordinate,

	worker_stop_requested: u32,
}

vulkan_context: VulkanContext
chunk_manager:  ChunkManager
edit_manager:   EditManager
mirror_manager: MirrorManager // C2
platform_hooks: PlatformHooks

// ============================================================================
// SEÇÃO 4: FUNÇÕES AUXILIARES E SINCRONIZAÇÃO
// ============================================================================
vulkan_check :: proc(result: vulkan.Result) { if result != .SUCCESS { panic("Erro Vulkan") } }

read_timeline_value :: proc(semaphore: vulkan.Semaphore) -> u64 {
	current_value: u64
	vulkan_check(vulkan.GetSemaphoreCounterValue(vulkan_context.device, semaphore, &current_value))
	return current_value
}

wait_for_timeline_value :: proc(semaphore: vulkan.Semaphore, target_value: u64) {
	s := semaphore; v := target_value
	wait_info := vulkan.SemaphoreWaitInfo{ sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &s, pValues = &v }
	vulkan_check(vulkan.WaitSemaphores(vulkan_context.device, &wait_info, max(u64)))
}

calculate_squared_distance :: proc(first, second: ChunkCoordinate) -> int {
	dx := int(first.x - second.x); dy := int(first.y - second.y); dz := int(first.z - second.z)
	return dx * dx + dy * dy + dz * dz
}

// Identidade completa de uma tarefa: coordenada + slot + geração.
task_matches :: proc(task: GenerationTask, coord: ChunkCoordinate, record: ChunkRecord) -> bool {
	return (
		task.coordinate == coord &&
		task.storage_slot_index == record.storage_slot_index &&
		task.generation == record.generation
	)
}

// ============================================================================
// SEÇÃO 5: STREAMING DE CHUNKS & HISTERESE (THREAD PRINCIPAL)
// ============================================================================

// CORREÇÃO B1 — Decide com segurança o destino do slot de um chunk
// descarregado em GENERATING. Chamada APENAS pela thread principal.
//
// Como o claim do worker (pop + registro do lote) é um único trecho crítico
// sob queue_mutex, a tarefa está em EXATAMENTE um destes lugares:
//   a) pending_tasks     -> a GPU nunca viu o slot: cancela e libera na hora.
//   b) submitted_batches -> a GPU vai escrever no slot: aposenta contra a
//                           timeline de compute do lote que o referencia.
//   c) nenhum dos dois   -> o lote já concluiu e foi processado (defensivo;
//                           com a validação por geração, um chunk em
//                           GENERATING sempre estará em (a) ou (b)).
//
// Custo: O(pendentes + lotes) por descarregamento. Se isso pesar (teleportes
// com milhares de descarregamentos por frame), trocar a varredura por
// tombstones com remoção preguiçosa no worker.
retire_generating_slot :: proc(coord: ChunkCoordinate, record: ChunkRecord) {
	sync.mutex_lock(&chunk_manager.queue_mutex)
	defer sync.mutex_unlock(&chunk_manager.queue_mutex)

	// (a) Ainda pendente: cancela antes que o worker a reivindique.
	for task, i in chunk_manager.pending_tasks {
		if task_matches(task, coord, record) {
			unordered_remove(&chunk_manager.pending_tasks, i)
			append(&chunk_manager.free_storage_slots, record.storage_slot_index)
			return
		}
	}

	// (b) Já reivindicada/submetida: a GPU ainda pode escrever no slot.
	//     Aposenta contra a timeline de COMPUTE — nunca contra a gráfica.
	for batch in chunk_manager.submitted_batches {
		for task in batch.tasks[:batch.task_count] {
			if task_matches(task, coord, record) {
				append(&chunk_manager.retiring_compute_slots, RetiringComputeSlot{record.storage_slot_index, batch.compute_timeline_value})
				return
			}
		}
	}

	// (c) Caminho defensivo: nenhuma escrita de GPU pendente pode existir.
	append(&chunk_manager.free_storage_slots, record.storage_slot_index)
}

update_chunk_streaming :: proc(camera_position: [3]f32, submitted_frame_count: u64) {
	camera_chunk := ChunkCoordinate {
		i32(math.floor(camera_position.x / CHUNK_SIZE)),
		i32(math.floor(camera_position.y / CHUNK_SIZE)),
		i32(math.floor(camera_position.z / CHUNK_SIZE)),
	}

	if camera_chunk == chunk_manager.last_camera_chunk { return }
	chunk_manager.last_camera_chunk = camera_chunk

	sync.mutex_lock(&chunk_manager.queue_mutex)
	chunk_manager.priority_camera_chunk = camera_chunk
	sync.mutex_unlock(&chunk_manager.queue_mutex)

	// 1. Descarrega os distantes
	to_unload := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in chunk_manager.active_chunks {
		if calculate_squared_distance(camera_chunk, coord) > RADIUS_UNLOAD * RADIUS_UNLOAD {
			append(&to_unload, coord)
		}
	}
	for coord in to_unload {
		record := chunk_manager.active_chunks[coord]
		if record.state == .GENERATING {
			// CORREÇÃO B1: NUNCA devolver o slot direto à free list — a GPU
			// pode estar prestes a escrever nele (lote em voo) ou a tarefa
			// pode ainda estar pendente de submissão.
			retire_generating_slot(coord, record)
		} else {
			append(&chunk_manager.retiring_slots, RetiringSlot{record.storage_slot_index, submitted_frame_count})
		}
		mirror_forget_chunk(coord, record) // C2: evicta a página (se houver)
		delete_key(&chunk_manager.active_chunks, coord)
	}

	// 2. Atualiza Visibilidade
	for coord, &record in chunk_manager.active_chunks {
		is_visible := calculate_squared_distance(camera_chunk, coord) <= RADIUS_VISION * RADIUS_VISION
		if record.state == .CACHED && is_visible { record.state = .RENDERABLE }
		else if record.state == .RENDERABLE && !is_visible { record.state = .CACHED }
	}

	// 3. Pede novos (Geração)
	new_tasks := make([dynamic]GenerationTask, context.temp_allocator)
	for x in -RADIUS_GENERATION..=RADIUS_GENERATION {
	for y in -RADIUS_GENERATION..=RADIUS_GENERATION {
	for z in -RADIUS_GENERATION..=RADIUS_GENERATION {
		coord := camera_chunk + ChunkCoordinate{i32(x), i32(y), i32(z)}
		if calculate_squared_distance(camera_chunk, coord) > RADIUS_GENERATION * RADIUS_GENERATION { continue }
		if coord in chunk_manager.active_chunks { continue }

		if len(chunk_manager.free_storage_slots) > 0 {
			slot := pop(&chunk_manager.free_storage_slots)
			// CORREÇÃO B1: cada alocação gera uma nova identidade para o slot.
			chunk_manager.slot_generations[slot] += 1
			generation := chunk_manager.slot_generations[slot]
			chunk_manager.active_chunks[coord] = ChunkRecord{.GENERATING, slot, generation}
			task := GenerationTask{ coordinate = coord, storage_slot_index = slot, generation = generation, mirror_ring_slot = -1 }
			// C2: dentro da bolha de simulação, a própria geração já exporta o
			// denso p/ o mirror (página PENDING + slot de ring acoplado à tarefa).
			if calculate_squared_distance(camera_chunk, coord) <= RADIUS_SIMULATION * RADIUS_SIMULATION {
				if page := mirror_page_acquire(coord); page != nil {
					if ring := mirror_ring_try_reserve(coord, generation); ring >= 0 {
						task.mirror_ring_slot = ring
						page.ring_slot = ring
					}
				}
			}
			append(&new_tasks, task)
		}
	}
	}
	}
	if len(new_tasks) > 0 {
		sync.mutex_lock(&chunk_manager.queue_mutex)
		append(&chunk_manager.pending_tasks, ..new_tasks[:])
		sync.cond_signal(&chunk_manager.queue_condition)
		sync.mutex_unlock(&chunk_manager.queue_mutex)
	}

	// 4. C2: bolha de simulação (independente da bolha de render) — mantém
	// páginas para os chunks próximos e evicta as que saíram.
	sim_radius2 := RADIUS_SIMULATION * RADIUS_SIMULATION
	// 4a. Evicta páginas cujo chunk saiu da bolha (o render segue intacto).
	to_forget := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in mirror_manager.pages {
		if calculate_squared_distance(camera_chunk, coord) > sim_radius2 {
			append(&to_forget, coord)
		}
	}
	for coord in to_forget {
		record, active := chunk_manager.active_chunks[coord]
		if active { mirror_forget_chunk(coord, record) } else { mirror_page_release(coord) }
	}
	// 4b. Pede páginas p/ chunks da bolha que ainda não têm (cobertura de
	// chunks que ENTRARAM na bolha já gerados: re-export; em geração: acopla).
	for coord, record in chunk_manager.active_chunks {
		if calculate_squared_distance(camera_chunk, coord) > sim_radius2 { continue }
		if coord in mirror_manager.pages { continue }
		mirror_request_page(coord, record)
	}
}

// ============================================================================
// SEÇÃO 5B: EDIÇÃO DE VOXELS — FILA, DEDUP E FLUSH INTERVALAR (E1)
// ============================================================================
// Divisão de trabalho:
//  - CPU (aqui): bufferiza pedidos em coordenada de MUNDO, faz dedup
//    "última escrita vence" por voxel, segura pedidos de chunks não prontos
//    e, a cada intervalo, converte para (slot, voxel, bloco) agrupado por
//    chunk — só chunks CACHED/RENDERABLE entram no lote (a GPU jamais disputa
//    um slot com a fila de geração, preservando o B1).
//  - GPU (apply_voxel_edits no Slang): 1 workgroup por chunk atualiza planos,
//    paleta+refcounts, ocupação brick/coarse, flag EMPTY e subdivisão (B).
//
// O flush roda no COMMAND BUFFER DO FRAME, antes do draw, com barreira
// COMPUTE->TASK|MESH — como a malha é refeita on-the-fly a cada frame, a
// alteração aparece no mesmo frame, sem dirty flag nem re-mesh agendado.

// Divisão com piso para coordenadas negativas (mundo -1 -> chunk -1, local 31).
floor_div_i32 :: proc(value, divisor: i32) -> i32 {
	quotient  := value / divisor
	remainder := value % divisor
	if remainder != 0 && ((remainder < 0) != (divisor < 0)) { quotient -= 1 }
	return quotient
}

// Mundo -> (chunk, índice denso do voxel). Layout denso igual ao Slang:
// x | z<<5 | y<<10.
voxel_chunk_and_index :: proc(world_voxel: [3]i32) -> (chunk: ChunkCoordinate, voxel_index: u32) {
	chunk = ChunkCoordinate{
		floor_div_i32(world_voxel.x, CHUNK_SIZE),
		floor_div_i32(world_voxel.y, CHUNK_SIZE),
		floor_div_i32(world_voxel.z, CHUNK_SIZE),
	}
	local_x := world_voxel.x - chunk.x * CHUNK_SIZE
	local_y := world_voxel.y - chunk.y * CHUNK_SIZE
	local_z := world_voxel.z - chunk.z * CHUNK_SIZE
	voxel_index = u32(local_x) | (u32(local_z) << 5) | (u32(local_y) << 10)
	return
}

// API pública: empilha (ou sobrescreve) um pedido de alteração. Deve ser
// chamada na thread principal (mesma do loop); se gameplay ganhar threads
// próprias, proteger queue+lookup com queue_mutex.
request_voxel_edit :: proc(world_voxel: [3]i32, block_id: u32) {
	if block_id > 65535 { return } // fora do domínio de 16 bits do registro do lote
	if index, found := edit_manager.lookup[world_voxel]; found {
		edit_manager.queue[index].block_id = block_id // última escrita vence
		return
	}
	append(&edit_manager.queue, VoxelEditRequest{world_voxel, block_id})
	edit_manager.lookup[world_voxel] = len(edit_manager.queue) - 1
}

// Atalho para explosões/pincéis: mesma semântica, um voxel por chamada.
request_voxel_edits_in_box :: proc(min_corner, max_corner: [3]i32, block_id: u32) {
	for x in min_corner.x..=max_corner.x {
	for y in min_corner.y..=max_corner.y {
	for z in min_corner.z..=max_corner.z {
		request_voxel_edit({x, y, z}, block_id)
	}
	}
	}
}

// Move o pedido para a lista pendente do chunk (chunk gerando ou ausente),
// com dedup por voxel dentro da lista.
edit_defer_to_pending :: proc(chunk: ChunkCoordinate, request: VoxelEditRequest) {
	list := edit_manager.pending[chunk] // dynamic array compartilha o backing
	for &existing in list {
		if existing.world_voxel == request.world_voxel {
			existing.block_id = request.block_id // última escrita vence
			edit_manager.pending[chunk] = list
			return
		}
	}
	append(&list, request)
	edit_manager.pending[chunk] = list // append pode realocar: escreve de volta
	// Nota: sem persistência em disco ainda — pendências de chunks que nunca
	// mais forem carregados ficam na memória (capar por TTL/quantidade é
	// melhoria futura, junto com o save do mundo).
}

edit_flush_due :: proc() -> bool {
	if edit_manager.force_next_flush { return len(edit_manager.queue) > 0 || len(edit_manager.pending) > 0 }
	if len(edit_manager.queue) == 0 && len(edit_manager.pending) == 0 { return false }
	if EDIT_FLUSH_INTERVAL_MS <= 0 { return true }
	return time.duration_milliseconds(time.tick_since(edit_manager.last_flush)) >= EDIT_FLUSH_INTERVAL_MS
}

// Monta o staging do flush: drena pendências prontas, converte mundo->slot,
// agrupa por chunk e aplica os tetos do lote. O que não couber permanece na
// fila para o próximo intervalo (backpressure natural).
flush_voxel_edits :: proc() {
	clear(&edit_manager.staged_jobs)
	clear(&edit_manager.staged_edits)

	// 1. Reintegra pendências de chunks que ficaram prontos desde o último flush.
	ready := make([dynamic]ChunkCoordinate, context.temp_allocator)
	for coord in edit_manager.pending {
		record, found := chunk_manager.active_chunks[coord]
		if found && record.state != .GENERATING {
			append(&ready, coord)
		}
	}
	for coord in ready {
		list := edit_manager.pending[coord]
		for request in list {
			request_voxel_edit(request.world_voxel, request.block_id) // dedup cuida de duplicatas
		}
		delete(list)
		delete_key(&edit_manager.pending, coord)
	}

	// 2. Drena a fila ativa agrupando por slot (edições contíguas por job).
	buckets := make(map[u32][dynamic]u32, context.temp_allocator) // slot -> packed edits
	total_staged := 0
	kept := make([dynamic]VoxelEditRequest, context.temp_allocator)

	for request in edit_manager.queue {
		chunk, voxel_index := voxel_chunk_and_index(request.world_voxel)
		record, found := chunk_manager.active_chunks[chunk]
		if !found || record.state == .GENERATING {
			edit_defer_to_pending(chunk, request)
			continue
		}
		if total_staged >= MAX_EDITS_PER_FLUSH {
			append(&kept, request); edit_manager.stats_deferred += 1
			continue
		}
		bucket, bucket_found := buckets[record.storage_slot_index]
		if !bucket_found {
			if len(buckets) >= MAX_EDIT_JOBS_PER_FLUSH {
				append(&kept, request); edit_manager.stats_deferred += 1
				continue
			}
			bucket = make([dynamic]u32, context.temp_allocator)
		}
		if len(bucket) >= MAX_EDITS_PER_CHUNK_PER_FLUSH {
			append(&kept, request); edit_manager.stats_deferred += 1
			continue
		}
		append(&bucket, voxel_index | (request.block_id << 16))
		buckets[record.storage_slot_index] = bucket
		total_staged += 1
		// C2 — DUPLA MATERIALIZAÇÃO: a MESMA edição staged p/ a GPU alimenta o
		// mirror (mesma ordem, mesmo dedup, mesmo teto — convergência por
		// construção). Edições retidas (kept/pending) NÃO se aplicam aqui:
		// passarão por este mesmo caminho no flush em que forem staged.
		mirror_journal_apply(chunk, request.world_voxel, request.block_id)
	}

	// 3. Emite os jobs com as edições contíguas (first_edit local do staging;
	//    edit_ring_write soma a base do ring ao copiar).
	for slot, bucket in buckets {
		job := EditChunkJob{
			storage_slot_index = slot,
			first_edit         = u32(len(edit_manager.staged_edits)),
			edit_count         = u32(len(bucket)),
		}
		append(&edit_manager.staged_jobs, job)
		append(&edit_manager.staged_edits, ..bucket[:])
	}

	// 4. Recompacta a fila com o que ficou e reconstrói o lookup.
	delete(edit_manager.queue)
	edit_manager.queue = make([dynamic]VoxelEditRequest)
	clear(&edit_manager.lookup)
	for request in kept {
		append(&edit_manager.queue, request)
		edit_manager.lookup[request.world_voxel] = len(edit_manager.queue) - 1
	}
}

// Copia o staging para o slot do ring deste frame e colhe o feedback do uso
// anterior daquele slot (2 frames atrás — a espera de frames-in-flight já
// garantiu a conclusão). Chamada DEPOIS da espera, nunca antes.
edit_ring_write :: proc(frame_index: u64) -> u32 {
	frame_idx := int(frame_index % MAXIMUM_FRAMES_IN_FLIGHT)

	// Feedback do flush que usou este slot há MAXIMUM_FRAMES_IN_FLIGHT frames.
	previous := edit_manager.ring_counts[frame_idx]
	for i in 0..<previous.edit_count {
		code := vulkan_context.edit_results_mapped[frame_idx * MAX_EDITS_PER_FLUSH + int(i)]
		switch code {
		case EDIT_RESULT_APPLIED: edit_manager.stats_applied += 1
		case EDIT_RESULT_NOOP:    edit_manager.stats_noop += 1
		case:                     edit_manager.stats_rejected += 1
		}
	}

	job_count  := u32(len(edit_manager.staged_jobs))
	edit_count := u32(len(edit_manager.staged_edits))
	jobs_base  := frame_idx * MAX_EDIT_JOBS_PER_FLUSH
	edits_base := frame_idx * MAX_EDITS_PER_FLUSH
	for job, i in edit_manager.staged_jobs {
		global_job := job
		global_job.first_edit += u32(edits_base) // índice global no ring (shader usa direto)
		vulkan_context.edit_jobs_mapped[jobs_base + i] = global_job
	}
	for packed_edit, i in edit_manager.staged_edits {
		vulkan_context.voxel_edits_mapped[edits_base + i] = packed_edit
	}

	edit_manager.ring_counts[frame_idx] = EditRingCounts{job_count, edit_count}
	edit_manager.last_flush = time.tick_now()
	edit_manager.force_next_flush = false
	return job_count
}

// ============================================================================
// SEÇÃO 5C: MIRROR CPU-SIDE — PÁGINAS, RING DE EXPORT E DUPLA APLICAÇÃO (C2)
// ============================================================================
// A verdade do mundo é worldgen + journal (E1); a GPU (packed) e a RAM
// (ChunkPage densa) são views materializadas do MESMO fluxo, na mesma ordem.
// Tudo aqui roda na thread principal, EXCETO as seções que tomam queue_mutex
// (tarefas de geração/re-export são domínio compartilhado com o worker).

// Mundo -> índice no layout do MIRROR (y-contíguo: y | z<<5 | x<<10).
// DIFERENTE de voxel_chunk_and_index (layout denso do GPU/E1, x-contíguo).
mirror_local_index :: proc(world_voxel: [3]i32) -> u32 {
	chunk := ChunkCoordinate{
		floor_div_i32(world_voxel.x, CHUNK_SIZE),
		floor_div_i32(world_voxel.y, CHUNK_SIZE),
		floor_div_i32(world_voxel.z, CHUNK_SIZE),
	}
	local_x := u32(world_voxel.x - chunk.x * CHUNK_SIZE)
	local_y := u32(world_voxel.y - chunk.y * CHUNK_SIZE)
	local_z := u32(world_voxel.z - chunk.z * CHUNK_SIZE)
	return local_y | (local_z << 5) | (local_x << 10)
}

mirror_bit_test :: proc(mask: []u32, index: u32) -> bool {
	return (mask[index >> 5] >> (index & 31)) & 1 != 0
}

mirror_bit_write :: proc(mask: []u32, index: u32, value: bool) {
	bit := u32(1) << (index & 31)
	if value { mask[index >> 5] |= bit } else { mask[index >> 5] &= ~bit }
}

// --- Pool de páginas (endereços estáveis; o hash guarda ponteiros) ---

mirror_page_acquire :: proc(coord: ChunkCoordinate) -> ^MirrorChunkPage {
	if len(mirror_manager.free_pages) == 0 { return nil }
	pool_index := pop(&mirror_manager.free_pages)
	page := &mirror_manager.pool[pool_index]
	page.coord = coord
	page.edit_seq = 0
	page.state = .PENDING_READBACK
	page.ring_slot = -1
	page.pending = nil // o backing da vida anterior já foi liberado no release
	// solid/ids não precisam de zero: a materialização sobrescreve tudo.
	mirror_manager.pages[coord] = page
	mirror_manager.stats_pages_live += 1
	return page
}

mirror_page_release :: proc(coord: ChunkCoordinate) {
	page, found := mirror_manager.pages[coord]
	if !found { return }
	delete(page.pending)
	page.pending = nil
	delete_key(&mirror_manager.pages, coord)
	pool_index := u32((uintptr(page) - uintptr(raw_data(mirror_manager.pool))) / size_of(MirrorChunkPage))
	append(&mirror_manager.free_pages, pool_index)
	mirror_manager.stats_pages_live -= 1
}

// --- Ring de export (slots reservados pela thread principal) ---

mirror_ring_try_reserve :: proc(coord: ChunkCoordinate, generation: u32) -> i32 {
	for &entry, i in mirror_manager.ring {
		if !entry.used {
			entry.used = true
			entry.coord = coord
			entry.generation = generation
			return i32(i)
		}
	}
	mirror_manager.stats_ring_misses += 1
	return -1 // ring cheio: mirror_service_retries tenta de novo nos próximos frames
}

mirror_ring_release :: proc(ring_slot: i32, coord: ChunkCoordinate, generation: u32) {
	entry := &mirror_manager.ring[ring_slot]
	// A checagem por (coord, geração) impede liberar uma entrada já reutilizada.
	if entry.used && entry.coord == coord && entry.generation == generation {
		entry.used = false
	}
}

// --- Aplicação de edições (dupla materialização) ---

mirror_page_apply :: proc(page: ^MirrorChunkPage, world_voxel: [3]i32, block_id: u32) {
	index := mirror_local_index(world_voxel)
	page.ids[index] = u16(block_id)
	mirror_bit_write(page.solid[:], index, block_id != 0)
}

// O MESMO pedido staged para a GPU alimenta o mirror — mesma ordem, mesmo
// dedup, mesmo teto de lote (chamada só no caminho "staged" do flush).
// Convergência por construção: os dois lados aplicam o mesmo journal.
mirror_journal_apply :: proc(chunk: ChunkCoordinate, world_voxel: [3]i32, block_id: u32) {
	page, found := mirror_manager.pages[chunk]
	if !found { return } // fora da bolha de simulação: só a GPU recebe o journal
	if page.state == .PENDING_READBACK {
		// O export em voo contém APENAS worldgen: retém a edição (dedup
		// "última escrita vence", mesma regra do E1) p/ replay na materialização.
		for &existing in page.pending {
			if existing.world_voxel == world_voxel {
				existing.block_id = block_id
				return
			}
		}
		append(&page.pending, VoxelEditRequest{world_voxel, block_id})
		return
	}
	mirror_page_apply(page, world_voxel, block_id)
	page.edit_seq += 1
}

// --- Materialização (handler de conclusão de lote, thread principal) ---

mirror_materialize_from_ring :: proc(task: GenerationTask, batch_timeline_value: u64) {
	ring_slot := task.mirror_ring_slot
	entry := &mirror_manager.ring[ring_slot]

	page, page_found := mirror_manager.pages[task.coordinate]
	record, active := chunk_manager.active_chunks[task.coordinate]
	// Mesma disciplina anti-ABA do B1: o conteúdo do ring só é válido para
	// exatamente o (coord, slot, geração) que pediu o export. Chunk recriado,
	// página evicta (saída da bolha) ou export vencido -> descarta e libera.
	valid := page_found && entry.used &&
		page.ring_slot == ring_slot &&
		entry.coord == task.coordinate && entry.generation == task.generation &&
		active && record.generation == task.generation &&
		record.storage_slot_index == task.storage_slot_index &&
		record.state != .GENERATING

	if !valid {
		entry.used = false
		return
	}

	// Acquire p/ o host: GetSemaphoreCounterValue NÃO é sincronização. Um
	// WaitSemaphores(0) sobre valor já alcançado retorna na hora e estabelece
	// a visibilidade das escritas do compute para a CPU (spec 7.4.2 — mesmo
	// padrão do readback de edit_results, protegido pela espera de frames).
	s := vulkan_context.compute_timeline; v := batch_timeline_value
	wait_info := vulkan.SemaphoreWaitInfo{ sType = .SEMAPHORE_WAIT_INFO, semaphoreCount = 1, pSemaphores = &s, pValues = &v }
	_ = vulkan.WaitSemaphores(vulkan_context.device, &wait_info, 0)

	// ring -> página (y-contíguo u16) + reconstrução da bitmask de sólidos.
	base := int(ring_slot) * CHUNK_VOXEL_COUNT
	src := vulkan_context.mirror_export_ring_mapped[base:base + CHUNK_VOXEL_COUNT]
	for i in 0..<CHUNK_VOXEL_COUNT {
		id := src[i]
		page.ids[i] = id
		mirror_bit_write(page.solid[:], u32(i), id != 0)
	}
	// Replay das edições staged p/ a GPU enquanto PENDING_READBACK: a edição
	// cai no packed DEPOIS do pack, então o export não a contém — sem o replay
	// os dois lados divergiriam.
	for edit in page.pending {
		mirror_page_apply(page, edit.world_voxel, edit.block_id)
	}
	clear(&page.pending)
	page.state = .MATERIALIZED
	page.ring_slot = -1
	page.edit_seq += 1
	entry.used = false
}

// --- Agendamento de preenchimento ---

// Chunk ainda em GENERATING com a tarefa pendente: acopla um slot de ring a
// ela — o export sai de graça, junto com o próprio generate.
mirror_try_attach_to_generation :: proc(coord: ChunkCoordinate, record: ChunkRecord, page: ^MirrorChunkPage) -> bool {
	sync.mutex_lock(&chunk_manager.queue_mutex)
	defer sync.mutex_unlock(&chunk_manager.queue_mutex)
	for &task in chunk_manager.pending_tasks {
		if task_matches(task, coord, record) && !task.export_only {
			ring := mirror_ring_try_reserve(coord, record.generation)
			if ring < 0 { return false }
			task.mirror_ring_slot = ring
			page.ring_slot = ring
			return true
		}
	}
	return false
}

// Chunk já CACHED/RENDERABLE: agenda um RE-EXPORT (tarefa export_only — roda
// só o generate; o pack NÃO pode rodar de novo, pois reescreveria o packed a
// partir do worldgen e apagaria edições já aplicadas). O scratch do slot é
// sobrescrito, mas é transitório por definição — ninguém mais o lê.
mirror_schedule_export :: proc(coord: ChunkCoordinate, record: ChunkRecord) -> bool {
	page, found := mirror_manager.pages[coord]
	if !found || page.state != .PENDING_READBACK || page.ring_slot >= 0 { return false }
	ring := mirror_ring_try_reserve(coord, record.generation)
	if ring < 0 { return false }
	page.ring_slot = ring
	task := GenerationTask{
		coordinate = coord, storage_slot_index = record.storage_slot_index,
		generation = record.generation, mirror_ring_slot = ring, export_only = true,
	}
	sync.mutex_lock(&chunk_manager.queue_mutex)
	append(&chunk_manager.pending_export_tasks, task)
	sync.cond_signal(&chunk_manager.queue_condition)
	sync.mutex_unlock(&chunk_manager.queue_mutex)
	return true
}

// Páginas PENDING sem export agendado: (a) tarefa de geração ainda pendente
// -> acopla um slot de ring agora; (b) chunk já CACHED -> agenda o re-export.
// Chamada todo frame, depois do processamento de lotes concluídos (é quando
// slots de ring são liberados).
mirror_service_retries :: proc() {
	for coord, page in mirror_manager.pages {
		if page.state != .PENDING_READBACK || page.ring_slot >= 0 { continue }
		record, active := chunk_manager.active_chunks[coord]
		if !active { continue }
		if record.state == .GENERATING {
			mirror_try_attach_to_generation(coord, record, page)
		} else {
			mirror_schedule_export(coord, record)
		}
	}
}

// Descarte do espelho de um chunk (descarregado ou fora da bolha). A página é
// liberada; exports PENDENTES são desacoplados/cancelados e seus slots de ring
// voltam ao pool; exports EM VOO são descartados pelo handler de conclusão
// (página ausente / geração não bate -> entry freed). A tarefa de GERAÇÃO em
// si nunca é cancelada aqui — o descarregamento de GENERATING já passou por
// retire_generating_slot, e um chunk fora da bolha continua renderizando.
mirror_forget_chunk :: proc(coord: ChunkCoordinate, record: ChunkRecord) {
	sync.mutex_lock(&chunk_manager.queue_mutex)
	for i := len(chunk_manager.pending_export_tasks) - 1; i >= 0; i -= 1 {
		task := chunk_manager.pending_export_tasks[i]
		if task_matches(task, coord, record) {
			if task.mirror_ring_slot >= 0 { mirror_ring_release(task.mirror_ring_slot, coord, record.generation) }
			unordered_remove(&chunk_manager.pending_export_tasks, i)
		}
	}
	for &task in chunk_manager.pending_tasks {
		if task_matches(task, coord, record) && task.mirror_ring_slot >= 0 {
			mirror_ring_release(task.mirror_ring_slot, coord, record.generation)
			task.mirror_ring_slot = -1
		}
	}
	// Se NADA em voo referencia este (coord, geração), qualquer entrada de ring
	// residual pode ser liberada na hora — a GPU nunca a escreverá. Cobre a
	// tarefa de geração já removida por retire_generating_slot no caminho (a)
	// do descarregamento. Se há lote em voo, quem libera é o handler de
	// conclusão (página ausente / geração não bate -> descarta).
	in_flight := false
	for batch in chunk_manager.submitted_batches {
		for task in batch.tasks[:batch.task_count] {
			if task_matches(task, coord, record) && task.mirror_ring_slot >= 0 { in_flight = true }
		}
	}
	if !in_flight {
		for &entry in mirror_manager.ring {
			if entry.used && entry.coord == coord && entry.generation == record.generation { entry.used = false }
		}
	}
	sync.mutex_unlock(&chunk_manager.queue_mutex)
	mirror_page_release(coord)
}

// Cria a página de um chunk e inicia o preenchimento pelo caminho adequado.
mirror_request_page :: proc(coord: ChunkCoordinate, record: ChunkRecord) {
	page := mirror_page_acquire(coord)
	if page == nil {
		mirror_manager.stats_pool_misses += 1 // pool cheio: tenta no próximo frame/movimento
		return
	}
	if record.state == .GENERATING {
		mirror_try_attach_to_generation(coord, record, page)
		// Se a tarefa já foi reivindicada (ou o ring está cheio), a página fica
		// PENDING sem slot: mirror_service_retries agenda o re-export quando o
		// chunk ficar CACHED.
	} else {
		mirror_schedule_export(coord, record)
	}
}

// ============================================================================
// SEÇÃO 5C.1: API PÚBLICA DO MIRROR (gameplay — thread principal)
// ============================================================================

VoxelSample :: struct {
	block_id: u16,
	solid:    bool, // derivado de id != 0 — mesma regra da ocupação na GPU
}

// Consulta tri-state canônica ("qual o voxel em (x,y,z)?"): (amostra, true) =
// leitura válida; ({}, false) = DESCONHECIDO (chunk sem página ou página em
// PENDING_READBACK). A política do desconhecido — bloquear, chutar, aguardar —
// é do consumidor; mirror_request puxa a página sob demanda.
voxel_get :: proc(world_voxel: [3]i32) -> (sample: VoxelSample, ok: bool) {
	chunk := ChunkCoordinate{
		floor_div_i32(world_voxel.x, CHUNK_SIZE),
		floor_div_i32(world_voxel.y, CHUNK_SIZE),
		floor_div_i32(world_voxel.z, CHUNK_SIZE),
	}
	page, found := mirror_manager.pages[chunk]
	if !found || page.state != .MATERIALIZED { return {}, false }
	index := mirror_local_index(world_voxel)
	return VoxelSample{ page.ids[index], mirror_bit_test(page.solid[:], index) }, true
}

voxel_is_solid :: proc(world_voxel: [3]i32) -> (solid: bool, ok: bool) {
	sample, valid := voxel_get(world_voxel)
	return sample.solid, valid
}

// Varredura colunar: primeiro sólido indo de y_from para baixo (raycast de
// coluna — o layout y-contíguo faz a coluna inteira caber em 1 linha de cache
// por chunk). Cruza fronteiras de chunk; retorna ok=false se a varredura
// atingir uma página desconhecida (o chamador decide a política).
mirror_column_ground :: proc(world_x, world_z, y_from: i32) -> (ground_y: i32, ok: bool) {
	y := y_from
	for {
		chunk := ChunkCoordinate{
			floor_div_i32(world_x, CHUNK_SIZE),
			floor_div_i32(y, CHUNK_SIZE),
			floor_div_i32(world_z, CHUNK_SIZE),
		}
		page, found := mirror_manager.pages[chunk]
		if !found || page.state != .MATERIALIZED { return 0, false }
		local_x := u32(world_x - chunk.x * CHUNK_SIZE)
		local_z := u32(world_z - chunk.z * CHUNK_SIZE)
		local_y := i32(y - chunk.y * CHUNK_SIZE)
		base := (local_x << 10) | (local_z << 5)
		for ly := local_y; ly >= 0; ly -= 1 {
			if mirror_bit_test(page.solid[:], base + u32(ly)) {
				return chunk.y * CHUNK_SIZE + ly, true
			}
		}
		y = chunk.y * CHUNK_SIZE - 1 // coluna toda de ar: desce p/ o chunk de baixo
	}
}

// Puxa a página de um chunk sob demanda (ex.: um sistema prestes a consultar
// um chunk fora da bolha de simulação). Não bloqueia: a página entra como
// PENDING_READBACK e o fluxo normal (acoplamento à tarefa ou re-export)
// completa o preenchimento em 1-3 frames; até lá, as consultas retornam
// unknown. Chunk fora do streaming (nem GENERATING): nada a espelhar agora.
mirror_request :: proc(chunk: ChunkCoordinate) {
	if chunk in mirror_manager.pages { return }
	record, active := chunk_manager.active_chunks[chunk]
	if !active { return }
	mirror_request_page(chunk, record)
}

// ============================================================================
// SEÇÃO 6: WORKER THREAD (COMPUTE VULKAN 1.4 SYNC2)
// ============================================================================
worker_thread_process :: proc(worker_thread: ^thread.Thread) {
	submitted_batch_count: u64 = 0

	for {
		sync.mutex_lock(&chunk_manager.queue_mutex)
		for len(chunk_manager.pending_tasks) == 0 && len(chunk_manager.pending_export_tasks) == 0 && sync.atomic_load(&chunk_manager.worker_stop_requested) == 0 {
			sync.cond_wait(&chunk_manager.queue_condition, &chunk_manager.queue_mutex)
		}
		if sync.atomic_load(&chunk_manager.worker_stop_requested) == 1 { sync.mutex_unlock(&chunk_manager.queue_mutex); break }

		claimed_batch := SubmittedBatch{compute_timeline_value = submitted_batch_count + 1}
		// C2: re-exports do mirror embarcam 1 por lote, antes do dreno normal
		// (são raros e não podem morrer de fome), e pulam o pack mais abaixo.
		export_only := false
		if len(chunk_manager.pending_export_tasks) > 0 {
			claimed_batch.tasks[0] = pop(&chunk_manager.pending_export_tasks)
			claimed_batch.task_count = 1
			export_only = true
		} else {
		// CORREÇÃO B4 — drena até MAXIMUM_CHUNKS_PER_BATCH tarefas por lote,
		// sempre as mais próximas da câmera. O chão sob o jogador continua
		// saindo primeiro; a diferença é que os 15 vizinhos mais próximos
		// embarcam na MESMA submissão, amortecendo o custo do QueueSubmit2.
		// (Custo: k varreduras lineares por lote — uma heap de prioridade
		// elimina isso; ver melhorias de performance.)
		for claimed_batch.task_count < MAXIMUM_CHUNKS_PER_BATCH && len(chunk_manager.pending_tasks) > 0 {
			best_idx := 0
			best_dist := max(int)
			for t, i in chunk_manager.pending_tasks {
				d := calculate_squared_distance(t.coordinate, chunk_manager.priority_camera_chunk)
				if d < best_dist { best_dist = d; best_idx = i }
			}
			claimed_batch.tasks[claimed_batch.task_count] = chunk_manager.pending_tasks[best_idx]
			claimed_batch.task_count += 1
			unordered_remove(&chunk_manager.pending_tasks, best_idx)
		}
		}

		// CORREÇÃO B1 — CLAIM ATÔMICO: o lote é publicado em submitted_batches
		// ANTES de qualquer trabalho Vulkan, ainda sob queue_mutex. Como o
		// descarregamento (thread principal) varre pending_tasks e
		// submitted_batches sob esta mesma trava, não existe janela em que a
		// tarefa esteja "fora" dos dois conjuntos: ou ela é cancelada antes
		// daqui (slot liberado na hora), ou o slot será aposentado contra
		// assigned_timeline — que é determinístico, pois esta é a única
		// thread que submete e os claims são sequenciais.
		assigned_timeline := submitted_batch_count + 1
		append(&chunk_manager.submitted_batches, claimed_batch)
		sync.mutex_unlock(&chunk_manager.queue_mutex)

		// Trava para respeitar Frames in Flight de Compute
		if submitted_batch_count >= MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT {
			wait_for_timeline_value(vulkan_context.compute_timeline, submitted_batch_count - MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT + 1)
		}

		ring_index := int(submitted_batch_count % MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT)
		job_offset := ring_index * MAXIMUM_CHUNKS_PER_BATCH

		// CORREÇÃO B4: grava TODOS os jobs do lote no ring (slots não usados
		// ficam obsoletos, mas o dispatch cobre apenas task_count jobs).
		for i in 0..<claimed_batch.task_count {
			task := claimed_batch.tasks[i]
			vulkan_context.generation_jobs_mapped[job_offset + i] = ChunkGenerationJob{
				chunk_world_origin = {task.coordinate.x * CHUNK_SIZE, task.coordinate.y * CHUNK_SIZE, task.coordinate.z * CHUNK_SIZE},
				storage_slot_index = task.storage_slot_index,
				mirror_ring_slot   = task.mirror_ring_slot, // C2: -1 = sem export
			}
		}

		cmd := vulkan_context.compute_command_buffers[ring_index]
		vulkan_check(vulkan.ResetCommandBuffer(cmd, {}))

		begin_info := vulkan.CommandBufferBeginInfo{ sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT} }
		vulkan_check(vulkan.BeginCommandBuffer(cmd, &begin_info))

		vulkan.CmdBindDescriptorSets(cmd, .COMPUTE, vulkan_context.pipeline_layout, 0, 1, &vulkan_context.descriptor_set, 0, nil)

		pc := PushConstants{ batch_job_offset = u32(job_offset) }
		vulkan.CmdPushConstants(cmd, vulkan_context.pipeline_layout, PUSH_CONSTANT_STAGES, 0, size_of(PushConstants), &pc)

		// CORREÇÃO B4: generate cobre N chunks (thread_id.z / 32 = job local);
		// pack cobre N chunks (group_id.x = job local).
		vulkan.CmdBindPipeline(cmd, .COMPUTE, vulkan_context.generation_pipeline)
		vulkan.CmdDispatch(cmd, 4, 4, 4 * u32(claimed_batch.task_count))

		// C2: lote export_only (re-export do mirror) NÃO roda o pack — o
		// packed já existe e contém edições; repackar a partir do scratch
		// (só worldgen) as apagaria. O ring já saiu escrito pelo generate.
		if !export_only {
		// Barreira Sync2 nativa
		mem_barrier := vulkan.MemoryBarrier2 {
			sType = .MEMORY_BARRIER_2,
			srcStageMask = {.COMPUTE_SHADER}, srcAccessMask = {.SHADER_STORAGE_WRITE},
			dstStageMask = {.COMPUTE_SHADER}, dstAccessMask = {.SHADER_STORAGE_READ},
		}
		dep_info := vulkan.DependencyInfo { sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &mem_barrier }
		vulkan.CmdPipelineBarrier2(cmd, &dep_info)

		vulkan.CmdBindPipeline(cmd, .COMPUTE, vulkan_context.packing_pipeline)
		vulkan.CmdDispatch(cmd, u32(claimed_batch.task_count), 1, 1)
		}

		vulkan_check(vulkan.EndCommandBuffer(cmd))

		submitted_batch_count += 1

		cmd_info := vulkan.CommandBufferSubmitInfo{ sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd }
		// O valor sinalizado é o MESMO publicado no claim atômico.
		signal_info := vulkan.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vulkan_context.compute_timeline, value = assigned_timeline, stageMask = {.ALL_COMMANDS} }
		submit_info := vulkan.SubmitInfo2{ sType = .SUBMIT_INFO_2, commandBufferInfoCount = 1, pCommandBufferInfos = &cmd_info, signalSemaphoreInfoCount = 1, pSignalSemaphoreInfos = &signal_info }

		vulkan_check(vulkan.QueueSubmit2(vulkan_context.compute_queue, 1, &submit_info, 0))
		// CORREÇÃO B1: nada mais a registrar — o lote já consta em
		// submitted_batches desde o claim (o antigo append tardio sob
		// submitted_mutex era a janela de corrida).
	}
}

// ============================================================================
// SEÇÃO 7: LOOP PRINCIPAL DE RENDERIZAÇÃO
// ============================================================================
run_voxel_engine :: proc() {
	chunk_manager.active_chunks = make(map[ChunkCoordinate]ChunkRecord)
	chunk_manager.slot_generations = make([]u32, MAXIMUM_RESIDENT_CHUNKS) // CORREÇÃO B1 (zero-init: 1ª alocação = geração 1)
	for i in 0..<MAXIMUM_RESIDENT_CHUNKS { append(&chunk_manager.free_storage_slots, u32(i)) }

	// E1: fila de edição (dedup por voxel) + pendências por chunk + staging do flush.
	edit_manager.queue = make([dynamic]VoxelEditRequest)
	edit_manager.lookup = make(map[[3]i32]int)
	edit_manager.pending = make(map[ChunkCoordinate][dynamic]VoxelEditRequest)
	edit_manager.staged_jobs = make([dynamic]EditChunkJob)
	edit_manager.staged_edits = make([dynamic]u32)
	edit_manager.last_flush = time.tick_now()

	// C2: pool fixo de páginas + hash de páginas vivas (o ring nasce zerado =
	// todos os slots livres; mirror_export_ring_mapped é criado no setup Vulkan
	// — ver TODO de integração).
	mirror_manager.pool = make([]MirrorChunkPage, MIRROR_PAGE_POOL_SIZE)
	mirror_manager.free_pages = make([dynamic]u32, 0, MIRROR_PAGE_POOL_SIZE)
	for i := MIRROR_PAGE_POOL_SIZE - 1; i >= 0; i -= 1 { append(&mirror_manager.free_pages, u32(i)) }
	mirror_manager.pages = make(map[ChunkCoordinate]^MirrorChunkPage)

	sync.mutex_init(&chunk_manager.queue_mutex)
	sync.cond_init(&chunk_manager.queue_condition)
	// CORREÇÃO B1: submitted_mutex deixou de existir — submitted_batches vive
	// no domínio de queue_mutex.

	worker_thread := thread.create(worker_thread_process)
	thread.start(worker_thread)

	submitted_frame_count: u64
	camera_pos: [3]f32
	vp_matrix: matrix[4, 4]f32

	for !platform_hooks.should_close() {
		platform_hooks.update_camera(&camera_pos, &vp_matrix)

		// 1. Verifica trabalhos terminados pela GPU e libera slots antigos
		completed_compute := read_timeline_value(vulkan_context.compute_timeline)
		sync.mutex_lock(&chunk_manager.queue_mutex)
		completed_count := 0
		for b in chunk_manager.submitted_batches {
			if b.compute_timeline_value > completed_compute { break }
			for task in b.tasks[:b.task_count] {
				// CORREÇÃO B1 — validação anti-ABA: só promove para CACHED se
				// coordenada, slot e geração ainda corresponderem ao chunk que
				// pediu a geração. Sem isso, um lote antigo podia marcar como
				// pronto um chunk recriado com outro slot (renderiza lixo).
				if task.coordinate in chunk_manager.active_chunks {
					rec := &chunk_manager.active_chunks[task.coordinate]
					if (
						rec.state == .GENERATING &&
						rec.storage_slot_index == task.storage_slot_index &&
						rec.generation == task.generation
					) {
						rec.state = .CACHED
					}
				}
				// C2: o lote também pode ter escrito o ring de export do mirror —
				// materializa a página (memcpy + replay de pendências) ou descarta
				// o export vencido. Em ambos os casos o slot do ring é liberado.
				if task.mirror_ring_slot >= 0 {
					mirror_materialize_from_ring(task, b.compute_timeline_value)
				}
			}
			chunk_manager.highest_completed_compute_value = max(chunk_manager.highest_completed_compute_value, b.compute_timeline_value)
			completed_count += 1
		}
		remove_range(&chunk_manager.submitted_batches, 0, completed_count)
		sync.mutex_unlock(&chunk_manager.queue_mutex)

		// C2: páginas PENDING sem export agendado tentam de novo (o handler
		// acima é quem libera os slots do ring ao concluir os lotes).
		mirror_service_retries()

		// CORREÇÃO B1: libera slots de chunks descarregados durante a geração.
		// A timeline de compute garante que a GPU já concluiu TODA escrita
		// pendente nesses slots (signal do lote implica visibilidade de
		// memória), então a reciclagem é segura aqui — e não antes.
		for i := len(chunk_manager.retiring_compute_slots) - 1; i >= 0; i -= 1 {
			if chunk_manager.retiring_compute_slots[i].release_timeline_value <= completed_compute {
				append(&chunk_manager.free_storage_slots, chunk_manager.retiring_compute_slots[i].storage_slot_index)
				unordered_remove(&chunk_manager.retiring_compute_slots, i)
			}
		}

		completed_frame := read_timeline_value(vulkan_context.graphics_timeline)
		for i := len(chunk_manager.retiring_slots) - 1; i >= 0; i -= 1 {
			if chunk_manager.retiring_slots[i].release_frame_value <= completed_frame {
				append(&chunk_manager.free_storage_slots, chunk_manager.retiring_slots[i].storage_slot_index)
				unordered_remove(&chunk_manager.retiring_slots, i)
			}
		}

		// 2. Histerese de Streaming
		update_chunk_streaming(camera_pos, submitted_frame_count)

		// 2.5 E1: vencido o intervalo, monta o staging do lote de edições.
		// A cópia ao ring acontece só DEPOIS da espera de frames-in-flight.
		flush_requested := edit_flush_due()
		if flush_requested { flush_voxel_edits() }

		// 3. Renderização
		if submitted_frame_count >= MAXIMUM_FRAMES_IN_FLIGHT {
			wait_for_timeline_value(vulkan_context.graphics_timeline, submitted_frame_count - MAXIMUM_FRAMES_IN_FLIGHT + 1)
		}

		frame_idx := submitted_frame_count % MAXIMUM_FRAMES_IN_FLIGHT

		// E1: slot do ring livre (a GPU terminou o frame de 2 atrás): copia o
		// lote e colhe o feedback do uso anterior deste slot.
		edit_job_count: u32 = 0
		if flush_requested { edit_job_count = edit_ring_write(submitted_frame_count) }

		visible_count: u32 = 0
		offset := int(frame_idx) * MAXIMUM_VISIBLE_CHUNKS
		for coord, rec in chunk_manager.active_chunks {
			if rec.state == .RENDERABLE && visible_count < MAXIMUM_VISIBLE_CHUNKS {
				entry := VisibleChunk{
					chunk_world_origin = {coord.x * CHUNK_SIZE, coord.y * CHUNK_SIZE, coord.z * CHUNK_SIZE},
					storage_slot_index = rec.storage_slot_index,
				}
				// CORREÇÃO B2: publica os slots dos vizinhos para o mesh shader
				// ler a ocupação além da fronteira do chunk.
				for neighbor_offset, i in NEIGHBOR_OFFSETS {
					entry.neighbor_slots[i] = NEIGHBOR_SLOT_INVALID
					neighbor_coord := coord + neighbor_offset
					if neighbor_coord in chunk_manager.active_chunks {
						neighbor_record := chunk_manager.active_chunks[neighbor_coord]
						// Só é seguro ler se a geração já concluiu: slot em
						// GENERATING contém lixo e pode estar sendo escrito
						// pela fila de compute neste instante.
						if neighbor_record.state != .GENERATING {
							entry.neighbor_slots[i] = neighbor_record.storage_slot_index
						}
					}
				}
				vulkan_context.visible_chunks_mapped[offset + int(visible_count)] = entry
				visible_count += 1
			}
		}

		platform_hooks.acquire_swapchain_image(vulkan_context.image_available[frame_idx])

		cmd := vulkan_context.graphics_command_buffers[frame_idx]
		vulkan_check(vulkan.ResetCommandBuffer(cmd, {}))
		begin_info := vulkan.CommandBufferBeginInfo{ sType = .COMMAND_BUFFER_BEGIN_INFO }
		vulkan_check(vulkan.BeginCommandBuffer(cmd, &begin_info))

		// E1: aplica as edições ANTES do render pass (compute não pode entrar
		// dentro de dynamic rendering). A barreira torna as escritas visíveis
		// para TASK/MESH — o frame já sai com a alteração aplicada.
		if edit_job_count > 0 {
			vulkan.CmdBindPipeline(cmd, .COMPUTE, vulkan_context.edit_pipeline)
			vulkan.CmdBindDescriptorSets(cmd, .COMPUTE, vulkan_context.pipeline_layout, 0, 1, &vulkan_context.descriptor_set, 0, nil)

			pc_edit := PushConstants{
				view_projection_matrix = vp_matrix,
				camera_position        = camera_pos,
				visible_chunk_offset   = u32(frame_idx) * MAXIMUM_VISIBLE_CHUNKS,
				edit_job_offset        = u32(frame_idx) * MAX_EDIT_JOBS_PER_FLUSH,
			}
			vulkan.CmdPushConstants(cmd, vulkan_context.pipeline_layout, PUSH_CONSTANT_STAGES, 0, size_of(PushConstants), &pc_edit)
			vulkan.CmdDispatch(cmd, edit_job_count, 1, 1)

			edit_barrier := vulkan.MemoryBarrier2{
				sType = .MEMORY_BARRIER_2,
				srcStageMask  = {.COMPUTE_SHADER}, srcAccessMask = {.SHADER_STORAGE_WRITE},
				dstStageMask  = {.TASK_SHADER_EXT, .MESH_SHADER_EXT}, dstAccessMask = {.SHADER_STORAGE_READ},
			}
			edit_dep := vulkan.DependencyInfo{ sType = .DEPENDENCY_INFO, memoryBarrierCount = 1, pMemoryBarriers = &edit_barrier }
			vulkan.CmdPipelineBarrier2(cmd, &edit_dep)
		}

		platform_hooks.begin_rendering(cmd)

		vulkan.CmdBindPipeline(cmd, .GRAPHICS, vulkan_context.mesh_pipeline)
		vulkan.CmdBindDescriptorSets(cmd, .GRAPHICS, vulkan_context.pipeline_layout, 0, 1, &vulkan_context.descriptor_set, 0, nil)

		pc := PushConstants{ view_projection_matrix = vp_matrix, camera_position = camera_pos, visible_chunk_offset = u32(frame_idx) * MAXIMUM_VISIBLE_CHUNKS }
		vulkan.CmdPushConstants(cmd, vulkan_context.pipeline_layout, PUSH_CONSTANT_STAGES, 0, size_of(PushConstants), &pc)

		if visible_count > 0 { vulkan.CmdDrawMeshTasksEXT(cmd, visible_count, 1, 1) }

		platform_hooks.end_rendering(cmd)
		vulkan_check(vulkan.EndCommandBuffer(cmd))

		submitted_frame_count += 1

		cmd_info := vulkan.CommandBufferSubmitInfo{ sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = cmd }
		wait_wsi := vulkan.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vulkan_context.image_available[frame_idx], stageMask = {.COLOR_ATTACHMENT_OUTPUT} }

		wait_compute := vulkan.SemaphoreSubmitInfo{
			sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vulkan_context.compute_timeline,
			// E1: COMPUTE_SHADER entra na máscara — o dispatch de edição deste
			// frame pode ler dados de um chunk promovido a CACHED agora mesmo.
			value = chunk_manager.highest_completed_compute_value, stageMask = {.COMPUTE_SHADER, .TASK_SHADER_EXT, .MESH_SHADER_EXT}
		}

		waits := [2]vulkan.SemaphoreSubmitInfo{ wait_wsi, wait_compute }
		wait_cnt: u32 = chunk_manager.highest_completed_compute_value > 0 ? 2 : 1

		signal_wsi := vulkan.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vulkan_context.render_finished[frame_idx], stageMask = {.ALL_GRAPHICS} }
		signal_time := vulkan.SemaphoreSubmitInfo{ sType = .SEMAPHORE_SUBMIT_INFO, semaphore = vulkan_context.graphics_timeline, value = submitted_frame_count, stageMask = {.ALL_GRAPHICS} }
		signals := [2]vulkan.SemaphoreSubmitInfo{ signal_wsi, signal_time }

		submit_info := vulkan.SubmitInfo2{
			sType = .SUBMIT_INFO_2, waitSemaphoreInfoCount = wait_cnt, pWaitSemaphoreInfos = &waits[0],
			commandBufferInfoCount = 1, pCommandBufferInfos = &cmd_info,
			signalSemaphoreInfoCount = 2, pSignalSemaphoreInfos = &signals[0],
		}
		vulkan_check(vulkan.QueueSubmit2(vulkan_context.graphics_queue, 1, &submit_info, 0))

		platform_hooks.present_swapchain_image(vulkan_context.render_finished[frame_idx])
	}

	sync.atomic_store(&chunk_manager.worker_stop_requested, 1)
	sync.mutex_lock(&chunk_manager.queue_mutex)
	sync.cond_broadcast(&chunk_manager.queue_condition)
	sync.mutex_unlock(&chunk_manager.queue_mutex)
	thread.join(worker_thread)
}
