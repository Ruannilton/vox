---
id: REF-VOXEL-ENGINE-WORKER
titulo: "Referência: voxel_engine + voxel_worker"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_engine` + `voxel_worker`

Você chegou à referência dos dois arquivos que formam o **coração do mundo**: `src/engine/voxel_engine.odin` (estado, cursor, completions, publish) e `src/engine/voxel_worker.odin` (a thread dona do mundo e o pipeline de lotes de compute). Se ainda não leu, a narrativa — por que a worker é dona do mundo, por que existe aposentadoria dual — está em [[sistema-streaming-mundo]]; o quadro macro das três threads está em [[visao-geral]]. Aqui é o nível contrato: cada struct campo a campo, cada proc com sua thread, seus mutexes e seus invariantes. Contratos de GPU: [[ref-voxel-gpu]]; edição/journal: [[ref-edit-mirror]].

Uma regra de leitura: dois invariantes cruzados aparecem por toda parte, então vamos apresentá-los uma vez, na primeira menção, e só linkar depois.

- **Invariante B1 (ciclo de vida dos slots)** — em resumo: *só o handler de conclusão libera slot*. Quando o mundo decide descarregar um chunk, o slot dele pode ainda estar **em uso pela GPU**; por isso nada libera slot diretamente no caminho de unload — a liberação é sempre adiada para a rotina que processa as conclusões, com a timeline apropriada garantindo que a GPU terminou. O raciocínio completo (e por que existem duas filas de aposentadoria) está em [[sistema-streaming-mundo]].
- **Invariante W1 (ownership do mundo)** — em resumo: *o mapa de chunks tem dono único, a worker thread*. A main nunca itera nem modifica o mundo; ela o enxerga só pelo publish e pelo mirror. A história (a captura Tracy que mostrava 7 ms de trabalho de mundo na main) está em [[sistema-streaming-mundo]].

> **Dono das threads (pós-VS-18)**: os comentários de domínio no `VoxelEngine` que dizem "thread principal" descrevem o pré-VS-18. Hoje, **toda proc de serviço do mundo roda na worker**; a main só chama `voxel_engine_request_frame` (pedido), `voxel_engine_wait_published` (consumo) e `ve_request_voxel_edit*` (produção, via mutex próprio). Cada proc abaixo declara sua thread e sua sincronização.

## Constantes

| Constante | Valor | Papel |
| --- | --- | --- |
| `STREAMING_SLICE_BUDGET_MS` | `6.0` | orçamento de tempo por fatia de streaming (regra: orçamento de tempo, não de iterações — REQ-STR-04) |
| `STREAMING_TICK_INTERVAL` | `64` | coordenadas processadas entre checagens do orçamento (e a cada descarga) |

## Enums e structs (`voxel_engine.odin`)

### `ChunkState` (`:15-20`)

Máquina de estados do chunk no mapa — o que cada registro em `active_chunks` carrega como `state`:

```
(UNLOADED) → GENERATING → CACHED ⇄ RENDERABLE
                  └→ EMPTY
```

- `GENERATING` — registro criado com slot claimado; a tarefa está em `pending_tasks` ou num lote submetido. Nunca publicado.
- `CACHED` — materializado, fora da bolha de visão.
- `RENDERABLE` — dentro da bolha; elegível ao publish.
- `EMPTY` — ar puro (VS-10): registro **sem slot**, nunca publicado; edição ≠ ar materializa de volta.

### `ChunkRecord` (`:22-26`)

Registro por coordenada em `active_chunks` — os três campos que definem a identidade de um chunk residente:

| Campo | Contrato |
| --- | --- |
| `state: ChunkState` | estado atual |
| `storage_slot_index: u32` | slot GPU; inválido quando `EMPTY` |
| `generation: u32` | **anti-ABA** (regra 3/B1): cada alocação incrementa `slot_generations[slot]`, então "mesmo slot" nunca significa "mesmo chunk"; `task_matches` confere os dois juntos |

### `GenerationTask` (`:28-34`)

Unidade de trabalho da geração — o que o cursor enfileira e o claim do lote consome. `{coordinate, storage_slot_index, generation}` é a chave anti-ABA: `task_matches` (`:130`) confirma os três contra o registro ativo antes de promover/cancelar, de modo que uma conclusão atrasada nunca toca o chunk novo de um slot reutilizado. `mirror_ring_slot: i32` = slot do ring de export do mirror (−1 = sem export); `export_only: bool` marca lotes de exportação do mirror (só generate, sem pack).

### `SubmittedBatch` (`:36-39`)

Lote claimado pela worker — o objeto publicado em `submitted_batches` no momento do claim. `compute_timeline_value: u64` é o **mesmo** valor sinalizado no submit (1 claim = 1 lote = 1 valor de timeline — regra 3). `tasks` tem cap = `config.chunks_per_batch` (VS-08).

### `RetiringSlot` / `RetiringComputeSlot` (`:41-49`)

As duas filas da **aposentadoria dual** (B1 — só o handler de conclusão libera, adiando a liberação até a GPU garantidamente terminar):

- `RetiringSlot{storage_slot_index, release_frame_value}` — chunk CACHED/RENDERABLE descarregado; o slot volta ao pool quando a **timeline gráfica** ≥ `release_frame_value` (a render ainda podia estar lendo o chunk no frame em curso).
- `RetiringComputeSlot{storage_slot_index, release_timeline_value}` — chunk ainda GENERATING cujo lote já foi submetido; a GPU de compute ainda vai escrever nele, então o slot volta quando a **timeline de compute** ≥ valor do lote.

### `StreamingCursor` (`:51-57`)

Estado persistente do cursor espiral (VS-17) — o que permite ao streaming ser incremental entre frames:

| Campo | Papel |
| --- | --- |
| `center: ChunkCoordinate` | âncora atual da espiral |
| `offsets: [dynamic]ChunkCoordinate` | cubo de `radius_unload` pré-ordenado por distância² crescente (desempate x,y,z) |
| `position: int` | índice de consumo na espiral — onde a fatia anterior parou |
| `pending_unload: [dynamic]ChunkCoordinate` | descargas da reancoragem, consumidas antes da espiral (orçadas) |
| `center_initialized: bool` | primeira âncora vem da câmera |

## `VoxelEngine` (`:59-111`)

Estado global; `active_ve: ^VoxelEngine` (`:113`) é o singleton que a worker captura no boot. Os campos estão agrupados abaixo pelo mutex — ou pela thread — que os protege.

### Domínio exclusivo da worker (pós-VS-18, invariante W1)

Ninguém além da worker lê ou escreve estes campos, então nenhum lock é necessário:

**Mapa e slots:**

- `active_chunks: map[ChunkCoordinate]ChunkRecord` — o mundo; dono único é a worker (W1).
- `free_storage_slots: [dynamic]u32` — pool de slots; pop no claim, push **só** nas vias de conclusão/cancelamento B1 (nunca no caminho de unload).
- `retiring_slots` / `retiring_compute_slots` — filas de aposentadoria dual (acima).
- `slot_generations: []u32` — geração por slot; incrementada em toda alocação.
- `last_camera_chunk: ChunkCoordinate` — âncora do publish/completions; iniciada em `{max(i32),…}` para forçar o primeiro rebuild.

**Cursor e visibilidade:**

- `streaming_cursor: StreamingCursor` — estado do cursor (acima).
- `visible_set: [dynamic]ChunkCoordinate` + `visible_membership: map[ChunkCoordinate]int` — conjunto visível com remoção O(1) por swap-pop (`visible_set_remove`, `:507`).
- `visible_set_camera` / `visible_set_initialized` — invalidação do conjunto por mudança de câmera.

**Métricas/handoff:**

- `update_appended_tasks: int` — tarefas enfileiradas no último update (plot work_items/Tracy).
- `slots_starved: bool` — pool esgotado no último avanço (loga warning na transição).
- `first_update: bool`, `highest_completed_compute_value: u64` — o valor publicado para a main esperar a timeline de compute antes de desenhar.
- VS-10: `empty_chunks_active`, `slots_saved_total`, `last_empty_log_time` — contadores de chunks vazios virtuais (log a cada 5 s).

**Sub-managers embutidos:** `edit: EditManager` ([[ref-edit-mirror]]), `mirror: MirrorManager` (possui `mirror.mutex`, segurado durante o service/publish), `physics: PhysicsManager` (VS-19), `gameplay: GameplayManager` (VS-20).

### Domínio de `queue_mutex` (worker ↔ retiradas enfileiradas pela própria worker)

- `queue_mutex` / `queue_condition` — guarda as filas de tarefas e `submitted_batches`; também usado por `retire_generating_slot` (chamado sob `mirror.mutex` no unload — lock aninhado: `mirror.mutex` → `queue_mutex`).
- `pending_tasks` — fila priorizada (ordenação por distância acontece no claim).
- `pending_export_tasks` — fila prioritária de export do mirror; esvazia um lote de tarefa única por vez.
- `submitted_batches` — lotes em voo, em ordem crescente de timeline; `voxel_engine_service_completions` drena o prefixo completado.
- `priority_camera_chunk` — escrito pela worker a cada update; usado no claim do lote.
- `worker_stop_requested: u32` — flag atômica de shutdown.

### Domínio de `frame_mutex` (handoff main↔worker)

- `frame_mutex` / `frame_condition` — guarda o estado do pedido e do publish.
- **Pedido (main→worker):** `requested_frame`, `requested_frame_index`, `requested_camera_chunk`.
- **Publish (worker→main):** `published_frame`, `published_frame_index`, `published_camera_chunk`, `published_visible_count`, `published_compute_value`, `published_revision`, `has_published`.
- **Gatilhos de republicação:** `world_revision` (incrementada quando ≥1 lote completa), `publish_bump`/`consumed_publish_bump` (keepalive pedido pela main quando o publish ficou velho).

## Procs utilitárias (`voxel_engine.odin`)

Pure functions sem estado — qualquer thread pode chamá-las, a qualquer momento, sem sincronização:

| Proc | Thread | Sincronização | Contrato |
| --- | --- | --- | --- |
| `calculate_squared_distance` (`:115`, contextless) | qualquer | nenhuma | distância euclidiana² em coordenadas de chunk (i64) |
| `floor_div_i32` (`:122`, contextless) | qualquer | nenhuma | divisão inteira com piso — correto para coordenadas negativas |
| `task_matches` (`:130`, contextless) | qualquer | nenhuma | anti-ABA: coord + slot + geração iguais ao registro |
| `chunk_coordinate_from_world` (`:518`, contextless) | qualquer | nenhuma | posição mundo → chunk (`floor` + divisão com piso) |

## Ciclo de vida

### `voxel_engine_init` (`:136`) — main, no boot, antes de qualquer frame

Quem chama: a `main`, uma única vez na inicialização. Aloca o engine, popula `free_storage_slots` com `config.resident_slots` slots, inicializa edit/mirror/physics/gameplay/cursor, chama `voxel_gpu_init`, instala `active_ve` e **cria e starta a thread worker** (`worker_thread_process`). A partir daqui o mundo é da worker — é este o momento em que o invariante W1 passa a valer.

### `voxel_engine_destroy` (`:167`) — main, no teardown (ou `--full-teardown`)

Quem chama: a `main`, ao desligar. Seta `worker_stop_requested` atômico, acorda a condvar sob `queue_mutex`, `thread.join` (a worker sai do claim), `QueueWaitIdle` compute+graphics, `DeviceWaitIdle`, `voxel_gpu_destroy`, deleta todas as coleções e os sub-managers, limpa `active_ve`, `free(ve)`.

### `voxel_engine_update` (`:360`) — worker, dentro de `worker_service_frame`, uma vez por iteração da worker

Quem chama: a própria worker, no passo 2 do laço de `worker_thread_process` — ou seja, sempre que a main acorda a worker com um pedido de frame. É o "tick" do serviço do mundo, e roda nesta ordem:

1. `voxel_engine_service_completions` (zone `service_completions`).
2. Zera `update_appended_tasks`; atualiza `last_camera_chunk` e `priority_camera_chunk` (sob `queue_mutex`).
3. `streaming_cursor_advance` (zone `streaming_slice`).
4. `mirror_update_bubble` + `mirror_service_retries` + `physics_drain_requests` (zone `mirror_service`).
5. Log dos contadores VS-10 a cada 5 s.

## Cursor espiral

### `streaming_cursor_init` (`:391`, privada) — main, durante `voxel_engine_init`

Quem chama: a `main`, uma vez no boot. Preenche `offsets` com o cubo `[-radius_unload, +radius_unload]³` e ordena uma vez por distância² ao centro, desempate determinístico x→y→z — a ordenação que faz a espiral visitar o que está perto primeiro.

### `streaming_cursor_advance` (`:411`, privada) — worker, passo 3 de `voxel_engine_update`

Quem chama: a worker, a cada tick do serviço do mundo — é aqui que o streaming faz seu trabalho, dentro do orçamento de 6 ms. A fatia orçada funciona assim:

1. Consome `pending_unload` (descargas da reancoragem), parando ao estourar `STREAMING_SLICE_BUDGET_MS`.
2. Avança a espiral: dentro da esfera de geração e ausente do map → **claim de slot** (`pop free_storage_slots`, `slot_generations[slot] += 1`, registro `GENERATING`, tarefa com `mirror_ring_slot = -1`); fora da esfera de descarga e presente → `streaming_unload_chunk`. Checa o orçamento a cada `STREAMING_TICK_INTERVAL` coordenadas.
3. Fim da espiral: varredura do map para `pending_unload` (chunks além do raio de unload) e reancoragem (`center = camera_chunk`, `position = 0`). Com câmera parada, os ciclos ficam baratos.
4. Log de pool esgotado na transição; anexa tarefas novas a `pending_tasks` sob `queue_mutex` + `cond_signal`.

Invariante B1: o slot só sai do pool aqui (ou em `ve_try_materialize_empty`); nunca é devolvido por esta proc.

### `streaming_unload_chunk` (`:486`, privada) — worker, chamada pela espiral ao cruzar um chunk fora do raio

Quem chama: `streaming_cursor_advance`, no momento em que uma coordenada presente no map cai fora da esfera de descarga. Descarrega uma coordenada: `mirror_forget_chunk`; se `GENERATING` → `retire_generating_slot` (o lote pode estar pendente ou submetido); se CACHED/RENDERABLE → empurra `RetiringSlot{slot, completed_graphics}` (leitura não-bloqueia da timeline gráfica no momento do unload); `EMPTY` não aposenta nada. Remove do visible_set e do map. **Nunca libera slot diretamente** (regra 4) — a liberação fica para os handlers de conclusão, com a timeline apropriada.

## Completions, promote e aposentadoria

### `voxel_engine_service_completions` (`:200`) — worker, passo 1 de `voxel_engine_update`, a cada tick

Quem chama: a worker no início de todo serviço do mundo. Esta é **o handler de conclusão** do invariante B1: a única rotina que, além dos cancelamentos em `retire_generating_slot`, devolve slots ao pool — sempre com a garantia de que a GPU terminou. Dreno não-bloqueio das conclusões, sob `queue_mutex`:

1. Lê `computeTimelineSemaphore` via `vkGetSemaphoreCounterValue` (sem espera).
2. Invalida o host-visible `chunk_result_flags` (REQ-VRT-02 — flags lidas após a timeline do lote).
3. Para cada lote com `compute_timeline_value ≤ completed`: para cada tarefa, se o registro ainda é `GENERATING` e passa em `task_matches`:
   - `CHUNK_FLAG_EMPTY` e sem edição pendente → **EMPTY** (adiado para depois do `mirror_materialize_from_ring`, que valida slot+geração): estado `EMPTY`, slot inválido, slot devolvido ao pool no instante da conclusão, contadores VS-10.
   - caso contrário → `CACHED`, e `RENDERABLE` + `visible_set_add` se dentro do raio de visão (promote).
   - `mirror_ring_slot ≥ 0` → `mirror_materialize_from_ring` (export denso).
4. Remove o prefixo completado de `submitted_batches`; se ≥1 lote, `world_revision += 1` (gatilho de republicação); atualiza `highest_completed_compute_value`.
5. Fora do lock: drena `retiring_compute_slots` (timeline compute) e `retiring_slots` (timeline gráfica), devolvendo slots ao pool.

### `retire_generating_slot` (`:527`, privada) — worker, chamada sob `mirror.mutex` durante o unload

Quem chama: `streaming_unload_chunk`, no caminho do mirror, para cancelar uma geração que ainda está em voo sem violar o B1 (nunca liberar um slot que a GPU de compute ainda vai escrever, nem um slot de ring em voo). Três caminhos:

- **(a)** tarefa ainda em `pending_tasks` → `unordered_remove` + libera na hora (nada foi submetido à GPU).
- **(b)** tarefa num lote submetido → empurra `RetiringComputeSlot{slot, batch.compute_timeline_value}` (libera quando o lote completar).
- **(c)** defensivo (tarefa não achada) → libera na hora.

Sempre valida `task_matches` antes de cancelar — conclusão/retirada vencida nunca toca o chunk novo do slot reutilizado.

## Publish: visible_set, handoff de frame e consumo

### `voxel_engine_publish_visible` (`:308`) — worker, chamada por `worker_service_frame` quando há o que republicar

Quem chama: a worker, já de posse do `mirror.mutex` e do `frame_mutex`, depois de decidir que o mundo publicável mudou. Rebuild do conjunto visível e escrita direta no ring `visible_chunks` (slot `frame_index % NUM_FRAMES_IN_FLIGHT`, capacity `visible_capacity`):

1. Se a câmera mudou (ou primeiro publish): passada única fundida sobre o map (REQ-STR-03) — dentro do raio de visão → `RENDERABLE` + `visible_set_add`; fora → `CACHED`.
2. Varre `visible_set` em ordem de inserção (proximidade): registra `VisibleChunk` com origem mundo e slot; para cada um dos 6 vizinhos, preenche `neighbor_slots[i]` **só se** o vizinho é CACHED/RENDERABLE (VS-10: EMPTY/GENERATING → `NEIGHBOR_SLOT_INVALID`, que o shader trata como ar — B2). Cap em `visible_capacity`.
3. Retorna o count (publicado pela caller em `published_visible_count`).

### `worker_service_frame` (`voxel_worker.odin:229`, privada) — worker, passo 2 do laço de `worker_thread_process`

Quem chama: o laço da worker, sempre que acordada pelo pedido de frame da main. É o coração do handoff sob demanda — a main espera em `voxel_engine_wait_published`, e é aqui que a resposta nasce:

1. Lê o pedido sob `frame_mutex` (`requested_frame`/`frame_index`/`camera_chunk`); `requested_frame == 0` → no-op.
2. Toma `mirror.mutex` e roda `voxel_engine_update` + `edit_update` — o service inteiro do mundo acontece com a bolha de simulação travada.
3. Decide republicação: `!has_published` **ou** `published_camera_chunk != camera` **ou** `published_revision != world_revision` **ou** `consumed_publish_bump != publish_bump`. Se reescreverá o slot, guarda de voo: só publica se a timeline gráfica ≥ `frame_value − 2` (slot de 2 frames atrás já consumido); se ainda não, devolve o lock e tenta no próximo pedido.
4. Publica: `voxel_engine_publish_visible`, atualiza todos os campos `published_*`, `has_published = true`, `cond_broadcast` na `frame_condition`.

### `voxel_engine_request_frame` (`:283`) — main, todo frame, no passo 2 do pipeline de frame

Quem chama: a `main` a cada frame — é o gatilho que acorda a worker. Escreve `requested_frame = frame_value + 1`, `requested_frame_index`, `requested_camera_chunk` sob `frame_mutex` + `cond_signal`. Dispara o service da worker.

### `voxel_engine_wait_published` (`:292`) — main, passo 4 do pipeline de frame

Quem chama: a `main`, logo antes de gravar o command buffer de render — é como ela recebe o conjunto visível sem esperar a worker rodar inteira. Consumo conservativo:

- Se há publish e o frame pedido está > 2 frames adiante do publicado → `publish_bump += 1` (keepalive: pede republicação sem mudança de mundo).
- Compatível = `published_camera_chunk == camera_chunk`; fresco = `frame_value ≤ published_frame + 2`.
- Se incompatível **ou** velho: espera no máximo **2 ms** na `frame_condition`; se continuar incompatível, loga "publish atrasado" e segue com o conjunto anterior — a main nunca trava.
- Retorna `published_visible_count` (o que a main usa no passo 5 do pipeline de frame, com `published_compute_value` para a espera da timeline de compute — [[visao-geral]]).

## Edição e materialização (`ve_request_*`)

Quem chama: a **main** (gameplay) produz edições por estas procs; a **worker** as consome. Vivem em `voxel_edit.odin`; são a **porta de entrada da main** para o mundo da worker (que é da worker por W1 — sem essa porta, a main não poderia editar o mundo). Domínio próprio: `ve.edit.mutex`.

| Proc | Thread | Contrato |
| --- | --- | --- |
| `ve_request_voxel_edit` (`voxel_edit.odin:38`) | main | Rejeita `block_id > 65535` (domínio de 16 bits do registro); enfileira com coalescência por `edit.lookup` (última escrita vence); `cond_signal` na `frame_condition` acorda a worker. Detalhes do flush/journal: [[ref-edit-mirror]]. |
| `ve_request_voxel_edits_in_box` (`:85`) | main | Fan-out volumétrico de `ve_request_voxel_edit` (min..=max em x,y,z). |
| `ve_retry_empty_edits` (`:53`) | worker (update) | VS-10/REQ-VRT-04: para cada edição na fila cujo chunk está `EMPTY`, tenta materializar; descarta no-op ar-em-ar; reconstrói `queue`/`lookup` se filtrou algo. |
| `ve_try_materialize_empty` (`:265`) | worker | Materializa um chunk EMPTY: `false` se o pool estiver seco (retry por update); caso contrário claim de slot (geração nova), volta a `GENERATING`, sintetiza página de mirror com zeros se o chunk está na bolha de simulação e sem página, enfileira tarefa em `pending_tasks` sob `queue_mutex`. |

## A worker e o pipeline de lotes (`voxel_worker.odin`)

### `worker_thread_process` (`:9`) — thread `voxel_worker`, única entry point, criada por `voxel_engine_init`

Quem chama: ninguém além do boot — é o corpo da thread. Boot: instala o contexto do app, **arena temporária própria de 4 MiB** (`Default_Temp_Allocator`) como `temp_allocator` — cada iteração faz `free_all`, então nenhuma alocação temporária atravessa iterações. Nome de thread `voxel_worker` para o Tracy.

Laço por iteração — e note como cada passo se encaixa no que vimos acima:

1. `worker_stop_requested` → sai.
2. **`worker_service_frame`** (service do mundo + publish — tudo da seção anterior).
3. `free_all(temp)`; se `requested_frame` não mudou desde a última iteração, dorme 1 ms (conservação de trabalho) e repete.
4. **Claim do lote** (zone `claim_batch`, `:40-85`), tudo numa única seção sob `queue_mutex` (REQ-SYNC-01 — a espera no `cond_wait_with_timeout(250 ms)` aparece como lock detido no Tracy, por construção VS-16):
   - Espera tarefa em `pending_tasks`/`pending_export_tasks` ou stop.
   - Valor do lote = `submitted_batch_count + 1` (1 claim = 1 lote = 1 valor de timeline).
   - Export tem prioridade: um lote de tarefa única `export_only`.
   - Caso normal: puxa até `chunks_per_batch` tarefas **mais próximas de `priority_camera_chunk`** por varredura linear (a "prioridade de graça" da VS-17 — não existe cota especial para a vizinhança).
   - Publica o `SubmittedBatch` em `submitted_batches` **antes** de soltar o lock — invariante: toda tarefa está em exatamente um dos conjuntos {pendente, submetida}.
5. **Backpressure** (zone `wait_batch_slot`, `:89-93`): com `batches_in_flight` lotes submetidos, espera a timeline de compute do lote de `batches_in_flight` atrás (`submitted_batch_count − batches_in_flight + 1`) antes de regravar a posição do ring — nunca se regrava um slot de ring em voo (regra 4 no domínio GPU); coleta telemetria GPU.
6. **Build + submit** (zone `submit_batch`, `:95-221`):
   - Ring index = `submitted_batch_count % batches_in_flight`; `job_offset = ring_index * chunks_per_batch`; coleta telemetria do slot anterior.
   - `build_jobs`: escreve `ChunkGenerationJob` (origem mundo, slot, ring slot do mirror) no ring mapeado.
   - Grava o CB de compute: descriptor set com offset dinâmico 0 → push constants (`batch_job_offset`, `visible_chunk_capacity`) → zonas GPU (`generate`: dispatch `(4,4,4·N)`) →, se não `export_only`, barreira `SHADER_STORAGE_WRITE → SHADER_STORAGE_READ` → `pack` (dispatch `(N,1,1)`), com labels e timestamps de telemetria em cada passo.
   - `submitted_batch_count += 1` e `vkQueueSubmit2` na fila de compute sinalizando `computeTimelineSemaphore` com **exatamente** o valor do claim — é este o valor que `voxel_engine_service_completions` lê na timeline para saber quais lotes terminaram.

### `wait_for_compute_timeline` (`:269`, privada) — worker, usada pelo backpressure do passo 5

Quem chama: a própria worker, no `wait_batch_slot`. `vkWaitSemaphores` bloqueante (timeout `max(u64)`) na timeline de compute até `target_value`. Único ponto onde a worker **espera** a GPU — por isso o restante do sistema é todo não-bloqueio.

## Invariantes cruzados (B1/W1)

Recapitulando os dois invariantes que organizam tudo acima (a narrativa completa está em [[sistema-streaming-mundo]]):

- **Regra 3 / anti-ABA** — todo claim incrementa a geração do slot; promote, esvaziamento VS-10 e cancelamento só valem com `task_matches` (coord+slot+geração); o valor da timeline publicado no claim é o mesmo sinalizado no submit.
- **Regra 4 / aposentadoria dual** (B1) — slot nunca é liberado por unload direto nem por reescrita de ring; só pelos handlers de conclusão (`service_completions`, `retire_generating_slot`) com a timeline apropriada (compute para lote/GENERATING, gráfica para CACHED/RENDERABLE).
- **ADR-W1** — `active_chunks` e o visible_set têm dono único (worker); a main lê o mundo só pelo publish e pelo mirror.

## Para ir mais fundo

[[sistema-streaming-mundo]] (narrativa e decisões) · [[sistema-mirror-fisica]] (mirror e journal) · [[sistema-edicao-eventos]] (E1) · [[ref-edit-mirror]] · [[ref-voxel-gpu]] · [[ref-voxel-types]].
