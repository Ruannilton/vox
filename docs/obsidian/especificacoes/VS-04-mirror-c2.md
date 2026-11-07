---
id: VS-04
titulo: Mirror C2
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-03
bloqueada_por: []
requisitos: [REQ-MIRROR-01, REQ-MIRROR-02, REQ-MIRROR-03, REQ-MIRROR-04, REQ-MIRROR-05, REQ-MIRROR-06, REQ-MIRROR-07, REQ-MIRROR-08, REQ-MIRROR-09, REQ-SIM-05]
ultima_atualizacao: 2026-11-05
---

# VS-04 — Mirror C2

## Objetivo

Manter uma view densa do mundo em RAM para consultas de gameplay (física, IA, ferramentas, saves), materializada pelo export direto do generate para um ring host-visible e atualizada pelo mesmo journal de E1 — sem criar uma segunda autoridade do mundo: a verdade é worldgen + journal, e GPU (packed) e RAM (denso) são views materializadas dessa mesma fonte, convergindo por construção.

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 7 (C2)](../../arquitetura.md) e [Manual Técnico — C2](../../manual-tecnico.md).
- Referência: `MirrorManager`, `MirrorChunkPage`, `mirror_*`, `voxel_get`/`voxel_is_solid`/`mirror_column_ground`, export no binding 16 e lotes `export_only` em `docs/examples/`.
- Decisões: [[ADR-E1-edicao-bufferizada|ADR-E1]] e [[ADR-C2-mirror-cpu|ADR-C2]]; a regra 7 do AGENTS.md (layout y-contíguo do mirror vs x-contíguo do scratch) é contrato desta fatia.
- Fundação: [[VS-03-edicao-e1|VS-03]] fornece o journal com flush, rings 13/14/15 e o feedback de rejeições; [[VS-01-streaming-generate-pack|VS-01]] fornece o ciclo de vida B1 dos slots e o handler de conclusão de lotes; `storageBuffer16BitAccess` já é habilitado e exigido na seleção do dispositivo (VS-00).

## Requisitos

### Páginas e bolha de simulação

- **REQ-MIRROR-01** — Pool fixo de `MIRROR_PAGE_POOL_SIZE = 768` páginas (~50 MiB; a bolha raio 5 tem ~523 chunks), endereços estáveis (pool em array + mapa coord→ponteiro). `MirrorChunkPage` ≈ 68,1 KiB: cabeçalho (`coord`, `edit_seq`, `state`, `ring_slot`, `pending`, `applied_log`) + bitmask `solid[1024]u32` (4 KiB, derivado de `id != 0` — mesma regra da ocupação) + `ids[32768]u16` **denso, sem paleta** (elimina divergência de paleta; chunks em `PALETTE_OVERFLOW` permanecem representáveis). Layout **y-contíguo**: `idx = y | z<<5 | x<<10` (coluna vertical = 64 B = 1 linha de cache) — nunca misturar com o layout x-contíguo do scratch/denso GPU (regra 7).
- **REQ-MIRROR-02** — Bolha de simulação independente da bolha de render: `RADIUS_SIMULATION = 5` chunks ao redor da câmera. Chunk da bolha sem página → `mirror_request_page` (acopla export à geração pendente ou agenda re-export); página cujo chunk saiu da bolha → evicção (`mirror_forget_chunk`/`mirror_page_release`); `mirror_request(chunk)` puxa página sob demanda (não bloqueia). Pool cheio → miss contabilizada e nova tentativa nos frames seguintes.

### Export direto e ring

- **REQ-MIRROR-03** — Ring de export host-visible no **binding 16**: 64 slots × 64 KiB (4 MiB) de `u16` denso y-contíguo. O `generate_voxels` ganha saída secundária: se `job.mirror_ring_slot >= 0`, cada voxel também é gravado no ring (a escrita do shader É o readback — write-combining sequencial, sem pool device-local nem `vkCmdCopyBuffer`). O scratch denso continua x-contíguo; só o export usa o índice y-contíguo.
- **REQ-MIRROR-04** — Disciplina do ring (regra 4 do AGENTS.md): slots reservados pela thread principal; **slot em voo só é liberado pelo handler de conclusão** (a GPU pode estar escrevendo); `mirror_ring_release` só vale para exports ainda não submetidos (tarefas em `pending_tasks`/`pending_export_tasks` canceladas pelo descarregamento). Anti-ABA por (coordenada, geração) em reserva, liberação e materialização.

### Materialização e estados

- **REQ-MIRROR-05** — Estados da página: `PENDING_READBACK` (export em voo ou aguardando slot; leitura = desconhecido) → `MATERIALIZED` (aberta a consultas). O handler de conclusão de lote, para cada task com `mirror_ring_slot >= 0`: valida anti-ABA completo (página viva com o mesmo `ring_slot`, entrada do ring casa (coord, geração), chunk ativo com mesma (slot, geração) e fora de `GENERATING`), faz o acquire de host por `WaitSemaphores(0)` sobre o valor do lote (visibilidade das escritas do compute; `GetSemaphoreCounterValue` não é sincronização), copia ring→página reconstruindo o bitmask, faz o **replay das edições retidas em `page.pending`** (o export contém só worldgen) e abre a página (`edit_seq += 1`). Export vencido (página evicta, chunk recriado, geração não bate) → descarta e libera o slot.
- **REQ-MIRROR-06** — Re-export `export_only`: chunk já `CACHED`/`RENDERABLE` sem slot de ring agenda uma tarefa `export_only` na fila separada `pending_export_tasks` (1 por lote, antes do dreno normal — não morrem de fome), que **nunca roda o pack** (repackar a partir do scratch — só worldgen — apagaria as edições já aplicadas no packed; regra do AC-03). O scratch do slot é sobrescrito pelo generate, o que é seguro por ser transitório. `mirror_service_retries` roda todo frame após o handler de conclusão: páginas `PENDING` sem slot tentam acoplar-se à geração pendente ou agendar re-export.

### Journal e consultas

- **REQ-MIRROR-07** — Dual-apply: toda edição staged no flush do E1 alimenta também o mirror (`mirror_journal_apply` no ponto de staging do flush — mesma ordem, mesmo dedup, mesmo teto; convergência por construção). Página `PENDING_READBACK` retém a edição em `page.pending` (dedup última-escrita-vence) para o replay da materialização; página `MATERIALIZED` aplica direto (`ids` + bitmask, `edit_seq += 1`) e registra em `applied_log` (para a reconciliação). Chunks fora da bolha não têm página: só a GPU recebe o journal (pendências do E1 seguem o ciclo normal deles).
- **REQ-MIRROR-08** — API tri-state (thread principal): `voxel_get(world_voxel) -> (VoxelSample{block_id: u16, solid: bool}, ok)` — `ok=false` = **desconhecido** (chunk sem página ou `PENDING_READBACK`); a política do desconhecido (bloquear, chutar, aguardar) é do consumidor. `voxel_is_solid` deriva de `voxel_get`. `mirror_column_ground(world_x, world_z, y_from) -> (ground_y, ok)`: varredura colunar para baixo cruzando fronteiras de chunk; `ok=false` se atingir página desconhecida.
- **REQ-MIRROR-09** — Reconciliação de rejeições: no feedback do E1 (2 frames depois), cada código `REJECTED_*` é mapeado de volta a (chunk, voxel, bloco) pelos rings de jobs/edições do slot (ainda intactos na colheita). A página afetada agenda **re-export `export_only`** e, na rematerialização, faz replay do `applied_log` **sem** as edições rejeitadas — convergência exata com a GPU (que rejeitou e não aplicou). Página evictada não precisa reconciliar (a GPU não mudou; o mirror não existe). Caminho raro (só overflow de paleta), custo de um re-export por chunk afetado.

### Simulação

- **REQ-SIM-05** — Antes da integração, simulação Python em `tools/sim/mirror_sim.py` cobrindo: indexação y-contígua vs x-contígua (nunca misturadas), máquina de estados da página e do ring (reserva, liberação, anti-ABA, evicção com export pendente/em voo), replay de pendências na materialização, paridade bit a bit GPU↔mirror sobre a mesma sequência de journal (incl. rejeições reconciliadas) e a API tri-state (desconhecido nunca inventa bloco).

## Escopo

- Bolha de simulação independente (raio 5) e pool fixo de páginas.
- Export denso u16 y-contíguo direto para ring host-visible (binding 16), sem pool device-local.
- Materialização após timeline com acquire de host, replay de pendências e consultas tri-state.
- Dual-apply do journal e reconciliação de rejeições por re-export + replay do log.
- Retry, `export_only`, evicção e anti-ABA por coordenada/geração.
- Validação de paridade GPU↔mirror (debug: comparação bit a bit por chunk).
- Gancho de evidência por log: consultas `voxel_get`/`mirror_column_ground` em coordenadas conhecidas do cenário roteirizado da VS-03.

## Não escopo

- Física, navegação, IA e persistência de saves como consumidores completos do mirror (a API tri-state e o gancho `mirror_request` são o entregável).
- Truncamento/checkpoint do `applied_log` de páginas longevas (backlog de memória; o log cresce com as edições do chunk e é liberado na evicção).
- Persistência do journal em disco (permanece no não-escopo da VS-03).
- Política de consumidores para o desconhecido (cada sistema decide).

## Dependências

- [[VS-03-edicao-e1|VS-03]] concluída e verificada (journal, rings 13/14/15, feedback de rejeições, flush no frame).
- `storageBuffer16BitAccess` habilitado e exigido na seleção do dispositivo (VS-00); binding 16 hoje ocupado por dummy.
- [[ADR-E1-edicao-bufferizada|ADR-E1]] e [[ADR-C2-mirror-cpu|ADR-C2]] aceitas; não há bloqueio de decisão.

## Interfaces e recursos

### Contratos novos (common.slang, espelhados no Odin)

| Contrato | Layout | Observação |
| --- | --- | --- |
| Export do mirror | `mirror_export_ring[slot * 32768 + (y \| z<<5 \| x<<10)] = uint16_t(block_id)` | Binding 16, `RWStructuredBuffer<uint16_t>`; escrito pelo generate quando `mirror_ring_slot >= 0` |
| `mirror_index_from_coordinate` | `y \| z<<5 \| x<<10` | Y-contíguo — NUNCA misturar com `dense_index_from_coordinate` (x-contíguo), regra 7 |
| Constantes | `RADIUS_SIMULATION = 5`, `MIRROR_RING_SLOTS = 64`, `MIRROR_PAGE_POOL_SIZE = 768` | Odin (bolha/pool são CPU); o tamanho do slot do ring (64 KiB) é compartilhado |

### Recursos e proprietários

- **`MirrorManager`** (novo módulo `voxel_mirror.odin`, campo da `VoxelEngine`): pool de páginas, mapa coord→página, ring de export (64 entradas `used/coord/generation`), estatísticas — domínio exclusivo da thread principal, EXCETO `pending_export_tasks` e o attach em `pending_tasks` (sob `queue_mutex`, compartilhado com a worker).
- **Ring de export** (binding 16): 4 MiB host-visible + coerente (`HOST_ACCESS_RANDOM` + `InvalidateAllocation` antes da leitura — mesmo padrão do `edit_results`); escrito pelo generate na fila de compute; lido pela CPU no handler de conclusão após o acquire.
- **`pending_export_tasks`**: fila separada na `VoxelEngine` (sob `queue_mutex`); a worker embarca 1 por lote antes do dreno normal e **não** despacha o pack para lote `export_only`.

### Sequência do frame (integração)

```
ve_update (streaming + conclusões):
  handler de conclusão: para cada task com mirror_ring_slot >= 0 → mirror_materialize_from_ring
  mirror_service_retries() (páginas PENDING sem slot)
  gestão da bolha: evicta páginas fora do raio 5; pede páginas ausentes
flush do E1 (quando devido): edições staged alimentam também o mirror (REQ-MIRROR-07)
edit_ring_write: feedback com reconciliação de rejeições (REQ-MIRROR-09)
(resto do frame inalterado — o mirror nunca toca a fila gráfica)
```

### Comportamento quando limites são atingidos

- Ring cheio (64 exports em voo): chunk fica `PENDING` sem slot; `mirror_service_retries` tenta nos frames seguintes (`stats_ring_misses` conta).
- Pool cheio (768 páginas): `mirror_request_page` falha sem falhar o frame (`stats_pool_misses`); páginas voltam a ser pedidas quando a bolha se move e evicta.
- Chunk ausente/em geração na consulta: `ok=false` — o consumidor decide.
- Export vencido por anti-ABA: descartado no handler; a página (se ainda viva) é re-agendada pelo `mirror_service_retries`.
- Rejeição de edição com página evictada: nada a reconciliar (GPU inalterada, página inexistente).

## Cenários

### Materialização sem edições e com replay de pendências

- **Dado** um chunk entrando na bolha de simulação, sem e com edições staged durante o `PENDING_READBACK`.
- **Quando** o lote conclui (timeline) e o handler roda.
- **Então** a página abre `MATERIALIZED` com o worldgen (sem edições) ou com o replay exato das pendências retidas (dedup última-escrita-vence), bitmask de sólidos reconstruído e `edit_seq` coerente.

### Ring cheio, página fora da bolha e retry por `export_only`

- **Dado** 64 exports em voo (ring cheio) e um chunk já `CACHED` pedindo página.
- **Quando** frames passam e slots são liberados pelo handler.
- **Então** o chunk permanece `PENDING` sem slot até sobrar ring, e então um re-export `export_only` é agendado — sem pack, sem tocar o packed (edições preservadas), materializando em seguida.

### Evicção com export pendente e com export em voo

- **Dado** uma página `PENDING` cujo chunk sai da bolha (a) com export apenas agendado (não submetido) e (b) com export já submetido num lote em voo.
- **Quando** `mirror_forget_chunk` roda.
- **Então** em (a) a tarefa é removida e o slot liberado na hora (a GPU nunca o escreverá); em (b) o slot permanece reservado até o handler de conclusão descartar o export vencido (página ausente) — nenhum slot em voo é liberado fora do handler (regra 4).

### Conclusão vencida por coordenada/geração

- **Dado** um chunk descarregado em `GENERATING` e recriado no mesmo slot de GPU (geração nova) enquanto um export antigo ainda está em voo.
- **Quando** o lote antigo conclui.
- **Então** a validação por (coord, slot, geração) descarta o export vencido e libera o slot; a página nova (se houver) segue seu próprio export.

### Rejeição de edição pela GPU e reconciliação da página

- **Dado** um chunk materializado cujo flush teve uma edição rejeitada (`REJECTED_OVERFLOW`/`REJECTED_PALETTE_FULL`).
- **Quando** o feedback é colhido (2 frames depois).
- **Então** a página agenda re-export `export_only` e rematerializa com o replay do `applied_log` sem a edição rejeitada — bit a bit igual ao packed da GPU (que não a aplicou).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-04-AC-01 | O layout do mirror é y-contíguo e não é misturado ao scratch x-contíguo | Testes de indexação na simulação + paridade | Verificado — `mirror_sim.py`: 31 checks (permutação completa dos índices, coluna y contígua de 64 B, passos (1,1024) vs (1024,1) dos dois layouts); a paridade bit a bit (abaixo) só fecha com os layouts corretos |
| VS-04-AC-02 | Nenhum slot de ring em voo é liberado fora do handler de conclusão | Cenários anti-ABA e evicção na simulação | Verificado — `mirror_sim.py`: evicção com export em voo preserva a entrada (liberada só no descarte do handler), liberação local só vale para não-submetidos com checagem (coord, geração), conclusão vencida não materializa na página nova |
| VS-04-AC-03 | `export_only` nunca executa pack nem apaga edições do formato packed | Cenário de retry com edições na simulação + inspeção do caminho da worker | Verificado — `mirror_sim.py`: packed byte-idêntico após export_only com edições aplicadas; worker despacha o pack apenas em lotes normais (`if !export_only`), re-export embarca 1 por lote |
| VS-04-AC-04 | GPU e mirror convergem para a mesma sequência do journal | Paridade bit a bit em 163.840 voxels (5 chunks: worldgen + journal com rejeição reconciliada, decode packed vs página) | Verificado — simulação: 163.840 voxels paritários após 3 flushes × 200 edições × 5 chunks + reconciliação exata pós-rejeição; smoke test: `DEBUG MIRROR PARITY OK` nos chunks [0,1,0] e [1,1,1] (32.768 voxels cada, GPU == mirror após o flush roteirizado) |
| VS-04-AC-05 | Consultas ausentes/pendentes retornam desconhecido sem inventar bloco | Testes da API tri-state na simulação + log de consultas em coordenadas conhecidas no smoke test | Verificado — simulação: ok=false sem página e em PENDING, `column_ground` cruzando fronteiras; smoke test: ok=false em tick inicial (PENDING) e fora da bolha (9999,10,9999), amostras corretas na caixa esculpida (ar) e no pilar (pedra, id=3) |

## Tarefas da especificação

- [x] Vincular todos os requisitos do GOAL (REQ-MIRROR-01..09, REQ-SIM-05).
- [x] Formalizar estados, proprietários e timelines do ring.
- [x] Definir reconciliação e cenários de retry/evicção.
- [x] Especificar a simulação de paridade GPU↔mirror.
- [x] Submeter à revisão e obter aprovação. — aprovada pelo mantenedor em 2026-11-05.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação. Só entram na fila após a aprovação desta spec.

1. **VS-04-IMPL-01 — Contratos do mirror no `common.slang` + espelho Odin** (REQ-MIRROR-01/03; AC-01). `mirror_index_from_coordinate`, binding 16 (`RWStructuredBuffer<uint16_t>`), constantes; structs Odin (`MirrorChunkPage`, `MirrorRingEntry`, `MirrorPageState`, `VoxelSample`) e constantes de bolha/pool.
2. **VS-04-IMPL-02 — Simulação do mirror** (REQ-SIM-05; AC-01..05). `tools/sim/mirror_sim.py`: indexação, estados de página/ring, anti-ABA, evicção, retry, replay, reconciliação e paridade com o modelo packed da `edit_sim.py`.
3. **VS-04-IMPL-03 — Export no generate + ring do binding 16** (REQ-MIRROR-03; AC-01). Saída secundária u16 y-contígua no `generate_voxels`; buffer host-coerente de 4 MiB substituindo o dummy; descriptor e destroy.
4. **VS-04-IMPL-04 — MirrorManager** (REQ-MIRROR-01/02/04; AC-02, AC-05). `voxel_mirror.odin`: pool, páginas, ring, reserva/liberação, bolha (evicção/pedido/retry), `mirror_forget_chunk`.
5. **VS-04-IMPL-05 — Worker `export_only` + materialização** (REQ-MIRROR-05/06; AC-02, AC-03). Fila `pending_export_tasks`, 1 por lote sem pack; handler de conclusão com acquire de host, cópia ring→página e replay.
6. **VS-04-IMPL-06 — Dual-apply, reconciliação e API tri-state** (REQ-MIRROR-07/08/09; AC-04, AC-05). `mirror_journal_apply` no staging do flush, `applied_log`, reconciliação por re-export+replay, `voxel_get`/`voxel_is_solid`/`mirror_column_ground`/`mirror_request`.
7. **VS-04-IMPL-07 — Evidências e fechamento** (AC-01..05). Readback de paridade GPU↔mirror por chunk (debug), log de consultas em coordenadas conhecidas, estatísticas do mirror; atualizar tracking e commitar com o nome da spec.

## Questões abertas

- `MIRROR_PAGE_POOL_SIZE = 768` cobre a bolha raio 5 (~523 chunks) com ~47% de folga; se a bolha mudar, o pool acompanha. Não bloqueia a aprovação.
- O `applied_log` por página cresce com as edições do chunk e só é liberado na evicção; truncamento por checkpoint fica no backlog de memória. Não bloqueia a aprovação.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
- 2026-11-05 — Elaboração completa: 10 requisitos (MIRROR/SIM), contratos do mirror, sequência do frame, cenários e ACs; submetida à revisão do mantenedor.
- 2026-11-05 — **Aprovada pelo mantenedor**; tarefas VS-04-IMPL-01..07 destravadas.
- 2026-11-05 — Implementação concluída (IMPL-01..07): contratos do mirror no `common.slang` (`mirror_index_from_coordinate` y-contíguo, binding 16 `RWStructuredBuffer<uint16_t>`) + structs Odin; `tools/sim/mirror_sim.py` com 31 checks; export u16 direto no `generate_voxels`; ring host-coerente de 4 MiB no binding 16; `MirrorManager` em `voxel_mirror.odin` (pool de 768 páginas, ring com regra 4, bolha raio 5, evicção/retries); worker com fila `pending_export_tasks` (1 por lote, sem pack) e materialização no handler de conclusão com acquire `WaitSemaphores(0)` + `InvalidateAllocation`; dual-apply no flush, reconciliação por re-export + replay do `applied_log` filtrado e API tri-state (`voxel_get`/`voxel_is_solid`/`mirror_column_ground`/`mirror_request`).
- 2026-11-05 — Ajuste na fundação: o SPIR-V do export u16 declara as capabilities `Int16` e `UniformAndStorageBuffer16BitAccess`, que não estavam habilitadas — a cadeia de features do dispositivo passou a exigir e habilitar `shaderInt16` (núcleo) e `uniformAndStorageBuffer16BitAccess` (Vulkan 1.1), além da já presente `storageBuffer16BitAccess` (revisão do contrato da VS-00 registrada aqui; seleção do dispositivo agora rejeita GPUs sem elas).
- 2026-11-05 — Validação verificada: evidências nos ACs acima. Notas: o smoke test rodou com o terreno de ruído do mantenedor (worldgen FastNoiseLite não commitado nesta fatia); `column_ground(32,32)` respondeu y=55 = topo do pilar de pedra da edição roteirizada da VS-03 — evidência ponta a ponta de que o journal converge no mirror; o `debug_readback_validate` da VS-01 segue falhando por comparar com a verdade do mundo plano (pendente de decisão do mantenedor); estatísticas estáveis: 515 páginas vivas (pool 768, zero misses), ring misses acumulados só durante o preenchimento inicial (retry por construção).
- 2026-11-06 — **Correção do `debug_readback_validate` (débito técnico flagado na VS-12).** Defeito: a checagem de mundo comparava o readback packed contra um modelo de mundo CPU de estratos planos (y<0/==0/==1), defasado desde que o worldgen virou noise-based — 32.768/32.768 divergências garantidas. Restrição (C2, Etapa 7): a CPU não pode reproduzir o worldgen GPU bit a bit (sem determinismo de ponto flutuante idêntico CPU↔GPU), então não se reimplementa ruído na CPU. Correção (opção (a)): a seleção de chunk passou a preferir chunks com página `MATERIALIZED` na bolha de simulação, e a comparação de conteúdo decodifica o readback packed (ocupação/paleta/planos) e confronta voxel a voxel com o grid denso u16 do mirror (`page.ids`, índice y-contíguo regra 7) + bitmask `page.solid` — ambos derivados do mesmo scratch GPU, então devem casar; o decode é o mesmo espelhado bit a bit por `tools/sim/pack_sim.py` offline. Sem página MATERIALIZED (chunk fora da bolha), mantêm-se apenas invariantes estruturais (palette[0]==0) com log justificando o pulo. Evidência (smoke 40 s, instrumentação temporária de chamada única em `main.odin`, revertida): `DEBUG READBACK OK: chunk [1, 0, 2] slot 13026 — packed == mirror denso (32768 voxels, 32768 sólidos, paleta 3, planos 2, flags 0)`; templates/UVs seguem OK (`== assets JSON`); zero VUIDs novos. Sims `render_sim.py` (2.906) e `pack_sim.py` (968) verdes; `odin build` OK.
