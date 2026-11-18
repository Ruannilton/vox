# Arquitetura Avançada para Geração Procedural de Biomas e Terrenos Voxel

## 1. Contexto e a Problemática dos Paredões Abruptos

Na geração procedural de mundos voxelizados, a determinação de biomas não pode ser tratada como um conjunto de partições isoladas com bordas secas (ex: `if (bioma == MONTANHA)`). Se cada bioma utilizar um algoritmo de ruído com amplitudes e frequências discrepantes (como um ruído suave de baixa frequência para estepes e um ruído *Fractal Brownian Motion* de alta amplitude para serras), a comutação direta entre essas funções gera **paredões verticais, sulcos anômalos e desníveis catastróficos** na malha topológica.

Para que o terreno transite de forma orgânica e plausível, é necessário abandonar o sorteio direto de biomas e adotar um **modelo climático contínuo**, onde a transição entre biomas ocorra por meio de uma zona de mistura ponderada (o ecótono).

---

## 2. Pilares Matemáticos e Algorítmicos de Suavização

### 2.1. Eixos Paramétricos de Decisão Climática
Inspirando-se no modelo ecoclimatológico de Whittaker, a distribuição geográfica dos biomas é regida por campos escalares contínuos de baixíssima frequência:
* **Temperatura ($T$):** Dita os gradientes de congelamento ou aridez regional.
* **Umidade ($H$):** Dita a densidade vegetal e a presença de bacias hídricas.

A posição espacial do voxel ou da coluna topológica é avaliada no espaço de fases cartesiano $(T, H)$. A distância euclidiana da coordenada atual em relação aos "centros climáticos" teóricos de cada bioma determina quais ecossistemas exercem influência sobre aquele ponto.

### 2.2. Interpolação Analítica e Ecótonos (*Blending*)
Nas zonas de transição (onde dois ou mais biomas possuem distâncias climáticas semelhantes), o sistema não escolhe um único bioma. Em vez disso, calcula a altura (ou densidade 3D) para ambos os biomas adjacentes e realiza uma média ponderada via interpolação linear (`lerp`), regulada por uma curva de transição suave (`smoothstep`):

$$Height_{Final} = \text{lerp}(Height_{Primario}, Height_{Secundario}, Peso_{Secundario})$$

### 2.3. Distorção de Domínio (*Domain Warping*)
Para impedir que as zonas de transição formem bordas perfeitamente retas e denunciem a matemática do gerador, as coordenadas de entrada $(X, Z)$ aplicadas à consulta climática sofrem uma perturbação prévia impulsionada por um ruído secundário:

$$P_{distorcido} = p + \begin{pmatrix} \text{Noise}_{warp}(p.x, p.z) \cdot \lambda \\ \text{Noise}_{warp}(p.x + \Delta, p.z + \Delta) \cdot \lambda \end{pmatrix}$$

Isso faz com que as fronteiras climáticas retorçam-se em contornos sinuosos, esporões geológicos e reentrâncias naturais.

### 2.4. Otimização por Descarte Antecipado (*Early-Out Culling*)
A avaliação de múltiplas oitavas de ruído para biomas primários e secundários em cada *thread* de um *Compute Shader* pode sobrecarregar as Unidades Lógico-Aritméticas (ALUs) da GPU. Por isso, a mistura só é calculada se a diferença de distância entre o bioma primário e o secundário for inferior a um limiar ($\text{limiarTransicao}$). Quando a *thread* está no interior profundo de um bioma, o processamento do bioma secundário é totalmente ignorado.

---

## 3. Evolução Arquitetural: O Paradigma *Data-Driven*

Para garantir flexibilidade sem a necessidade de reescrever os *Compute Shaders*, a composição morfológica do terreno foi desvinculada do código principal. A CPU injeta buffers estruturados contendo as definições dos biomas e suas respectivas pilhas de ruído.

### 3.1. Estruturas de Dados
* **`BiomeHeader`:** Define o centro climático $(T, H)$, a elevação base e o ponteiro/quantidade de parâmetros de ruído associados.
* **`BiomeNoiseParams`:** Define os atributos de cada camada de ruído (amplitude, frequência, oitavas, tipo de algoritmo) e a operação espacial (Adição para elevações ou Subtração para a escavação de vales/ravinas).

---

## 4. Implementação Completa em Slang Compute Shader

Abaixo encontra-se o código final em linguagem **Slang**, integrando a arquitetura orientada a dados, *Domain Warping*, classificação por eixos climáticos, somatório dinâmico de ruídos e otimização por *Early-Out Culling*.

```slang
import FastNoiseLite; 

// ==========================================
// ESTRUTURAS DE DADOS (DATA-DRIVEN)
// ==========================================

/// Cabeçalho com os dados macro e climáticos do bioma
struct BiomeHeader {
    float tempCentro;             // Ponto ideal no eixo de Temperatura [-1.0, 1.0]
    float umidCentro;             // Ponto ideal no eixo de Umidade [-1.0, 1.0]
    
    float alturaBase;             // Cota mínima de elevação do solo
    uint  noiseParamIndexStart;   // Índice inicial no buffer de parâmetros de ruído
    uint  noiseParamCount;        // Quantidade de camadas de ruído que compõem o bioma
};

/// Parâmetros de cada camada individual de ruído do bioma
struct BiomeNoiseParams {
    float amplitude;              // Multiplicador de força vertical
    float frequencia;             // Frequência espacial de amostragem
    uint  numOitavas;             // Quantidade de oitavas (fBm)
    uint  noiseType;              // 0 = Simplex, 1 = Perlin/Fractal, 2 = Cellular/Voronoi
    uint  operation;              // 0 = Subtração (Escavação), 1 = Adição (Elevação)
};

// ==========================================
// BUFFERS DE ENTRADA & CONSTANTES
// ==========================================

StructuredBuffer<BiomeHeader>      biomes;
StructuredBuffer<BiomeNoiseParams> noiseParams;

cbuffer GeracaoParams {
    uint   numBiomes;
    float2 offsetGlobal;
    float  forcaDistorcao;
    float  limiarTransicao;      // Largura da faixa de mistura climática
};

// ==========================================
// FUNÇÕES AUXILIARES
// ==========================================

/// Aplica Domain Warping nas coordenadas horizontais
float2 AplicarDistorcao2D(float2 p) 
{
    float desvioX = fnlGetNoise2D(p.x, p.y) * forcaDistorcao;
    float desvioZ = fnlGetNoise2D(p.x + 123.4, p.y + 567.8) * forcaDistorcao;
    return float2(p.x + desvioX, p.y + desvioZ); 
}

/// Acumulador dinâmico de ruídos para um bioma específico
float GerarAlturaBioma(BiomeHeader b, float2 posGlobal) 
{
    float alturaAcumulada = b.alturaBase;

    for (uint i = 0; i < b.noiseParamCount; i++) 
    {
        uint paramIndex = b.noiseParamIndexStart + i;
        BiomeNoiseParams np = noiseParams[paramIndex];

        float valorRuido = 0.0;
        
        switch(np.noiseType) 
        {
            case 0: // Simplex
                valorRuido = fnlGetNoise2D_Simplex(posGlobal.x * np.frequencia, posGlobal.y * np.frequencia);
                break;
                
            case 1: // Perlin / Fractal Brownian Motion (fBm)
                valorRuido = fnlGetNoise2D_Fractal(posGlobal.x * np.frequencia, posGlobal.y * np.frequencia, np.numOitavas);
                break;
                
            case 2: // Cellular / Voronoi
                valorRuido = fnlGetNoise2D_Cellular(posGlobal.x * np.frequencia, posGlobal.y * np.frequencia);
                break;
        }

        float modificador = valorRuido * np.amplitude;

        if (np.operation == 1) {
            alturaAcumulada += modificador;
        } else {
            alturaAcumulada -= modificador;
        }
    }

    return alturaAcumulada;
}

// ==========================================
// COMPUTE SHADER KERNEL PRINCIPAL
// ==========================================

[shader("compute")]
[numthreads(8, 8, 1)]
void MainCompute(uint3 threadId : SV_DispatchThreadID)
{
    float2 posGlobal = float2(threadId.x, threadId.y) + offsetGlobal;

    // 1. Aplicação de Domain Warping para sinuosidade das fronteiras
    float2 posClima = AplicarDistorcao2D(posGlobal);

    // 2. Amostragem dos Eixos Climáticos (Baixíssima Frequência)
    float temperatura = fnlGetNoise2D(posClima.x * 0.001, posClima.y * 0.001);
    float umidade     = fnlGetNoise2D(posClima.x * 0.002, posClima.y * 0.002);

    // 3. Classificação dos Biomas Mais Próximos (Busca Euclidiana)
    int   idPrimario     = -1;    float distPrimario     = 9999.0;
    int   idSecundario   = -1;    float distSecundario   = 9999.0;

    for (uint i = 0; i < numBiomes; i++) 
    {
        float dist = distance(float2(temperatura, umidade), float2(biomes[i].tempCentro, biomes[i].umidCentro));

        if (dist < distPrimario) {
            distSecundario = distPrimario;
            idSecundario   = idPrimario;
            distPrimario   = dist;
            idPrimario     = i;
        } 
        else if (dist < distSecundario) {
            distSecundario = dist;
            idSecundario   = i;
        }
    }

    // 4. Determinação da Elevação com Blending e Early-Out Culling
    float alturaFinal = 0.0;
    float diferencaDistancia = distSecundario - distPrimario;

    if (diferencaDistancia > limiarTransicao) 
    {
        // Fora da zona de transição: Processa unicamente o bioma primário (Economia de ALUs)
        alturaFinal = GerarAlturaBioma(biomes[idPrimario], posGlobal);
    } 
    else 
    {
        // Zona de Transição (Ecótono): Calcula ambos e realiza o blending
        float alturaPrimaria   = GerarAlturaBioma(biomes[idPrimario], posGlobal);
        float alturaSecundaria = GerarAlturaBioma(biomes[idSecundario], posGlobal);

        // Fator de mistura entre 0.0 e 0.5 conforme se aproxima da fronteira
        float pesoSecundario = smoothstep(limiarTransicao, 0.0, diferencaDistancia) * 0.5;
        
        alturaFinal = lerp(alturaPrimaria, alturaSecundaria, pesoSecundario);
    }

    // 5. O valor de 'alturaFinal' pode agora ser exportado para o Buffer de Alturas (Heightmap)
}
```