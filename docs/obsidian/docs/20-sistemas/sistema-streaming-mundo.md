---
id: SISTEMA-STREAMING-MUNDO
titulo: Streaming e mundo
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Streaming e mundo

Como o mundo de chunks 32³ é materializado, mantido e descarregado — e por quê. Este documento é a visão de **Sistema**: para o quadro macro das três threads e do pipeline de um frame, ver [[visao-geral]]; para os contratos struct-a-struct de `voxel_engine.odin`/`voxel_worker.odin`, ver [[ref-voxel-engine-worker]]. Decisões de desenho: specs [[VS-01-streaming-generate-pack|VS-01]], [[VS-08-config-ini-provisionamento|VS-08]], [[VS-10-chunks-vazios-virtuais|VS-10]], [[VS-17-streaming-incremental|VS-17]], [[VS-18-mundo-na-worker|VS-18]]; ADRs [[ADR-B1-ciclo-vida-slots|B1]], [[ADR-B5-capacidade-streaming|B5]], [[ADR-C1-config-ini-provisionamento|C1]], [[ADR-W1-ownership-mundo-worker|W1]].

## Ownership: a worker é dona do mundo

Desde a VS-18, **a worker thread (`voxel_worker.odin`) é a única que itera ou muta o mapa de chunks** (`VoxelEngine.active_chunks`, `voxel_engine.odin:61`). O serviço do mundo inteiro roda no laço da worker, em `worker_service_frame` (`voxel_worker.odin:229`), disparado pelo pedido de frame da main (`voxel_engine_request_frame`): completions/B1, avanço do cursor de streaming, materialização por edição, mirror service e produce do publish. A main fica com input/eventos, espera do publish, gravação do command buffer e present — o que tirou o frame da main de ~11,5 ms (VS-17) para mediana ~1 ms (VS-18). A migração foi a Opção A do [[ADR-W1-ownership-mundo-worker|ADR-W1]], motivada pela captura `tracy_view_22`: a main carregava ~7 ms/frame de trabalho de mundo.

Consequência direta: os comentários de domínio no `VoxelEngine` que ainda dizem "thread principal" descrevem o pré-VS-18; o código atual executa tudo isso na thread `voxel_worker`. As leituras da main no mundo passam por dois únicos caminhos: o mirror (mutexes de página, [[sistema-mirror-fisica]]) e o publish (abaixo).

## O mapa de chunks e seus estados

`active_chunks` é um `map[ChunkCoordinate]ChunkRecord` (`voxel_engine.odin:61-69`). Cada registro carrega `state`, `storage_slot_index` e `generation`. A máquina de estados (`voxel_engine.odin:15-20`):

```
(UNLOADED) → GENERATING → CACHED ⇄ RENDERABLE
                  │
                  └→ EMPTY   (VS-10: ar puro, registro sem slot)
```

- **GENERATING** — registro criado pelo cursor com um slot claimado; a tarefa está pendente ou num lote submetido. Nunca é publicado.
- **CACHED** — chunk materializado fora da bolha de visão (retido por histerese até o raio de descarga).
- **RENDERABLE** — dentro da bolha de visão; elegível ao publish.
- **EMPTY** — chunk de ar puro descoberto na geração (VS-10): vive no map **sem slot** (`storage_slot_index` inválido), nunca é publicado, nunca despacha builder. Unload além do raio = deletar o registro, sem aposentadoria GPU. Edição com bloco ≠ ar materializa o chunk de volta (geração + mecanismo de pendências E1, com retry por update se o pool estiver seco).

A transição CACHED⇄RENDERABLE acontece numa única passada fundida com o publish (`voxel_engine_publish_visible`, `voxel_engine.odin:308` — REQ-STR-03 da VS-17: antes eram duas varreduras de ~40 mil entradas por frame).

## Cursor espiral incremental com orçamento

O streaming não tem mais gatilho de "câmera mudou de chunk". Em vez disso, um **cursor em espiral persistente** (`StreamingCursor`, `voxel_engine.odin:51-57`) consome o espaço de chunks centrado na câmera:

1. **Geração e descarga fundidas numa única espiral** (VS-17): os offsets do cubo de `radius_unload` são pré-ordenados uma vez por distância quadrada crescente (`streaming_cursor_init`, `voxel_engine.odin:391` — desempate determinístico por x,y,z). A cada coordenada da fatia: dentro da esfera de geração e ausente do map → claim de slot + tarefa de geração; fora da esfera de descarga e presente → descarga. Fundir os dois laços eliminou os spikes de 312–746 ms do handler de mudança de chunk (16 chamadas somando 7,5 s na captura baseline) — com laços separados, cada cruzamento varria o map inteiro + a esfera inteira sincronamente.
2. **Orçamento de tempo, não de iterações** (REQ-STR-04): `STREAMING_SLICE_BUDGET_MS = 6,0` ms por fatia, com tick a cada 64 coordenadas — e a cada descarga, após o SHIFT-flight da VS-18 (descargas da reancoragem dominavam o slice). Estourado o orçamento, o cursor suspende e retoma no próximo pedido de frame; o estado persiste no `VoxelEngine`.
3. **Reancoragem ao fim do ciclo**: completada a espira, os chunks fora do raio de descarga entram em `pending_unload` (descarga orçada, consumida antes da espira) e o cursor reancora no `camera_chunk` atual (`streaming_cursor_advance`, `voxel_engine.odin:462-470`). Com a câmera parada, os ciclos ficam baratos e o custo por frame tende a zero.
4. **Prioridade de graça** (REQ-STR-02): não existe cota especial para a vizinhança da câmera — a fila de tarefas é puxada pela worker em ordem de distância, então o chunk sob a câmera gera primeiro naturalmente.

## Fila priorizada por distância e lotes de compute

Tarefas novas vão para `pending_tasks` sob `queue_mutex` (`voxel_engine.odin:476-481`). A worker, em `worker_thread_process` (`voxel_worker.odin:9`), faz o **claim do lote na mesma seção crítica** em que retira as tarefas da fila (REQ-SYNC-01): escolhe as até `chunks_per_batch` tarefas mais próximas de `priority_camera_chunk` por varredura linear (VS-01 registrou a heap para o backlog de performance) e publica o `SubmittedBatch` em `submitted_batches` — invariante: toda tarefa está em exatamente um dos conjuntos {pendente, submetida}.

**1 claim = 1 lote = 1 valor de timeline** (regra 3, ADR-B1): o valor do lote é `submitted_batch_count + 1`, publicado no claim e sinalizado no `vkQueueSubmit2` — deterministicamente iguais. **No máximo 3 lotes em voo** (`config.batches_in_flight`, ADR-B4/B5): antes de regravar a posição `lote % 3` do ring de jobs/scratch, a worker espera a timeline do lote de 3 atrás (`wait_batch_slot`, `voxel_worker.odin:89-93`) — backpressure natural. Um lote = um command buffer de compute com generate `(4,4,4·N)` → barreira → pack `(N,1,1)` (ou só generate, nos lotes `export_only` do mirror) e um único submit na fila de compute. Detalhes do que a GPU executa: [[sistema-renderizacao]].

## Completions e aposentadoria dual (B1)

Só o handler de conclusão libera slot — nunca o unload direto (regra 4, ADR-B1). `voxel_engine_service_completions` (`voxel_engine.odin:200`) lê o contador da timeline de compute **sem bloqueio** (`vkGetSemaphoreCounterValue`) e, para cada lote com valor ≤ contador, promove GENERATING → CACHED/RENDERABLE (validando coord+slot+geração, abaixo) e materializa o export do mirror. Depois drena as duas filas de aposentadoria:

- **`retiring_compute_slots`** — slot de chunk descarregado ainda em GENERATING cujo lote já foi submetido: liberado quando a timeline de **compute** do lote avança.
- **`retiring_slots`** — slot de chunk CACHED/RENDERABLE descarregado: liberado quando a timeline **gráfica** avança.

Os três caminhos de `retire_generating_slot` (`voxel_engine.odin:527`): (a) tarefa ainda pendente → cancela e libera na hora; (b) já submetida → aposenta pela timeline do lote; (c) defensivo → libera na hora.

**Anti-ABA**: cada alocação incrementa `slot_generations[slot]`; conclusões e cancelamentos só valem se `task_matches` (`voxel_engine.odin:130`) confirmar coordenada + slot + geração contra o registro ativo — uma conclusão vencida nunca promove (nem esvazia) o chunk novo que reutilizou o slot.

**Chunks EMPTY virtuais** (VS-10): o pack escreve as flags de cada chunk em `chunk_result_flags` (binding 18, host-visible, indexado por slot). Na conclusão — mesma ordenação de timeline, mesmo anti-ABA —, `CHUNK_FLAG_EMPTY` sem edições pendentes → estado EMPTY e slot devolvido ao pool **no instante da conclusão**. O publish publica só CACHED/RENDERABLE com slot; vizinho EMPTY/GENERATING vira `NEIGHBOR_SLOT_INVALID`, que o shader já trata como ar ([[ADR-B2-fronteiras-chunks|B2]]) — render idêntico, zero mudança de shader.

## Handoff: publish sob demanda

A main nunca espera uma rodada inteira da worker (emenda pós-implementação da VS-18 — o lockstep por frame serializava as threads e piorou o ritmo). O handoff é por **conservação de trabalho** (`voxel_engine_wait_published`, `voxel_engine.odin:292`; `worker_service_frame`, `voxel_worker.odin:229`):

- **Pedido (main→worker)**: `requested_frame` + `camera_chunk` + `frame_index` sob `frame_mutex`, todo frame.
- **Publish (worker→main)**: a worker produz promote+publish escrevendo direto no ring `visible_chunks` no slot `% 2` **apenas quando o mundo publicável mudou** — (a) `published_camera_chunk` difere do pedido corrente, (b) `world_revision` mudou (completions/edições alteraram o conjunto), ou (c) `publish_bump` explícito (a main pede keepalive quando o publish ficou velho). A reescrita do slot só ocorre após `vkGetSemaphoreCounterValue` não-bloqueante confirmar que o uso anterior (duas frames atrás) completou.
- **Consumo (main)**: a main usa o último publish cujo `published_camera_chunk` == chunk da câmera corrente e que não seja mais velho que 2 frames (guarda de staleness). Acabou de cruzar e a worker ainda não publicou? A main espera no máximo **2 ms**, loga "publish atrasado" e renderiza com o conjunto anterior — nunca deadlock silencioso. Nos frames entre cruzamentos, a main não espera nada: render puro com input fresco. **Liberdade de deadlock** ([[ADR-W1-ownership-mundo-worker|ADR-W1]]): as dependências apontam para trás — publish de N depende do slot de N−2 (já submetido); a main depende só de publish existente.

O `published_compute_value` que acompanha o publish é o `highest_completed_compute_value`: o valor com que a main espera a timeline de compute antes de desenhar ([[visao-geral]], pipeline de um frame, passo 5).

## Configuração INI → capacidades derivadas

Nada do que está acima é constante de compilação. Seis parâmetros vêm de `vox.ini` (seções `[streaming]`/`[compute]`, `--config` para override, defaults embutidos + warning se ausente; parse estrito, erro fatal pré-janela) e **todas as capacidades são derivadas** das esferas discretas `x²+y²+z² ≤ r²` (`config_derive_and_validate`, `config.odin:187`; [[ADR-C1-config-ini-provisionamento|ADR-C1]]):

| Derivada | Fórmula | Por quê |
| --- | --- | --- |
| `visible_capacity` | \|esfera(vision)\| | o publish publica até esse teto; excedente nunca ocorre por construção |
| `resident_slots` | ⌈\|esfera(unload)\| × 1,05⌉ | o conjunto vivo é a esfera de **unload** (CACHED incluído, histerese até lá) + transitório de aposentadoria B1; derivar de `generation` esgotava estruturalmente o pool (emenda VS-08, absorve o backlog B5) |
| `scratch_chunks` | `batches_in_flight × chunks_per_batch` (≤ 256) | ring de jobs/scratch dos lotes |
| `mirror_pages` | ⌈\|esfera(simulation)\| × 1,5⌉ | folga de 50% no pool de páginas do mirror |
| `mirror_ring_slots` | `max(64, 2^⌈log2(scratch)⌉)` | ring de export do mirror |
| `work_item_capacity` | `visible_capacity × BRICKS_PER_CHUNK` | fila de trabalho do builder |

A histerese é validada estritamente: `vision ≤ generation < unload`, `1 ≤ vision ≤ 25` (limite de formato do `visible_index` de 16 bits da VS-09), `resident_slots ≤ 65535`, `chunks_per_batch ≤ 64`, `batches_in_flight ≤ 8`. Depois do VMA, a **validação de máquina** (REQ-CFG-04) soma os bytes device requeridos (pools de slots, fila de trabalho, scratch, visíveis, jobs, flags — `config_device_bytes_required`, `config.odin:156`) e compara com o budget da heap device-local (`GetHeapBudgets`) × 0,9; excedeu → erro fatal sugerindo reduzir `unload` (piso `generation + 1`). Isso fecha a contradição histórica do [[ADR-B5-capacidade-streaming|B5]] (raio de geração > pool): com slots derivados de unload × 1,05, o pool cabe o conjunto vivo por construção para qualquer config válida.

## Leitura sugerida a partir daqui

[[visao-geral]] (contexto) · [[sistema-renderizacao]] (o que acontece com os chunks publicados) · [[sistema-mirror-fisica]] (a outra view do mundo e o journal) · [[sistema-edicao-eventos]] (E1 e materialização de EMPTY) · [[sistema-suporte]] (config INI, telemetria). Referência de structs/procs: [[ref-voxel-engine-worker]].
