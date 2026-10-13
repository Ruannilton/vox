// Define a estrutura de dados que passará do Vertex para o Fragment Shader
struct VertexOut {
    float4 position : SV_Position;
    float3 color : COLOR;
};

// Entry point do Vertex Shader
[shader("vertex")]
VertexOut vertexMain(uint vertexID : SV_VertexID) {
    VertexOut output;
    
    // Coordenadas dos 3 vértices do triângulo (em NDC)
    float2 positions[3] = {
        float2( 0.0, -0.5), // Topo
        float2( 0.5,  0.5), // Base Direita
        float2(-0.5,  0.5)  // Base Esquerda
    };
    
    // Cores RGB para cada vértice
    float3 colors[3] = {
        float3(1.0, 0.0, 0.0), // Vermelho
        float3(0.0, 1.0, 0.0), // Verde
        float3(0.0, 0.0, 1.0)  // Azul
    };

    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.color = colors[vertexID];
    
    return output;
}

// Entry point do Fragment (Pixel) Shader
[shader("fragment")]
float4 fragmentMain(VertexOut input) : SV_Target {
    // Retorna a cor interpolada com Alpha 1.0 (opaco)
    return float4(input.color, 1.0);
}