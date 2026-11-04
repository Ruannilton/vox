// =============================================================================
// CHUNK SHADERS (Slang)
// =============================================================================
//
// Este arquivo reúne todos os shaders do pipeline de chunks:
//
//   PARTE 1  generate_chunk            (compute)       gera o terreno de cada chunk pendente
//   PARTE 2  cull_and_dispatch_bricks  (amplification) descarta chunks fora da tela e escolhe bricks
//   PARTE 3  build_brick_mesh          (mesh)          transforma voxels em triângulos
//   PARTE 4  shade_fragment            (fragment)      pinta os pixels
//
// FLUXO DE DADOS
// --------------
//   [thread de geração]                         [thread de render]
//   generate_chunk  ---escreve--->  voxel_pool  <---lê---  task / mesh
//
// Um "slot" é um pedaço fixo de voxel_pool com CHUNK_VOXEL_COUNT (4096) voxels de 64 bits.
// O slot N começa em N * 4096.
//
// COMO O DESENHO FUNCIONA
// -----------------------
//   - vkCmdDrawMeshTasksEXT(visible_chunk_count, 1, 1): UM workgroup de task por chunk visível.
//   - O task shader divide o chunk em 128 "bricks" de 4x2x4 voxels (32 voxels cada).
//     Só os bricks que têm alguma face visível viram workgroups de mesh.
//   - O mesh shader (32 threads = 1 thread por voxel do brick) emite um cubo de 8 vértices
//     para cada voxel exposto, mas só com os triângulos das faces voltadas para a câmera.
//
// LIMITES DO MESH SHADER (mínimos garantidos pela especificação: 256 vértices / 256 primitivas)
//   32 voxels * 8 vértices      = 256 vértices   (cabe)
//   32 voxels * 3 faces * 2 tri = 192 triângulos (cabe: uma câmera vê no máximo 3 faces de um cubo)
//
// BINDINGS (todos no set 0)
//   0  voxel_pool        storage buffer   COMPUTE | TASK | MESH
//   1  generation_jobs   storage buffer   COMPUTE
//   2  visible_chunks    storage buffer   TASK
//   3  camera            uniform buffer   TASK | MESH | FRAGMENT
//
// EXEMPLO DE COMPILAÇÃO (confira as flags com `slangc -h` na sua versão):
//   slangc chunk_shaders.slang -target spirv -profile spirv_1_5 -fvk-use-entrypoint-name -o chunk_shaders.spv
//   Features Vulkan necessárias: shaderInt64, meshShader, taskShader, timelineSemaphore.
//
// =============================================================================


// =============================================================================
// SEÇÃO 1: CONSTANTES
// =============================================================================

static const int  CHUNK_SIZE        = 16;              // voxels por lado
static const uint CHUNK_VOXEL_COUNT = 16 * 16 * 16;

static const uint64_t VOXEL_AIR   = 0;
static const uint64_t VOXEL_SOLID = 1;

// Um brick é um bloco de 4 (x) * 2 (y) * 4 (z) = 32 voxels.
// Um chunk tem 4 * 8 * 4 = 128 bricks.
static const int3 BRICK_SIZE        = int3(4, 2, 4);
static const uint BRICK_VOXEL_COUNT = 32;
static const uint BRICKS_PER_CHUNK  = 128;

static const uint VERTICES_PER_VOXEL     = 8;                              // os 8 cantos de um cubo
static const uint MAX_MESH_VERTICES      = BRICK_VOXEL_COUNT * 8;          // 256
static const uint MAX_MESH_TRIANGLES     = BRICK_VOXEL_COUNT * 3 * 2;      // 192

// O terreno precisa caber nos 16 voxels de altura de um chunk (o streamer só cria chunks em y = 0).
static const float TERRAIN_BASE_HEIGHT      = 3.0;
static const float TERRAIN_HEIGHT_VARIATION = 10.0;
static const float TERRAIN_NOISE_SCALE      = 0.02;


// =============================================================================
// SEÇÃO 2: STRUCTS E RECURSOS
// =============================================================================

// Mesmo layout (16 bytes) dos structs ChunkGenerationJob e VisibleChunk do Odin.
struct ChunkGenerationJob
{
    int3 world_origin; // canto do chunk em coordenadas de voxel do mundo
    uint slot_id;      // onde gravar em voxel_pool
};

struct VisibleChunk
{
    int3 world_origin;
    uint slot_id;
};

// Layout std140. No Odin:
//   CameraConstants :: struct #align(16) {
//       view_projection: matrix[4, 4]f32, // column-major, profundidade em [0, 1] (Vulkan)
//       camera_position: [3]f32,
//       _padding:        f32,
//   }
struct CameraConstants
{
    column_major float4x4 view_projection;
    float3 camera_position;
    float  _padding;
};

// Usado como RW porque o compute escreve. Task e mesh apenas leem.
[[vk::binding(0, 0)]] RWStructuredBuffer<uint64_t>     voxel_pool;
[[vk::binding(1, 0)]] StructuredBuffer<ChunkGenerationJob> generation_jobs;
[[vk::binding(2, 0)]] StructuredBuffer<VisibleChunk>   visible_chunks;
[[vk::binding(3, 0)]] ConstantBuffer<CameraConstants>  camera;


// =============================================================================
// SEÇÃO 3: FUNÇÕES COMPARTILHADAS
// =============================================================================

// Posição de um voxel dentro do slot. x varia mais rápido, depois z, depois y.
// Threads vizinhas (x consecutivo) acessam endereços consecutivos: acesso coalescido.
uint voxel_index_in_chunk(int3 voxel_coord)
{
    return uint(voxel_coord.x) | (uint(voxel_coord.z) << 4) | (uint(voxel_coord.y) << 8);
}

// Lê um voxel. A coordenada precisa estar dentro do chunk.
bool is_voxel_solid(uint slot_id, int3 voxel_coord)
{
    uint address = slot_id * CHUNK_VOXEL_COUNT + voxel_index_in_chunk(voxel_coord);
    return voxel_pool[address] != VOXEL_AIR;
}

// Uma face fica ESCONDIDA se o vizinho do outro lado a bloqueia.
// A coordenada do vizinho pode cair fora do chunk, então tratamos as bordas:
//   - abaixo do chunk (y < 0): conta como sólido (o fundo do mundo nunca aparece)
//   - lados e topo: conta como ar (limitação: não consultamos o chunk vizinho,
//     então as faces nas bordas laterais são desenhadas mesmo se encostarem em outro chunk)
bool does_neighbor_block_face(uint slot_id, int3 neighbor_coord)
{
    if (neighbor_coord.y < 0)
    {
        return true;
    }

    bool outside_chunk = any(neighbor_coord.xz < 0)
                      || any(neighbor_coord.xz >= CHUNK_SIZE)
                      || neighbor_coord.y >= CHUNK_SIZE;
    if (outside_chunk)
    {
        return false;
    }

    return is_voxel_solid(slot_id, neighbor_coord);
}

// As 6 faces de um cubo. A ordem (índice = bit na máscara) é: +X, -X, +Y, -Y, +Z, -Z.
static const int3 FACE_NORMALS[6] = {
    int3( 1, 0, 0), int3(-1, 0, 0),
    int3( 0, 1, 0), int3( 0,-1, 0),
    int3( 0, 0, 1), int3( 0, 0,-1),
};

// Máscara de faces que valem a pena desenhar para um voxel.
// Bit `face` ligado significa: a face existe E está voltada para a câmera E não está escondida.
uint compute_visible_face_mask(uint slot_id, int3 voxel_coord, int3 chunk_world_origin, float3 camera_position)
{
    if (!is_voxel_solid(slot_id, voxel_coord))
    {
        return 0; // ar não gera nada
    }

    float3 voxel_min_world = float3(chunk_world_origin + voxel_coord);
    uint   face_mask       = 0;

    [unroll]
    for (uint face = 0; face < 6; face++)
    {
        // 1) Escondida por um vizinho sólido?
        if (does_neighbor_block_face(slot_id, voxel_coord + FACE_NORMALS[face]))
        {
            continue;
        }

        // 2) Voltada para a câmera? A câmera precisa estar do lado de fora do plano da face.
        uint  axis        = face >> 1;           // 0 = X, 1 = Y, 2 = Z
        bool  is_positive = (face & 1) == 0;     // faces +X, +Y, +Z
        float plane_position = voxel_min_world[axis] + (is_positive ? 1.0 : 0.0);
        bool  camera_sees_face = is_positive ? (camera_position[axis] > plane_position)
                                             : (camera_position[axis] < plane_position);
        if (!camera_sees_face)
        {
            continue;
        }

        face_mask |= 1u << face;
    }

    return face_mask;
}

// Converte um índice linear em coordenada (x mais rápido, depois z, depois y).
//   - índice de brick no chunk (0..127) -> coordenada do brick (x 0..3, y 0..7, z 0..3)
//   - índice de voxel no brick (0..31)  -> coordenada no brick  (x 0..3, y 0..1, z 0..3)
int3 unpack_xzy_index(uint index)
{
    return int3(int(index & 3u), int(index >> 4u), int((index >> 2u) & 3u));
}


// =============================================================================
// PARTE 1: COMPUTE - GERAÇÃO DE TERRENO
// =============================================================================
// Dispatch: vkCmdDispatch(job_count, 1, 1). Um workgroup por chunk do batch.
// Cada thread cuida de UMA COLUNA (x, z) e preenche os 16 voxels dela em y.
// Assim o ruído 2D de altura é calculado uma vez por coluna, não 16 vezes.

// Hash de inteiro (PCG). Mesma entrada -> mesma saída, em qualquer GPU.
uint hash_integer(uint value)
{
    uint state = value * 747796405u + 2891336453u;
    uint word  = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Número "aleatório" fixo entre 0 e 1 para cada ponto inteiro do grid.
float random_value_at_grid_point(int2 grid_point)
{
    uint hashed = hash_integer(uint(grid_point.x) ^ hash_integer(uint(grid_point.y)));
    return float(hashed) / 4294967295.0;
}

// Value noise: interpola suavemente os valores dos 4 pontos do grid ao redor.
float value_noise_2d(float2 position)
{
    int2   cell     = int2(floor(position));
    float2 fraction = frac(position);
    float2 smooth   = fraction * fraction * (3.0 - 2.0 * fraction); // smoothstep

    float bottom_left  = random_value_at_grid_point(cell);
    float bottom_right = random_value_at_grid_point(cell + int2(1, 0));
    float top_left     = random_value_at_grid_point(cell + int2(0, 1));
    float top_right    = random_value_at_grid_point(cell + int2(1, 1));

    return lerp(lerp(bottom_left, bottom_right, smooth.x),
                lerp(top_left,    top_right,    smooth.x),
                smooth.y);
}

// Fractal Brownian Motion: soma 4 camadas de ruído, cada uma com metade da força
// e o dobro da frequência. Resultado normalizado em [0, 1].
float fractal_noise_2d(float2 position)
{
    float sum       = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float amplitude_total = 0.0;

    for (int octave = 0; octave < 4; octave++)
    {
        sum            += value_noise_2d(position * frequency) * amplitude;
        amplitude_total += amplitude;
        amplitude      *= 0.5;
        frequency      *= 2.0;
    }
    return sum / amplitude_total;
}

float terrain_height_at(int2 world_xz)
{
    float noise = fractal_noise_2d(float2(world_xz) * TERRAIN_NOISE_SCALE);
    return TERRAIN_BASE_HEIGHT + noise * TERRAIN_HEIGHT_VARIATION;
}

[shader("compute")]
[numthreads(16, 16, 1)] // = CHUNK_SIZE x CHUNK_SIZE: uma thread por coluna
void generate_chunk(
    uint3 group_id        : SV_GroupID,         // x = índice do job no batch
    uint3 thread_in_group : SV_GroupThreadID)   // (x, z) da coluna dentro do chunk
{
    ChunkGenerationJob job = generation_jobs[group_id.x];

    int2  column_in_chunk = int2(thread_in_group.xy);
    int2  column_world_xz = job.world_origin.xz + column_in_chunk;
    float column_height   = terrain_height_at(column_world_xz);

    for (int local_y = 0; local_y < CHUNK_SIZE; local_y++)
    {
        int world_y = job.world_origin.y + local_y;

        uint64_t voxel = (float(world_y) < column_height) ? VOXEL_SOLID : VOXEL_AIR;

        int3 voxel_coord = int3(column_in_chunk.x, local_y, column_in_chunk.y);
        uint address     = job.slot_id * CHUNK_VOXEL_COUNT + voxel_index_in_chunk(voxel_coord);

        voxel_pool[address] = voxel;
    }
}


// =============================================================================
// PARTE 2: TASK (AMPLIFICATION) - CULLING E ESCOLHA DOS BRICKS
// =============================================================================
// Um workgroup por chunk visível (group_id.x = índice em visible_chunks).
// 128 threads = 128 bricks: cada thread avalia um brick.
// No fim, DispatchMesh lança um workgroup de mesh apenas para os bricks que importam.

// Dados que o task envia para os workgroups de mesh que ele lança.
struct TaskPayload
{
    uint slot_id;
    int3 chunk_world_origin;
    uint brick_indices[BRICKS_PER_CHUNK]; // só os primeiros `visible_brick_count` são válidos
};

groupshared TaskPayload shared_payload;
groupshared uint        shared_visible_brick_count;

// O chunk (um cubo de 16^3) está, ao menos em parte, dentro do campo de visão da câmera?
// Os 6 planos do frustum saem direto da matriz view-projection (método de Gribb-Hartmann).
bool is_chunk_inside_frustum(int3 chunk_world_origin)
{
    float3 box_min = float3(chunk_world_origin);
    float3 box_max = box_min + float(CHUNK_SIZE);

    float4x4 m = camera.view_projection;
    float4 planes[6];
    planes[0] = m[3] + m[0]; // esquerda
    planes[1] = m[3] - m[0]; // direita
    planes[2] = m[3] + m[1]; // baixo
    planes[3] = m[3] - m[1]; // cima
    planes[4] = m[2];        // perto (profundidade de 0 a 1)
    planes[5] = m[3] - m[2]; // longe

    for (int i = 0; i < 6; i++)
    {
        float3 normal = planes[i].xyz;

        // Canto da caixa que fica mais "para dentro" do plano.
        float3 farthest_corner = float3(
            normal.x >= 0 ? box_max.x : box_min.x,
            normal.y >= 0 ? box_max.y : box_min.y,
            normal.z >= 0 ? box_max.z : box_min.z);

        if (dot(normal, farthest_corner) + planes[i].w < 0)
        {
            return false; // até o melhor canto está fora: a caixa inteira está fora
        }
    }
    return true;
}

// O brick tem algum voxel com face desenhável? Para na primeira que achar.
bool does_brick_have_visible_face(uint slot_id, int3 chunk_world_origin, uint brick_index)
{
    int3 brick_origin = unpack_xzy_index(brick_index) * BRICK_SIZE;

    for (uint voxel_in_brick = 0; voxel_in_brick < BRICK_VOXEL_COUNT; voxel_in_brick++)
    {
        int3 voxel_coord = brick_origin + unpack_xzy_index(voxel_in_brick);

        if (compute_visible_face_mask(slot_id, voxel_coord, chunk_world_origin, camera.camera_position) != 0)
        {
            return true;
        }
    }
    return false;
}

[shader("amplification")]
[numthreads(128, 1, 1)] // = BRICKS_PER_CHUNK
void cull_and_dispatch_bricks(
    uint3 group_id    : SV_GroupID,     // x = índice em visible_chunks
    uint  brick_index : SV_GroupIndex)  // 0..127: esta thread avalia este brick
{
    VisibleChunk chunk = visible_chunks[group_id.x];

    // Passo 1: a thread 0 prepara o payload e zera o contador.
    if (brick_index == 0)
    {
        shared_visible_brick_count        = 0;
        shared_payload.slot_id            = chunk.slot_id;
        shared_payload.chunk_world_origin = chunk.world_origin;
    }
    GroupMemoryBarrierWithGroupSync();

    // Passo 2: se o chunk está na tela, cada thread avalia seu brick.
    // (O resultado do teste de frustum é igual para todas as threads, então não há divergência.)
    if (is_chunk_inside_frustum(chunk.world_origin))
    {
        if (does_brick_have_visible_face(chunk.slot_id, chunk.world_origin, brick_index))
        {
            // Reserva a próxima posição livre da lista de bricks.
            uint list_position;
            InterlockedAdd(shared_visible_brick_count, 1, list_position);
            shared_payload.brick_indices[list_position] = brick_index;
        }
    }
    GroupMemoryBarrierWithGroupSync();

    // Passo 3: lança um workgroup de mesh por brick escolhido.
    // Todas as threads chamam DispatchMesh com os mesmos valores. Se o contador for 0, nada é lançado.
    DispatchMesh(shared_visible_brick_count, 1, 1, shared_payload);
}


// =============================================================================
// PARTE 3: MESH - VOXELS VIRAM TRIÂNGULOS
// =============================================================================
// Um workgroup por brick escolhido pelo task (group_id.x = posição na lista do payload).
// 32 threads = 32 voxels: cada thread cuida de um voxel.
//
// Cada voxel exposto emite os 8 cantos de um cubo, mas só os triângulos das faces visíveis.
// Como o número de voxels expostos varia, usamos uma "soma de prefixos" para saber onde
// cada thread escreve na saída (thread 0 calcula, as demais leem).

struct MeshVertex
{
    float4 clip_position  : SV_Position;
    float3 world_position : WORLD_POSITION;
};

// Os 2 triângulos de cada face, em índices de canto do cubo.
// Canto i: x = bit 0, y = bit 1, z = bit 2. Exemplo: canto 5 (101b) = (x=1, y=0, z=1).
// Ordem das faces igual a FACE_NORMALS. A ordem dos vértices não garante um sentido de rotação
// único, então use cull mode NONE no pipeline (já só emitimos faces voltadas para a câmera).
static const uint3 FACE_TRIANGLES[12] = {
    uint3(1, 3, 7), uint3(1, 7, 5), // +X
    uint3(0, 4, 6), uint3(0, 6, 2), // -X
    uint3(2, 6, 7), uint3(2, 7, 3), // +Y
    uint3(0, 1, 5), uint3(0, 5, 4), // -Y
    uint3(4, 5, 7), uint3(4, 7, 6), // +Z
    uint3(0, 2, 3), uint3(0, 3, 1), // -Z
};

groupshared uint shared_face_mask[BRICK_VOXEL_COUNT];      // faces visíveis de cada voxel
groupshared uint shared_first_vertex[BRICK_VOXEL_COUNT];   // onde cada voxel começa nos vértices
groupshared uint shared_first_triangle[BRICK_VOXEL_COUNT]; // onde cada voxel começa nos triângulos
groupshared uint shared_total_vertices;
groupshared uint shared_total_triangles;

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(32, 1, 1)] // = BRICK_VOXEL_COUNT
void build_brick_mesh(
    uint3 group_id             : SV_GroupID,     // x = posição na lista do payload
    uint  voxel_in_brick_index : SV_GroupIndex,  // 0..31
    in payload TaskPayload task_payload,
    OutputVertices<MeshVertex, MAX_MESH_VERTICES> out_vertices,
    OutputIndices<uint3, MAX_MESH_TRIANGLES>      out_triangles)
{
    // Passo 1: descobrir qual voxel é o desta thread e quais faces ele precisa desenhar.
    uint brick_index = task_payload.brick_indices[group_id.x];
    int3 voxel_coord = unpack_xzy_index(brick_index) * BRICK_SIZE
                     + unpack_xzy_index(voxel_in_brick_index);

    uint face_mask = compute_visible_face_mask(
        task_payload.slot_id, voxel_coord, task_payload.chunk_world_origin, camera.camera_position);

    shared_face_mask[voxel_in_brick_index] = face_mask;
    GroupMemoryBarrierWithGroupSync();

    // Passo 2: a thread 0 calcula onde cada voxel escreve (soma de prefixos sequencial, 32 passos).
    if (voxel_in_brick_index == 0)
    {
        uint vertex_cursor   = 0;
        uint triangle_cursor = 0;

        for (uint i = 0; i < BRICK_VOXEL_COUNT; i++)
        {
            shared_first_vertex[i]   = vertex_cursor;
            shared_first_triangle[i] = triangle_cursor;

            uint mask = shared_face_mask[i];
            if (mask != 0)
            {
                vertex_cursor   += VERTICES_PER_VOXEL;
                triangle_cursor += 2 * countbits(mask); // 2 triângulos por face
            }
        }
        shared_total_vertices  = vertex_cursor;
        shared_total_triangles = triangle_cursor;
    }
    GroupMemoryBarrierWithGroupSync();

    // Passo 3: todas as threads declaram o tamanho da saída (mesmos valores para todas).
    SetMeshOutputCounts(shared_total_vertices, shared_total_triangles);

    if (face_mask == 0)
    {
        return; // voxel de ar ou totalmente escondido: nada a escrever
    }

    // Passo 4: escreve os 8 vértices do cubo.
    uint   first_vertex    = shared_first_vertex[voxel_in_brick_index];
    float3 voxel_min_world = float3(task_payload.chunk_world_origin + voxel_coord);

    for (uint corner = 0; corner < VERTICES_PER_VOXEL; corner++)
    {
        float3 corner_offset = float3(
            float(corner & 1u),
            float((corner >> 1u) & 1u),
            float((corner >> 2u) & 1u));

        float3 world_position = voxel_min_world + corner_offset;

        MeshVertex vertex;
        vertex.clip_position  = mul(camera.view_projection, float4(world_position, 1.0));
        vertex.world_position = world_position;

        out_vertices[first_vertex + corner] = vertex;
    }

    // Passo 5: escreve os triângulos, só das faces visíveis.
    uint triangle_cursor = shared_first_triangle[voxel_in_brick_index];

    for (uint face = 0; face < 6; face++)
    {
        if ((face_mask & (1u << face)) == 0)
        {
            continue;
        }

        out_triangles[triangle_cursor + 0] = first_vertex + FACE_TRIANGLES[face * 2 + 0];
        out_triangles[triangle_cursor + 1] = first_vertex + FACE_TRIANGLES[face * 2 + 1];
        triangle_cursor += 2;
    }
}


// =============================================================================
// PARTE 4: FRAGMENT - COR DO PIXEL
// =============================================================================
// Iluminação simples com sombreamento chapado (flat). Como os vértices do cubo são
// compartilhados entre faces, a normal vem das derivadas da posição na tela, e não de um atributo.

[shader("fragment")]
float4 shade_fragment(MeshVertex input) : SV_Target
{
    // Normal da face: perpendicular às duas direções em que a posição muda na tela.
    float3 face_normal = normalize(cross(ddx(input.world_position), ddy(input.world_position)));

    // A orientação do produto vetorial depende da convenção de coordenadas.
    // Garante que a normal aponte para a câmera.
    float3 direction_to_camera = camera.camera_position - input.world_position;
    if (dot(face_normal, direction_to_camera) < 0.0)
    {
        face_normal = -face_normal;
    }

    float3 light_direction = normalize(float3(0.4, 1.0, 0.3));
    float  diffuse         = saturate(dot(face_normal, light_direction));
    float  ambient         = 0.3;

    // Cor por altura: grama embaixo, pedra em cima.
    float3 grass_color = float3(0.25, 0.55, 0.20);
    float3 rock_color  = float3(0.50, 0.45, 0.40);
    float  height_blend = saturate(input.world_position.y / float(CHUNK_SIZE));
    float3 base_color  = lerp(grass_color, rock_color, height_blend);

    return float4(base_color * (ambient + (1.0 - ambient) * diffuse), 1.0);
}
