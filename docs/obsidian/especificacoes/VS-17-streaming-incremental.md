---
id: VS-17
titulo: Streaming incremental
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-01
bloqueada_por: []
requisitos: [REQ-STR-01, REQ-STR-02, REQ-STR-03, REQ-STR-04]
ultima_atualizacao: 2026-11-08
---

# VS-17 — Streaming incremental

## Objetivo

Eliminar os lag spikes causados pelo handler de mudança de chunk da câmera: hoje `streaming_update` (`voxel_engine.odin`) varre todo o `active_chunks` (~40 mil entradas) + a esfera de geração inteira (~69 mil iterações com r=20) **sincronamente, a cada chunk cruzado** — 16 chamadas de 312–746 ms na captura `tracy_view_22.tracy` (41 frames >30 ms somando 9,1 s; frame máximo 782 ms; worker morrendo de fome em `claim_batch` durante 6,0 s; GPU ociosa). A substituição: um **único cursor em espiral ordenado por distância** (geração + descarga fundidas) processado em fatias com orçamento de tempo por frame.

## Rastreabilidade

- GOAL: análise da captura Tracy `tracy_view_22.tracy` (2026-11-07, anexada ao pedido do mantenedor): `streaming_update` = 7,48 s dentro dos spikes; `claim_batch` (worker) = 6,0 s de espera; `promote_visibility` 1,9 ms + `publish_visible` 2,0 ms por frame (duas varreduras completas do mapa por frame).
- Referência: `voxel_engine_update` (`src/engine/voxel_engine.odin` — branch `camera_chunk != last_camera_chunk`), fila de prioridade por distância (VS-01), worker (`voxel_worker.odin`), promote/publish (`ve_publish_visible`).
- Decisões: sequenciamento VS-17→VS-18 aprovado pelo mantenedor (2026-11-07) — a migração do ownership do mundo para a worker thread fica registrada no backlog como VS-18 planejada.
- Fundação: VS-01 (streaming/fila/worker), VS-10 (materialização por edição com retry — inalterada).

## Requisitos

### Cursor espiral unificado

- **REQ-STR-01** — Substituir o gatilho "câmera mudou de chunk" por um **cursor em espiral** sobre o espaço de chunks: centrado no `camera_chunk` atual, ordenado por distância quadrada crescente, cobrindo a esfera de unload (raio maior). A cada frame, o cursor consome uma fatia dentro de um **orçamento de tempo** (constante, ex. 6 ms — fixada na implementação e registrada aqui). Para cada coordenada da fatia: (a) dentro da esfera de geração e ausente do map → enfileira tarefa de geração (mesmo caminho de hoje: claim de slot + `GenerationTask` na fila priorizada); (b) fora da esfera de unload e presente no map → descarrega (mesmo caminho de hoje: mirror_forget + aposentadoria B1); (c) demais casos → nada. O cursor **persiste entre frames** (não recomeça a espiral a cada cruzamento); ao completar um ciclo, reancora no `camera_chunk` e recomeça. Remover o código do branch de mudança de chunk (o update passa a chamar apenas "avança o cursor").
- **REQ-STR-02** — **Prioridade de graça:** como a fila de tarefas (VS-01) já é puxada pela worker em ordem de distância, a vizinhança da câmera é gerada primeiro naturalmente; nenhuma cota especial é necessária. Comportamento sob câmera parada: o cursor completa ciclos baratos (tudo presente/ Ausente estável) — custo por frame tende a zero quando o mundo está em equilíbrio.

### Passada única de visibilidade

- **REQ-STR-03** — Fundir `promote_visibility` + `publish_visible` numa única iteração sobre `active_chunks` por frame: para cada registro, decidir CACHED⇄RENDERABLE e, se RENDERABLE, escrever a entrada no ring `visible_chunks` na mesma passada (mesma ordem/capacidade de hoje; `visible_chunk_offset` e o consumidor no render inalterados). Duas varreduras de 40 mil entradas viram uma.

### Orçamento e medidas

- **REQ-STR-04** — Orçamento de fatia em **tempo** (não em iterações): medido por `time.tick_now()`; ao estourar, o cursor suspende e retoma no frame seguinte ( estado do cursor persistido no `VoxelEngine`). Constante documentada no manual. **Medição de aceite:** mesma pose/roteiro da captura `tracy_view_22` — `streaming_update` deixa de existir como zona única (vira `streaming_slice`, ~orçamento ms por frame); frames >50 ms após aquecimento ≈ 0; `claim_batch` sem esperas longas (worker alimentado continuamente).

## Escopo

- Cursor espiral (estrutura de estado no `VoxelEngine` + avanço por orçamento no `voxel_engine_update`), remoção do branch de mudança de chunk, fusão promote+publish.
- Sim `tools/sim/streaming_sim.py` estendido (modelo do cursor: ordem da espiral, fatias por orçamento, geração×descarga por coordenada, reancoração de ciclo) — antes da implementação, sem mudança de shader (não exige sim de shader pelo AGENTS.md, mas o streaming_sim existente é o espelho natural e é estendido nos ACs.
- Docs: spec, arquitetura §2 (histerese → streaming incremental), manual técnico, tracking; backlog ganha a VS-18 planejada.

## Não escopo

- **VS-18 (backlog):** migração do ownership do mundo para a worker thread (streaming + promote/publish + mirror + completions na worker; publish pipelined por frame; main só render) — spec própria depois desta.
- `mirror_service` (rajadas de materialização) e `generate`/`pack` (picos) — otimizações futuras, registradas.
- Mudanças em raios/config, worker, fila de prioridade, B1/E1/mirror (caminhos internos reutilizados como estão).

## Dependências

- [[VS-01-streaming-generate-pack|VS-01]] concluída (fila por distância, worker, aposentadoria B1).
- Sem bloqueio de ADR (decisão de sequenciamento VS-17→VS-18 já aprovada pelo mantenedor).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `streaming_cursor` (estado no `VoxelEngine`) | centro (chunk), índice da espiral, coord atual | persiste entre frames; reancora ao fim do ciclo |
| Orçamento | constante de tempo por frame (ex. 6 ms) | fixada na implementação, registrada aqui e no manual |
| Zona Tracy | `streaming_update` → `streaming_slice` | evidência de aceite nos ACs |

### Comportamento quando limites são atingidos

- Orçamento estourado mid-fatia: suspende imediatamente (o tick é checado a cada N coords), retoma no próximo frame.
- Pool de slots esgotado durante a fatia: as tarefas excedentes simplesmente não são enfileiradas (o cursor passa adiante; na próxima volta elas ainda estarão ausentes do map) — o warning "pool esgotado" por episódio permanece.
- Câmera teleportada longe: a espiral reancora no próximo fim de ciclo; a fila por distância prioriza a nova vizinhança assim que as tarefas chegam (latência de uma fatia ~orçamento).

## Cenários

### Cenário de sucesso — voando sem spikes

- **Dado** o mesmo roteiro da captura `tracy_view_22` (movimento contínuo cruzando chunks).
- **Quando** frames avançam.
- **Então** `streaming_slice` fica na faixa do orçamento por frame; frames >50 ms ≈ 0 após aquecimento; `claim_batch` sem esperas longas; o mundo materializa na frente da câmera sem engasgos (worker sempre alimentado).

### Câmera parada

- **Dado** a câmera imóvel.
- **Quando** o cursor completa o ciclo.
- **Então** as fatias ficam quase vazias (coords estáveis), o custo por frame tende a ~0; descarga ocorre naturalmente se algo expira do raio (não o caso de câmera parada).

### Paridade funcional

- **Dado** edições, materializações por edição (VS-10) e descargas.
- **Quando** a sessão avança.
- **Então** contagens de ativos/EMPTY/visíveis evoluem como antes; journal e feedback E1 normais; readbacks e sims verdes.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-17-AC-01 | Mesmo roteiro de movimento da captura baseline: zero frames >50 ms após aquecimento; `streaming_slice` ≤ orçamento+ε; `claim_batch` p99 baixo | Tracy headless (`tracy-capture`) nos dois builds, comparado com `tracy_view_22` | **Verificado:** roteiro de movimento `events_20261108_013623.jsonl` (vision=20), 3.670 frames; 0 >50 ms após 120 frames; frame máx 42,09 ms. `streaming_slice` p99 8,32 ms (orçamento 6 ms + trabalho da fatia), `claim_batch` p99 9,31 ms/máx 28,07 ms vs baseline p99 185,46 ms; builds default/Tracy OK |
| VS-17-AC-02 | Paridade funcional: contadores de ativos/EMPTY/visíveis coerentes; edição/materialização/descarga normais; sims verdes (`streaming_sim` estendido com o cursor) | Sessão replay com edições + teleports + contadores no log | **Verificado:** replay com 2 teleports + Add/Remove, 8 eventos, `applied=3 noop=0 rejected=0 deferred=0`; EMPTY 222, slots livres 1.529 após descarga; sims antigos + cursor (parado/teleporte/pool) verdes |
| VS-17-AC-03 | `promote_visibility`+`publish_visible` fundidos em uma passada; `visible_count` e conteúdo do ring inalterados (render idêntico) | Smoke com readback/capturas e contagens comparadas | **Verificado:** uma única passada em `voxel_engine_publish_visible`, mesma capacidade/offset/entries/vizinhos; render e builder normais no replay, sem publicação de GENERATING (defeito da integração corrigido e revalidado); smoke full zero VUIDs |

## Tarefas da especificação

- [x] Vincular a evidência da captura `tracy_view_22` (spikes = streaming_update; worker faminto; GPU ociosa).
- [x] Formalizar o cursor espiral unificado com orçamento de tempo e a fusão promote+publish.
- [x] Cobrir sucesso, câmera parada/teleporte e paridade funcional.
- [x] Registrar a VS-18 planejada (migração para worker) no backlog.
- [x] Obter aprovação da spec. — aprovada pelo mantenedor em 2026-11-07.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-17-IMPL-01 — Sim do cursor** (AC-02). `tools/sim/streaming_sim.py`: espiral por distância, fatias por orçamento, geração×descarga por coordenada, reancoração; casos (movimento contínuo, parado, teleporte, pool esgotado).
2. **VS-17-IMPL-02 — Cursor + remoção do gatilho** (REQ-STR-01/02/04; AC-01/02). Estado no `VoxelEngine`, avanço por orçamento no update, zona Tracy `streaming_slice`, remoção do branch de mudança de chunk.
3. **VS-17-IMPL-03 — Fusão promote+publish** (REQ-STR-03; AC-03). Passada única, semântica do ring inalterada.
4. **VS-17-IMPL-04 — Evidências e fechamento** (AC-01..03). Captura Tracy comparada ao baseline, sessão de paridade, docs (spec, arquitetura §2, manual, tracking) e commit com o nome da spec.

## Questões abertas

- Resolvido: orçamento **6 ms**, tick a cada **64 coordenadas**; descargas da reancoragem entram em `pending_unload` e consomem o mesmo orçamento.
- A VS-18 (migração para worker) é spec própria após esta — o desenho (worker dona do mapa, publish pipelined) fica no backlog.

## Histórico

- 2026-11-07 — Rascunho elaborado a partir da análise da captura `tracy_view_22.tracy` (streaming_update = 7,48 s nos spikes; claim_batch 6,0 s esperando; promote+publish 4 ms/frame em duas passadas); sequenciamento VS-17→VS-18 aprovado pelo mantenedor; spec submetida à revisão.
- 2026-11-07 — **Spec aprovada** pelo mantenedor; tarefas VS-17-IMPL-01..04 destravadas.
- 2026-11-08 — **Implementação concluída e ACs verificados.** Cursor de offsets do cubo de unload ordenado por distância, 6 ms/64 coords, fila de descarga orçada na reancoragem; gatilho por chunk removido e promote+publish fundidos. Baseline: 41 spikes >30 ms/9,1 s, `streaming_update` 7,48 s em 16 chamadas, `claim_batch` p99 185,46 ms. Depois: zero frames >50 ms após aquecimento, frame máx 42,09 ms, slice p99 8,32 ms, claim p99 9,31 ms; publish mediano 2,40 ms (antes publish+promote ~3,78 ms medianos somados). Paridade E1/teleports/EMPTY e full teardown sem VUIDs; sims `render=2930`, `pack=1077`, `mirror=53`, `heightmap=13` e `streaming_sim` sem falhas.
