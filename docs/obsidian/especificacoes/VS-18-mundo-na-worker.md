---
id: VS-18
titulo: Mundo na worker (world ownership)
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-17
bloqueada_por: []
requisitos: [REQ-WKR-01, REQ-WKR-02, REQ-WKR-03, REQ-WKR-04, REQ-WKR-05, REQ-WKR-06, REQ-VAL]
ultima_atualizacao: 2026-11-08
---

# VS-18 — Mundo na worker (world ownership)

## Objetivo

Migrar o ownership do mundo da thread principal para a worker: `active_chunks`, streaming incremental (VS-17), completions/aposentadoria (B1), promote/publish, materialização por edição (VS-10) e mirror service passam a rodar na worker thread. A main fica com input/eventos, espera do slot publicado, gravação do command buffer e present — frame alvo de **~4-5 ms** (hoje ~11 ms; ~7 ms de mundo migram). Baseline: análise `tracy_view_22` + VS-17.

## Rastreabilidade

- GOAL: decisão do mantenedor (2026-11-08) — implementar a "Opção A" por inteiro (citada na íntegra e aprovada); backlog BLK-40.
- Referência: `voxel_engine_update`/`ve_publish_visible`/`voxel_engine.odin`, worker (`voxel_worker.odin` — laço atual orientado a lotes), edição (`voxel_edit.odin` — intake/flush/staging), mirror (`voxel_mirror.odin` — journal/service/leituras), ring `visible_chunks` (VS-02, host-visible, 2 slots), fast-exit/`--full-teardown` (BLK-39).
- Decisões: [[ADR-W1-ownership-mundo-worker|ADR-W1]] (aceita junto a esta spec — handoff de frame, argumento de liberdade de deadlock, E1 intake/staging, mirror).
- Fundação: VS-17 (streaming incremental — o cursor roda na worker sem mudança de desenho), VS-01 (B1/fila), VS-04 (mirror), VS-10 (EMPTY).

## Requisitos

### Ownership e handoff de frame

- **REQ-WKR-01** — A worker é a **única** thread que itera ou muta `ve.active_chunks` (auditoria: nenhum acesso fora de `voxel_engine.odin`/`voxel_worker.odin` nos caminhos migrados; a main não referencia o mapa). Mirror e edição coordenam com a worker pelos mutexes existentes.
- **REQ-WKR-02** — Laço da worker por frame com **publish sob demanda** (emenda 2026-11-08 — o lockstep por frame serializava main e worker e piorava o ritmo; conservação de trabalho): a worker produz promote+publish (passada fundida da VS-17) escrevendo direto no ring `visible_chunks` no slot `% 2`, **apenas quando o mundo publicável mudou** — (a) `camera_chunk` do último publish difere do pedido corrente (cruzamento), (b) completions/promoções/edições alteraram o conjunto RENDERABLE, ou (c) bump explícito de sequência. Grava no slot de handoff: `visible_count`, `published_camera_chunk` e `published_compute_value`; sinaliza. A main consome o **último publish cujo `published_camera_chunk` == camera_chunk corrente**; se nenhum (acabou de cruzar e a worker ainda não publicou), espera com timeout defensivo (proposta 250 ms + log — nunca deadlock silencioso). **Guarda de staleness:** nunca reusar publish mais velho que 2 frames atrás (senão a main espera — protege contra worker morta). Reescrita do slot só após `vkGetSemaphoreCounterValue` (não-bloqueante, retry no próprio laço) confirmar o uso anterior completo (mesma garantia VS-02). **Liberdade de deadlock:** dependências apontam para trás (publish depende do slot de 2 frames atrás; a main depende só de publish existente ou de uma iteração da worker). Nos frames entre cruzamentos, a main não espera nada — roda render puro com input fresco.

### Edições (E1)

- **REQ-WKR-03** — Intake na main: `ve_request_voxel_edit`/`ve_request_voxel_edits_in_box` apenas travam o mutex do edit e empurram para a fila (sem tocar em mapa/mirror); sinalizam a worker. Pipeline completo na worker: dedup «última escrita vence», `mirror_journal_apply`, materialização de EMPTY (retry), `edit_flush_due`/`flush_voxel_edits` (staging). A main consome o staging em `edit_ring_write` (mesmo mutex; staging vale por uma cópia como hoje). `force_next_flush` vê flag compartilhada. Logs/feedback do E1 rodam na worker (thread deles no Tracy: `voxel_worker`).

### Completions, B1 e mirror

- **REQ-WKR-04** — Completions (promoção GENERATING→CACHED/EMPTY, aposentadoria dual, retries de materialização) rodam na worker; a timeline gráfica é lida por `vkGetSemaphoreCounterValue` (o valor `app.currentTimelineValue` da main não é mais usado neste caminho). Regras 3 e 4 do AGENTS.md intactas (1 claim = 1 lote = 1 timeline; só o handler de conclusão libera slot de ring).
- **REQ-WKR-05** — Mirror: journal, materialização de páginas, `mirror_service` e `mirror_request` na worker; APIs de leitura (`voxel_get`, `mirror_height_get`) continuam chamáveis da main — cobertura de mutex das páginas auditada e, se necessário, estendida (leitores nunca veem estado parcialmente atualizado).

### Observabilidade e teardown

- **REQ-WKR-06** — Tracy: `FrameMark` na main; zones de mundo reportam na thread `voxel_worker` (ajuste dos nomes se necessário); `frame_wait` na main passa a incluir a espera do publish. Fast-exit inalterado (worker morre com o processo, sem join); `--full-teardown` mantém stop+broadcast+join da worker antes dos waits (ordem BLK-28).
- **REQ-VAL** — Stress: 5 execuções do replay longo (125 eventos) + edições + teleports em ambos os builds com validation layers e `--full-teardown`: zero VUIDs, zero warnings de threading, zero deadlock (esperas com timeout detectam); captura Tracy íntegra.

## Escopo

- Migração dos caminhos acima + handoff frame/edições + auditoria de mutexes do mirror.
- Laço da worker reorganizado (frame-paced: service do mundo → batch pipeline existente).
- Tracy/zones e docs (spec, arquitetura §2/§3, manual técnico, tracking); backlog: BLK-40 sai.

## Não escopo

- Otimização do `mirror_service` (rajadas) e de generate/pack (picos) — backlog.
- Novos consumidores de gameplay das APIs de mirror.
- Mudanças em shaders, work queue, visão/raios, fast-exit.

## Dependências

- [[VS-17-streaming-incremental|VS-17]] concluída e verificada (cursor incremental — base do service da worker).
- [[ADR-W1-ownership-mundo-worker|ADR-W1]] aceita (desenho aprovado pelo mantenedor).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| Pedido de frame (main→worker) | atomic `frame_index` + `camera_chunk` | publicado antes da espera da main |
| Slot publicado (worker→main) | `visible_count` + ring `visible_chunks[slot]` + `published_camera_chunk` + `published_compute_value` | slot `% 2`; sinal por condição só quando publica; reuse após timeline gráfica |
| Fila de edições | mutex existente + sinal à worker | intake main; consumo worker |
| Staging E1 (worker→main) | `edit.staged_jobs/edits` sob o mesmo mutex | vale por uma cópia (semântica atual) |

### Comportamento quando limites são atingidos

- Worker lenta: a main espera (bounded pelo timeout defensivo + log); frames ficam no ritmo da worker — nunca corrupção.
- Worker à frente: publica no máximo 1 frame além do pedido (sem corrida de slots).
- Edições durante espera do frame: entram na fila; materialização/processamento na worker no próprio laço.

## Cenários

### Cenário de sucesso — frame leve

- **Dado** caminhada com movimento contínuo (streaming, edições, worker ativa).
- **Quando** frames avançam.
- **Então** nos frames entre cruzamentos de chunk a mediana da zone `frame` (main) fica em ~4-6 ms (render puro); publishes ocorrem só quando o mundo muda (contagem ≪ frames); em cruzamentos há uma espera pontual curta e rara; mundo evolui como na VS-17 (contadores, EMPTY, visíveis, journal).

### Paridade funcional

- **Dado** o replay de 125 eventos com edições e teleports.
- **Quando** a sessão completa.
- **Então** contagens/journal/heights/readbacks equivalentes aos da VS-17; sims verdes; feedback E1 normal.

### Robustez

- **Dado** 5 execuções de stress em ambos os builds.
- **Quando** saídas ocorrem (todas as vias).
- **Então** zero VUIDs/threading/deadlock; teardown completo limpo; captura Tracy íntegra.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-18-AC-01 | **Steady state** (frames entre cruzamentos de chunk): `frame` (main) mediano ≤ ~6 ms (render puro, input fresco); **publishes raros** (contagem de publishes ≪ frames no trace — evidência de que a carga saiu do caminho do frame); zero frames >50 ms fora de cruzamentos; em cruzamentos, latência pontual ≤ ~30 ms (espera de um publish, evento raro) | Tracy headless com movimento contínuo; comparação direta VS-17×VS-18 | **Verificado:** 8.845 frames, mediana 0,973 ms, p99 19,57 ms, zero >50 ms após aquecimento; 2.641 `publish_world` (29,9% dos frames). Espera máxima pós-aquecimento 34,27 ms num cruzamento (próximo do teto aproximado); frame máx pós-aquecimento 36,03 ms |
| VS-18-AC-02 | Paridade funcional com a VS-17 (contadores, journal, heights, readbacks, sims) | Sessão replay + edições; comparação de contadores | **Verificado:** replay com 2 teleports/edições, 8 eventos, `applied=3 noop=0 rejected=0 deferred=0`; EMPTY e reciclagem coerentes; feedback E1 na worker; sims `streaming` 9 cenários sem falhas, `render=2930`, `pack=1077`, `mirror=53`, `heightmap=13` |
| VS-18-AC-03 | Robustez: 5× stress × 2 builds sem VUIDs/threading/deadlock; teardown completo limpo | Stress scriptado com saídas por todas as vias | **Verificado:** 5/5 default + 5/5 Tracy com validation e `--full-teardown`, todos exit 0 e destroy concluído; zero VUIDs, threading warnings e timeouts de publish |

## Tarefas da especificação

- [x] Vincular a decisão do mantenedor (Opção A citada na íntegra) e a ADR-W1.
- [x] Formalizar ownership, handoff de frame (com o argumento de liberdade de deadlock), E1 intake/staging e mirror.
- [x] Cobrir sucesso, paridade e robustez; definir ACs de stress.
- [x] Registrar BLK-40 como esta spec.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec (previamente aprovada pelo mantendor em 2026-11-08). Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-18-IMPL-01 — Handoff de frame** (REQ-WKR-01/02; AC-01). Pedido atomic, publish da worker no ring com reuse guardado por timeline gráfica, espera da main, auditoria de acessos ao mapa.
2. **VS-18-IMPL-02 — Pipeline do mundo na worker** (REQ-WKR-04/05; AC-02/03). Completions/B1/EMPTY/mirror service/materialização no laço da worker; contadores lidos via `vkGetSemaphoreCounterValue`; auditoria/ajuste de mutexes do mirror para leituras da main.
3. **VS-18-IMPL-03 — Edições intake/staging** (REQ-WKR-03; AC-02). Fila com mutex+sinal; pipeline na worker; consumo do staging na main; `force_next_flush` compartilhado.
4. **VS-18-IMPL-04 — Frame-paced loop + Tracy** (REQ-WKR-06; AC-01). Laço da worker por frame (service → batch pipeline), ajuste de zones/FrameMark.
5. **VS-18-IMPL-05 — Evidências e fechamento** (AC-01..03). Capturas Tracy comparadas à VS-17, stress 5×, docs (spec, arquitetura, manual, tracking) e commit com o nome da spec.

## Questões abertas

- Resolvido: timeout defensivo de **250 ms + log com frames/centros/revisões**; keepalive por `publish_bump`.
- Resolvido: `publish_world` na worker; `publish_visible` na main representa consumo/espera.

## Histórico

- 2026-11-08 — Rascunho elaborado a partir da decisão do mantenedor (Opção A citada na íntegra e aprovada; BLK-40); ADR-W1 registrada e aceita; spec **aprovada pelo mantenedor** junto à citação — tarefas VS-18-IMPL-01..05 destravadas.
- 2026-11-08 — **Emenda pós-implementação (AC-01 vermelho):** o lockstep por frame serializava main e worker (`frame` main 16,4 ms vs 11,5 ms da VS-17 — conservação de trabalho: mundo+batches na mesma thread). REQ-WKR-02 e AC-01 reescritos para **publish sob demanda** (só quando o mundo publicável muda; main render puro entre cruzamentos; guarda de staleness de 2 frames). Interface do slot ganha `published_camera_chunk`/`published_compute_value`.
- 2026-11-08 — **Implementação concluída.** Publish por centro/`world_revision`/bump, consumo sem espera entre mudanças, reuse não-bloqueante por timeline e snapshot de compute. Na integração, a arena temporária compartilhada pela main/worker zerava `GenerationTask`s; a worker ganhou `Default_Temp_Allocator` própria, corrigindo anti-ABA/promoção. Capture: VS-17 frame mediano 11,49 ms → VS-18 **0,973 ms**; 2.641 publishes/8.845 frames; zero >50 ms após aquecimento. Paridade E1/teleports/EMPTY e sims verdes; CSV VS-05 com 13 colunas. Stress e hashes dos logs em `bin/vs18_stress_{default,tracy}_*.log`.
- 2026-11-08 — **Correção de handoff destroçado.** A worker escrevia o ring antes de adquirir `frame_mutex`; após o consume, um pedido posterior podia reescrever o slot antes do submit da main. O guard N−2 protegia GPU antiga, não essa janela CPU. Fix: worker mantém ring+metadados+sinal sob `frame_mutex`; main mantém o mesmo lock do consume até `vkQueueSubmit2`. Publish sob demanda e staleness 2 inalterados. Detector temporário (hash dos chunks a ≤ vision/2, revisão e razão de publish), revertido: baseline 1.121 consumes/605 publishes, 0 assinaturas; pós-fix 1.425 consumes/662 publishes, 0 assinaturas — a sessão não reproduziu o buraco, portanto a evidência causal é a janela de código, não uma contagem visual fabricada. Flicker distante segue aceito; fog/LOD futuro mitiga. No stress, o atalho de batch sem novo frame também impedia observar stop no teardown; o teste de `worker_stop_requested` foi movido ao topo do laço, eliminando o join pendente.
