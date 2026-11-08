---
id: VS-19
titulo: Física de gameplay — solver CPU sobre o mirror
tipo: especificacao
status_spec: aprovada
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de: [VS-04, VS-13, VS-14, VS-18]
bloqueada_por: []
requisitos: [REQ-PHY-01, REQ-PHY-02, REQ-PHY-03, REQ-PHY-04, REQ-PHY-05, REQ-PHY-06, REQ-PHY-07, REQ-PHY-08, REQ-PHY-09, REQ-PHY-10]
ultima_atualizacao: 2026-11-08
---

# VS-19 — Física de gameplay: solver CPU sobre o mirror

## Objetivo

Fornecer física autoritativa de gameplay na CPU: AABBs dinâmicas colidem com o mundo estático do mirror em timestep fixo, com sliding, step-up e grounded, e raycasts DDA distinguem blocos atingíveis de blocos bloqueantes. A consulta respeita a bolha de simulação e nunca interpreta mundo desconhecido como ar.

## Rastreabilidade

- GOAL: [[analise-fisica-arquitetura]] e escolhas do mantenedor de 2026-11-08.
- Decisão: [[ADR-F1-fisica-solver-mirror|ADR-F1]], pendente e bloqueando a aprovação.
- Referências: `voxel_mirror.odin` (`MirrorChunkPage`, `voxel_get`, `mirror_height_get`, mutex de página), `voxel_assets.odin` e `assets/blocks.json` (VS-12/VS-14), ownership e leituras da VS-18.
- Revisões de contrato: VS-13 (heightmap derivado do bitmask; ring removido) e VS-00 (binding 20 removido).

## Requisitos

### Dados e tempo

- **REQ-PHY-01 — Tabela física data-driven.** Criar `PhysicsDefinition` exclusivamente CPU-side, indexada pelo id do bloco, com flags `BLOCKING`, `HITTABLE` e os bits reservados `CLIMBABLE`/`LIQUID`, além de fricção e restituição. `blocks.json` ganha um objeto opcional por bloco com defaults explícitos; ar é sempre não-bloqueante e não-atingível. A planta padrão é não-bloqueante e atingível. Validador offline e loader rejeitam tipos inválidos, flags desconhecidas e materiais fora dos limites documentados (fricção ≥ 0; restituição em [0,1]), citando o bloco. O fallback built-in tem paridade semântica. `BlockDefinition` e o registry std430 de 48 B não mudam.
- **REQ-PHY-02 — Timestep fixo.** O estado físico avança somente em passos fixos na main, por acumulador de tempo; o resto fracionário não produz meio passo. Definir constante de passo e limite de passos por frame para evitar espiral de morte, com descarte/limite documentado do excesso. Mesmo estado inicial e mesma sequência de passos/inputs produzem o mesmo resultado no processo; replay permanece best-effort como VS-07, sem promessa bit-exata entre plataformas.

### Movimento estático-dinâmico

- **REQ-PHY-03 — Sweep eixo a eixo.** Cada corpo é uma AABB alinhada à grade. O deslocamento do passo é resolvido contra voxels bloqueantes na ordem estável X→Y→Z, restringindo candidatos à caixa varrida; contatos param o componente sem penetrar, permitem sliding e expõem grounded. Subdividir deslocamentos grandes em incrementos que impeçam atravessar um voxel sem teste. O bitmask `solid` é o filtro inicial e a tabela decide a semântica do candidato.
- **REQ-PHY-04 — Step-up e materiais.** Step-up só ocorre quando há espaço livre para toda a AABB na altura elevada e apoio bloqueante no destino; limite máximo de um voxel nesta fatia. Grounded é recalculado por contato real, não persistido após perder apoio. Fricção e restituição vêm da `PhysicsDefinition` do bloco de contato, com regra de combinação documentada e determinística; nenhuma propriedade física é enviada ao shader.
- **REQ-PHY-05 — Fast-path de chão.** Para apoio em colunas com topo conhecido e corpo fora de interiores/cavernas, consultar `heights` em O(1) por coluna coberta pela AABB. O fast-path só é aceito se produzir o mesmo apoio do sweep; topo `0xFFFF`, travessia entre chunks, corpo abaixo do topo, sobreposição ou qualquer ambiguidade usa o sweep completo. O heightmap nunca elimina testes de teto/paredes.
- **REQ-PHY-06 — Mundo desconhecido.** Se qualquer página necessária ao movimento estiver ausente ou não materializada, a entidade congela no último estado válido (sem integrar deslocamento parcial) e registra a coordenada para `mirror_request` na worker. Não há stall síncrono, teleporte ou presunção de ar; ao materializar, o movimento retoma em passos futuros. O pedido é coalescido para não inundar a worker.

### Heightmap e raycast

- **REQ-PHY-07 — Heightmap medido no mirror.** Após preencher `ids` e `solid` na materialização, derivar as 1.024 entradas `heights` varrendo cada coluna do bitmask (no máximo 32 bits), mantendo `0xFFFF` para coluna sem sólido e o journal E1 existente. Remover o ring `mirror_heightmap_ring`, o binding 20, o write no generate, invalidação/cópia e provisionamento associados. A geração groupshared usada pelo worldgen permanece; somente o export redundante sai. Atualizar `heightmap_sim` e `mirror_sim` antes da alteração do shader.
- **REQ-PHY-08 — Raycast DDA.** Implementar Amanatides & Woo sobre coordenadas inteiras do mirror, com origem/direção em mundo, distância máxima positiva e tratamento definido de origem em voxel, direção zero e fronteiras. Percorrer apenas voxels atravessados; consultar `ids` e `HITTABLE` para decidir o hit, inclusive para plantas não-sólidas. Retornar coordenada/id, distância e normal da face atingida.
- **REQ-PHY-09 — Resultado tri-state do raio.** Resultado é `hit`, `miss` ou `unknown`. `miss` somente ao esgotar a distância sem hit; encontrar página ausente/em readback antes disso retorna `unknown` com a coordenada que bloqueou a consulta. Distância inválida ou direção nula é rejeitada sem percorrer a grade. Nenhum bitmask `hittable` é criado.

### Integração e observabilidade

- **REQ-PHY-10 — Hooks e Tracy.** Expor API mínima para jogador/consumidores: criar/remover corpo AABB, definir pose/velocidade, aplicar movimento no tick, consultar estado (posição, velocidade, grounded, congelado) e emitir raycast. Integrar o jogador a esses hooks sem mudar input/eventos/render nem ownership da worker. Instrumentar com zones Tracy ligadas à física: tick/acumulador, sweep por corpo, fast-path/fallback, congelamento/pedido de página e DDA, com contadores de corpos, contatos e voxels visitados.

## Escopo

- Tabela e validação de física no JSON e no fallback built-in.
- Solver estático-dinâmico de AABB, timestep fixo, sliding, step-up, grounded e materiais.
- Heightmap derivado do mirror e remoção integral do ring/binding 20.
- Raycast DDA tri-state e hooks de gameplay/jogador.
- Sims, testes reproduzíveis, instrumentação, stress, capturas e documentação/emendas.

## Não escopo

- Colisão ou resposta dinâmica-dinâmica (jogador empurrando NPC).
- Física autoritativa em GPU, partículas ou destroços físicos.
- Cápsulas, rotação, formas não-cúbicas/sub-AABBs e rampas contínuas.
- Bitmask `hittable`, BVH/octree, líquidos/escaláveis funcionais (flags apenas reservadas).
- Determinismo bit-exato, lockstep de rede, save/serialização do estado físico.

## Dependências

- [[VS-04-mirror-c2|VS-04]], [[VS-13-heightmap-geracao-mirror|VS-13]], [[VS-14-plantas-alpha-test-spawn|VS-14]] e [[VS-18-mundo-na-worker|VS-18]] concluídas e verificadas.
- [[ADR-F1-fisica-solver-mirror|ADR-F1]] deve ser aceita antes da aprovação desta spec.

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `PhysicsDefinition` | flags + fricção + restituição por id | somente CPU; não altera std430 |
| Tick físico | passo fixo + acumulador na main | leituras auditadas pelo mutex do mirror |
| Corpo | AABB, pose, velocidade e flags de contato | somente contra mundo estático |
| Consulta de página | materializada / desconhecida | worker solicita e materializa |
| Raycast | hit/miss/unknown + dados do hit | distância máxima obrigatória |
| `ChunkPage.heights` | topo sólido derivado de `solid` | índice `x \| z<<5`; E1 mantém |

### Comportamento quando limites são atingidos

- Excesso de tempo: executar no máximo o limite de passos por frame e registrar o descarte; nunca criar espiral de morte.
- Página desconhecida: congelar corpo ou retornar `unknown`, conforme a operação.
- Deslocamento alto: subdividir; não usar apenas teste na posição final.
- Fast-path inaplicável: fallback ao sweep, sem resultado aproximado.

## Cenários

### Cenário de sucesso — caminhada e contato

- **Dado** jogador AABB sobre terreno materializado, com parede e degrau de um voxel.
- **Quando** inputs produzem gravidade e movimento em passos fixos.
- **Então** o jogador permanece apoiado, desliza ao encontrar a parede, executa step-up apenas com espaço livre e não penetra voxels, inclusive com deslocamento subdividido.

### Planta e raycast

- **Dado** planta não-bloqueante e atingível à frente de um bloco sólido.
- **Quando** o corpo a atravessa e um raio é emitido.
- **Então** o movimento não é bloqueado; o DDA atinge primeiro a planta e reporta sua coordenada, distância e normal.

### Falhas e concorrência

- **Dado** movimento ou raio alcança página em readback/ausente enquanto a worker edita outra página.
- **Quando** a consulta ocorre na main.
- **Então** o corpo congela e coalesce `mirror_request`, ou o raio retorna `unknown`; mutexes impedem leituras parciais e não há deadlock.

### Heightmap com topologia não-heightfield

- **Dado** coluna materializada com arcos ou bloco flutuante acima do terreno.
- **Quando** a página é derivada do bitmask.
- **Então** `heights` aponta para o sólido mais alto real, sem depender do ruído; o binding 20 não existe mais.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-19-AC-01 | Loader, fallback e validador cobrem defaults, planta e erros de schema/material; `BlockDefinition` permanece 48 B | Bateria offline de assets + build | Pendente |
| VS-19-AC-02 | Sims provam sweep eixo a eixo, anti-tunneling, sliding, grounded, step-up seguro e fast-path equivalente com fallback; timestep produz resultados repetíveis para mesma sequência | Simulação de física e testes de acumulador antes/depois da integração | Pendente |
| VS-19-AC-03 | DDA cobre eixos/diagonais, fronteiras, origem interna, distância, planta `HITTABLE` e tri-state sem falsos misses | Simulação DDA + consultas em sessão | Pendente |
| VS-19-AC-04 | `heights` é idêntico ao topo medido do bitmask, inclusive topologia não-heightfield e E1; ring/binding/write/provisionamento 20 removidos | `heightmap_sim`, `mirror_sim`, `spirv-val`, build e inspeção dos recursos | Pendente |
| VS-19-AC-05 | Jogador integrado caminha, colide e seleciona via hooks; desconhecido congela/retorna unknown e retoma após materialização, sem leitura parcial ou deadlock | Sessões com edições, teleports e travessia da bolha em builds default/Tracy com validation | Pendente |
| VS-19-AC-06 | Stress: 5 execuções com replay, movimento, edições e teleports em ambos os builds e `--full-teardown`: zero VUIDs/threading/deadlock e teardown limpo | Stress scriptado reproduzível | Pendente |
| VS-19-AC-07 | Zones/contadores Tracy cobrem todos os caminhos novos; captura íntegra salva em `bin/debug/<version>/tracy/VS-19_fisica_solver_mirror.tracy`; comparação com versão anterior registrada | `run_tracy.bat` + `tracy-capture`; relatório por subagente coder K2.8 thinking low | Pendente |

## Tarefas da especificação

- [x] Vincular requisitos, análise, ADR e dependências.
- [x] Definir escopo, não escopo, interfaces e política do desconhecido.
- [x] Cobrir sucesso, falhas e concorrência.
- [x] Definir validação para cada critério de aceitação.
- [x] Resolver forma, timestep, replay e localização da tabela.
- [ ] Ratificar ADR-F1 e obter aprovação da spec.

## Tarefas de implementação

Ver [[VS-19-fisica-solver-mirror-tasks]]. Nenhuma etapa pode iniciar antes da aprovação da spec e da ADR-F1.

## Emendas registradas

- **VS-13:** REQ-MIR-01 e a origem por ring de REQ-MIR-02 ficam superseded pela VS-19; `ChunkPage.heights`, semântica, helper e manutenção E1 permanecem, agora derivados do `solid` na materialização. A otimização groupshared do worldgen não é revertida.
- **VS-00:** o binding 20 `mirror_heightmap_ring` é removido; contagem de descriptors e provisionamento retornam ao estado sem esse recurso.

## Questões abertas

- Nenhuma questão crítica. Valores concretos de passo, limite de subpassos e constantes de movimento serão fixados e documentados na implementação, sem mudar as decisões arquiteturais.

## Histórico

- 2026-11-08 — Conteúdo completo submetido à revisão; ADR-F1 pendente. Arquivo de tarefas criado; nenhuma implementação iniciada.
- 2026-11-08 — Rascunho criado pelo subagente K3.1 (ADR-F1 + spec + TASKS) a partir de `analise-fisica-arquitetura.md` e das escolhas do mantenedor; submetida à revisão.
- 2026-11-08 — **ADR-F1 ratificada e spec aprovada** pelo mantenedor; tarefas destravadas para implementação K2.8 pelo arquivo de TASKS.
