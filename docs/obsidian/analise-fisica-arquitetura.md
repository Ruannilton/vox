---
id: ANALISE-FISICA-01
titulo: Análise — Arquitetura da engine de física
tipo: analise
status: rascunho
alimenta: futura spec VS-XX (física) + ADR
ultima_atualizacao: 2026-11-08
---

# Análise — Arquitetura da engine de física

Documento de teorização pré-spec. Nenhuma decisão aqui é final; ao aprovar um
caminho, registrar ADR em `decisoes/` e gerar a spec correspondente.

## 1. Premissas do modelo

Dois tipos de entidades físicas:

- **Estáticas:** os voxels dos chunks. Não se movem; mudam apenas por edição (E1)
  ou geração. Já existem materializados em duas views: VRAM (packed, render) e
  RAM (mirror C2, denso, consulta).
- **Dinâmicas:** jogador, NPCs e futuros corpos móveis. Volumes simples
  (AABB ou cápsula) que se movem pelo mundo e interagem com as estáticas e,
  eventualmente, entre si.

Distinção semântica importante (levantada na discussão): **ocupar espaço ≠
bloquear movimento ≠ ser alvo de raycast**. A planta é o caso canônico: não
bloqueia o jogador, mas deve ser atingida pelo raycast de seleção. Hoje isso já
existe parcialmente: `BLOCK_DEFINITION_FLAG_NON_SOLID` (VS-14) marca a planta
como "ocupa o voxel mas não é sólida", e o bitmask `solid` da ChunkPage a
exclui — enquanto o `ids` denso continua contendo o bloco para consulta.

## 2. Estado atual (o que já existe e pode ser reaproveitado)

| Recurso | Onde | Relevância para física |
| --- | --- | --- |
| Bitmask `solid` (4 KiB/chunk, 1 bit/voxel) | `MirrorChunkPage` (C2) | Broadphase binário "bloqueia movimento?" — 32 voxels por load |
| Grid denso `ids` u16 y-major | `MirrorChunkPage` | Identidade do voxel para lookup de propriedades |
| `voxel_get` tri-state | `voxel_mirror.odin` | Consulta pontual com "desconhecido" explícito |
| Heightmap da coluna (VS-13) | `MirrorChunkPage.heights` | Ground query O(1) — com ressalvas: a semente é analítica (ruído, `voxel.slang:52-66`), não medida dos voxels; o journal E1 mantém o valor a cada edição (`voxel_mirror.odin:479-498`), mas a semente pressupõe worldgen heightfield puro |
| `BlockDefinition.flags` (NON_SOLID, TRANSPARENT) | registry / `blocks.json` | Início da tabela de física por tipo |
| Journal E1 mantém bitmask + heightmap | `voxel_mirror.odin` | Colisão converge com edições por construção, sem dirty flag |

**Conclusão parcial:** a proposta de "bitmap de colisão + lookup table" já está
meio implementada no mirror — o bitmask `solid` é o bitmap, e o registry de
`BlockDefinition` é o embrião da lookup table. A questão é como completá-la.

## 3. Eixo 1 — Onde mora o dado de colisão do mundo estático

### Opção A — Reutilizar o bitmask `solid` do mirror C2 (recomendada)

O bitmask já é derivado do registry, mantido pelo journal e coberto pela
máquina de estados da página. A física lê o mirror diretamente.

- ✅ Zero memória e zero sincronização novas; converge com edições por
  construção (mesmo journal, mesmo `edit_seq`).
- ✅ Layout contíguo: 64 B por coluna de 32 voxels; o sweep de um corpo toca
  poucas linhas de cache.
- ✅ Tri-state já resolve "chunk fora da bolha" honestamente.
- ❌ Binário: não carrega forma (escada, meio-bloco) nem "hittable" — precisa
  ser combinado com a lookup table (Eixo 2).
- ❌ Cobre só a bolha de simulação (~500 chunks nos defaults) — mas é
  exatamente para isso que a bolha existe.

### Opção B — Bitmask de colisão dedicado, gerado no pack GPU e exportado

Seguir à risca o paralelo com o bitmap de ocupação de render: o pack produziria
um bitmap físico por chunk, exportado como o grid u16.

- ✅ Semântica própria, desacoplada do registry (poderia codificar 2–4 bits:
  bloqueia / atingível / líquido / etc.).
- ❌ **Redundante**: o que um voxel "é" fisicamente deriva do tipo do bloco, e
  o registry CPU já sabe disso — gerar na GPU e reexportar duplicaria informação
  que o mirror deriva localmente a custo zero ao materializar a página.
- ❌ Mais banda de readback, mais memória, mais um formato para manter
  consistente com o journal.
- ❌ Viola o espírito do C2: a RAM já é a view de gameplay; física é gameplay.

### Opção C — Sem bitmask: consultar `ids` + lookup por consulta

- ✅ Uma fonte só, código mínimo.
- ❌ Dois loads dependentes (id → definição) por voxel testado; um corpo
  testando ~100 voxels/frame × N entidades vira centenas de acessos dispersos —
  o bitmask existe justamente porque "ocupa espaço?" é a query mais frequente.

**Síntese:** Opção A como broadphase; o "bitmap de colisão" da proposta já é o
`solid` da ChunkPage. A semântica mais rica vai na lookup table, não em bitmaps
adicionais (com a possível exceção de **um** segundo bitmask `hittable`, ver
Eixo 2).

## 4. Eixo 2 — Semântica dupla: bloquear movimento vs. ser alvo de raycast

### Opção A — Tabela de física por bloco (lookup table)

Estender o dado por tipo de bloco com flags e materiais físicos:
`BLOCKING`, `HITTABLE`, `CLIMBABLE`, `LIQUID`, fricção, restituição. O fluxo de
resolução fica: bitmask filtra candidatos → para cada candidato, `ids` +
tabela decide a interação exata. É a proposta original da discussão.

- ✅ Data-driven, coerente com o motor: `blocks.json` ganha campos de física e
  o carregador VS-12 já tem o fluxo de validação/upload.
- ✅ Extensível sem tocar em algoritmos (novo comportamento = nova flag).
- ✅ Separação limpa: broadphase barato (bit), narrowphase semântico (tabela).
- ❌ Onde colocar: estender `BlockDefinition` (48 B, std430, espelhado no
  Slang) custa bytes em todo chunk/registry GPU; uma `PhysicsDefinition`
  separada CPU-side evita inchar o contrato GPU — o shader não precisa de
  fricção.

### Opção B — Dois bitmasks por chunk: `solid` + `hittable`

- ✅ Raycast vira DDA sobre um bitmask só — sem lookup por voxel na malha do
  raio, muito barato.
- ✅ +4 KiB/chunk é pouco (~5,7% da página de 70 KiB).
- ❌ Só resolve a dicotomia binária; materiais (fricção etc.) ainda exigem
  tabela.
- ❌ Mais uma estrutura para o journal manter (barata: deriva do registry,
  mesma linha do `mirror_bit_write` existente).

### Opção C — Bitmask único de presença (ocupação) + tabela decide tudo

O bit marca "há algo aqui" (planta inclusa); blocking/hittable saem da tabela.

- ✅ Um bitmask só serve de broadphase para movimento **e** raycast.
- ❌ Raycast atravessando campos de planta consulta a tabela a cada voxel —
  aceitável (plants são esparsas), mas perde o early-out puro por bit.
- ❌ Movimento passaria a testar bits de plantas (falso positivo no broadphase)
  — custo pequeno, pois o narrowphase as descarta via tabela.

**Síntese:** A (tabela de física CPU-side) é obrigatória de qualquer forma para
materiais; a dúvida real é `solid`+tabela (A+C híbrido, reusa o que existe)
versus bitmask `hittable` dedicado (B) para raycasts longos baratos. Decisão
adiável: começar com `solid` + tabela e medir o custo do DDA.

## 5. Eixo 3 — Narrowphase espacial (reduzir o cenário de teste)

A observação chave: **a grade de voxels já é a broadphase perfeita** — um
particionamento espacial uniforme com consulta O(1). Nenhuma BVH/octree se
justifica para mundo estático.

### Opção A — Sweep de AABB contra a grade

O corpo dinâmico (AABB/cápsula) testa apenas os voxels na caixa varrida pelo
movimento do tick (posição antiga → nova, expandida por 1 voxel). Resolução
eixo a eixo (move X, resolve; move Y, resolve; move Z, resolve), como nos
engines de voxel clássicos.

- ✅ Testa dezenas de voxels por entidade por tick, não milhares.
- ✅ Eixo a eixo dá sliding, step-up e grounded flag quase de graça.
- ❌ Tunneling em alta velocidade exige subdividir o movimento ou DDA de
  varredura (canto de voxel é o caso patológico clássico).

### Opção B — Heightmap como fast-path de chão

Para entidades em pé e fora de cavernas, `heights` responde "tem chão sob mim e
a que altura" em O(1) por coluna — o caso 90% dos NPCs.

- ✅ Extremamente barato; edições não o dessincronizam — o journal E1 mantém o
  topo a cada edição (sobe ao colocar acima do topo; rescan de 32 bits ao
  remover o topo; no-op nos demais casos).
- ❌ **A semente é analítica, não medida:** o export GPU (`voxel.slang:52-66`)
  escreve `min(ruído - origem_y, 31)` sem varrer os voxels gerados. Correto
  apenas enquanto o worldgen for heightfield puro; qualquer estrutura acima do
  terreno (árvore, arco, ilha flutuante) quebra a semente silenciosamente.
  Mitigação barata: derivar `heights` na materialização varrendo o bitmask
  `solid` (1.024 colunas × ≤32 testes de bit — irrisório contra o memcpy de
  64 KiB), tornando o ring de heightmap (binding 20) redundante.
- ❌ Semântica por chunk: 0xFFFF exige continuar a busca no chunk abaixo; o
  consumidor precisa iterar páginas.
- ❌ Não serve para interiores/cavernas (heightmap é o topo, não o teto) —
  precisa de fallback para Opção A quando a entidade está abaixo do topo.

### Opção C — Estrutura de aceleração global (BVH de chunks, octree)

- ❌ Redundante com a grade; custo de manutenção alto; rejeitada.

**Síntese:** A como algoritmo central + B como otimização do caso comum. O
"reduzir o cenário de teste" da discussão é exatamente o sweep de AABB: a caixa
expandida do movimento define o conjunto de voxels candidatos.

## 6. Eixo 4 — Onde a física roda: CPU vs GPU

### Opção A — CPU sobre o mirror C2 (recomendada)

Física é gameplay: consome e produz estado do jogo, precisa de determinismo
razoável e de responder "desconhecido" com política, não com stall.

- ✅ A bolha de simulação existe exatamente para isso; `mirror_request` puxa
  páginas sob demanda para agentes ativos.
- ✅ Resultado fica na CPU, onde o consumidor (IA, input, rede futura) está —
  sem readback.
- ✅ Determinismo reproduzível em testes/sim (cultura de `tools/sim/`).
- ❌ Entidade fora da bolha = mundo "desconhecido": precisa de política
  (congelar entidade, puxar página, ou assumir chão via heightmap quando
  disponível).

### Opção B — GPU compute sobre os slots packed

- ✅ Escala para milhares de corpos triviais (partículas, destroços visuais).
- ❌ Formato packed (paleta + planos) é péssimo para consulta pontual — foi o
  motivo de existir o C2.
- ❌ Resultado de gameplay teria que voltar por readback (latência de frames,
  acoplamento com timeline) — inaceitável para o jogador.
- ❌ Bolha de render ≠ bolha de simulação: NPC atrás da câmera pode não ter
  slot de VRAM.

### Opção C — Híbrido

CPU authoritative para entidades de gameplay (jogador, NPCs); GPU apenas para
efeitos visuais sem gameplay (partículas de quebra de bloco). Caminho natural
a longo prazo, não arquitetura inicial.

## 7. Eixo 5 — Raycast

- **DDA (Amanatides & Woo) na grade do mirror:** percorre só os voxels
  tocados pelo raio; por voxel, bit de presença/solid filtra e a tabela
  (`HITTABLE`) decide se conta como hit. Planta atingível sai de graça da
  distinção do Eixo 2.
- **Distância máxima e tri-state:** raio que sai da bolha materializada
  retorna "desconhecido/miss" com flag — o consumidor decide (seleção de bloco
  do jogador sempre opera dentro da bolha de simulação centrada nele).
- Custo: ~3× a distância em loads de bit — um raycast de 8 voxels são ~24
  testes de bit. Irrelevante.

## 8. Formas não-cúbicas (questão futura, não escopo)

Escada, meio-bloco e afins: o voxel unitário (regra 1) limita a forma visual,
mas a colisão pode ser mais fina que 1³. Caminho data-driven coerente com o
Caminho B: o template de malha carrega também **caixas de colisão** (sub-AABBs
em [0,1]³). Broadphase por bit continua igual; o narrowphase, ao bater num
voxel com forma, testa as caixas do template. Adiável: colisão cúbica para
tudo no início.

## 9. Recomendação consolidada

1. **Mundo estático:** mirror C2 como única fonte (Eixo 1-A). O "bitmap de
   colisão" já existe: é o `solid` da ChunkPage.
2. **Semântica:** tabela de física CPU-side por tipo de bloco (Eixo 2-A),
   populada do `blocks.json`; bitmask `hittable` dedicado fica como otimização
   adiável (Eixo 2-B) se o DDA pesar.
3. **Narrowphase:** sweep de AABB eixo a eixo contra a grade (Eixo 3-A) +
   fast-path de chão pelo heightmap (Eixo 3-B).
4. **Execução:** CPU sobre o mirror (Eixo 4-A); GPU no máximo para efeitos
   visuais depois (Eixo 4-C).
5. **Raycast:** DDA na grade com filtro bit + tabela (Eixo 5).
6. **Política do desconhecido:** entidade dinâmica exige página MATERIALIZED;
   `mirror_request` garante a bolha centrada nos agentes; comportamento fora da
   bolha (congelar vs. assumir chão) é decisão de gameplay a registrar na spec.

A intuição original da discussão (bitmap como filtro + lookup table na
resolução + testar só a vizinhança) está correta e, melhor: já está parcialmente
construída — o trabalho da spec será formalizar a tabela de física e escrever
o solver de corpos dinâmicos sobre o mirror.

## 10. Questões abertas

- Forma do corpo dinâmico: AABB (simples) ou cápsula (melhor para rampas)?
- Timestep fixo com acumulador ou variável clampado? (afeta replay VS-07:
  eventos gravados têm tempo do dreno — física determinística ajuda o replay)
- Entidades dinâmica-dinâmica (jogador empurra NPC) entram na primeira spec?
- Física precisa participar do replay de eventos com determinismo bit-exato ou
  apenas "best-effort 1×" como o resto do VS-07?
- `PhysicsDefinition` separada ou extensão do `BlockDefinition`? (impacto no
  contrato std430 de 48 B e no `common.slang`)
- Heightmap: manter a semente analítica do ruído (binding 20) ou derivá-la do
  bitmask `solid` na materialização? A segunda elimina o acoplamento frágil
  com a topologia do worldgen e torna o ring de heightmap redundante.
