# Iluminação por GPU no motor voxel

Antes das técnicas, uma decisão de arquitetura que afeta todas elas. Você pretende usar mesh shader para a visibilidade primária, então o caminho natural é **híbrido**: o rasterizador resolve o que cada pixel vê (G-buffer com profundidade, normal axial e ID do material), e compute shaders fazem raios só para sombra, AO e reflexão. Como as normais dos voxels são axiais, a normal cabe em 3 bits. Isso deixa o raio secundário barato, porque o `hitPos` vem da profundidade e não de uma travessia completa.

Isso exige que o mundo seja **atravessável na GPU independente da malha**. Os raios secundários precisam consultar a geometria fora da tela, inclusive atrás da câmera.

## 1. Iluminação direta com várias luzes

O modelo é Lambert com atenuação, mas o ponto crítico é **não iterar sobre todas as luzes por pixel**. Em um mundo voxel, cada tocha ou bloco emissivo pode ser uma luz, e isso chega a milhares.

- **Sol e lua (direcionais):** custo trivial, sem atenuação e com um raio de sombra por pixel.
- **Luzes pontuais:** use uma grade de luzes (clustered/froxel, ou uma grade 3D de células com a lista de luzes que a afetam). Cada pixel consulta só as luzes da sua célula.
- **Muitas luzes:** sorteie **uma luz por pixel por frame**, com probabilidade proporcional à contribuição estimada (importance sampling, ou RIS/ReSTIR se quiser ir longe). Divida pela probabilidade de escolha e acumule no tempo. É a escolha que mais escala.
- **Atenuação:** prefira `1/d²` com uma janela suave que zera em um raio máximo, por exemplo `saturate(1 - (d/R)^4)^2`. Assim a luz tem alcance finito e entra na grade de luzes sem cortes visíveis.

```slang
float3 L = lightPos - hitPos;
float  d = length(L);  L /= d;
float  ndl = max(dot(hitNormal, L), 0);
float  att = windowedFalloff(d, light.radius) / (d*d + 1e-4);
float3 direct = light.color * light.intensity * ndl * att * visibility;
```

## 2. Sombras com shadow rays

O DDA clássico (Amanatides & Woo) funciona bem, e a otimização principal é ser hierárquico:

1. **Nível de chunk:** DDA sobre a grade de chunks (o seu lookup de posições), pulando chunks vazios ou ausentes de uma vez.
2. **Dentro do chunk:** DDA voxel a voxel, ou melhor, sobre uma **máscara de ocupação de 1 bit por voxel**.

Vale manter essa máscara separada dos dados de bloco. Um chunk 32³ ocupa 4 KB em bits, contra dezenas de KB com paleta e IDs. Com ela cada passo do DDA lê muito menos memória, e para sombra só interessa "bloqueia ou não". Para chunks distantes em SVDAG, a mesma travessia desce no DAG, e o raio de sombra pode parar cedo em níveis grossos, porque a precisão ali importa menos.

Detalhes que evitam artefatos:

- **Bias:** comece o raio em `hitPos + hitNormal * epsilon`, ou ande para fora um voxel inteiro. Como as faces são axiais, isso é exato.
- **Any-hit:** o raio de sombra termina no primeiro sólido, sem procurar o mais próximo, e é bem mais barato que o raio primário.
- **Distância máxima:** limite o raio ao alcance da luz ou ao raio de renderização.
- **Sombras macias:** em vez de apontar para o centro da luz, sorteie um ponto dentro do raio dela (ou um cone, para o sol). Um raio por pixel por frame com acúmulo temporal e filtro espacial resolve.
- **Alternativa para o sol:** cascaded shadow maps rasterizados pelo mesmo pipeline de mesh shader. São baratos, mas menos precisos, e o raio é mais simples de manter coerente com o resto.
- **Vidro:** se o raio de sombra passar por um bloco translúcido, multiplique a visibilidade pela cor dele em vez de bloquear.

## 3. Luz ambiente e Ambient Occlusion

Há três níveis de custo e qualidade, e dá para combinar:

- **AO estático nos vértices (a técnica da "0fps"):** para cada vértice de uma face, olhe 3 vizinhos (dois laterais e o canto). O resultado é um valor de 0 a 3 por vértice, calculado na geração da malha ou no mesh shader. Custa quase nada e dá o visual clássico de voxel. Lembre de inverter a diagonal do quad quando o AO for anisotrópico, para evitar o artefato de interpolação.
- **AO dinâmico por raios curtos:** dispare de 1 a 4 raios por pixel em hemisfério com amostragem cosseno-ponderada, com alcance de 4 a 8 voxels. A fração bloqueada vira a oclusão. É ruidoso, então precisa de acúmulo temporal e filtro.
- **Luz ambiente:** um gradiente de céu pela normal (cima mais claro, baixo mais escuro) multiplicado pela oclusão. Para um resultado melhor, use a **visibilidade do céu**, a fração de raios que escapam para cima.

Um complemento muito usado em voxel é um **volume de luz propagada** por flood-fill (BFS), com 4 bits de skylight e 4 bits de block light por voxel, guardado por chunk. Ele dá iluminação interna de cavernas e tochas quase de graça e escala bem. A atualização após uma edição é local: um compute que reexpande só a região afetada. Isso combina bem com seu requisito de chunks com edição imprevisível.

## 4. Múltiplos rebatimentos, espelhos e vidros (path tracing)

O loop com `throughput` é o esqueleto certo:

```slang
float3 radiance = 0, throughput = 1;
for (int b = 0; b < MAX_BOUNCES; b++) {
    Hit h;
    if (!traverse(ro, rd, h)) { radiance += throughput * skyColor(rd); break; }

    radiance += throughput * h.emission;
    Material m = materials[h.matId];

    if (m.isMirror) {
        rd = reflect(rd, h.normal);
        throughput *= m.reflectivity;
    } else if (m.isGlass) {
        // Fresnel (Schlick) decide entre refletir e refratar
        float F = schlick(dot(-rd, h.normal), m.ior);
        if (rand() < F) rd = reflect(rd, h.normal);
        else            rd = refractOrTIR(rd, h.normal, m.ior);
        throughput *= m.tint;           // ou Beer-Lambert: exp(-sigma * distancia)
    } else {
        radiance += throughput * m.albedo * sampleDirectLight(h); // NEE
        rd = cosineHemisphere(h.normal, rand2());
        throughput *= m.albedo;
    }

    // Russian roulette
    if (b > 2) {
        float p = max3(throughput);
        if (rand() > p) break;
        throughput /= p;
    }
    ro = h.pos + rd * eps;
}
```

Pontos que fazem diferença na prática:

- **NEE (next event estimation):** em cada rebatimento difuso, faça uma amostragem direta de luz com shadow ray. Sem isso, achar uma luz pequena só por acaso gera ruído enorme.
- **Vidro colorido:** multiplicar o `throughput` pela cor funciona, mas o realista é a absorção de Beer-Lambert, `exp(-sigma * distância)`, em que um vidro mais espesso fica mais escuro. A distância sai de graça do DDA.
- **Refração:** guarde se o raio está entrando ou saindo do meio para inverter o IOR, e trate a reflexão interna total.
- **Russian roulette:** termina caminhos de baixa contribuição sem viés.
- **Denoising:** com 1 amostra por pixel a imagem é ruidosa. Precisa de acúmulo temporal com reprojeção, e filtro à-trous guiado por normal e profundidade (estilo SVGF). Como seu G-buffer já tem normal e profundidade, a integração é natural.
- **Espelho em raster híbrido:** a reflexão precisa do mundo inteiro acessível ao raio, não só do que aparece na tela. É aqui que a travessia hierárquica sobre chunks e SVDAG paga o investimento.

## Ordem de implementação que eu sugeriria

1. Sol com shadow ray (DDA hierárquico sobre a máscara de ocupação).
2. AO estático nos vértices e ambiente por gradiente de céu.
3. Luzes pontuais com grade de luzes e uma amostra por pixel.
4. Volume de luz propagada (skylight e block light) com atualização por edição.
5. Acúmulo temporal e denoiser, depois AO dinâmico e sombras macias.
6. Espelhos e vidro com o loop de `throughput`, ainda limitados a 2 ou 3 rebatimentos.

Estou lendo os seus shaders (já vi `common` e `render`) para ajustar a proposta de iluminação à estrutura real; faltam `voxel.slang` e `edit.slang`.

Li os quatro arquivos. A base que você já tem favorece bastante o traçado de raios, mas faltam três peças. Descrevo primeiro o que dá para reaproveitar e o que falta, depois a implementação por fases, com código encaixado nos seus shaders.

## O que você já tem

- **Hierarquia de ocupação pronta para travessia.** O pool por chunk tem 3 níveis: células grossas 8×8×8 (64 bits), bricks 4×2×4 (1 word de ocupação e 1 de solidez por brick) e o bit do voxel. É exatamente o que um raio hierárquico precisa.
- **Máscara de solidez separada do material.** `is_voxel_solid_local` não decodifica paleta, o que serve para sombra e AO.
- **`emission_color` no `BlockDefinition`.** Os blocos emissivos já estão definidos, só não iluminam nada ainda.
- **`apply_voxel_edits` já marca bricks sujos.** Dá para reaproveitar isso para invalidar luz.

## O que falta

1. **Lookup global de chunks na GPU.** `neighbor_slots[6]` só dá os vizinhos de face de cada chunk visível, o que basta para culling de faces. Um raio atravessa vários chunks em sequência, inclusive fora do frustum, então é preciso um grid `coord de chunk → slot` na GPU (o `lookup_positions` que hoje vive na CPU).
2. **Máscara de opacidade.** `solid` inclui vidro, porque só exclui `NON_SOLID`. Vidro deve deixar a luz passar (ou tingi-la), então para sombra e AO você precisa de `opaque = !NON_SOLID && !TRANSPARENT`.
3. **Normal e posição exatas no hit.** Hoje a normal vem de `ddx/ddy`. Para raios secundários o tracer deve devolver a normal pelo eixo do último passo.

## Fase 0: dados novos

```slang
// common.slang
static const uint OPAQUE_WORD_BASE = SOLID_WORD_BASE + BRICKS_PER_CHUNK; // 2114
// OCCUPANCY_WORDS_PER_CHUNK += BRICKS_PER_CHUNK  (+4 KiB por chunk; espelhar no Odin)

struct LightGlobals {
    float4 sun_direction;     // xyz aponta para o sol
    float4 sun_color;
    float4 sky_zenith;
    float4 sky_horizon;
    int4   grid_min_chunk;    // xyz
    int4   grid_dim_chunks;   // xyz
    float4 params;            // x = shadow_max_distance, y = ao_strength
};
[[vk::binding(25, 0)]] ConstantBuffer<LightGlobals> light_globals;
[[vk::binding(26, 0)]] StructuredBuffer<uint>       chunk_grid; // slot ou NEIGHBOR_SLOT_INVALID

bool block_is_opaque(uint id) {
    return id != 0u && (global_block_registry[id].flags &
        (BLOCK_DEFINITION_FLAG_NON_SOLID | BLOCK_DEFINITION_FLAG_TRANSPARENT)) == 0u;
}

uint chunk_slot_at(int3 cc) {
    int3 rel = cc - light_globals.grid_min_chunk.xyz;
    int3 dim = light_globals.grid_dim_chunks.xyz;
    if (any(rel < 0) || any(rel >= dim)) return NEIGHBOR_SLOT_INVALID;
    return chunk_grid[uint(rel.x) + uint(dim.x) * (uint(rel.z) + uint(dim.z) * uint(rel.y))];
}
```

Os pontos de escrita são dois, ao lado do que já existe para `solidity`:

- Em `pack_chunk` (voxel.slang, junto de `solidity |= ...`), acumule `opaque` e grave `occupancy_pool[base + OPAQUE_WORD_BASE + brick_idx]`.
- Em `apply_voxel_edits` (edit.slang, linhas 239-241), faça o mesmo par `InterlockedOr/And` com `block_is_opaque(new_block)`.

Sobre o grid: no CPU basta reescrever as células quando um chunk carrega ou descarrega. Com 64×16×64 chunks são 256 KB. Um grid toroidal (posmod mais validação) fica para depois.

## Fase 1: sol com sombra (no próprio `shade_voxel`)

É o maior ganho visual pelo menor custo, e como a sombra dura não tem ruído, não precisa de denoiser. A travessia é **hierárquica e sem estado**. A cada iteração ela recalcula em que nível está a partir da posição e salta para a saída da célula vazia. É mais simples que um DDA incremental e já elimina quase todo o espaço vazio.

```slang
float exit_t(float3 ro, float3 inv_rd, float3 rd, int3 cell_min, int3 cell_size) {
    float3 bound = float3(cell_min) + float3(rd.x > 0 ? cell_size.x : 0,
                                             rd.y > 0 ? cell_size.y : 0,
                                             rd.z > 0 ? cell_size.z : 0);
    float3 t = (bound - ro) * inv_rd;
    return min(t.x, min(t.y, t.z));
}

bool trace_occluded(float3 ro, float3 rd, float t_max, int3 ignore_voxel) {
    float3 d = float3(abs(rd.x) < 1e-6 ? 1e-6 : rd.x,
                      abs(rd.y) < 1e-6 ? 1e-6 : rd.y,
                      abs(rd.z) < 1e-6 ? 1e-6 : rd.z);
    float3 inv_rd = 1.0 / d;
    float t = 0.0;

    [loop] for (uint i = 0; i < 192 && t < t_max; i++) {
        float3 p  = ro + rd * (t + 1e-3);
        int3   w  = int3(floor(p));
        int3   cc = w >> 5;                       // CHUNK_SIZE = 32
        uint slot = chunk_slot_at(cc);

        int3 cell_min, cell_size;
        if (slot == NEIGHBOR_SLOT_INVALID ||
            (chunk_headers[slot].flags & CHUNK_FLAG_EMPTY) != 0u) {
            cell_min = cc << 5;  cell_size = int3(32);          // chunk ausente/vazio: aberto
        } else {
            int3 l    = w - (cc << 5);
            uint base = slot * OCCUPANCY_WORDS_PER_CHUNK;
            uint cell = uint(l.x >> 3) + 4u * (uint(l.z >> 3) + 4u * uint(l.y >> 3));
            if (((occupancy_pool[base + BRICKS_PER_CHUNK + (cell >> 5)] >> (cell & 31u)) & 1u) == 0u) {
                cell_min = (w >> 3) << 3;  cell_size = int3(8);  // célula grossa vazia
            } else {
                uint brick = brick_index_from_coordinate(l / BRICK_SIZE);
                uint word  = occupancy_pool[base + OPAQUE_WORD_BASE + brick];
                if (word == 0u) {
                    cell_min  = int3((w.x >> 2) << 2, (w.y >> 1) << 1, (w.z >> 2) << 2);
                    cell_size = BRICK_SIZE;                      // brick sem opaco
                } else {
                    uint bit = bit_index_from_local_coordinate(l % BRICK_SIZE);
                    if (((word >> bit) & 1u) != 0u && any(w != ignore_voxel)) return true;
                    cell_min = w;  cell_size = int3(1);
                }
            }
        }
        t = max(exit_t(ro, inv_rd, rd, cell_min, cell_size), t + 1e-4);
    }
    return false;
}
```

No fragment shader, depois do `discard` para não gastar raio em pixel descartado:

```slang
float3 L   = light_globals.sun_direction.xyz;
float  ndl = max(dot(normal, L), 0.0);
float3 ro  = input.world_position + normal * 0.01;
int3   own = int3(floor(input.world_position - normal * 0.01));
float  vis = (ndl > 0.0 && !trace_occluded(ro, L, light_globals.params.x, own)) ? 1.0 : 0.0;

float3 direct = light_globals.sun_color.rgb * ndl * vis;
```

O parâmetro `ignore_voxel` existe porque seus templates têm formas parciais (slabs, por exemplo). Nesses casos o ponto de origem ainda fica dentro do próprio voxel, que é opaco, e sem isso o raio acertaria a si mesmo.

Três ressalvas dessa fase:

- O `1e-3` de nudge pode vazar em cantos muito finos. Para sombra é aceitável. Se incomodar, migre para um DDA com coordenada inteira.
- O raio trata o voxel inteiro como opaco mesmo para formas parciais. Isso é conservador e raramente se nota.
- Sem depth pre-pass, cada fragmento em overdraw dispara um raio. Um pass só de profundidade com `depth == equal` no pass principal resolve.

## Fase 2: AO por fragmento (sem tocar na malha)

Como seus templates têm vértices arbitrários, o AO por vértice (técnica clássica da 0fps) não se aplica direto. A versão por fragmento funciona com qualquer face alinhada ao voxel. Pegue o voxel **à frente da face**, leia os 8 vizinhos na camada e interpole bilinearmente pela posição do pixel dentro da face:

```slang
bool opaque_at(int3 w) {
    uint slot = chunk_slot_at(w >> 5);
    if (slot == NEIGHBOR_SLOT_INVALID) return false;
    return is_voxel_solid_local(slot, w & 31);   // ou a máscara de opacidade
}
float corner_ao(bool s1, bool s2, bool c) { return (s1 && s2) ? 0.0 : (3.0 - float(s1) - float(s2) - float(c)) / 3.0; }
```

Com `n` a normal inteira da face, `v` o voxel à frente dela e `t1`/`t2` os eixos tangentes (por exemplo, para `n.y`: X e Z), calcule os 4 cantos com `corner_ao` usando os dois lados e o canto diagonal. Depois faça `lerp(lerp(a00, a10, u), lerp(a01, a11, u), w)`, onde `u` e `w` são a parte fracionária da posição nos eixos tangentes. O custo é de 8 leituras de máscara por pixel, e o resultado é limpo e determinístico.

A luz ambiente passa a ser `lerp(sky_horizon, sky_zenith, N.y*0.5+0.5) * ao`.

## Fase 3: luz de blocos (tochas, lava) e luz de céu

Para muitas luzes emissivas, shadow rays por luz não escalam. O caminho que casa com a sua arquitetura é um **volume de luz propagada**:

- **Armazenamento:** um pool `light_pool` por slot, `uint16_t` por voxel (4 bits RGB de block light + 4 bits de skylight), no mesmo estilo do `mirror_export_ring`. Isso dá 64 KB por chunk. Se bastar luz monocromática, cai para 1 byte.
- **Fontes:** voxels cujo bloco tem `emission_color != 0` (via palette, como `read_block_identifier`) e, para o céu, a coluna acima do primeiro bloco opaco.
- **Propagação:** relaxação em passes de compute, onde cada voxel recebe `max(vizinhos) - 1` se não for opaco. Como não há sincronização entre workgroups, os passes vizinhos fazem ping-pong, com no máximo 15 dispatches e só sobre chunks sujos mais vizinhos.
- **Gatilho:** o `shared_edit_dirty_bricks` de `apply_voxel_edits` já diz quais bricks mudaram, e a partir dele você marca o chunk e seus vizinhos para relight.
- **Uso:** no fragment, amostre o volume em `world_pos + normal*0.5` com filtragem trilinear nos 8 voxels.

Para uma luz dinâmica forte, como a tocha do jogador, use a Fase 1 com um raio de sombra por luz, limitado a 1 ou 2 luzes.

## Fase 4: deferred, ruído e path tracing

Tudo que é estocástico (AO por raios, sombras macias, GI, reflexos) precisa de acúmulo temporal e filtro espacial. Isso exige saída em G-buffer e um pass de compute:

1. `shade_voxel` passa a escrever MRT: albedo, normal octaédrica, `block_id` e profundidade. A luz vira um compute que lê o G-buffer.
2. O tracer ganha uma versão **closest-hit** que devolve voxel, normal pelo eixo do último passo e `block_id`.
3. Aí entram o loop de `throughput`, o NEE e o vidro com Beer-Lambert que descrevi antes. Seu vidro hoje é só recorte por alpha (`discard`), então vidro de verdade precisa desse caminho.

Um cuidado de desempenho: `read_block_identifier` recebe `ChunkHeader` por valor, e a struct tem cerca de 2 KB. No tracer, crie uma variante que leia só `plane_count` e `palette[idx]` direto de `chunk_headers[slot]`.

## Ordem sugerida

1. Máscara de opacidade, grid na GPU e `LightGlobals` (Fase 0).
2. Sol com sombra e depth pre-pass (Fase 1).
3. AO por fragmento (Fase 2).
4. Volume de luz de blocos e céu, com relight nas edições (Fase 3).
5. G-buffer, acúmulo temporal e reflexos (Fase 4).

Um limite a ter em mente: sem SVDAG nem LOD distante, a sombra só enxerga chunks carregados. Isso é aceitável agora e se resolve depois com uma segunda travessia sobre a representação compacta.

# Tasks de iluminação: o que mudar no shader e o que a CPU deve fazer

Convenção: cada task tem **Shader** (código a alterar, com arquivo e posição) e **CPU esperado** (comportamento, sem código).

**Shaders que não mudam:** `generate_voxels`, `build_work_queue`, `finalize_work_queue` e `build_brick_mesh`. O culling e a geração de malha continuam como estão.

**Resumo dos recursos novos**

| Recurso | Onde | Quem usa |
|---|---|---|
| `lighting.slang` (novo módulo) | trace, AO, `shade_surface` | `render.slang`, `light.slang` |
| `light.slang` (novo módulo) | seed, propagate, resolve | pipelines de compute |
| binding 25 `light_globals` (UBO) | `common.slang` | tudo |
| binding 26 `chunk_grid` | `common.slang` | tudo |
| binding 27 `light_pool` | `common.slang` | Fase 3 |
| binding 28 `light_jobs` | `common.slang` | Fase 3 |
| set 1, bindings 0 a 4 (G-buffer) | `light.slang` | Fase 4 |

---

## Fase 0: Fundação

### T0.1 Máscara de opacidade

Hoje `solid` inclui vidro. Sombra e AO precisam de "bloqueia luz".

**Shader: `common.slang`**

```slang
// ANTES
static const uint OCCUPANCY_WORDS_PER_CHUNK = 2 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK;

// DEPOIS  (3138 words por chunk)
//   [2114..3138) = 1 word de opacidade por brick (opaco = !NON_SOLID && !TRANSPARENT)
static const uint OCCUPANCY_WORDS_PER_CHUNK = 3 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK;
static const uint OPAQUE_WORD_BASE          = SOLID_WORD_BASE + BRICKS_PER_CHUNK; // 2114
```

```slang
// logo abaixo de block_is_solid()
bool block_is_opaque(uint block_id) {
    return block_id != 0u &&
        (global_block_registry[block_id].flags &
         (BLOCK_DEFINITION_FLAG_NON_SOLID | BLOCK_DEFINITION_FLAG_TRANSPARENT)) == 0u;
}
```

**Shader: `voxel.slang`, `pack_chunk`**

```slang
uint occupancy = 0;
uint solidity = 0;
uint opacity = 0;                                   // NOVO
...
BlockDefinition def = global_block_registry[block_id];
if ((def.flags & BLOCK_DEFINITION_FLAG_NON_SOLID) == 0u) solidity |= 1u << bit_idx;
if ((def.flags & (BLOCK_DEFINITION_FLAG_NON_SOLID | BLOCK_DEFINITION_FLAG_TRANSPARENT)) == 0u)
    opacity |= 1u << bit_idx;                       // NOVO
...
occupancy_pool[occupancy_base + brick_idx] = occupancy;
occupancy_pool[occupancy_base + SOLID_WORD_BASE + brick_idx] = solidity;
occupancy_pool[occupancy_base + OPAQUE_WORD_BASE + brick_idx] = opacity;   // NOVO
```

**Shader: `edit.slang`, `apply_voxel_edits`, logo após o bloco de `solidity_addr`**

```slang
uint opaque_addr = occupancy_base + OPAQUE_WORD_BASE + brick_idx;
if (block_is_opaque(new_block)) { InterlockedOr(occupancy_pool[opaque_addr], mask); }
else { InterlockedAnd(occupancy_pool[opaque_addr], ~mask); }
```

**CPU esperado**
- A constante `OCCUPANCY_WORDS_PER_CHUNK` no Odin passa a 3138, e o `occupancy_pool` é realocado com `slots × 3138 × 4 B` (+4 KiB por chunk).
- Nada precisa mudar no fluxo de geração ou edição, porque `pack_chunk` e `apply_voxel_edits` já rodam para todo chunk. Se existir cache em disco do `occupancy_pool`, invalide-o.

### T0.2 Grid de chunks e UBO de luz

**Shader: `common.slang`, após o binding 24**

```slang
struct LightGlobals {
    float4 sun_direction;     // xyz: direção PARA o sol, normalizada
    float4 sun_color;         // rgb
    float4 sky_zenith;        // rgb
    float4 sky_horizon;       // rgb
    int4   grid_min_chunk;    // xyz: coordenada do primeiro chunk coberto pelo grid
    int4   grid_dim_chunks;   // xyz: dimensões do grid
    float4 params;            // x: shadow_max_distance, y: ao_strength, z: block_light_strength
    float4 dynamic_light_position_radius[2];
    float4 dynamic_light_color[2];
    uint4  counts;            // x: dynamic_light_count, y: debug_mode
    column_major float4x4 inverse_view_projection;   // usado na Fase 4
};
[[vk::binding(25, 0)]] ConstantBuffer<LightGlobals> light_globals;
[[vk::binding(26, 0)]] StructuredBuffer<uint>       chunk_grid;

uint chunk_slot_at(int3 chunk_coord) {
    int3 rel = chunk_coord - light_globals.grid_min_chunk.xyz;
    int3 dim = light_globals.grid_dim_chunks.xyz;
    if (any(rel < 0) || any(rel >= dim)) return NEIGHBOR_SLOT_INVALID;
    return chunk_grid[uint(rel.x) + uint(dim.x) * (uint(rel.z) + uint(dim.z) * uint(rel.y))];
}

bool opaque_at_world(int3 w) {
    uint slot = chunk_slot_at(w >> 5);
    if (slot == NEIGHBOR_SLOT_INVALID) return false;
    int3 l = w & 31;
    uint word = occupancy_pool[slot * OCCUPANCY_WORDS_PER_CHUNK + OPAQUE_WORD_BASE
                               + brick_index_from_coordinate(l / BRICK_SIZE)];
    return ((word >> bit_index_from_local_coordinate(l % BRICK_SIZE)) & 1u) != 0u;
}
```

**CPU esperado**
- **`chunk_grid`:** buffer de `uint` com `dim.x × dim.y × dim.z` células, indexado por `x + dim.x*(z + dim.z*y)` relativo a `grid_min_chunk`. Célula sem chunk vale `0xFFFFFFFF`.
- **Publicação:** o slot só entra no grid depois que o `pack_chunk` desse chunk terminou (o handler que hoje lê `chunk_result_flags`). Na descarga, a célula é limpa antes de o slot ser reutilizado. Assim um raio nunca lê um slot em construção.
- **Recentralização:** o grid acompanha a câmera, e ao mudar `grid_min_chunk` a CPU reescreve as células afetadas. O tamanho típico (64×16×64) ocupa 256 KB.
- **UBO:** é atualizado todo frame (sol, céu, `inverse_view_projection`, luzes dinâmicas). Ele não vai em push constant, que já está em 92 B.

### T0.3 Visibilidade dos descriptors e sincronização

Não há mudança de shader, só CPU.

**CPU esperado**
- Os bindings 2 (`occupancy_pool`), 4 (`chunk_headers`), 7, 25, 26 e (depois) 27 precisam estar visíveis também ao estágio **fragment** e ao compute.
- Os buffers são declarados `RWStructuredBuffer`. Como o fragment passa a lê-los, ou o device habilita `fragmentStoresAndAtomics`, ou a validation layer vai reclamar (VUID de `NonWritable`). Habilitar a feature é o caminho mais simples.
- Barreiras entre `pack_chunk`, `apply_voxel_edits` e os passes de luz (escrita em shader) e o fragment ou compute que lê (leitura em shader).
- Ordem do frame: gerar e editar, depois luz (Fase 3), depois pre-pass e pass principal.

---

## Fase 1: Sol com sombra

### T1.1 Travessia de raio

**Shader: novo `lighting.slang`**

```slang
import common;

// Tempo (absoluto, a partir de ro) até sair da célula alinhada [cell_min, cell_min+cell_size).
float exit_t(float3 ro, float3 inv_rd, float3 rd, int3 cell_min, int3 cell_size, out int axis) {
    float3 bound = float3(cell_min) + float3(rd.x > 0 ? float(cell_size.x) : 0.0,
                                             rd.y > 0 ? float(cell_size.y) : 0.0,
                                             rd.z > 0 ? float(cell_size.z) : 0.0);
    float3 t = (bound - ro) * inv_rd;
    if (t.x <= t.y && t.x <= t.z) { axis = 0; return t.x; }
    if (t.y <= t.z)               { axis = 1; return t.y; }
    axis = 2; return t.z;
}

bool trace_occluded(float3 ro, float3 rd_in, float t_max, int3 ignore_voxel) {
    float3 rd = float3(abs(rd_in.x) < 1e-6 ? 1e-6 : rd_in.x,
                       abs(rd_in.y) < 1e-6 ? 1e-6 : rd_in.y,
                       abs(rd_in.z) < 1e-6 ? 1e-6 : rd_in.z);
    float3 inv_rd = 1.0 / rd;
    float t = 0.0;

    [loop] for (uint i = 0; i < 192 && t < t_max; i++) {
        float3 p  = ro + rd * (t + 1e-3);
        int3   w  = int3(floor(p));
        int3   cc = w >> 5;                                  // CHUNK_SIZE = 32
        uint slot = chunk_slot_at(cc);

        int3 cell_min, cell_size;
        if (slot == NEIGHBOR_SLOT_INVALID || (chunk_headers[slot].flags & CHUNK_FLAG_EMPTY) != 0u) {
            cell_min = cc << 5;  cell_size = int3(32);       // chunk ausente ou vazio: aberto
        } else {
            int3 l    = w - (cc << 5);
            uint base = slot * OCCUPANCY_WORDS_PER_CHUNK;
            uint cell = uint(l.x >> 3) + 4u * (uint(l.z >> 3) + 4u * uint(l.y >> 3));
            if (((occupancy_pool[base + BRICKS_PER_CHUNK + (cell >> 5)] >> (cell & 31u)) & 1u) == 0u) {
                cell_min = (w >> 3) << 3;  cell_size = int3(8);          // célula grossa vazia
            } else {
                uint brick = brick_index_from_coordinate(l / BRICK_SIZE);
                uint word  = occupancy_pool[base + OPAQUE_WORD_BASE + brick];
                if (word == 0u) {
                    cell_min  = int3((w.x >> 2) << 2, (w.y >> 1) << 1, (w.z >> 2) << 2);
                    cell_size = BRICK_SIZE;                              // brick sem opaco
                } else {
                    uint bit = bit_index_from_local_coordinate(l % BRICK_SIZE);
                    if (((word >> bit) & 1u) != 0u && any(w != ignore_voxel)) return true;
                    cell_min = w;  cell_size = int3(1);
                }
            }
        }
        int axis;
        t = max(exit_t(ro, inv_rd, rd, cell_min, cell_size, axis), t + 1e-4);
    }
    return false;
}
```

**CPU esperado:** nada novo. O módulo precisa entrar no build de shaders (caminho de import do Slang).

### T1.2 `shade_surface` e fragment

**Shader: `lighting.slang`, adicionar**

```slang
float3 shade_surface(float3 world_pos, float3 normal, float3 albedo, uint block_id) {
    float3 ray_origin = world_pos + normal * 0.01;
    int3   own_voxel  = int3(floor(world_pos - normal * 0.01));

    // Sol
    float3 L   = light_globals.sun_direction.xyz;
    float  ndl = max(dot(normal, L), 0.0);
    float  sun_visibility = 0.0;
    if (ndl > 0.0) {
        sun_visibility = trace_occluded(ray_origin, L, light_globals.params.x, own_voxel) ? 0.0 : 1.0;
    }
    float3 sun = light_globals.sun_color.rgb * ndl * sun_visibility;

    // Ambiente (gradiente de céu)
    float3 ambient = lerp(light_globals.sky_horizon.rgb, light_globals.sky_zenith.rgb,
                          normal.y * 0.5 + 0.5);

    float3 emission = global_block_registry[block_id & 0x7FFFFFFFu].emission_color;
    return albedo * (sun + ambient) + emission;
}
```

**Shader: `render.slang`**. Primeiro extraia dois helpers (o `shade_voxel` e o pre-pass da T1.3 usam a mesma lógica), depois reescreva o fragment.

```slang
import common;
import lighting;
// ... (build_work_queue, finalize_work_queue, build_brick_mesh, sample_triplanar_albedo inalterados)

float3 face_normal_from_derivatives(MeshVertex input) {
    float3 n = normalize(cross(ddx(input.world_position), ddy(input.world_position)));
    float3 view_dir = normalize(push_constants.camera_position - input.world_position);
    return dot(n, view_dir) < 0.0 ? -n : n;
}

float4 fetch_albedo(MeshVertex input, BlockDefinition def, float3 normal) {
    float3 an = abs(normal);
    uint face_index;
    if (an.y >= an.x && an.y >= an.z) { face_index = normal.y > 0.0 ? 2u : 3u; }
    else if (an.x >= an.z)            { face_index = normal.x > 0.0 ? 0u : 1u; }
    else                              { face_index = normal.z > 0.0 ? 4u : 5u; }
    uint layer = def.albedo_faces[face_index];
    return input.uv.x >= 0.0
        ? block_albedo_textures.Sample(float3(input.uv, float(layer)))
        : sample_triplanar_albedo(input.world_position, normal, layer);
}

[shader("fragment")]
float4 shade_voxel(MeshVertex input) : SV_Target {
    BlockDefinition def = global_block_registry[input.block_id];
    float3 normal = face_normal_from_derivatives(input);
    float4 albedo = fetch_albedo(input, def, normal);

    if ((def.flags & BLOCK_DEFINITION_FLAG_TRANSPARENT) != 0u && albedo.a < 0.5) discard;

    float3 color = shade_surface(input.world_position, normal, albedo.rgb, input.block_id);

    if (target_highlight.target_valid != 0u
        && all(int3(floor(input.world_position)) == target_highlight.target_voxel)) {
        color *= 1.4;
    }
    return float4(color, 1.0);
}
```

Isso substitui o trecho de `light_dir`, `diffuse`, `ambient` e `final_color`. O `discard` fica antes do raio, e as chamadas a `Sample` ficam antes de qualquer ramo divergente.

**CPU esperado**
- Preencher `sun_direction` (valores iniciais sugeridos: `(0.5, 0.8, 0.3)` normalizado), `sun_color ≈ 1.0`, `sky_zenith`, `sky_horizon` (em torno de `0.2`) e `params.x = 128`.
- Antes de ligar a luz, o grid (T0.2) e as barreiras (T0.3) precisam estar corretos.

### T1.3 Depth pre-pass

**Shader: `render.slang`, adicionar**

```slang
[shader("fragment")]
void depth_prepass(MeshVertex input) {
    BlockDefinition def = global_block_registry[input.block_id];
    if ((def.flags & BLOCK_DEFINITION_FLAG_TRANSPARENT) == 0u) return;   // opaco: nada a testar
    float3 normal = face_normal_from_derivatives(input);
    if (fetch_albedo(input, def, normal).a < 0.5) discard;
}
```

**CPU esperado**
- Um segundo pipeline com o **mesmo** mesh shader (`build_brick_mesh`) e este fragment, sem color attachment, com depth write ligado.
- O pass principal usa o depth já preenchido, com compare `LESS_OR_EQUAL` e depth write desligado. Use `LESS_OR_EQUAL` em vez de `EQUAL` para não depender de invariância bit a bit entre pipelines.
- O pre-pass roda antes do pass principal, sobre a mesma `work_queue`.

### T1.4 Modos de debug

**Shader: `lighting.slang`, dentro de `shade_surface`, após calcular `sun_visibility`**

```slang
if (light_globals.counts.y == 1u) return float3(sun_visibility);
```

**CPU esperado:** uma tecla de debug que escreve `counts.y` (0 = normal, 1 = só sombra, 2 = só AO, 3 = só luz de bloco).

---

## Fase 2: AO por fragmento

### T2.1 AO sem tocar na malha

**Shader: `lighting.slang`, adicionar acima de `shade_surface`**

```slang
float corner_ao(bool side1, bool side2, bool corner) {
    if (side1 && side2) return 0.0;
    return (3.0 - float(side1) - float(side2) - float(corner)) / 3.0;
}

float voxel_ao(float3 world_pos, float3 normal) {
    float3 an = abs(normal);
    if (max(an.x, max(an.y, an.z)) < 0.99) return 1.0;       // faces diagonais (plantas): sem AO

    int3 n  = int3(round(normal));
    int3 t1 = (an.x > 0.5) ? int3(0, 1, 0) : int3(1, 0, 0);
    int3 t2 = (an.z > 0.5) ? int3(0, 1, 0) : int3(0, 0, 1);

    int3   own = int3(floor(world_pos - normal * 0.01));
    int3   v   = own + n;                                    // voxel à frente da face
    float3 fr  = world_pos - float3(own);
    float  u   = saturate(dot(fr, float3(t1)));
    float  w   = saturate(dot(fr, float3(t2)));

    bool e1 = opaque_at_world(v + t1), e2 = opaque_at_world(v - t1);
    bool f1 = opaque_at_world(v + t2), f2 = opaque_at_world(v - t2);
    float a00 = corner_ao(e2, f2, opaque_at_world(v - t1 - t2));
    float a10 = corner_ao(e1, f2, opaque_at_world(v + t1 - t2));
    float a01 = corner_ao(e2, f1, opaque_at_world(v - t1 + t2));
    float a11 = corner_ao(e1, f1, opaque_at_world(v + t1 + t2));
    return lerp(lerp(a00, a10, u), lerp(a01, a11, u), w);
}
```

**Shader: `shade_surface`, substituir o ambiente**

```slang
float ao = lerp(1.0, voxel_ao(world_pos, normal), light_globals.params.y);
float3 ambient = lerp(light_globals.sky_horizon.rgb, light_globals.sky_zenith.rgb,
                      normal.y * 0.5 + 0.5) * ao;
if (light_globals.counts.y == 2u) return float3(ao);
```

**CPU esperado:** apenas `params.y` (`ao_strength`, de 0 a 1) no UBO.

---

## Fase 3: Luz de blocos

Escopo: luz de blocos RGB (4 bits por canal). Skylight (luz de céu propagada) fica fora porque exige passada de cima para baixo por coluna entre chunks, que merece task própria. Por enquanto, cavernas recebem o ambiente de céu normalmente.

### T3.1 Pool e helpers

**Shader: `common.slang`, após o binding 26**

```slang
struct LightJob {
    int3 chunk_world_origin;
    uint storage_slot_index;
};
[[vk::binding(27, 0)]] RWStructuredBuffer<uint16_t> light_pool;   // CHUNK_VOXEL_COUNT por slot
[[vk::binding(28, 0)]] StructuredBuffer<LightJob>   light_jobs;

uint  light_index(uint slot, int3 l)   { return slot * CHUNK_VOXEL_COUNT + dense_index_from_coordinate(l); }
uint3 unpack_block_light(uint v)       { return uint3(v & 15u, (v >> 4u) & 15u, (v >> 8u) & 15u); }
uint  pack_block_light(uint3 c)        { return c.x | (c.y << 4u) | (c.z << 8u); }   // bits 12..15 reservados (sky)

uint3 block_light_at_world(int3 w) {
    uint slot = chunk_slot_at(w >> 5);
    if (slot == NEIGHBOR_SLOT_INVALID) return uint3(0);
    return unpack_block_light(uint(light_pool[light_index(slot, w & 31)]));
}

uint read_block_identifier_fast(uint slot, int3 coord) {      // não copia o ChunkHeader inteiro (~2 KB)
    uint plane_count  = chunk_headers[slot].plane_count;
    uint palette_size = chunk_headers[slot].palette_size;
    uint idx = read_palette_index_at(slot, plane_count, coord);
    return chunk_headers[slot].palette[min(idx, max(palette_size, 1u) - 1u)];
}
```

**CPU esperado**
- `light_pool` com `slots × 32768 × 2 B` (64 KiB por chunk), com o mesmo ciclo de vida dos slots do `occupancy_pool`.
- `light_jobs`, um buffer pequeno reescrito por frame com `{ origem do chunk, slot }`.

### T3.2 Sementes

**Shader: novo `light.slang`**

```slang
import common;
import lighting;

[shader("compute")]
[numthreads(8, 8, 8)]
void light_seed(uint3 thread_id : SV_DispatchThreadID) {
    uint job_index = thread_id.z / CHUNK_SIZE;
    LightJob job   = light_jobs[push_constants.batch_job_offset + job_index];
    int3 l         = int3(int(thread_id.x), int(thread_id.y), int(thread_id.z % CHUNK_SIZE));
    uint slot      = job.storage_slot_index;

    uint3 level = uint3(0);
    if ((chunk_headers[slot].flags & CHUNK_FLAG_EMPTY) == 0u) {
        uint block_id = read_block_identifier_fast(slot, l);
        if (block_id != 0u) {
            level = uint3(round(saturate(global_block_registry[block_id].emission_color) * 15.0));
        }
    }
    light_pool[light_index(slot, l)] = uint16_t(pack_block_light(level));   // sempre escreve (limpa)
}
```

### T3.3 Propagação

**Shader: `light.slang`**

```slang
[shader("compute")]
[numthreads(8, 8, 8)]
void light_propagate(uint3 thread_id : SV_DispatchThreadID) {
    uint job_index = thread_id.z / CHUNK_SIZE;
    LightJob job   = light_jobs[push_constants.batch_job_offset + job_index];
    int3 l         = int3(int(thread_id.x), int(thread_id.y), int(thread_id.z % CHUNK_SIZE));
    int3 w         = job.chunk_world_origin + l;
    uint slot      = job.storage_slot_index;

    if (opaque_at_world(w)) return;                      // opaco só mantém a própria emissão

    uint3 best = uint3(0);
    best = max(best, block_light_at_world(w + int3( 1, 0, 0)));
    best = max(best, block_light_at_world(w + int3(-1, 0, 0)));
    best = max(best, block_light_at_world(w + int3( 0, 1, 0)));
    best = max(best, block_light_at_world(w + int3( 0,-1, 0)));
    best = max(best, block_light_at_world(w + int3( 0, 0, 1)));
    best = max(best, block_light_at_world(w + int3( 0, 0,-1)));

    uint3 cur  = unpack_block_light(uint(light_pool[light_index(slot, l)]));
    uint3 next = max(cur, max(best, uint3(1)) - 1u);
    light_pool[light_index(slot, l)] = uint16_t(pack_block_light(next));
}
```

A propagação é in-place e monotônica. Cada valor escrito vem de um caminho válido, então a leitura de um vizinho "novo ou velho" nunca superestima, e 15 passes bastam para convergir.

**CPU esperado**
- Dispatch de `light_seed` e depois 15 dispatches de `light_propagate`, com barreira de compute para compute entre cada um.
- Grade de dispatch `(4, 4, 4 × N)` com `N` jobs por dispatch (o `thread_id.z / 32` seleciona o job). Use `push_constants.batch_job_offset` como offset em `light_jobs`.

### T3.4 Gatilhos de relight (só CPU)

Não há mudança em `edit.slang`: a CPU já sabe quais chunks foram editados pela lista `EditChunkJob`.

**CPU esperado**
- Para cada chunk editado ou recém-gerado, criar jobs para ele e para os **26 vizinhos** carregados (a luz alcança 15 voxels, então chega a diagonais). Remover duplicatas no flush.
- O conjunto inteiro passa por seed e depois pelos 15 passes de propagate. O seed limpa tudo antes, o que remove luz de fontes apagadas.
- Chunk descarregado também gera relight dos vizinhos.
- O relight roda depois de `pack_chunk` e de `apply_voxel_edits`, e antes do pre-pass e do pass principal.

### T3.5 Amostragem no shading

**Shader: `shade_surface`**

```slang
float3 block_light = float3(block_light_at_world(int3(floor(world_pos + normal * 0.5)))) / 15.0
                     * light_globals.params.z;
if (light_globals.counts.y == 3u) return block_light;

return albedo * (sun + ambient + block_light) + emission;     // substitui o return anterior
```

**CPU esperado:** `params.z` (intensidade da luz de bloco, em torno de `1.0`). Para suavizar o degradê, uma evolução posterior amostra 4 voxels e interpola, no mesmo molde do AO.

### T3.6 Luzes dinâmicas (tocha do jogador)

**Shader: `shade_surface`, antes do `return`**

```slang
float3 dynamic_light = float3(0.0);
for (uint i = 0; i < light_globals.counts.x; i++) {
    float4 pr   = light_globals.dynamic_light_position_radius[i];
    float3 to_l = pr.xyz - world_pos;
    float  dist = length(to_l);
    if (dist >= pr.w) continue;
    float3 Ld = to_l / dist;
    float  nd = max(dot(normal, Ld), 0.0);
    if (nd <= 0.0) continue;
    if (trace_occluded(ray_origin, Ld, dist, own_voxel)) continue;
    float window = saturate(1.0 - pow(dist / pr.w, 4.0));
    dynamic_light += light_globals.dynamic_light_color[i].rgb * nd * window * window / (dist * dist + 1.0);
}
return albedo * (sun + ambient + block_light + dynamic_light) + emission;
```

**CPU esperado:** no máximo 2 luzes por frame, preenchendo `dynamic_light_position_radius`, `dynamic_light_color` e `counts.x`.

---

## Fase 4: Deferred

### T4.1 G-buffer

**Shader: `render.slang`, adicionar**

```slang
float2 oct_encode(float3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    float2 e = n.xy;
    if (n.z < 0.0) e = (1.0 - abs(e.yx)) * float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return e;
}

struct GBufferOutput {
    float4 albedo   : SV_Target0;   // RGBA8
    float2 normal   : SV_Target1;   // RG16_SNORM (octaédrica)
    uint   block_id : SV_Target2;   // R32_UINT; bit 31 = highlight
};

[shader("fragment")]
GBufferOutput shade_voxel_gbuffer(MeshVertex input) {
    BlockDefinition def = global_block_registry[input.block_id];
    float3 normal = face_normal_from_derivatives(input);
    float4 albedo = fetch_albedo(input, def, normal);
    if ((def.flags & BLOCK_DEFINITION_FLAG_TRANSPARENT) != 0u && albedo.a < 0.5) discard;

    bool highlight = target_highlight.target_valid != 0u
        && all(int3(floor(input.world_position)) == target_highlight.target_voxel);

    GBufferOutput o;
    o.albedo   = float4(albedo.rgb, 1.0);
    o.normal   = oct_encode(normal);
    o.block_id = input.block_id | (highlight ? 0x80000000u : 0u);
    return o;
}
```

**CPU esperado**
- Render pass com 3 color attachments (`RGBA8`, `RG16_SNORM`, `R32_UINT`) mais depth com uso `SAMPLED`.
- O pipeline do pass principal troca o fragment para `shade_voxel_gbuffer`. O pre-pass da T1.3 continua igual.
- Recriar essas imagens quando a janela for redimensionada.

### T4.2 Resolve de iluminação

**Shader: `light.slang`, adicionar**

```slang
[[vk::binding(0, 1)]] Texture2D<float>  gbuffer_depth;
[[vk::binding(1, 1)]] Texture2D<float4> gbuffer_albedo;
[[vk::binding(2, 1)]] Texture2D<float2> gbuffer_normal;
[[vk::binding(3, 1)]] Texture2D<uint>   gbuffer_block;
[[vk::binding(4, 1)]] RWTexture2D<float4> hdr_output;

float3 oct_decode(float2 e) {
    float3 n = float3(e.x, e.y, 1.0 - abs(e.x) - abs(e.y));
    if (n.z < 0.0) n.xy = (1.0 - abs(n.yx)) * float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    return normalize(n);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void light_resolve(uint3 pixel : SV_DispatchThreadID) {
    uint w, h; hdr_output.GetDimensions(w, h);
    if (pixel.x >= w || pixel.y >= h) return;

    float depth = gbuffer_depth.Load(int3(pixel.xy, 0));
    if (depth >= 1.0) { hdr_output[pixel.xy] = float4(light_globals.sky_horizon.rgb, 1.0); return; }

    float2 ndc   = (float2(pixel.xy) + 0.5) / float2(w, h) * 2.0 - 1.0;
    float4 world = mul(light_globals.inverse_view_projection, float4(ndc, depth, 1.0));
    float3 world_pos = world.xyz / world.w;

    float3 albedo = gbuffer_albedo.Load(int3(pixel.xy, 0)).rgb;
    float3 normal = oct_decode(gbuffer_normal.Load(int3(pixel.xy, 0)));
    uint   packed = gbuffer_block.Load(int3(pixel.xy, 0));

    float3 color = shade_surface(world_pos, normal, albedo, packed & 0x7FFFFFFFu);
    if ((packed & 0x80000000u) != 0u) color *= 1.4;
    hdr_output[pixel.xy] = float4(color, 1.0);
}
```

A reconstrução usa depth em `[0,1]` e `ndc.y = uv.y*2-1` sem flip, consistente com as suas planos de frustum (`z_ndc >= 0`) e com a convenção Vulkan.

**CPU esperado**
- Um descriptor set 1 (separado, para recursos do tamanho da tela) com depth, G-buffer e o alvo HDR `RGBA16F` em modo storage.
- Dispatch `(ceil(w/8), ceil(h/8), 1)` depois do pass de geometria, com barreira de attachment para leitura em shader.
- `inverse_view_projection` atualizado todo frame no UBO. Passe a inversa de `view_projection_matrix` na mesma convenção `column_major` usada com `mul(M, v)`.

### T4.3 Tracer closest-hit

Prepara reflexos e vidro. Generalize `trace_occluded` para devolver o hit.

**Shader: `lighting.slang`, adicionar**

```slang
struct RayHit {
    bool hit;
    int3 voxel;
    float t;
    float3 normal;     // pela face de entrada (exata, sem ddx/ddy)
    uint block_id;
};
```

Mudanças em relação ao `trace_occluded`:
- Ler a máscara `SOLID_WORD_BASE + brick` em vez da de opacidade, porque vidro precisa ser atingível. Quem decide refletir, refratar ou atravessar é o loop de path tracing.
- Guardar `entry_axis` do `axis` devolvido por `exit_t` na iteração anterior. Na colisão, a normal é `-sign(rd[entry_axis])` nesse eixo.
- No hit, buscar o bloco com `read_block_identifier_fast(slot, l)`.

### T4.4 em diante (contrato; código depois das Fases 0 a 3 validadas)

| Task | Shader (entrada → saída) | CPU esperado |
|---|---|---|
| **T4.4 Acúmulo temporal + denoise** | compute que lê `hdr` atual, histórico, vetor de movimento, normal e profundidade; saída `hdr` filtrado | imagens de histórico em ping-pong, matriz do frame anterior no UBO, passes à-trous com barreiras |
| **T4.5 AO e sombra macia por raio** | em `shade_surface`: amostras aleatórias com `rand` seedado por pixel e frame | índice de frame no UBO; passa a depender da T4.4 |
| **T4.6 Espelho e vidro** | loop de `throughput` usando `trace_closest`, com Fresnel, Beer-Lambert e Russian roulette | pass de transparência separado, pois o G-buffer guarda uma única superfície |
| **T4.7 Tonemap** | compute ou fullscreen: `hdr / (1 + hdr)` mais conversão para o formato do swapchain | passe final para a imagem de apresentação |

---

## Ordem do frame na CPU (visão final)

```
1. gerar chunks / aplicar edições (pack_chunk, apply_voxel_edits)
2. publicar slots no chunk_grid + montar light_jobs (chunk + 26 vizinhos)
3. light_seed  → 15× light_propagate            [barreira entre cada]
4. build_work_queue → finalize_work_queue
5. depth pre-pass                               (T1.3)
6. pass principal: shade_voxel  (Fases 1–3)
   ou shade_voxel_gbuffer + light_resolve        (Fase 4)
7. (Fase 4) denoise → tonemap → apresentação
```

Recomendo implementar e testar nesta ordem: T0.1 a T0.3, depois T1.1 a T1.4, depois T2.1. Com isso você já tem sol com sombra e AO funcionando antes de tocar no volume de luz.