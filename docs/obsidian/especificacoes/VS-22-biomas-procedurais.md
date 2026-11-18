---
id: VS-22
titulo: Biomas procedurais data-driven na geração
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: em-validacao
depende_de:
  - VS-01
  - VS-12
  - VS-13
  - VS-14
bloqueada_por: []
requisitos: [REQ-BIO-01, REQ-BIO-02, REQ-BIO-03, REQ-BIO-04, REQ-BIO-05, REQ-SIM-11]
ultima_atualizacao: 2026-11-12
---

# VS-22 — Biomas procedurais data-driven na geração

## Objetivo

Substituir a composição do terreno **hardcoded** do kernel de geração (dois ruídos fixos, `altura = 32 + n1*10 + n2*5`, ids de bloco fixos grama/terra/pedra em `src/assets/shaders/voxel.slang`) por um sistema de **biomas procedurais configuráveis em JSON** — no mesmo padrão data-driven dos blocos (VS-12) — com classificação climática contínua (eixos temperatura/umidade), transição suave entre biomas (ecótono com blending) e escolha de blocos por bioma: qual bloco aparece na **superfície** e qual aparece **abaixo dela** (subsolo e fundo). O resultado observável é um mundo com biomas distintos que transitam organicamente, sem paredões verticais, regenerável bit a bit.

A estratégia matemática segue o documento de referência do mantenedor (`arquitetura_e_implementa_o_de_biomas_procedurais_em_compute_shaders.md`): eixos climáticos de baixíssima frequência, interpolação por `lerp` + `smoothstep`, *domain warping* nas fronteiras e *early-out* de ALU fora das zonas de transição — adaptada ao pipeline de geração existente (heightmap por coluna da VS-13, buffers StructuredBuffer, FastNoiseLite já vendorado em `src/assets/shaders/lib/FastNoiseLite.slang`).

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 3](../../arquitetura.md) (Geração e compactação) e [Manual Técnico](../../manual-tecnico.md) — geração de chunks.
- Referência: kernel `generate_voxels` em `src/assets/shaders/voxel.slang` (terreno hardcoded nas linhas do bloco `block_id`), loader de `assets/blocks.json` (padrão VS-12 a replicar para o novo arquivo), heightmap em groupshared + export (VS-13), spawn de plantas (VS-14).
- Decisões: [[ADR-B12-biomas-data-driven|ADR-B12]] (onde a composição mora — **pendente; bloqueia a aprovação desta spec**).
- Fundação: [[VS-01-streaming-generate-pack|VS-01]] (pipeline de geração/pack), [[VS-12-assets-json|VS-12]] (JSON data-driven + registry de blocos), [[VS-13-heightmap-geracao-mirror|VS-13]] (heightmap uma vez por coluna + export ao mirror), [[VS-14-plantas-alpha-test-spawn|VS-14]] (spawn determinístico de plantas por wang hash).

## Requisitos

### Configuração data-driven (REQ-BIO-01)

- Novo arquivo `assets/biomes.json`, carregado no boot pelo mesmo caminho do `blocks.json` (VS-12), com duas seções:
  - **`global`:** `semente` (u32), `forcaDistorcao` (float ≥ 0), `limiarTransicao` (float > 0), frequências climáticas (`frequenciaTemperatura`, `frequenciaUmidade`, floats > 0) e `offsetMundial` (float2, default 0).
  - **`biomas`** (1..16): `nome`, `centroTemperatura` e `centroUmidade` (floats em [−1, 1]), `alturaBase` (float, clampada a [1, 32767]), `blocoSuperficie`, `blocoSubsuperficie` e `blocoProfundo` — **nomes** de blocos do registry global (VS-12), sendo `blocoProfundo` opcional (default = `blocoSubsuperficie`), `profundidadeSubsuperficie` (uint, default 8 — quantos voxels abaixo do topo usam o subsolo; abaixo disso entra o fundo), `permitePlantas` (bool, default `false`) e `camadas` (0..8): `{amplitude, frequencia, oitavas (1..8), tipo ("simplex" | "perlin" | "cellular"), operacao ("adicao" | "subtracao")}`.
- Limites fixos de buffer: máx. **16 biomas** e máx. **64 camadas no total**; violação → recusa na carga com log de erro fatal (sem fallback silencioso), mesmo padrão de rejeição da VS-12. Campos ausentes usam os defaults acima; `camadas` vazio é permitido (bioma plano em `alturaBase`).
- **Config padrão aprovada (2026-11-12):** 5 biomas usando apenas blocos existentes no `assets/blocks.json`, sem vegetação (`permitePlantas = false` em todos — vegetação fica para trabalho posterior):
  | Bioma | Centro (T, H) | alturaBase | Superfície | Subsolo | Fundo | prof. | Camadas de ruído |
  | --- | --- | ---: | --- | --- | --- | ---: | --- |
  | planicies | ( 0.3,  0.2) | 32 | grama | terra | pedra | 8 | simplex ×10 @0,010 · perlin ×5 @0,010 |
  | deserto   | ( 0.8, −0.7) | 34 | sand | sand | sand | 4 | simplex ×6 @0,008 · perlin ×2 @0,020 |
  | pantano   | ( 0.5,  0.8) | 30 | podzol | terra | terra | 8 | simplex ×2 @0,006 |
  | gelado    | (−0.8,  0.0) | 36 | snow | ice | pedra | 4 | perlin fBm ×8 @0,012 (3 oitavas) · simplex ×3 @0,030 |
  | montanhoso| (−0.1, −0.3) | 40 | pedra | pedra | pedra | 4 | perlin fBm ×25 @0,006 (4 oitavas) · simplex subtração ×8 @0,010 (ravinas) |
  
  Globais: `limiarTransicao = 0.15`, `forcaDistorcao = 24`, `frequenciaTemperatura = 0.001`, `frequenciaUmidade = 0.002`, `offsetMundial = (0, 0)`; a `semente` fica a critério da implementação (registrada no histórico ao fixar o valor).

### Classificação climática e ecótono (REQ-BIO-02)

- Por **coluna** (x, z) — nunca por voxel: a posição horizontal sofre *domain warping* (dois desvios independentes de ruído × `forcaDistorcao`), depois amostra temperatura e umidade com ruído de baixíssima frequência (`frequenciaTemperatura`/`frequenciaUmidade`), resultando num ponto (T, H) ∈ [−1, 1]².
- Bioma **primário** = menor distância euclidiana de (T, H) ao centro do bioma (desempate por menor índice). As distâncias de **todos** os biomas são usadas no blending abaixo.
- **Blending normalizado multiclique (generalização do ecótono):** para cada bioma `i`, `diff_i = d_i − d_prim`; se `diff_i ≤ limiarTransicao`, o bioma participa com peso bruto `s_i = smoothstep(limiarTransicao, 0, diff_i)` — o primário participa sempre com `s = 1` (smoothstep em 0). Altura final = `Σ(s_i × altura_i) / Σ(s_i)`. Consequências:
  - **Early-out por bioma:** a pilha de ruído de um bioma só é avaliada se `s_i > 0` — no interior profundo de um bioma (todos os `diff_i > limiar`), só o primário é avaliado, como antes;
  - **2 biomas nos extremos = comportamento anterior:** interior puro → primário só; centro do ecótono (diff = 0) → 50/50, igual ao `lerp` com peso máx. 0,5 da versão original; meio do caminho a curva difere levemente (o vizinho recebe mais peso na franja — transições um pouco mais largas);
  - **Multiclique contínuo por construção:** onde 3+ biomas se encontram dentro do limiar, todos contribuem com peso suave (3 equidistantes → média ponderada igualitária), sem degrau na troca de "secundário" — o denominador nunca zera (`s_prim = 1`);
  - Invariante preservado: `s_i ≤ s_prim`, então **nenhum bioma individual supera o primário** no peso normalizado (generalização do cap de 0,5).
- **Blocos seguem o primário:** a escolha superfície/subsolo/fundo/planta da coluna usa o bioma primário; apenas a altura faz blending. Regra simples, determinística e sem cintilação de bloco em zona de transição.

### Composição da coluna (REQ-BIO-03)

- Altura do bioma = `alturaBase + Σ camadas`, cada camada contribuindo `ruído(x, z × frequencia) × amplitude` com sinal positivo (`adicao`) ou negativo (`subtracao` — escavação de vales/ravinas). Tipo de ruído mapeado para os tipos do FastNoiseLite já vendorado (simplex/perlin/cellular) com fBm de `oitavas` oitavas.
- Altura final = valor blended (REQ-BIO-02), arredondado para o inteiro mais próximo (*round half up*) e clampado a **[1, 32767]** (cabe no `uint16_t` do heightmap; o valor 0 fica reservado e nunca ocorre).
- Coluna sólida de `y = 0` até `y = altura` (regra atual preservada): `y == altura` → bloco de superfície; `altura − profundidadeSubsuperficie < y < altura` → subsolo; `y ≤ altura − profundidadeSubsuperficie` → fundo. Acima da altura: ar; em `y == altura + 1`, planta (id fixo 4) quando o bioma primário tem `permitePlantas` e a coluna sorteia spawn pela wang hash — regra VS-14 **inalterada**.

### Determinismo e integração (REQ-BIO-04)

- Mesma configuração + mesma coordenada → mesma ocupação e mesmos ids de bloco **bit a bit** (regeneração de chunks descarregados, streaming, mirror e journal permanecem consistentes). Nenhum estado global além da config e da coordenada pode influenciar o resultado (sem RNG por execução, sem tempo).
- Otimização da VS-13 preservada: T/H, classificação, blending e altura calculados **uma única vez por coluna** (fatia 8×8 em groupshared, estado de ruído criado uma vez por workgroup); o export do heightmap ao mirror usa a **altura final pós-blend** (formato e semântica do ring inalterados — topo sólido, `0xFFFF` = coluna vazia).
- O *early-out* do REQ-BIO-02 garante que o custo de ALU no interior de biomas seja comparável ao da VS-13; a regressão de tempo de geração por chunk é medida via telemetria existente (VS-05/VS-16) e registrada na validação.

### Interfaces GPU (REQ-BIO-05)

- Três novos bindings no descriptor set global (hoje 0–21; `DESCRIPTOR_SET_BINDING_COUNT = 22`): **22** = `StructuredBuffer<BiomeDefinition>` (≤ 16 entradas), **23** = `StructuredBuffer<BiomeNoiseLayer>` (≤ 64 entradas), **24** = `StructuredBuffer<BiomeGlobals>` (1 entrada: semente aplicada aos estados FNL, força do warp, limiar, frequências climáticas, offset, contagens). `DESCRIPTOR_SET_BINDING_COUNT` passa a 25; o guard de `maxDescriptorSetStorageBuffers` existente continua valendo.
- **Push constants intactos** (88 B, contrato VS-00); nenhuma constante nova entra no `PushConstants`. Os buffers são preenchidos uma vez no boot e lidos apenas pelo kernel de geração (worker); render/edit ignoram os bindings novos (compartilham o layout, como os demais).

### Simulação (REQ-SIM-11)

- Antes da integração, `tools/sim/biomes_sim.py` espelha em float32 por operação (padrão `render_sim.py`): classificação (primário/secundário + desempate por índice), decisão de early-out, `smoothstep`/`lerp` com peso ≤ 0,5, somatório de camadas com sinal, round half up, clamp, seleção de bloco por faixa de y (superfície/subsolo/fundo/planta/ar) e validação de JSON (bloco inexistente, limites, defaults).
- **Divisão de responsabilidade com o oracle:** os valores de ruído do FastNoiseLite são **entradas injetadas** (tabela determinística/mock) — a sim valida a lógica de composição; a avaliação FNL em si é da biblioteca compartilhada já em uso (mesma divisão da VS-06, onde o GH float32 foi validado contra projeção de cantos com a FNL fora do escopo do espelho).
- Casos obrigatórios: interior de bioma (early-out por bioma, vizinhos ignorados); ecótono central a 2 biomas (peso = 0,5 cada); zona de limiar exato; empate de distâncias (desempate por índice); **multiclique** — 3 biomas equidistantes dentro do limiar (contribuição ⅓ cada; um terceiro bioma entrando no anel tem peso que sobe de 0 — continuidade), 4+ biomas no limiar, e bioma com `diff > limiar` excluído mesmo no meio de um multiclique; camadas de subtração, `alturaBase` acima do clamp, `profundidadeSubsuperficie` 0, bioma sem camadas, coluna com planta e sem planta, e JSON inválido (bloco desconhecido, > 16 biomas, > 64 camadas, tipos inválidos).

## Escopo

- Arquivo `assets/biomes.json` + schema/defaults/validação + loader (padrão VS-12) e buffers/bindings (REQ-BIO-01, REQ-BIO-05).
- Reescrita data-driven do trecho de terreno do `generate_voxels` (classificação, blending, composição de altura, seleção de blocos) preservando a estrutura do kernel e o export VS-13 (REQ-BIO-02/03/04).
- Simulação `tools/sim/biomes_sim.py` (REQ-SIM-11).
- Config padrão aprovada: 5 biomas (planícies, deserto, pantano, gelado, montanhoso) com blocos existentes, sem vegetação (REQ-BIO-01).
- Atualização de `docs/arquitetura.md`, manual técnico, tracking e frontmatter.
- Validação: regeneração bit a bit, screenshots de ecótono, métricas de telemetria de geração, smoke test com validation layers.

## Não escopo

- Água, rios, lagos e neve/variação de bloco por temperatura (o clima decide **qual bioma**, não o bloco diretamente — decorações climáticas são backlog).
- Cavernas e densidade 3D (o terreno continua colunar sólido até `y = 0`).
- Vegetação além do spawn VS-14 (árvores, estruturas).
- Hot-reload de config em runtime, seed persistida por mundo, biomas verticais (variação com y).
- Migração de mundos gerados com outra config: chunks já gerados mantêm seus dados; a config nova vale só para chunks novos (mundo misto aceito e documentado).
- Mudanças em pack, mesh shader, culling, edição E1, mirror (além do consumo da altura já exportada) e física.

## Dependências

- [[VS-01-streaming-generate-pack|VS-01]] — pipeline de geração/pack que recebe a reescrita (concluída e verificada).
- [[VS-12-assets-json|VS-12]] — padrão de JSON data-driven, registry de blocos por nome e rejeição na carga (concluída e verificada).
- [[VS-13-heightmap-geracao-mirror|VS-13]] — heightmap por coluna e export ao mirror a preservar (concluída e verificada).
- [[VS-14-plantas-alpha-test-spawn|VS-14]] — regra de spawn a manter, agora condicionada ao bioma (concluída e verificada).
- [[ADR-B12-biomas-data-driven|ADR-B12]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: composição climática contínua data-driven no kernel de geração).

## Interfaces e recursos

### Contratos novos

| Contrato | Assinatura / formato | Observação |
| --- | --- | --- |
| `assets/biomes.json` | schema do REQ-BIO-01 | validado na carga; recusa fatal em erro |
| `BiomeDefinition` (std430) | centro T/H, alturaBase, 3 ids de bloco (u32), profundidade (u32), flags (plantas), índice/contagem de camadas | espelhado em Odin e na sim |
| `BiomeNoiseLayer` (std430) | amplitude, frequencia, oitavas, tipo, operacao | ≤ 64 no total |
| `BiomeGlobals` (std430) | semente, forcaDistorcao, limiarTransicao, freq. T/H, offsetMundial, numBiomas | 1 entrada, binding 24 |
| Bindings 22/23/24 | StructuredBuffers (leitura) | `DESCRIPTOR_SET_BINDING_COUNT` 22 → 25 |

- Sem estruturas novas de memória além dos três buffers; sem push constants novos; sem bindings novos em outras stages.

### Sequência (integração)

Inalterada em relação à VS-01/VS-13 — a composição mora **dentro** do kernel de geração existente:

```
generation_jobs → generate_voxels (AGORA COM: warp → clima (T,H) → primário/secundário
  → early-out/blending → altura data-driven → blocos por bioma) → pack → …
```

### Comportamento quando limites são atingidos

- Altura final clampada a [1, 32767] antes de qualquer uso (heightmap groupshared, export, blocos).
- `limiarTransicao` muito pequeno degenera o ecótono (só early-out) — comportamento correto por construção; `forcaDistorcao = 0` remove o warp (fronteiras retas) — permitido.
- Mundo misto (config trocada entre sessões): chunks antigos não regeneram; só chunks novos usam a config — documentado, sem migração (não escopo).

## Cenários

### Cenário de sucesso

- **Dado** a config padrão (≥ 3 biomas com centros climáticos distintos e pelo menos uma camada de subtração num deles) e a câmera dentro do terreno olhando para o horizonte.
- **Quando** a bolha de chunks é gerada.
- **Então** o mundo exibe biomas distintos (blocos de superfície/subsolo diferentes) separados por zonas de transição suaves — sem paredões, sulcos ou desníveis abruptos na malha —; o heightmap exportado ao mirror casa bit a bit com a simulação; o `x` do draw indireto e a imagem renderizada dos chunks visíveis são consistentes com a altura final.

### Travessia de ecótono e multiclique

- **Dado** uma linha de colunas cruzando a fronteira entre dois biomas de amplitudes diferentes, e um ponto onde três ou mais biomas se encontram dentro do `limiarTransicao`.
- **Quando** as alturas são comparadas entre colunas adjacentes.
- **Então** a diferença de altura entre colunas vizinhas nunca salta diretamente entre as envelopes dos biomas: no ecótono a altura é a média ponderada (peso ≤ peso do primário), garantindo rampa contínua; no multiclique, todos os biomas dentro do limiar contribuem suavemente e um terceiro bioma entrando na zona de transição tem peso que cresce a partir de 0 — sem degrau nem pico no vértice.

### Falhas e concorrência

- **JSON inválido** (bloco inexistente, > 16 biomas, > 64 camadas, tipo/operacao desconhecido): recusa na carga com log fatal — o app não inicia com config inválida (padrão VS-12).
- **Regeneração:** chunk descarregado e recarregado na mesma sessão produz ocupação idêntica (REQ-BIO-04); edições E1 posteriores à geração continuam governadas pelo journal — a VS-22 não toca em edição.
- **Worker vs main:** os buffers de bioma são imutáveis após o boot — nenhuma corrida nova é introduzida; o ownership da worker (VS-18) e o ring/timeline existentes seguem governando a geração.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-22-AC-01 | Determinismo: mesma config + coordenada → ocupação e ids de bloco bit a bit idênticos em regeneração | Sim: `biomes_sim.py` (float32 por operação vs oracle f64) verde; App: gerar → descarregar → recarregar chunks e comparar dense/mirror | Pendente |
| VS-22-AC-02 | Transição suave: travessia de ecótono sem paredões (diferença de altura entre colunas vizinhas limitada pela envelope de blending) | Dump do heightmap ao longo de uma travessia + inspeção numérica; screenshot do ecótono comparado com comutação direta (não usada) | Pendente |
| VS-22-AC-03 | Data-driven: trocar `blocoSuperficie`/`blocoSubsuperficie` no JSON muda o mundo novo sem recompilar; config inválida recusa na carga | Runs com configs distintas (screenshots) + runs de erro com validation/mensagens de log | Pendente |
| VS-22-AC-04 | Integração: push constants/contratos intactos; heightmap/mirror/física O(1) e plantas VS-14 funcionando; geração sem regressão de ALU fora do ecótono | Regression dos sims existentes (render/pack), smoke test com validation layers, timestamp de geração (VS-05/16) vs baseline VS-13 | Pendente |
| VS-22-AC-05 | Simulação cobre os casos do REQ-SIM-11 (interior, ecótono, empate, subtração, clamp, blocos por faixa, JSON inválido) | `tools/sim/biomes_sim.py` verde com contagens de checks registradas | Pendente |

## Tarefas da especificação

- [x] Vincular os requisitos (REQ-BIO-01..05, REQ-SIM-11) ao GOAL (Etapa 3 da arquitetura).
- [x] Definir escopo, não escopo e interfaces (schema JSON, structs std430, bindings 22–24).
- [x] Cobrir sucesso, dados-limite e concorrência.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-B12 e obter aprovação da spec. — ADR-B12 **ratificada (Opção A)** e spec **aprovada** pelo mantenedor em 2026-11-12, com a config padrão fixada em 5 biomas (planícies, deserto, pantano, gelado, montanhoso) sem vegetação.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-B12. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-22-IMPL-01 — Simulação de biomas** (REQ-SIM-11; AC-01, AC-02, AC-05). `tools/sim/biomes_sim.py`: espelho float32 (classificação, early-out, blending, somatório, round/clamp, blocos por faixa, validação de JSON) + oracle f64 independente com ruído injetado; casos obrigatórios do REQ-SIM-11.
2. **VS-22-IMPL-02 — JSON, loader e buffers** (REQ-BIO-01, REQ-BIO-05; AC-03, AC-04). `assets/biomes.json` + schema/defaults/validação (padrão VS-12), structs espelhadas em Odin, buffers e bindings 22–24, `DESCRIPTOR_SET_BINDING_COUNT = 25`.
3. **VS-22-IMPL-03 — Kernel data-driven** (REQ-BIO-02, REQ-BIO-03, REQ-BIO-04; AC-01, AC-02, AC-04). Reescrita do trecho de terreno do `generate_voxels`: warp → clima → classificação → early-out/blending → altura → blocos; preserva heightmap por coluna (VS-13) e export pós-blend; `spirv-val` limpo.
4. **VS-22-IMPL-04 — Config padrão e docs** (REQ-BIO-01). `assets/biomes.json` padrão equivalente ao mundo atual; atualização de arquitetura/manual técnico/tracking/frontmatter.
5. **VS-22-IMPL-05 — Evidências e fechamento reduzido** (AC-01..05). **Dispensa registrada (2026-11-12):** o mantenedor validará manualmente — as validações automatizadas com captura de screenshot/readback são **fora desta fatia**. Escopo do IMPL-05: sims verdes (`biomes_sim.py` + regressões `render_sim.py`/`pack_sim.py`), `spirv-val` limpo, build limpo, smoke run (app inicia, mundo dos 5 biomas gera, sem erros de validation além dos pré-existentes da VS-05). Evidências manuais (screenshots de ecótono, métricas de telemetria, regeneração bit a bit) ficam por conta do mantenedor; registrar resultado na validação manual e commitar com o nome da spec.

## Questões abertas

- Nenhuma bloqueante. Resolvidas na aprovação (2026-11-12): limites (16 biomas / 8 camadas por bioma / 64 camadas totais) **confirmados**; config padrão = **5 biomas sem vegetação** (o campo `permitePlantas` permanece no schema para trabalho futuro, mas fica `false` em todos os biomas entregues); mundo misto após troca de config **aceito** (só chunks novos); semente **global da config** (não há seed por mundo persistida hoje).

## Histórico

- 2026-11-12 — Rascunho elaborado a partir do documento do mantenedor (geração procedural de biomas em compute shaders: eixos climáticos, ecótono, domain warping, early-out), adaptado ao pipeline de geração existente, com a adição pedida de blocos de superfície/subsolo/fundo configuráveis por bioma via JSON; ADR-B12 registrada como pendente (bloqueia a aprovação).
- 2026-11-12 — **ADR-B12 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido. Config padrão fixada em 5 biomas usando blocos existentes (grama/terra/pedra/sand/podzol/snow/ice): planícies, deserto, pantano, gelado e montanhoso — sem vegetação (`permitePlantas = false` em todos; vegetação em trabalho posterior); limites de buffer confirmados (16 biomas / 8 camadas / 64 totais). Tarefas VS-22-IMPL-01..05 destravadas.
- 2026-11-12 — **Validações automatizadas posteriores dispensadas pelo mantenedor** (ele valida manualmente): o IMPL-05 fica reduzido a sims + `spirv-val` + build + smoke run; evidências de screenshot/readback/regeneração saem do escopo da fatia. Semente da config padrão fixada em **1337** (implantação).
- 2026-11-12 — **Implementação concluída (IMPL-01..04)**: (1) `tools/sim/biomes_sim.py` — 1.271 checks verdes (espelho f32 por operação vs oracle f64, distância euclidiana real, validação de `assets/biomes.json` incluída); (2) `assets/biomes.json` + `src/engine/voxel_biomes.odin` (loader com validação fatal padrão VS-12) + structs std430 em `common.slang` + bindings 22–24 (`DESCRIPTOR_SET_BINDING_COUNT` = 25); (3) kernel `generate_voxels` data-driven (warp → clima → classificação com sqrt real e desempate por índice → early-out/ecótono com `smoothstep` explícito → altura por camadas → round half up + clamp [1,32767] → blocos por faixa de y seguindo o primário; `biome_gs[8][8]` novo; heightmap/export VS-13 preservados); (4) docs: manual técnico §3.1/§8 e arquitetura. Regressões verdes: `render_sim.py` (2.982) e `pack_sim.py` (1.077); `spirv-val` limpo nos três SPIR-V. **Validação manual (screenshots de ecótono, telemetria de geração, regeneração bit a bit) pendente com o mantenedor.**
- 2026-11-12 — **Fix pós-validação do mantenedor**: constantes de enum de biomas tipadas como `u32` (o `biomes_parse_enum` variádico asseriia `.(u32)` e rejeitava os valores `int` — o app abortava na carga do `assets/biomes.json`); boot verificado (5 biomas, 9 camadas carregados).
- 2026-11-12 — **Melhoria aprovada pelo mantenedor: blending multiclique.** O ecótono que misturava apenas o bioma secundário deixava um degrau de até `0.5·|h_B − h_C|` nos pontos onde 3+ biomas se encontram (troca de secundário no vértice). REQ-BIO-02 generalizado para **blending normalizado**: todo bioma com `d_i − d_prim ≤ limiarTransicao` participa com peso bruto `smoothstep(limiar, 0, d_i − d_prim)` (primário = 1) e a altura é `Σ(s_i·h_i)/Σ(s_i)`; early-out passa a ser por bioma (a pilha de ruído só roda para `s_i > 0`). Reduz ao comportamento anterior nos extremos (interior puro; 50/50 a 2 biomas no centro), multiclique contínuo por construção (denominador ≥ 1) e o invariante "nenhum bioma supera o primário" generaliza o cap de 0,5. Sim e kernel atualizados; sims verdes.
- 2026-11-12 — **Ajuste de config pelo mantenedor (em andamento)**: durante a validação manual, o mantenedor está afinando o `assets/biomes.json` ao vivo (montanhoso ganhou camadas fBm extras para mais amplitude; globais de transição alargados). A tabela do REQ-BIO-01 permanece como **baseline aprovada** — o arquivo entregue é o alvo de tuning data-driven por design, e a sim relata a deriva campo a campo (report-only, não falha).
