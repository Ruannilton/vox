struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR;
};

// View Projection Matrix (VP)
struct PushConstants {
    float4x4 mvp;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> pc;

const static float3[4] colors = {
    float3(1.0, 0.0, 0.0), // Vermelho
    float3(0.0, 1.0, 0.0), // Verde
    float3(0.0, 0.0, 1.0), // Azul
    float3(1.0, 1.0, 0.0)  // Amarelo
};

[shader("mesh")]
[numthreads(1, 1, 1)]
[outputtopology("triangle")]
void meshMain( uint3 groupID  : SV_GroupID,
    OutputVertices<VertexOutput, 8> verts, 
    OutputIndices<uint3, 12> tris  ){

    SetMeshOutputCounts(8, 12);
    float3 origin = float3(-0.5, -0.5, -0.5);

    float ox = float(origin.x);
    float oy = float(origin.y);
    float oz = float(origin.z);

    for(int i = 0; i < 8; i++) {
        float vx = ox + float(i & 1);           // Extrai o bit 0
        float vy = oy + float((i >> 1) & 1);    // Extrai o bit 1
        float vz = oz + float((i >> 2) & 1);    // Extrai o bit 2

         verts[i] = { mul(pc.mvp,float4(vx * 2.0, vy * 2.0, vz * 2.0, 1.0)), colors[i % 4] };
    }

    // Face Frontal
    tris[0] = uint3(2, 1, 0); tris[1] = uint3(3, 1, 2);
    // Face Trás
    tris[2] = uint3(7, 4, 5); tris[3] = uint3(6, 4, 7);
    // Face Topo
    tris[4] = uint3(0, 1, 4); tris[5] = uint3(4, 1, 5); 
    // Face Base
    tris[6] = uint3(2, 6, 3); tris[7] = uint3(3, 6, 7); 
    // Face Esquerda
    tris[8] = uint3(6, 0, 4); tris[9] = uint3(2, 0, 6);
    // Face Direita
    tris[10] = uint3(3, 5, 1); tris[11] = uint3(7, 5, 3);
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    return float4(input.color, 1.0);
}