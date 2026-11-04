#include "./lib/FastNoiseLite.slang"

#define TASK_GROUP_SIZE 16
#define VOXEL_GRID_SIZE 16

struct PushConstants {
    float4x4 mvp;
    float time;
};


const static float3[4] colors = {
    float3(1.0, 0.0, 0.0), // Vermelho
    float3(0.0, 1.0, 0.0), // Verde
    float3(0.0, 0.0, 1.0), // Azul
    float3(1.0, 1.0, 0.0)  // Amarelo
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> pc;

uint3 getVoxelCoords(uint id) {
    uint x = id % VOXEL_GRID_SIZE;
    uint y = (id / VOXEL_GRID_SIZE) % VOXEL_GRID_SIZE;
    uint z = id / (VOXEL_GRID_SIZE * VOXEL_GRID_SIZE);
    return uint3(x, y, z);
}

uint getVoxelID(uint3 coord) {
    return coord.x + coord.y * VOXEL_GRID_SIZE + coord.z * VOXEL_GRID_SIZE * VOXEL_GRID_SIZE;
}

// Reaproveitamos o VoxelValue para armazenar o ID real do voxel
struct VoxelValue {
    uint value; 
};

// O Buffer será usado para leitura e escrita
[[vk::binding(0,0)]]
RWStructuredBuffer<VoxelValue> voxelBuffer;

[[vk::binding(1,0)]]
RWStructuredBuffer<uint> noiseBuffer;

[shader("compute")]
[numthreads(VOXEL_GRID_SIZE,VOXEL_GRID_SIZE,4)]
void computeNoise(uint3 groupID: SV_DispatchThreadID){
    fnl_state fnl;
    fnl = fnlCreateState();
    fnl.frequency = 0.1;
    fnl.noise_type = FNL_NOISE_PERLIN;

    uint voxelLocalId = getVoxelID(groupID);
    uint3 coord = getVoxelCoords(voxelLocalId);

    uint density = fnlGetNoise3D(fnl,coord.x, coord.y, coord.z) > 0 ? 1 : 0;

    voxelBuffer[voxelLocalId].value = voxelLocalId;
}



// PAYLOAD OTIMIZADO: Apenas 4 bytes! Transporta só a referência do grupo.
struct TaskToMeshPayload {
    uint taskGroupID;
};

struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR;
};



groupshared Atomic<uint> s_validVoxelCount;
groupshared TaskToMeshPayload s_payload;

[shader("task")]
[numthreads(TASK_GROUP_SIZE, 1, 1)]
void taskMain(
    uint3 globalID: SV_DispatchThreadID, 
    uint3 localID: SV_GroupThreadID,
    uint3 groupID: SV_GroupID // Pedimos o ID do grupo para indexar o SSBO
) {
    fnl_state fnl;
    fnl = fnlCreateState();
    fnl.frequency = 0.1;
    fnl.noise_type = FNL_NOISE_PERLIN;


    if (localID.x == 0) {    
        s_validVoxelCount.store(0);
        s_payload.taskGroupID = groupID.x; // Guardamos quem nós somos no payload
    }
    GroupMemoryBarrierWithGroupSync();

    uint voxelGlobalID = globalID.x;
    uint3 coord = getVoxelCoords(voxelGlobalID);
   
    uint density = fnlGetNoise3D(fnl,coord.x, coord.y, coord.z) > 0 ? 1 : 0;
        
    if(density > 0) {
        uint slot = s_validVoxelCount.increment();
        
        // ESCRITA NO SSBO:
        // Cada Task Group (de 0 a 511) tem um pedaço fixo e exclusivo de tamanho 8 no buffer.
        // Isto elimina qualquer condição de corrida entre grupos diferentes.
        uint ssboIndex = (groupID.x * TASK_GROUP_SIZE) + slot;
        voxelBuffer[ssboIndex].value = voxelGlobalID;
    }
        
    GroupMemoryBarrierWithGroupSync();

    if (localID.x == 0) {
        DispatchMesh(s_validVoxelCount.load(), 1, 1, s_payload);
    }
}

[shader("mesh")]
[numthreads(1, 1, 1)]
[outputtopology("triangle")]
void meshMain( 
    uint3 meshGroupID : SV_GroupID,
    in payload TaskToMeshPayload p,
    OutputVertices<VertexOutput, 8> verts, 
    OutputIndices<uint3, 12> tris)
{
    SetMeshOutputCounts(8, 12);
    
    // LEITURA DO SSBO:
    // Reconstruímos a posição exata da memória usando o taskGroupID que viajou no payload minúsculo
    uint ssboIndex = (p.taskGroupID * TASK_GROUP_SIZE) + meshGroupID.x;
    uint voxelID = voxelBuffer[ssboIndex].value;

    uint3 position = getVoxelCoords(voxelID);
    var color = colors[voxelID % 4];

    float halfGrid = float(VOXEL_GRID_SIZE) * 0.5f;
    float ox = float(position.x) - halfGrid;
    float oy = float(position.y) - halfGrid;
    float oz = float(position.z) - halfGrid;

    for(int i = 0; i < 8; i++) {
        float vx = ox + float(i & 1);           
        float vy = oy + float((i >> 1) & 1);    
        float vz = oz + float((i >> 2) & 1);    

        verts[i] = { mul(pc.mvp, float4(vx, vy, vz, 1.0)), color };
    }

    tris[0] = uint3(2, 1, 0); tris[1] = uint3(3, 1, 2);
    tris[2] = uint3(7, 4, 5); tris[3] = uint3(6, 4, 7);
    tris[4] = uint3(0, 1, 4); tris[5] = uint3(4, 1, 5); 
    tris[6] = uint3(2, 6, 3); tris[7] = uint3(3, 6, 7); 
    tris[8] = uint3(6, 0, 4); tris[9] = uint3(2, 0, 6);
    tris[10] = uint3(3, 5, 1); tris[11] = uint3(7, 5, 3);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    return float4(input.color, 1.0);
}