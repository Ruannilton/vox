// ============================================================================
// PIPELINE DE VOXELS (SLANG) - VULKAN 1.4
// ARQUITETURA DATA-DRIVEN, PBR E GEOMETRIA DINÂMICA (TASK/MESH SHADERS)
// ============================================================================
// CORREÇÃO B2 — FRONTEIRAS: leituras fora do chunk redirecionam para a
// ocupação dos 6 vizinhos (slots publicados pela CPU por frame).
//
// CORREÇÃO B3 — PACK COMPLETO: ocupação+presença -> coarse+prefixo+paleta ->
// planos. INVARIANTE: slot 0 da paleta = AR. Overflow (>255 tipos) vira
// SpecialVoxelRecord com flag CHUNK_FLAG_PALETTE_OVERFLOW.
//
// CAMINHO B — TEMPLATES DE MALHA (voxels com malhas diferentes):
// A geometria deixa de ser hardcoded (CUBE/PLANT) e vira DADO: uma tabela
// global de templates (vértices em [0,1]^3 + triângulos com tag de culling),
// indexada por BlockDefinition.mesh_template_index. REGRA DA ENGINE: todo
// voxel ocupa exatamente 1 unidade^3; objetos maiores são divididos em
// múltiplos voxels, cada um com seu próprio template (parte).
//
// Garantia de orçamento (256 verts / 192 tris por mesh group): o pack soma o
// custo pior-caso de cada brick e grava 2 bits de SUBDIVISÃO por brick na
// região de ocupação; o task shader despacha 1, 2 ou 4 mesh groups por brick
// conforme o custo. Contrato de carga: templates com <= 32 verts e <= 24 tris
// pior-caso por voxel (a subdivisão x4 sempre acomoda: 8 voxels x 32/24).
//
// E1 — EDIÇÃO DE VOXELS (alterações bufferizadas, aplicadas em intervalos):
// A CPU acumula pedidos de edição (última escrita vence por voxel) e, a cada
// intervalo, envia um lote: 1 workgroup por chunk tocado. O shader atualiza
// planos de material, paleta (com refcounts por entrada — mantidos pelo pack),
// ocupação de bricks/coarse, flag EMPTY e os 2 bits de subdivisão dos bricks
// sujos. Como a malha é reconstruída on-the-fly a cada frame, basta a
// barreira COMPUTE->TASK|MESH no próprio command buffer: o frame já renderiza
// a alteração, e o culling de fronteira entre chunks (B2) se ajusta sozinho
// porque o vizinho lê a ocupação ao vivo — sem dirty flags de re-mesh.
//
// C2 — MIRROR CPU-SIDE (v3.0): o mundo tem DUAS views materializadas da mesma
// verdade (worldgen + journal de edições do E1): o formato packed na VRAM
// (render) e um grid denso u16 na RAM (gameplay: física, IA, saves...).
// O generate ganha uma saída secundária: se o job traz mirror_ring_slot >= 0,
// cada voxel também é gravado como u16 no ring de export (binding 16,
// host-visible) no LAYOUT DO MIRROR (y-contíguo — diferente do scratch!):
//   idx_mirror = y | z<<5 | x<<10          (uma coluna = 64 B contíguos)
// A CPU consome o slot do ring quando a timeline do lote sinaliza (memcpy p/
// a ChunkPage + replay das edições retidas) — ver voxel.odin, Seção 5C.
// Nota de integração: uint16_t em SSBO exige storageBuffer16BitAccess
// (VK_KHR_16bit_storage / Vulkan 1.1+) — habilitar na criação do device.
// ============================================================================

// ============================================================================
// SEÇÃO 1: CONSTANTES GLOBAIS E LIMITES
// ============================================================================
static const int  CHUNK_SIZE        = 32;
static const uint CHUNK_VOXEL_COUNT = 32 * 32 * 32;

static const int3 BRICK_SIZE            = int3(4, 2, 4);
static const uint VOXELS_PER_BRICK      = 32;
static const int3 BRICKS_PER_CHUNK_AXIS = int3(8, 16, 8);
static const uint BRICKS_PER_CHUNK      = 1024;

static const int3 BRICKS_PER_COARSE_CELL    = int3(2, 4, 2);
static const uint COARSE_CELLS_PER_CHUNK    = 64;
static const uint COARSE_WORDS_PER_CHUNK    = 2;
// CAMINHO B: 2 bits de subdivisão por brick = 64 words por chunk.
static const uint SUBDIVISION_WORDS_PER_CHUNK = 64;
// Layout do pool de ocupação por chunk:
//   [0..1024)    = 1 word de ocupação por brick
//   [1024..1026) = 64 bits de coarse cells
//   [1026..1090) = 2 bits de subdivisão por brick (caminho B)
static const uint OCCUPANCY_WORDS_PER_CHUNK = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK;
static const uint SUBDIVISION_WORD_BASE     = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK; // 1026

// Paleta: 8 planos, 256 entradas — slot 0 é SEMPRE ar (invariante do B3).
static const uint MATERIAL_PLANE_COUNT_MAXIMUM = 8;
static const uint MATERIAL_WORDS_PER_CHUNK     = MATERIAL_PLANE_COUNT_MAXIMUM * BRICKS_PER_CHUNK;
static const uint PALETTE_SIZE_MAXIMUM         = 256;
static const uint BLOCK_IDENTIFIER_MAXIMUM     = 65535;
static const uint BLOCK_PRESENCE_WORDS         = 2048;
static const uint PACK_THREADS                 = 128;
static const uint PRESENCE_WORDS_PER_THREAD    = BLOCK_PRESENCE_WORDS / PACK_THREADS;
static const uint SPECIAL_RECORDS_PER_CHUNK    = 256;

static const uint CHUNK_FLAG_EMPTY            = 1;
static const uint CHUNK_FLAG_PALETTE_OVERFLOW = 2;

static const uint MESH_VERTEX_MAXIMUM   = 256;
static const uint MESH_TRIANGLE_MAXIMUM = 192;

// CAMINHO B: limites de template (contrato de carga) e codificação.
static const uint MAX_TEMPLATE_VERTICES = 32; // por voxel; subdivisão x4 => 8*32 = 256
static const uint MAX_TEMPLATE_TRIANGLES = 24; // pior-caso por voxel; x4 => 8*24 = 192
static const uint TEMPLATE_FLAG_HAS_FLUSH_FACES = 1; // template tem tris colados em faces do voxel
static const uint CULL_FACE_NEVER = 7;               // triângulo nunca é culpado (interior/diagonal)
// brick_indices do payload: bits [0..10) brick, [10..12) parte, [12..14) log2(subdivisão)
static const uint TASK_PAYLOAD_BRICK_CAPACITY = 2048; // payload total ~8,2 KB < 16 KB

// E1 — EDIÇÃO DE VOXELS: limites do lote e codificação de resultados.
static const uint MAX_EDITS_PER_CHUNK_PER_FLUSH = 1024; // teto por workgroup (CPU faz spill p/ próximo flush)
static const uint EDIT_HASH_CAPACITY = 512;             // 2x a paleta: load factor <= 0,5
static const uint EDIT_HASH_EMPTY     = 0xFFFFFFFFu;
static const uint EDIT_HASH_TOMBSTONE = 0xFFFFFFFEu;
static const uint EDIT_REFCLAIMED     = 0x80000000u; // refcount em fluxo (alocação reivindicou, ainda publicando)
// Códigos escritos em edit_results (a CPU lê o ring 2 frames depois — feedback estatístico).
static const uint EDIT_RESULT_APPLIED                = 0;
static const uint EDIT_RESULT_NOOP                   = 1; // bloco novo == bloco antigo
static const uint EDIT_RESULT_REJECTED_PALETTE_FULL  = 2; // 255 tipos + AR já ocupados
static const uint EDIT_RESULT_REJECTED_OVERFLOW      = 3; // chunk com CHUNK_FLAG_PALETTE_OVERFLOW é somente-leitura
// Sentinelas de shared_edit_new_slot (nunca colidem com índices 0..255).
static const uint EDIT_SLOT_NOOP     = 0xFFFFFFFFu;
static const uint EDIT_SLOT_REJECTED = 0xFFFFFFFEu;
static const uint EDIT_COUNTED_FLAG  = 0x80000000u; // bit alto: refcount já saiu contado da Fase 1

// Sentinela de vizinho (B2), igual ao Odin.
static const uint NEIGHBOR_SLOT_INVALID = 0xFFFFFFFFu;

// ============================================================================
// SEÇÃO 2: ESTRUTURAS DE DADOS
// ============================================================================
struct ChunkGenerationJob {
	int3 chunk_world_origin;
	uint storage_slot_index;
	// C2: >= 0 = exporta o grid denso u16 p/ este slot do ring de export do
	// mirror CPU-side (binding 16); -1 = geração só p/ render (fora da bolha
	// de simulação). Escrito pela CPU junto com o job.
	int  mirror_ring_slot;
	uint _padding[3]; // 32 B totais (múltiplo de 16) — casar com voxel.odin
};

struct VisibleChunk {
	int3 chunk_world_origin;
	uint storage_slot_index;
	uint neighbor_slots[6]; // ordem: +X, -X, +Y, -Y, +Z, -Z (mesma de FACE_NORMALS)
	uint _padding[2];
};

struct ChunkHeader {
	uint palette_size;
	uint plane_count;
	uint special_voxel_count;
	uint flags;
	uint palette[PALETTE_SIZE_MAXIMUM];
	// E1: refcount por entrada da paleta (quantos voxels usam o slot).
	// Mantido pelo pack na geração e pelo apply_voxel_edits nos flushes;
	// slot com refcount 0 é reciclável (o slot 0 — AR — nunca é reciclado).
	uint refcount[PALETTE_SIZE_MAXIMUM];
};

struct SpecialVoxelRecord {
	uint voxel_index;           // dense_index_from_coordinate (15 bits)
	uint shape_and_orientation;
	uint block_identifier;
};

// Dicionário Global lido no momento da renderização (Orientação a Dados)
struct BlockDefinition {
	uint   mesh_template_index; // CAMINHO B: índice na tabela de templates (0 = vazio/ar)
	uint   albedo_texture_index;
	uint   pbr_texture_index;
	uint   flags;               // Bit 0 = É transparente?
	float3 emission_color;
	float  base_roughness;
	float  base_metallic;
	uint   rotation;            // CAMINHO B: yaw em passos de 90° (0..3) aplicado ao template
	uint   padding_2;
	uint   padding_3;
};

// CAMINHO B: template de micro-mesh. Vértices em [0,1]^3 (regra da engine:
// voxel de tamanho único). Triângulos no pool global, cada um packed em uint:
// bits [0..8) v0, [8..16) v1, [16..24) v2, [24..27) face de culling
// (0..5 = colada na face do voxel, culpa por vizinho sólido/câmera; 7 = nunca).
struct MeshTemplate {
	uint vertex_offset;     // no pool template_vertices
	uint vertex_count;      // <= MAX_TEMPLATE_VERTICES
	uint triangle_offset;   // no pool template_triangles
	uint triangle_count;
	uint worst_case_tris;   // pré-computado no load: never_cull + sum_eixos max(tris face+, tris face-)
	uint flags;             // bit 0: HAS_FLUSH_FACES
	uint padding_0;
	uint padding_1;
};

// E1: um job de edição = 1 workgroup no flush. As edições (binding 14) vêm
// agrupadas por chunk: [first_edit, first_edit + edit_count).
struct EditChunkJob {
	uint storage_slot_index;
	uint first_edit;
	uint edit_count;   // <= MAX_EDITS_PER_CHUNK_PER_FLUSH
	uint padding;
};

struct PushConstants {
	column_major float4x4 view_projection_matrix;
	float3 camera_position;
	uint   visible_chunk_offset;
	uint   batch_job_offset;
	uint   edit_job_offset; // E1: base do ring de EditChunkJob deste frame (88 bytes)
};

struct TaskPayload {
	uint storage_slot_index;
	int3 chunk_world_origin;
	uint neighbor_slots[6];
	uint brick_indices[TASK_PAYLOAD_BRICK_CAPACITY];
};

struct MeshVertex {
	float4 clip_position  : SV_Position;
	float3 world_position : WORLD_POSITION;
	uint   block_id       : BLENDINDICES;
};

[[vk::push_constant]] PushConstants push_constants;

// ============================================================================
// SEÇÃO 3: BINDINGS (RECURSOS DA GPU)
// ============================================================================
[[vk::binding(0, 0)]] RWStructuredBuffer<uint>               temporary_dense_chunks;
[[vk::binding(1, 0)]] StructuredBuffer<ChunkGenerationJob>   generation_jobs;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint>               occupancy_pool;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint>               material_plane_pool;
[[vk::binding(4, 0)]] RWStructuredBuffer<ChunkHeader>        chunk_headers;
[[vk::binding(5, 0)]] RWStructuredBuffer<SpecialVoxelRecord> special_voxel_records;
[[vk::binding(6, 0)]] StructuredBuffer<VisibleChunk>         visible_chunks;
[[vk::binding(7, 0)]] StructuredBuffer<BlockDefinition>      global_block_registry;
[[vk::binding(8, 0)]] Sampler2DArray                         block_albedo_textures;
[[vk::binding(9, 0)]] Sampler2DArray                         block_pbr_textures;
// CAMINHO B: tabela de templates + pools de geometria (escritos no load pela CPU)
[[vk::binding(10, 0)]] StructuredBuffer<MeshTemplate>        mesh_templates;
[[vk::binding(11, 0)]] StructuredBuffer<float3>              template_vertices;
[[vk::binding(12, 0)]] StructuredBuffer<uint>                template_triangles;
// E1: ring de edição (host-visible, 2 slots de frame; a CPU escreve antes do
// dispatch e lê edit_results do slot de 2 frames atrás — ver voxel.odin).
[[vk::binding(13, 0)]] StructuredBuffer<EditChunkJob>        edit_jobs;
[[vk::binding(14, 0)]] StructuredBuffer<uint>                voxel_edits; // packed: voxel_index(15 bits) | block_id<<16
[[vk::binding(15, 0)]] RWStructuredBuffer<uint>              edit_results;
// C2: ring de export do mirror (host-visible + coherent, MIRROR_RING_SLOTS
// slots de CHUNK_VOXEL_COUNT u16 cada, contíguos). O generate escreve aqui
// quando job.mirror_ring_slot >= 0; a CPU faz memcpy p/ a ChunkPage quando a
// timeline do lote sinaliza. Exige storageBuffer16BitAccess no device.
[[vk::binding(16, 0)]] RWStructuredBuffer<uint16_t>           mirror_export_ring;

// ============================================================================
// SEÇÃO 4: FUNÇÕES AUXILIARES DE COORDENADAS E MEMÓRIA
// ============================================================================
uint brick_index_from_coordinate(int3 coord) { return uint(coord.x) + 8u * (uint(coord.z) + 8u * uint(coord.y)); }
int3 brick_coordinate_from_index(uint index) { return int3(int(index & 7u), int(index >> 6u), int((index >> 3u) & 7u)); }
uint bit_index_from_local_coordinate(int3 coord) { return uint(coord.x) + 4u * (uint(coord.z) + 4u * uint(coord.y)); }
int3 local_coordinate_from_bit_index(uint index) { return int3(int(index & 3u), int(index >> 4u), int((index >> 2u) & 3u)); }
uint dense_index_from_coordinate(int3 coord) { return uint(coord.x) | (uint(coord.z) << 5u) | (uint(coord.y) << 10u); }
int3 coordinate_from_dense_index(uint index) { return int3(int(index & 31u), int(index >> 10u), int((index >> 5u) & 31u)); }
// C2: layout do MIRROR na RAM — y-contíguo (uma coluna vertical = 64 B
// contíguos, 1 linha de cache; varredura de terreno é sequencial).
// ATENÇÃO: NÃO é o layout do scratch denso acima (que é x-contíguo).
uint mirror_index_from_coordinate(int3 coord) { return uint(coord.y) | (uint(coord.z) << 5u) | (uint(coord.x) << 10u); }
uint coarse_cell_index_from_brick_coordinate(int3 coord) { int3 cell = coord / BRICKS_PER_COARSE_CELL; return uint(cell.x) + 4u * (uint(cell.z) + 4u * uint(cell.y)); }

// E1: índice de paleta de um voxel lendo apenas os planos (sem o header).
// plane_count é parâmetro explícito porque a edição cresce os planos no meio
// do flush — chamadores usam sempre a contagem JÁ atualizada (planos novos
// chegam zerados, então bits altos não mudam índices antigos).
uint read_palette_index_at(uint slot, uint plane_count, int3 coord) {
	uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
	uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);
	uint palette_index = 0;
	for (uint plane = 0; plane < plane_count; plane++) {
		uint plane_word = material_plane_pool[slot * MATERIAL_WORDS_PER_CHUNK + plane * BRICKS_PER_CHUNK + brick_idx];
		palette_index |= ((plane_word >> bit_idx) & 1u) << plane;
	}
	return palette_index;
}

uint read_brick_occupancy(uint slot, int3 coord) {
	if (any(coord < 0) || any(coord >= BRICKS_PER_CHUNK_AXIS)) return 0;
	return occupancy_pool[slot * OCCUPANCY_WORDS_PER_CHUNK + brick_index_from_coordinate(coord)];
}

bool is_voxel_solid_local(uint slot, int3 coord) {
	uint occupancy = read_brick_occupancy(slot, coord / BRICK_SIZE);
	return ((occupancy >> bit_index_from_local_coordinate(coord % BRICK_SIZE)) & 1u) != 0;
}

// CORREÇÃO B2: consulta com redirecionamento de fronteira (ver cabeçalho).
bool is_voxel_solid(uint slot, int3 coord, uint neighbor_slots[6]) {
	if (all(coord >= 0) && all(coord < CHUNK_SIZE)) {
		return is_voxel_solid_local(slot, coord);
	}
	uint neighbor_slot = NEIGHBOR_SLOT_INVALID;
	int3 local = coord;
	if (coord.x < 0)                  { neighbor_slot = neighbor_slots[1]; local.x += CHUNK_SIZE; }
	else if (coord.x >= CHUNK_SIZE)   { neighbor_slot = neighbor_slots[0]; local.x -= CHUNK_SIZE; }
	else if (coord.y < 0)             { neighbor_slot = neighbor_slots[3]; local.y += CHUNK_SIZE; }
	else if (coord.y >= CHUNK_SIZE)   { neighbor_slot = neighbor_slots[2]; local.y -= CHUNK_SIZE; }
	else if (coord.z < 0)             { neighbor_slot = neighbor_slots[5]; local.z += CHUNK_SIZE; }
	else                              { neighbor_slot = neighbor_slots[4]; local.z -= CHUNK_SIZE; }
	if (neighbor_slot == NEIGHBOR_SLOT_INVALID) return false;
	if (any(local < 0) || any(local >= CHUNK_SIZE)) return false;
	return is_voxel_solid_local(neighbor_slot, local);
}

uint read_block_identifier(uint slot, ChunkHeader header, int3 coord) {
	uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
	uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);

	uint palette_index = 0;
	for (uint plane = 0; plane < header.plane_count; plane++) {
		uint plane_word = material_plane_pool[slot * MATERIAL_WORDS_PER_CHUNK + plane * BRICKS_PER_CHUNK + brick_idx];
		palette_index |= ((plane_word >> bit_idx) & 1u) << plane;
	}
	return header.palette[min(palette_index, max(header.palette_size, 1u) - 1u)];
}

static const int3 FACE_NORMALS[6] = { int3(1,0,0), int3(-1,0,0), int3(0,1,0), int3(0,-1,0), int3(0,0,1), int3(0,0,-1) };

// Máscara de faces: bit F setado se a face F do voxel pode ser visível
// (vizinho não-sólido E câmera do lado de fora do plano). Uso: culling de
// triângulos colados em faces do voxel (tag 0..5) nos templates.
uint compute_visible_face_mask(uint slot, int3 coord, int3 chunk_world_origin, float3 camera_position, uint neighbor_slots[6]) {
	float3 voxel_min_world = float3(chunk_world_origin + coord);
	uint face_mask = 0;

	[unroll]
	for (uint face_index = 0; face_index < 6; face_index++) {
		int3 neighbor_coord = coord + FACE_NORMALS[face_index];
		if (is_voxel_solid(slot, neighbor_coord, neighbor_slots)) continue;

		uint axis_index = face_index >> 1;
		bool is_positive_face = (face_index & 1) == 0;
		float plane_position = voxel_min_world[axis_index] + (is_positive_face ? 1.0 : 0.0);
		bool camera_sees_face = is_positive_face ? (camera_position[axis_index] > plane_position) : (camera_position[axis_index] < plane_position);

		if (camera_sees_face) {
			face_mask |= 1u << face_index;
		}
	}
	return face_mask;
}

// CAMINHO B: rotação yaw do template (passos de 90°, centrada no voxel).
// Convenção r=1: (x,z) -> (z, 1-x).
float3 rotate_vertex_yaw(float3 p, uint r) {
	switch (r & 3u) {
	case 1:  return float3(p.z, p.y, 1.0 - p.x);
	case 2:  return float3(1.0 - p.x, p.y, 1.0 - p.z);
	case 3:  return float3(1.0 - p.z, p.y, p.x);
	default: return p;
	}
}

// CAMINHO B: para onde aponta cada face após a rotação yaw (ordem de FACE_NORMALS).
static const uint ROTATED_FACE[24] = {
	0, 1, 2, 3, 4, 5,  // r=0: identidade
	5, 4, 2, 3, 0, 1,  // r=1: +X->-Z, -X->+Z, +Z->+X, -Z->-X
	1, 0, 2, 3, 5, 4,  // r=2: 180°
	4, 5, 2, 3, 1, 0,  // r=3
};

// CAMINHO B: um triângulo de template sobrevive ao culling?
bool triangle_survives_culling(uint packed_tri, uint rotation, uint face_mask) {
	uint cull_face = (packed_tri >> 24u) & 7u;
	if (cull_face == CULL_FACE_NEVER) return true;
	uint rotated_face = ROTATED_FACE[(rotation & 3u) * 6u + cull_face];
	return (face_mask & (1u << rotated_face)) != 0u;
}
// ============================================================================
// SEÇÃO 5: COMPUTE SHADER - GERAÇÃO DE DADOS BRUTOS (Passo 1)
// ============================================================================
// A geração escreve a malha densa (ID completo por voxel) em um scratch buffer
// temporário, liberando o pipeline de packing para operar de forma assíncrona.
// B9: eram grupos (4,4,4) com dispatch (4,4,4·N) — só 16×16×32 voxels/chunk
// eram escritos (8192 de 32768!) e, em lotes com N > 8, os chunks 8..N-1
// ficavam zerados (group_id.z indexava o job errado). O Manual sempre
// documentou grupos 8×8×8 — corrigido: agora o dispatch (4,4,4·N) cobre
// 32×32×32N threads e o job vem de thread_id.z / 32.
[shader("compute")]
[numthreads(8, 8, 8)]
void generate_voxels(uint3 thread_id : SV_DispatchThreadID) {
	uint chunk_in_batch = thread_id.z / CHUNK_SIZE;
	uint local_z        = thread_id.z % CHUNK_SIZE;

	ChunkGenerationJob job = generation_jobs[push_constants.batch_job_offset + chunk_in_batch];

	int3 coord = int3(int(thread_id.x), int(thread_id.y), int(local_z));
	int3 voxel_world_position = job.chunk_world_origin + coord;

	uint block_id = 0;

	if (voxel_world_position.y < 0) {
		block_id = 3; // Exemplo: pedra profunda
	} else if (voxel_world_position.y == 0) {
		block_id = 2; // Exemplo: terra
	} else if (voxel_world_position.y == 1) {
		block_id = 1; // Exemplo: grama (cubo com textura)
	}

	temporary_dense_chunks[job.storage_slot_index * CHUNK_VOXEL_COUNT + dense_index_from_coordinate(coord)] = block_id;

	// C2: saída secundária — export denso u16 p/ o mirror CPU-side, já no
	// layout do mirror (y-contíguo). A CPU reserva o slot do ring ao enfileirar
	// a tarefa; -1 = chunk fora da bolha de simulação, sem export.
	if (job.mirror_ring_slot >= 0) {
		mirror_export_ring[uint(job.mirror_ring_slot) * CHUNK_VOXEL_COUNT + mirror_index_from_coordinate(coord)] = uint16_t(block_id);
	}
}

// ============================================================================
// SEÇÃO 6: COMPUTE SHADER - OTIMIZAÇÃO EMPACOTADORA (Passo 2)
// ============================================================================
groupshared uint shared_block_presence[BLOCK_PRESENCE_WORDS];
groupshared uint shared_presence_prefix[BLOCK_PRESENCE_WORDS];
groupshared uint shared_block_partials[PACK_THREADS];
groupshared uint shared_palette_blocks[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_palette_size;
// E1: contagem de voxels por entrada da paleta (vai para ChunkHeader.refcount).
groupshared uint shared_refcount[PALETTE_SIZE_MAXIMUM];

uint palette_rank_of_block(uint block_id) {
	uint word_index = block_id >> 5u;
	uint bit_index = block_id & 31u;
	uint word = shared_block_presence[word_index];
	return shared_presence_prefix[word_index] + countbits(word & ((1u << bit_index) - 1u));
}

[shader("compute")]
[numthreads(128, 1, 1)]
void pack_chunk(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint thread = local_id.x;
	uint slot = generation_jobs[push_constants.batch_job_offset + group_id.x].storage_slot_index;

	uint dense_base = slot * CHUNK_VOXEL_COUNT;
	uint occupancy_base = slot * OCCUPANCY_WORDS_PER_CHUNK;
	uint plane_base = slot * MATERIAL_WORDS_PER_CHUNK;

	// ----------------------------------------------------------
	// Fase 0: Zera os contadores compartilhados
	// ----------------------------------------------------------
	if (thread < 32u) {
		shared_block_partials[thread] = 0u;
	}
	if (thread == 0u) {
		shared_palette_size = 0u;
	}
	// Zera presença (2048 words) e a região [coarse|subdivisão] da ocupação (66 words)
	for (uint i = thread; i < BLOCK_PRESENCE_WORDS; i += PACK_THREADS) {
		shared_block_presence[i] = 0u;
	}
	// E1: zera refcounts (256 entradas; slots além da paleta ficam 0 = livres)
	for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += PACK_THREADS) {
		shared_refcount[i] = 0u;
	}
	for (uint i = thread; i < COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK; i += PACK_THREADS) {
		occupancy_pool[occupancy_base + BRICKS_PER_CHUNK + i] = 0u;
	}
	GroupMemoryBarrierWithGroupSync();

	// ----------------------------------------------------------
	// Fase A: Ocupação de bricks + presença de blocos +
	//         CAMINHO B: custo pior-caso de geometria por brick
	// ----------------------------------------------------------
	uint step_count = BRICKS_PER_CHUNK / PACK_THREADS;
	for (uint step = 0; step < step_count; step++) {
		uint brick_idx = thread + step * PACK_THREADS;
		int3 brick_coord = brick_coordinate_from_index(brick_idx);

		uint occupancy = 0;
		// CAMINHO B: somas por parte (4 partes de 8 voxels = granularidade máxima)
		uint part_verts[4] = { 0u, 0u, 0u, 0u };
		uint part_tris[4]  = { 0u, 0u, 0u, 0u };

		for (uint bit_idx = 0; bit_idx < VOXELS_PER_BRICK; bit_idx++) {
			int3 local_coord = local_coordinate_from_bit_index(bit_idx);
			int3 coord = brick_coord * BRICK_SIZE + local_coord;
			uint block_id = temporary_dense_chunks[dense_base + dense_index_from_coordinate(coord)];

			if (block_id != 0u) {
				occupancy |= 1u << bit_idx;
				InterlockedOr(shared_block_presence[block_id >> 5u], 1u << (block_id & 31u));

				// CAMINHO B: acumula o custo pior-caso do template deste voxel.
				BlockDefinition def = global_block_registry[block_id];
				MeshTemplate tmpl = mesh_templates[def.mesh_template_index];
				if (tmpl.triangle_count > 0u) {
					uint part = bit_idx >> 3u; // partes contíguas: [0..8),[8..16),[16..24),[24..32)
					part_verts[part] += tmpl.vertex_count;
					part_tris[part]  += tmpl.worst_case_tris;
				}
			}
		}

		occupancy_pool[occupancy_base + brick_idx] = occupancy;

		// CAMINHO B: escolhe a menor subdivisão cuja pior parte cabe no
		// orçamento do mesh shader (256 verts / 192 tris por grupo).
		uint half_verts  = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3]);
		uint half_tris   = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3]);
		uint total_verts = part_verts[0] + part_verts[1] + part_verts[2] + part_verts[3];
		uint total_tris  = part_tris[0] + part_tris[1] + part_tris[2] + part_tris[3];

		uint subdivision = 0u;
		if (total_verts > MESH_VERTEX_MAXIMUM || total_tris > MESH_TRIANGLE_MAXIMUM) {
			subdivision = 1u; // 2 grupos de 16 voxels
			if (half_verts > MESH_VERTEX_MAXIMUM || half_tris > MESH_TRIANGLE_MAXIMUM) {
				subdivision = 2u; // 4 grupos de 8 voxels (suficiente pelo contrato de carga)
			}
		}
		if (subdivision != 0u) {
			InterlockedOr(occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_idx >> 4u)],
			              subdivision << ((brick_idx & 15u) * 2u));
		}
	}
	GroupMemoryBarrierWithGroupSync();

	// ----------------------------------------------------------
	// Fase B1: Otimização Hierárquica de Coarse Cells
	// ----------------------------------------------------------
	for (uint step = 0; step < step_count; step++) {
		uint brick_idx = thread + step * PACK_THREADS;
		uint occupancy = occupancy_pool[occupancy_base + brick_idx];

		if (occupancy != 0) {
			uint cell_index = coarse_cell_index_from_brick_coordinate(brick_coordinate_from_index(brick_idx));
			InterlockedOr(occupancy_pool[occupancy_base + BRICKS_PER_CHUNK + (cell_index >> 5u)], 1u << (cell_index & 31u));
		}
	}
	GroupMemoryBarrierWithGroupSync();

	// ----------------------------------------------------------
	// Fase B2: Scan de prefixo sobre a presença (ranking da paleta)
	// ----------------------------------------------------------
	uint thread_partial = 0;
	for (uint i = 0; i < PRESENCE_WORDS_PER_THREAD; i++) {
		uint word_index = thread + i * PACK_THREADS;
		thread_partial += countbits(shared_block_presence[word_index]);
	}
	shared_block_partials[thread] = thread_partial;
	GroupMemoryBarrierWithGroupSync();

	if (thread == 0u) {
		uint running_total = 0;
		for (uint i = 0; i < PACK_THREADS; i++) {
			uint current = shared_block_partials[i];
			shared_block_partials[i] = running_total;
			running_total += current;
		}
		shared_palette_size = running_total;
	}
	GroupMemoryBarrierWithGroupSync();

	uint thread_prefix = shared_block_partials[thread];
	uint running_prefix = thread_prefix;
	for (uint i = 0; i < PRESENCE_WORDS_PER_THREAD; i++) {
		uint word_index = thread + i * PACK_THREADS;
		shared_presence_prefix[word_index] = running_prefix;
		running_prefix += countbits(shared_block_presence[word_index]);
	}
	GroupMemoryBarrierWithGroupSync();

	uint distinct_count = shared_palette_size;
	bool palette_overflow = distinct_count > (PALETTE_SIZE_MAXIMUM - 1u);

	// ----------------------------------------------------------
	// Fase B3: Constrói a paleta e grava o ChunkHeader
	// ----------------------------------------------------------
	if (thread == 0u) {
		uint palette_count = min(distinct_count, PALETTE_SIZE_MAXIMUM - 1u) + 1u;
		uint plane_count = 1u;
		while ((1u << plane_count) < palette_count) plane_count++;

		// INVARIANTE: slot 0 da paleta = AR
		shared_palette_blocks[0] = 0u;

		ChunkHeader header;
		header.palette_size = palette_count;
		header.plane_count = plane_count;
		header.special_voxel_count = 0;
		header.flags = (distinct_count == 0u) ? CHUNK_FLAG_EMPTY : 0u;
		if (palette_overflow) {
			header.flags |= CHUNK_FLAG_PALETTE_OVERFLOW;
		}

		chunk_headers[slot] = header;
	}
	GroupMemoryBarrierWithGroupSync();

	// Upload cooperativo da paleta (ids presentes em ordem crescente)
	for (uint i = thread; i < BLOCK_PRESENCE_WORDS; i += PACK_THREADS) {
		uint word = shared_block_presence[i];
		while (word != 0u) {
			uint bit = firstbitlow(word);
			word &= word - 1u;
			uint block_id = (i << 5u) + bit;
			uint rank = palette_rank_of_block(block_id);
			if (rank < PALETTE_SIZE_MAXIMUM - 1u) {
				shared_palette_blocks[rank + 1u] = block_id;
			}
		}
	}
	GroupMemoryBarrierWithGroupSync();

	uint palette_count = chunk_headers[slot].palette_size;
	for (uint i = thread; i < palette_count; i += PACK_THREADS) {
		chunk_headers[slot].palette[i] = shared_palette_blocks[i];
	}
	GroupMemoryBarrierWithGroupSync();

	// ----------------------------------------------------------
	// Fase C: Zera e preenche os planos materiais (+ rank + 1 pelo slot de ar)
	// ----------------------------------------------------------
	uint plane_count = chunk_headers[slot].plane_count;
	uint total_plane_words = plane_count * BRICKS_PER_CHUNK;
	for (uint i = thread; i < total_plane_words; i += PACK_THREADS) {
		material_plane_pool[plane_base + i] = 0u;
	}
	GroupMemoryBarrierWithGroupSync();

	uint special_count = 0;
	uint voxel_steps = CHUNK_VOXEL_COUNT / PACK_THREADS;
	for (uint step = 0; step < voxel_steps; step++) {
		uint dense_idx = thread + step * PACK_THREADS;
		uint block_id = temporary_dense_chunks[dense_base + dense_idx];

		if (block_id == 0u) continue;

		uint rank = palette_rank_of_block(block_id);
		uint palette_index = rank + 1u;

		if (palette_index >= palette_count) {
			uint write_idx;
			InterlockedAdd(chunk_headers[slot].special_voxel_count, 1u, write_idx);
			if (write_idx < SPECIAL_RECORDS_PER_CHUNK) {
				SpecialVoxelRecord record;
				record.voxel_index = dense_idx;
				record.shape_and_orientation = 0u;
				record.block_identifier = block_id;
				special_voxel_records[slot * SPECIAL_RECORDS_PER_CHUNK + write_idx] = record;
			}
			continue; // voxel sem bits de plano: decodifica como ar (degradação segura)
		}

		// E1: contabiliza o uso do slot (a edição depende disso para reciclar).
		InterlockedAdd(shared_refcount[palette_index], 1u);

		int3 coord = int3(int(dense_idx & 31u), int(dense_idx >> 10u), int((dense_idx >> 5u) & 31u));
		uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
		uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);

		for (uint plane = 0; plane < plane_count; plane++) {
			if (((palette_index >> plane) & 1u) != 0u) {
				InterlockedOr(material_plane_pool[plane_base + plane * BRICKS_PER_CHUNK + brick_idx], 1u << bit_idx);
			}
		}
	}
	GroupMemoryBarrierWithGroupSync();

	// E1: fecha os refcounts — o slot 0 (AR) fica com os voxels não sólidos —
	// e sobe TODAS as 256 entradas (slots além da paleta precisam constar como
	// 0 = livres para a alocação da edição; o buffer pode conter lixo).
	if (thread == 0u) {
		uint solid_total = 0;
		for (uint i = 1u; i < palette_count; i++) { solid_total += shared_refcount[i]; }
		shared_refcount[0] = CHUNK_VOXEL_COUNT - solid_total;
	}
	GroupMemoryBarrierWithGroupSync();
	for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += PACK_THREADS) {
		chunk_headers[slot].refcount[i] = shared_refcount[i];
	}
}
// ============================================================================
// SEÇÃO 6B: COMPUTE SHADER - EDIÇÃO DE VOXELS (E1)
// ============================================================================
// A CPU bufferiza pedidos de edição (última escrita vence por voxel) e, a cada
// intervalo, despacha 1 workgroup de 128 threads por chunk tocado. Fases:
//   0   - cache do header em shared + hash block_id -> slot da paleta
//   1   - resolve: decodifica o bloco antigo e resolve o slot do novo
//         (lookup no hash; miss -> alocação atômica de slot com refcount 0)
//   1.5 - crescimento de planos (planos novos nascem zerados ANTES do uso)
//   2   - aplica: planos, ocupação, refcounts, código de resultado
//   2.5 - coarse cells + flag EMPTY + writeback dos refcounts no header
//   3   - recomputa os 2 bits de subdivisão dos bricks sujos (Caminho B)
//
// Contratos com a CPU (ver voxel.odin):
//  - Uma edição por voxel por flush (dedup "última escrita vence"): é o que
//    permite decodificar o bloco antigo na Fase 1 e aplicar na Fase 2 sem
//    re-leitura — nenhum outro thread toca ESTE voxel neste dispatch.
//  - Só entram no lote chunks CACHED/RENDERABLE: edição nunca disputa slot
//    com a fila de geração (B1). Pendências ficam na CPU até o chunk ficar
//    pronto.
//  - Chunk com CHUNK_FLAG_PALETTE_OVERFLOW é somente-leitura: blocos em
//    SpecialVoxelRecord não aparecem nos planos, então a edição não consegue
//    manter refcounts — rejeitado com código próprio.
//
// Como a malha é reconstruída on-the-fly a cada frame, nenhuma dirty flag de
// renderização é necessária: a barreira COMPUTE->TASK|MESH no command buffer
// do frame torna as escritas visíveis e o frame já sai com a alteração. O
// culling de fronteira (B2) se ajusta sozinho — o vizinho lê a ocupação ao
// vivo, inclusive através da fronteira do chunk editado.
groupshared uint shared_edit_palette[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_edit_refcount[PALETTE_SIZE_MAXIMUM];
groupshared uint shared_edit_hash_key[EDIT_HASH_CAPACITY];  // block_id | EMPTY | TOMBSTONE
groupshared uint shared_edit_hash_slot[EDIT_HASH_CAPACITY]; // slot | EMPTY (pendente) | REJECTED
groupshared uint shared_edit_new_slot[MAX_EDITS_PER_CHUNK_PER_FLUSH];
groupshared uint shared_edit_old_index[MAX_EDITS_PER_CHUNK_PER_FLUSH];
groupshared uint shared_edit_dirty_bricks[BRICKS_PER_CHUNK / 32];
groupshared uint shared_edit_palette_size;
groupshared uint shared_edit_plane_count;
groupshared uint shared_edit_flags;
groupshared uint shared_edit_nonempty;

uint edit_hash_bucket(uint block_id) {
	return ((block_id * 0x9E3779B1u) >> 23u) & (EDIT_HASH_CAPACITY - 1u);
}

// Reserva o bucket de block_id (probing linear; tombstones são puladas, nunca
// reutilizadas — o hash é reconstruído a cada dispatch, então no pior caso
// 255 ids vivos + <= 255 alocações do flush < 512 buckets).
// owned=true: esta thread reservou e DEVE publicar o slot. bucket=EMPTY na
// volta: tabela cheia (defensivo; não ocorre na prática).
void edit_hash_reserve(uint block_id, out uint bucket, out bool owned) {
	uint h = edit_hash_bucket(block_id);
	owned = false;
	bucket = EDIT_HASH_EMPTY;
	for (uint probe = 0u; probe < EDIT_HASH_CAPACITY; probe++) {
		uint idx = (h + probe) & (EDIT_HASH_CAPACITY - 1u);
		uint key;
		InterlockedAdd(shared_edit_hash_key[idx], 0u, key); // leitura atômica
		if (key == block_id) { bucket = idx; return; }
		if (key == EDIT_HASH_TOMBSTONE) { continue; }
		uint original;
		InterlockedCompareExchange(shared_edit_hash_key[idx], EDIT_HASH_EMPTY, block_id, original);
		if (original == EDIT_HASH_EMPTY) { owned = true; bucket = idx; return; }
		if (original == block_id) { bucket = idx; return; }
		// Outra chave recém-reservada: segue o probing.
	}
}

// Remove a entrada de um id (evicção de slot reciclado). Idempotente.
void edit_hash_tombstone(uint block_id) {
	uint h = edit_hash_bucket(block_id);
	for (uint probe = 0u; probe < EDIT_HASH_CAPACITY; probe++) {
		uint idx = (h + probe) & (EDIT_HASH_CAPACITY - 1u);
		uint key;
		InterlockedAdd(shared_edit_hash_key[idx], 0u, key);
		if (key == EDIT_HASH_EMPTY) { return; }
		if (key == block_id) {
			uint original;
			InterlockedCompareExchange(shared_edit_hash_key[idx], block_id, EDIT_HASH_TOMBSTONE, original);
			return;
		}
	}
}

// Espera o dono do bucket publicar o slot (ou REJECTED se a paleta lotou).
uint edit_hash_wait_slot(uint bucket) {
	for (uint spin = 0u; spin < 4096u; spin++) {
		uint value;
		InterlockedAdd(shared_edit_hash_slot[bucket], 0u, value);
		if (value != EDIT_HASH_EMPTY) { return value; }
	}
	return EDIT_SLOT_REJECTED; // defensivo: timeout
}

// Aloca um slot livre (refcount == 0, exceto o slot 0 = AR) para block_id e
// publica no bucket reservado. O refcount sai = 1 (primeiro uso já contado).
uint edit_alloc_slot(uint slot, uint block_id, uint bucket) {
	for (uint s = 1u; s < PALETTE_SIZE_MAXIMUM; s++) {
		uint rc;
		InterlockedAdd(shared_edit_refcount[s], 0u, rc);
		if (rc != 0u) { continue; }
		uint original;
		InterlockedCompareExchange(shared_edit_refcount[s], 0u, EDIT_REFCLAIMED, original);
		if (original != 0u) { continue; }
		// Reivindicado. Um slot reciclado pode ainda constar no hash com o id
		// antigo (esvaziamento preguiçoso): expulsa antes de republicar.
		uint old_id = shared_edit_palette[s];
		if (old_id != 0u && old_id != block_id) { edit_hash_tombstone(old_id); }
		shared_edit_palette[s] = block_id;
		chunk_headers[slot].palette[s] = block_id;
		InterlockedMax(shared_edit_palette_size, s + 1u);
		InterlockedExchange(shared_edit_hash_slot[bucket], s, original); // publica
		InterlockedExchange(shared_edit_refcount[s], 1u, original);      // libera o claim
		return s;
	}
	uint original;
	InterlockedExchange(shared_edit_hash_slot[bucket], EDIT_SLOT_REJECTED, original); // acorda waiters
	return EDIT_SLOT_REJECTED;
}

// Reivindica uma referência ao slot encontrado no hash. Slot com refcount 0
// (bloco removido por completo num flush anterior, entrada preguiçosa) é
// ressuscitado com CAS 0->1; se o slot trocou de dono no meio do caminho,
// sinaliza para re-resolver. Na Fase 1 nenhum decremento acontece, então um
// refcount > 0 lido aqui não pode zerar até a Fase 2 — sem risco de evicção.
uint edit_claim_slot(uint slot_idx, uint block_id, out bool counted) {
	counted = false;
	for (uint attempt = 0u; attempt < 64u; attempt++) {
		uint rc;
		InterlockedAdd(shared_edit_refcount[slot_idx], 0u, rc);
		if (rc == EDIT_REFCLAIMED) { continue; } // alocação em fluxo: gira
		if (rc != 0u) {
			if (shared_edit_palette[slot_idx] == block_id) { return slot_idx; }
			return EDIT_HASH_EMPTY; // conteúdo mudou: re-resolve pelo hash
		}
		uint original;
		InterlockedCompareExchange(shared_edit_refcount[slot_idx], 0u, 1u, original);
		if (original != 0u) { continue; }
		if (shared_edit_palette[slot_idx] == block_id) { counted = true; return slot_idx; }
		InterlockedAdd(shared_edit_refcount[slot_idx], 0xFFFFFFFFu); // desfaz (-1) e re-resolve
		return EDIT_HASH_EMPTY;
	}
	return EDIT_HASH_EMPTY; // defensivo: contenção patológica
}

// Resolve o slot de paleta de block_id para este flush. counted=true indica
// que o refcount já saiu contado daqui (alocação ou ressurreição) — a Fase 2
// não deve incrementar de novo.
uint edit_resolve_slot(uint slot, uint block_id, out bool counted) {
	counted = false;
	for (uint attempt = 0u; attempt < 32u; attempt++) {
		uint bucket; bool owned;
		edit_hash_reserve(block_id, bucket, owned);
		if (bucket == EDIT_HASH_EMPTY) { return EDIT_SLOT_REJECTED; }
		if (owned) {
			uint s = edit_alloc_slot(slot, block_id, bucket);
			counted = (s != EDIT_SLOT_REJECTED);
			return s;
		}
		uint s = edit_hash_wait_slot(bucket);
		if (s == EDIT_SLOT_REJECTED) { return EDIT_SLOT_REJECTED; }
		bool c;
		uint claimed = edit_claim_slot(s, block_id, c);
		if (claimed != EDIT_HASH_EMPTY) { counted = c; return claimed; }
	}
	return EDIT_SLOT_REJECTED; // defensivo
}

[shader("compute")]
[numthreads(128, 1, 1)]
void apply_voxel_edits(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint thread = local_id.x;
	EditChunkJob job = edit_jobs[push_constants.edit_job_offset + group_id.x];
	uint slot = job.storage_slot_index;
	uint occupancy_base = slot * OCCUPANCY_WORDS_PER_CHUNK;
	uint plane_base = slot * MATERIAL_WORDS_PER_CHUNK;

	// ------------------------- Fase 0: cache do header -------------------------
	uint h_palette_size = chunk_headers[slot].palette_size;
	uint h_flags = chunk_headers[slot].flags;
	for (uint i = thread; i < EDIT_HASH_CAPACITY; i += 128u) {
		shared_edit_hash_key[i] = EDIT_HASH_EMPTY;
		shared_edit_hash_slot[i] = EDIT_HASH_EMPTY;
	}
	for (uint i = thread; i < BRICKS_PER_CHUNK / 32u; i += 128u) {
		shared_edit_dirty_bricks[i] = 0u;
	}
	if (thread == 0u) {
		shared_edit_palette_size = h_palette_size;
		shared_edit_plane_count = chunk_headers[slot].plane_count;
		shared_edit_flags = h_flags;
		shared_edit_nonempty = 0u;
	}
	for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += 128u) {
		// Slots além da paleta são normalizados (o buffer pode conter lixo).
		bool live = i < h_palette_size;
		shared_edit_palette[i] = live ? chunk_headers[slot].palette[i] : 0u;
		shared_edit_refcount[i] = live ? chunk_headers[slot].refcount[i] : 0u;
	}
	GroupMemoryBarrierWithGroupSync();

	if ((h_flags & CHUNK_FLAG_PALETTE_OVERFLOW) != 0u) {
		for (uint i = thread; i < job.edit_count; i += 128u) {
			edit_results[job.first_edit + i] = EDIT_RESULT_REJECTED_OVERFLOW;
		}
		return;
	}

	// Hash block_id -> slot. O AR (slot 0) entra SEMPRE — mesmo com refcount 0
	// (chunk 100% sólido) — porque toda remoção de bloco vira uma ida para o AR.
	for (uint i = thread; i < h_palette_size; i += 128u) {
		if (i == 0u || shared_edit_refcount[i] > 0u) {
			uint bucket; bool owned;
			edit_hash_reserve(shared_edit_palette[i], bucket, owned);
			if (owned) { uint original; InterlockedExchange(shared_edit_hash_slot[bucket], i, original); }
		}
	}
	GroupMemoryBarrierWithGroupSync();

	// ------------------------- Fase 1: resolve slots -------------------------
	for (uint i = thread; i < job.edit_count; i += 128u) {
		uint packed_edit = voxel_edits[job.first_edit + i];
		uint voxel_index = packed_edit & 0x7FFFu;
		uint new_block = packed_edit >> 16u;
		int3 coord = coordinate_from_dense_index(voxel_index);

		uint old_index = read_palette_index_at(slot, shared_edit_plane_count, coord);
		old_index = min(old_index, shared_edit_palette_size - 1u); // clamp defensivo
		uint old_block = shared_edit_palette[old_index];

		shared_edit_old_index[i] = old_index;
		if (old_block == new_block) {
			shared_edit_new_slot[i] = EDIT_SLOT_NOOP;
			continue;
		}
		bool counted;
		uint s = edit_resolve_slot(slot, new_block, counted);
		shared_edit_new_slot[i] = (s == EDIT_SLOT_REJECTED)
			? EDIT_SLOT_REJECTED
			: (s | (counted ? EDIT_COUNTED_FLAG : 0u));
	}
	GroupMemoryBarrierWithGroupSync();

	// ------------------- Fase 1.5: crescimento de planos -------------------
	// Leitura uniforme (pós-barreira) dos escalares antes de qualquer escrita.
	uint old_planes = shared_edit_plane_count;
	uint required_planes = old_planes;
	while ((1u << required_planes) < max(shared_edit_palette_size, 1u)) { required_planes++; }
	if (required_planes > old_planes) {
		uint first_new_word = old_planes * BRICKS_PER_CHUNK;
		uint new_word_count = (required_planes - old_planes) * BRICKS_PER_CHUNK;
		for (uint i = thread; i < new_word_count; i += 128u) {
			material_plane_pool[plane_base + first_new_word + i] = 0u;
		}
		if (thread == 0u) { shared_edit_plane_count = required_planes; }
	}
	GroupMemoryBarrierWithGroupSync();

	// ------------------------- Fase 2: aplica as edições -------------------------
	for (uint i = thread; i < job.edit_count; i += 128u) {
		uint packed_slot = shared_edit_new_slot[i];
		if (packed_slot == EDIT_SLOT_NOOP) { edit_results[job.first_edit + i] = EDIT_RESULT_NOOP; continue; }
		if (packed_slot == EDIT_SLOT_REJECTED) { edit_results[job.first_edit + i] = EDIT_RESULT_REJECTED_PALETTE_FULL; continue; }

		uint new_index = packed_slot & 0x7FFFFFFFu;
		bool counted = (packed_slot & EDIT_COUNTED_FLAG) != 0u;
		uint old_index = shared_edit_old_index[i];

		uint packed_edit = voxel_edits[job.first_edit + i];
		uint voxel_index = packed_edit & 0x7FFFu;
		uint new_block = packed_edit >> 16u;
		int3 coord = coordinate_from_dense_index(voxel_index);
		uint brick_idx = brick_index_from_coordinate(coord / BRICK_SIZE);
		uint bit_idx = bit_index_from_local_coordinate(coord % BRICK_SIZE);
		uint mask = 1u << bit_idx;

		// Planos: toca só nos bits que mudam (RMW atômico preserva os vizinhos
		// do mesmo word — edições de voxels distintos no mesmo brick compõem).
		for (uint plane = 0u; plane < shared_edit_plane_count; plane++) {
			bool old_bit = ((old_index >> plane) & 1u) != 0u;
			bool new_bit = ((new_index >> plane) & 1u) != 0u;
			if (old_bit == new_bit) { continue; }
			uint addr = plane_base + plane * BRICKS_PER_CHUNK + brick_idx;
			if (new_bit) { InterlockedOr(material_plane_pool[addr], mask); }
			else { InterlockedAnd(material_plane_pool[addr], ~mask); }
		}

		// Ocupação (mesma regra do pack: sólido = bloco != 0).
		uint occupancy_addr = occupancy_base + brick_idx;
		if (new_block != 0u) { InterlockedOr(occupancy_pool[occupancy_addr], mask); }
		else { InterlockedAnd(occupancy_pool[occupancy_addr], ~mask); }
		InterlockedOr(shared_edit_dirty_bricks[brick_idx >> 5u], 1u << (brick_idx & 31u));

		// Refcounts. O novo slot só incrementa se a Fase 1 ainda não contou;
		// o antigo decrementa sempre — a CPU garante 1 edição por voxel por
		// flush, então cada voxel decrementa exatamente o tipo que tinha.
		if (!counted) { InterlockedAdd(shared_edit_refcount[new_index], 1u); }
		InterlockedAdd(shared_edit_refcount[old_index], 0xFFFFFFFFu); // -1

		edit_results[job.first_edit + i] = EDIT_RESULT_APPLIED;
	}
	GroupMemoryBarrierWithGroupSync();

	// --------------- Fase 2.5: coarse cells, flag EMPTY, refcounts ---------------
	uint local_or = 0u;
	for (uint i = thread; i < BRICKS_PER_CHUNK; i += 128u) {
		local_or |= occupancy_pool[occupancy_base + i];
	}
	if (local_or != 0u) { InterlockedOr(shared_edit_nonempty, 1u); }

	// Coarse: 1 thread por célula (64), cada uma cobre 2x4x2 = 16 bricks.
	if (thread < COARSE_CELLS_PER_CHUNK) {
		int3 cell = int3(int(thread & 3u), int(thread >> 4u), int((thread >> 2u) & 3u));
		int3 base_brick = cell * BRICKS_PER_COARSE_CELL;
		bool any_solid = false;
		for (uint b = 0u; b < 16u && !any_solid; b++) {
			int3 brick_coord = base_brick + int3(int(b & 1u), int(b >> 2u), int((b >> 1u) & 1u));
			any_solid = occupancy_pool[occupancy_base + brick_index_from_coordinate(brick_coord)] != 0u;
		}
		uint cell_addr = occupancy_base + BRICKS_PER_CHUNK + (thread >> 5u);
		uint cell_mask = 1u << (thread & 31u);
		if (any_solid) { InterlockedOr(occupancy_pool[cell_addr], cell_mask); }
		else { InterlockedAnd(occupancy_pool[cell_addr], ~cell_mask); }
	}

	// Writeback dos refcounts (as entradas da paleta já foram escritas na
	// alocação, na Fase 1).
	for (uint i = thread; i < PALETTE_SIZE_MAXIMUM; i += 128u) {
		uint rc = shared_edit_refcount[i];
		if (rc == EDIT_REFCLAIMED) { rc = 0u; } // defensivo: claim interrompido
		chunk_headers[slot].refcount[i] = rc;
	}
	GroupMemoryBarrierWithGroupSync();

	if (thread == 0u) {
		uint flags = shared_edit_flags;
		if (shared_edit_nonempty != 0u) { flags &= ~CHUNK_FLAG_EMPTY; } else { flags |= CHUNK_FLAG_EMPTY; }
		chunk_headers[slot].flags = flags;
		chunk_headers[slot].palette_size = shared_edit_palette_size;
		chunk_headers[slot].plane_count = shared_edit_plane_count;
	}

	// --------- Fase 3: subdivisão dos bricks sujos (Caminho B) ---------
	// Mesma regra do pack, mas lendo dos planos atualizados (o scratch denso
	// não existe mais depois da geração). Um thread por brick sujo.
	for (uint brick_idx = thread; brick_idx < BRICKS_PER_CHUNK; brick_idx += 128u) {
		if (((shared_edit_dirty_bricks[brick_idx >> 5u] >> (brick_idx & 31u)) & 1u) == 0u) { continue; }
		int3 brick_coord = brick_coordinate_from_index(brick_idx);
		uint part_verts[4] = { 0u, 0u, 0u, 0u };
		uint part_tris[4]  = { 0u, 0u, 0u, 0u };
		for (uint bit_idx = 0u; bit_idx < VOXELS_PER_BRICK; bit_idx++) {
			int3 coord = brick_coord * BRICK_SIZE + local_coordinate_from_bit_index(bit_idx);
			uint palette_index = read_palette_index_at(slot, shared_edit_plane_count, coord);
			palette_index = min(palette_index, shared_edit_palette_size - 1u);
			uint block_id = shared_edit_palette[palette_index];
			if (block_id == 0u) { continue; }
			BlockDefinition def = global_block_registry[block_id];
			MeshTemplate tmpl = mesh_templates[def.mesh_template_index];
			if (tmpl.triangle_count > 0u) {
				uint part = bit_idx >> 3u;
				part_verts[part] += tmpl.vertex_count;
				part_tris[part]  += tmpl.worst_case_tris;
			}
		}
		uint half_verts  = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3]);
		uint half_tris   = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3]);
		uint total_verts = part_verts[0] + part_verts[1] + part_verts[2] + part_verts[3];
		uint total_tris  = part_tris[0] + part_tris[1] + part_tris[2] + part_tris[3];
		uint subdivision = 0u;
		if (total_verts > MESH_VERTEX_MAXIMUM || total_tris > MESH_TRIANGLE_MAXIMUM) {
			subdivision = 1u;
			if (half_verts > MESH_VERTEX_MAXIMUM || half_tris > MESH_TRIANGLE_MAXIMUM) { subdivision = 2u; }
		}
		// Dois RMWs atômicos com campos de 2 bits disjuntos por brick: seguro.
		uint addr = occupancy_base + SUBDIVISION_WORD_BASE + (brick_idx >> 4u);
		uint shift = (brick_idx & 15u) * 2u;
		InterlockedAnd(occupancy_pool[addr], ~(3u << shift));
		if (subdivision != 0u) { InterlockedOr(occupancy_pool[addr], subdivision << shift); }
	}
}

// ============================================================================
// SEÇÃO 7: TASK SHADER (AMPLIFICATION)
// ============================================================================
groupshared TaskPayload shared_payload;
groupshared uint shared_selected_brick_count;

[shader("amplification")]
[numthreads(128, 1, 1)]
void select_bricks(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint thread = local_id.x;
	VisibleChunk chunk = visible_chunks[push_constants.visible_chunk_offset + group_id.x];

	if (thread == 0) {
		shared_selected_brick_count = 0;
		shared_payload.storage_slot_index = chunk.storage_slot_index;
		shared_payload.chunk_world_origin = chunk.chunk_world_origin;
		[unroll]
		for (uint face = 0; face < 6; face++) {
			shared_payload.neighbor_slots[face] = chunk.neighbor_slots[face];
		}
	}
	GroupMemoryBarrierWithGroupSync();

	ChunkHeader header = chunk_headers[chunk.storage_slot_index];
	if ((header.flags & CHUNK_FLAG_EMPTY) != 0) {
		return;
	}

	uint occupancy_base = chunk.storage_slot_index * OCCUPANCY_WORDS_PER_CHUNK;

	uint step_count = BRICKS_PER_CHUNK / 128;
	for (uint step = 0; step < step_count; step++) {
		uint brick_index = thread + step * 128;
		uint occupancy_word = occupancy_pool[occupancy_base + brick_index];

		// TODO: culling de frustum por brick (bounds do brick vs frustum).
		if (occupancy_word != 0) {
			// CAMINHO B: lê o nível de subdivisão decidido pelo pack.
			uint subd_word = occupancy_pool[occupancy_base + SUBDIVISION_WORD_BASE + (brick_index >> 4u)];
			uint subdivision = (subd_word >> ((brick_index & 15u) * 2u)) & 3u;
			uint parts = 1u << subdivision;

			for (uint part = 0; part < parts; part++) {
				uint position;
				InterlockedAdd(shared_selected_brick_count, 1, position);
				if (position < TASK_PAYLOAD_BRICK_CAPACITY) {
					shared_payload.brick_indices[position] =
						brick_index | (part << 10u) | (subdivision << 12u);
				}
				// Payload cheio (patológico: todos os bricks pesados x4):
				// os excedentes são descartados neste frame.
			}
		}
	}
	GroupMemoryBarrierWithGroupSync();

	if (thread == 0) {
		uint dispatch_count = min(shared_selected_brick_count, TASK_PAYLOAD_BRICK_CAPACITY);
		DispatchMesh(dispatch_count, 1, 1, shared_payload);
	}
}

// ============================================================================
// SEÇÃO 8: MESH SHADER - MONTAGEM DA GEOMETRIA A PARTIR DE TEMPLATES
// ============================================================================
groupshared uint shared_v_count[VOXELS_PER_BRICK];
groupshared uint shared_t_count[VOXELS_PER_BRICK];
groupshared uint shared_face_mask[VOXELS_PER_BRICK];
groupshared uint shared_total_v;
groupshared uint shared_total_t;

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)]
void build_brick_mesh(
	uint3 group_id : SV_GroupID,
	uint3 local_id : SV_GroupThreadID,
	in payload TaskPayload payload,
	out indices uint3 tris[MESH_TRIANGLE_MAXIMUM],
	out vertices MeshVertex verts[MESH_VERTEX_MAXIMUM]
) {
	uint slot = payload.storage_slot_index;

	// CAMINHO B: decodifica o grupo (brick + parte, conforme subdivisão do pack)
	uint entry            = payload.brick_indices[group_id.x];
	uint brick_idx        = entry & 1023u;
	uint part             = (entry >> 10u) & 3u;
	uint subdivision_log2 = (entry >> 12u) & 3u;
	uint voxels_in_group  = VOXELS_PER_BRICK >> subdivision_log2;
	bool active           = local_id.x < voxels_in_group;
	uint voxel_slot       = part * voxels_in_group + min(local_id.x, voxels_in_group - 1u);
	int3 voxel_coord      = brick_coordinate_from_index(brick_idx) * BRICK_SIZE + local_coordinate_from_bit_index(voxel_slot);

	uint v_cnt = 0u;
	uint t_cnt = 0u;
	uint face_mask = 0u;
	MeshTemplate tmpl;
	BlockDefinition def;
	uint block_id = 0u;

	if (active) {
		ChunkHeader header = chunk_headers[slot];
		block_id = read_block_identifier(slot, header, voxel_coord);
		def = global_block_registry[block_id];
		tmpl = mesh_templates[def.mesh_template_index];

		if (tmpl.triangle_count > 0u) {
			// Culling de faces só é necessário para templates com triângulos
			// colados em faces do voxel (bit HAS_FLUSH_FACES).
			if ((tmpl.flags & TEMPLATE_FLAG_HAS_FLUSH_FACES) != 0u) {
				face_mask = compute_visible_face_mask(slot, voxel_coord,
					payload.chunk_world_origin, push_constants.camera_position,
					payload.neighbor_slots);
			}

			for (uint t = 0; t < tmpl.triangle_count; t++) {
				uint packed_tri = template_triangles[tmpl.triangle_offset + t];
				if (triangle_survives_culling(packed_tri, def.rotation, face_mask)) {
					t_cnt++;
				}
			}
			// Sem triângulos sobreviventes: nenhum vértice é emitido.
			if (t_cnt > 0u) v_cnt = tmpl.vertex_count;
		}
	}

	shared_v_count[local_id.x] = v_cnt;
	shared_t_count[local_id.x] = t_cnt;
	shared_face_mask[local_id.x] = face_mask;
	GroupMemoryBarrierWithGroupSync();

	// Prefixo exclusivo sequencial (32 elementos; threads inativas contribuem 0).
	// Totais vão para escalares dedicados para não destruir o prefixo do voxel 0.
	if (local_id.x == 0) {
		uint v_acc = 0u, t_acc = 0u;
		for (uint i = 0; i < VOXELS_PER_BRICK; i++) {
			uint vc = shared_v_count[i], tc = shared_t_count[i];
			shared_v_count[i] = v_acc; shared_t_count[i] = t_acc;
			v_acc += vc; t_acc += tc;
		}
		shared_total_v = v_acc;
		shared_total_t = t_acc;
	}
	GroupMemoryBarrierWithGroupSync();

	uint first_v = shared_v_count[local_id.x];
	uint first_t = shared_t_count[local_id.x];

	SetMeshOutputCounts(shared_total_v, shared_total_t);

	if (!active || v_cnt == 0u) return;

	// ------------------------- Emissão de vértices -------------------------
	float3 voxel_min_world = float3(payload.chunk_world_origin + voxel_coord);
	for (uint i = 0; i < tmpl.vertex_count; i++) {
		float3 local_pos = template_vertices[tmpl.vertex_offset + i];
		local_pos = rotate_vertex_yaw(local_pos, def.rotation);

		MeshVertex v;
		v.world_position = voxel_min_world + local_pos;
		v.clip_position = mul(push_constants.view_projection_matrix, float4(v.world_position, 1.0));
		v.block_id = block_id;
		verts[first_v + i] = v;
	}

	// ------------------------- Emissão de triângulos ------------------------
	uint mask = shared_face_mask[local_id.x];
	uint t_cur = first_t;
	for (uint t = 0; t < tmpl.triangle_count; t++) {
		uint packed_tri = template_triangles[tmpl.triangle_offset + t];
		if (!triangle_survives_culling(packed_tri, def.rotation, mask)) continue;

		uint3 tri = uint3(packed_tri & 0xFFu, (packed_tri >> 8u) & 0xFFu, (packed_tri >> 16u) & 0xFFu);
		tris[t_cur++] = tri + first_v;
	}
}

// ============================================================================
// SEÇÃO 9: FRAGMENT SHADER (PBR + TRIPLANAR + DENOISING DE NORMAL)
// ============================================================================
// As normais são calculadas com derivadas espaciais (dFdx/dFdy) na tela.
// Isso elimina o custo de transferência de normais e suaviza o aliasing de geometria.
// Funciona para qualquer malha (cubos, escadas, plantas, móveis em múltiplos voxels).
float3 sample_triplanar_albedo(float3 world_pos, float3 world_normal, uint texture_index) {
	float3 blend_weights = abs(world_normal);
	blend_weights = blend_weights / (blend_weights.x + blend_weights.y + blend_weights.z);

	float3 x_projection = block_albedo_textures.Sample(float3(world_pos.zy, float(texture_index))).rgb;
	float3 y_projection = block_albedo_textures.Sample(float3(world_pos.xz, float(texture_index))).rgb;
	float3 z_projection = block_albedo_textures.Sample(float3(world_pos.xy, float(texture_index))).rgb;

	return x_projection * blend_weights.x + y_projection * blend_weights.y + z_projection * blend_weights.z;
}

[shader("fragment")]
float4 shade_voxel(MeshVertex input) : SV_Target {
	BlockDefinition def = global_block_registry[input.block_id];

	float3 normal_x = dFdx(input.world_position);
	float3 normal_y = dFdy(input.world_position);
	float3 normal = normalize(cross(normal_x, normal_y));

	float3 albedo = sample_triplanar_albedo(input.world_position, normal, def.albedo_texture_index);

	// TODO: implementar a equação de Cook-Torrance completa e SSAO de tela.
	float3 light_dir = normalize(float3(0.5, 0.8, 0.3));
	float diffuse = max(dot(normal, light_dir), 0.0);
	float3 ambient = float3(0.2);
	float3 final_color = albedo * (ambient + diffuse) + def.emission_color;

	return float4(final_color, 1.0);
}
