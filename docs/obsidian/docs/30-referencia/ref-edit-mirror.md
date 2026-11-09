---
id: REF-EDIT-MIRROR
titulo: "Referência: voxel_edit + voxel_mirror"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_edit` + `voxel_mirror`

Contratos struct-a-struct e proc-a-proc dos dois arquivos do **journal de edição (E1)** e do **mirror**: `src/engine/voxel_edit.odin` (intake, dedup, flush, staging e feedback) e `src/engine/voxel_mirror.odin` (o mundo na RAM: páginas por chunk, materialização e reconciliação). Contexto e porquê: [[sistema-edicao-eventos]] e [[sistema-mirror-fisica]] (narrativas principais); quadro macro: [[visao-geral]]. Dona do mundo e handoff: [[ref-voxel-engine-worker]]; recursos e rings GPU: [[ref-voxel-gpu]]; structs compartilhadas: [[ref-voxel-types]]. Genealogia: specs VS-03 (edição), VS-04 (mirror), VS-08 (config dos pools/rings), VS-10 (chunks vazios), VS-13 (heightmap), VS-14 (sólido por registry), VS-18 (mundo na worker), VS-19 (física/heights).

> **Dono das threads (pós-VS-18)**: o serviço do E1 (`edit_update` e tudo que ele chama) roda **na worker**, dentro da seção sob `mirror.mutex` de `worker_service_frame`. A **main** é a única produtora de edições (`ve_request_voxel_edit*` via `ve.edit.mutex`) e a consumidora do staging (`edit_ring_write`, a cada frame, antes de gravar o CB). Leituras de gameplay (`voxel_get`, `mirror_height_get`, raycast) vêm da main/física sob `ve.mirror.mutex` — ver contenção BLK-41 em [[sistema-mirror-fisica]].

## `voxel_edit.odin` — journal E1

### Structs

#### `VoxelEditRequest` (`:9-12`)

Unidade do E1: `{world_voxel: [3]i32, block_id: u32}`. `block_id` é validado no intake contra o domínio de 16 bits do registro denso (`> 65535` é rejeitado).

#### `EditRingCounts` (`:14-17`)

`{job_count, edit_count}` do flush que usou cada slot de ring (indexado por `frame_index % NUM_FRAMES_IN_FLIGHT`). É a âncora do feedback: `edit_collect_feedback` sabe quantos resultados ler de `edit_results` no slot NUM_FRAMES_IN_FLIGHT frames depois.

#### `EditManager` (`:19-33`)

Estado do E1, embutido em `VoxelEngine` (`ve.edit`). Domínio exclusivo: `ve.edit.mutex`.

| Campo | Contrato |
| --- | --- |
| `mutex: sync.Mutex` | guarda todo o manager |
| `queue: [dynamic]VoxelEditRequest` | fila de intake, ordem de chegada; esvaziada no flush |
| `lookup: map[[3]i32]int` | voxel → índice na `queue` (coalescência O(1)); invalidado junto com a fila |
| `pending: map[ChunkCoordinate][dynamic]VoxelEditRequest` | edições cujo chunk ainda não está pronto (GENERATING/EMPTY): saem só quando o chunk chega a CACHED/RENDERABLE |
| `last_flush: time.Tick` | marca do último flush (intervalo `EDIT_FLUSH_INTERVAL_MS`) |
| `force_next_flush: bool` | próximo `edit_flush_due` ignora o intervalo (se houver conteúdo) |
| `staged_jobs: [dynamic]EditChunkJob` | staging do próximo flush: jobs por slot, editados na worker |
| `staged_edits: [dynamic]u32` | staging packed (mesma ordem dos jobs; `first_edit` é offset local) |
| `ring_counts: [NUM_FRAMES_IN_FLIGHT]EditRingCounts` | contadores por slot de ring, para o feedback |
| `stats_applied/noop/rejected/deferred: u64` | contadores do feedback e do orçamento do flush |

### Porta de entrada (main → worker)

#### `ve_request_voxel_edit` (`:38`) — **main**

Intake do E1. Rejeita `block_id > 65535`; enfileira sob `ve.edit.mutex` com coalescência por `lookup` (mesmo voxel: última escrita vence); `cond_signal` na `frame_condition` acorda a worker. Nunca bloqueia além do mutex.

#### `ve_request_voxel_edits_in_box` (`:85`) — **main**

Fan-out volumétrico: itera min..=max em x,y,z chamando `ve_request_voxel_edit`. Uma caixa de N³ voxels vira N³ requests coalescidos pela fila.

#### `edit_enqueue` (`:76`, privada) — worker (sob `edit.mutex`)

Coalescência por `lookup`: se o voxel já está na fila, sobrescreve `block_id`; senão, append + registro do índice. Usada pelo intake e pelo `flush_voxel_edits` (quando pendências voltam à fila).

### Serviço do update (worker)

#### `edit_update` (`:225`) — **worker** (sob `edit.mutex`, chamada por `worker_service_frame`)

Um tick do E1, na ordem:

1. `edit_collect_feedback` — lê os resultados do slot de ring NUM_FRAMES_IN_FLIGHT frames atrás.
2. `ve_retry_empty_edits` — VS-10: retenta materialização de edições em chunks EMPTY.
3. Se `edit_flush_due` → `flush_voxel_edits` (staging do journal).

#### `edit_collect_feedback` (`:204`, privada) — worker (sob `edit.mutex`)

Feedback do flush antigo no slot:

1. `InvalidateAllocation` no `edit_results` (HOST_ACCESS_RANDOM; no-op em memória coerente).
2. Por edição, conta `EDIT_RESULT_APPLIED`/`NOOP`/rejeitado; cada **rejeição** dispara `mirror_reconcile_ring_position` — o mirror aplicou otimisticamente no flush e precisa desfazer (VS-04/REQ-MIRROR-09).
3. Acumula nos `stats_*` e loga diagnóstico.

#### `ve_retry_empty_edits` (`:53`) — worker (sob `edit.mutex`)

VS-10 (REQ-VRT-04). Varre a fila: para cada edição cujo chunk está `EMPTY`, chama `ve_try_materialize_empty` (claim de slot + volta a GENERATING); descarta no-op ar-em-ar (`block_id == 0` em chunk EMPTY). Se filtrou algo, reconstrói `queue`/`lookup` (o índice denso muda ao remover itens). Chamado a cada update; é o mecanismo de retry do pool seco.

#### `ve_try_materialize_empty` (`:265`, privada) — worker (sob `edit.mutex`)

Materializa um chunk EMPTY: `false` se `free_storage_slots` estiver vazio (retry vem de `ve_retry_empty_edits`). No sucesso: claim (pop do pool, `slot_generations[slot] += 1` — regra 3/anti-ABA), registro volta a `GENERATING` com slot+geração, `empty_chunks_active -= 1`. Se o chunk está na bolha de simulação e sem página, sintetiza página de mirror com zeros (`mirror_page_acquire` + `mirror_page_fill_empty`). Enfileira `GenerationTask` em `pending_tasks` sob `queue_mutex` + `cond_signal`.

#### `edit_defer_to_pending` (`:304`, privada) — worker (sob `edit.mutex`)

Move uma edição para `pending[chunk]`, com coalescência por voxel (última escrita vence) dentro da lista do chunk. Pendências de chunks que nunca mais carregam ficam em memória (cap por TTL/quantidade está no backlog). A saída da pendência acontece só no flush, quando o chunk está CACHED/RENDERABLE.

#### `edit_flush_due` (`:320`, privada) — worker (sob `edit.mutex`)

Gatilho do flush: `force_next_flush` (se houver conteúdo) > fila/pendências vazias (não) > `EDIT_FLUSH_INTERVAL_MS <= 0` (sempre) > intervalo decorrido desde `last_flush`.

#### `flush_voxel_edits` (`:328`, privada) — worker (sob `edit.mutex`)

O coração do E1 — monta o staging do journal:

1. Re-promove pendências cujo chunk chegou a CACHED/RENDERABLE de volta à `queue`.
2. Orçamento por edição: `MAX_EDITS_PER_FLUSH` no total, `MAX_EDIT_JOBS_PER_FLUSH` buckets (chunks/slots) e `MAX_EDITS_PER_CHUNK_PER_FLUSH` por chunk; o que excede fica na `queue` como `kept` (`stats_deferred += 1`).
3. Chunk GENERATING/EMPTY (ou ausente do mapa) → `edit_defer_to_pending` (VS-10: sem slot não há para onde despachar).
4. Edição staged → `mirror_journal_apply` (otimismo do mirror) e packed em bucket por `storage_slot_index`.
5. Buckets viram `EditChunkJob{slot, first_edit, count}` + `staged_edits` contíguos.
6. Reconstrói `queue`/`lookup` só com `kept`; se houve staging, `world_revision += 1` (gatilho de republicação do publish).

`last_flush`/`force_next_flush` só são tocados aqui — `edit_ring_write` não consome o intervalo.

### Consumo do staging (main)

#### `edit_ring_write` (`:98`) — **main**, todo frame (passo pré-submit do CB)

Sob `ve.edit.mutex`: copia `staged_jobs`/`staged_edits` para os rings mapeados no slot `frame_index % NUM_FRAMES_IN_FLIGHT` (ajustando `first_edit` para o índice global do ring), grava `ring_counts[frame_idx]` e **limpa o staging** — sem limpar, frames seguintes re-copiariam e re-despachariam o mesmo flush (no-ops redundantes no feedback). Retorna `job_count` (a main usa no dispatch). Nunca toca em `last_flush`/`force_next_flush`.

#### `edit_ring_write_legacy` (`:119`, privada) — **obsoleta** (@private)

Versão antiga que coletava o feedback inline antes de copiar. Substituída por `edit_collect_feedback` (chamado na worker) + `edit_ring_write` puro. Mantida só como histórico — não chamar.

### Reconciliação de rejeição (worker)

#### `mirror_reconcile_ring_position` (`:422`, privada) — worker (sob `edit.mutex`)

Caminho raro (só em rejeição do shader). Mapeia a posição `i` do ring de volta a `(chunk, voxel, bloco)`:

1. Localiza o `EditChunkJob` cuja faixa `[first_edit, first_edit+count)` cobre `i`.
2. Busca reversa slot → coordenada em `active_chunks` (linear; caminho frio).
3. Desempacota o voxel (layout denso do registro: `x | z<<5 | y<<10` — **não** o índice y-contíguo do mirror, regra 7) e delega a `mirror_reconcile_rejection`.

### Telemetria e ciclo de vida

#### `edit_log_stats` (`:233`) — qualquer thread (mutex próprio)

Loga `applied/noop/rejected/deferred` + tamanhos de fila/pendências. Chamada pela main no teardown (`FINAL edits:`).

#### `voxel_chunk_and_index` (`:251`, privada, contextless) — qualquer

Mundo → `(chunk, índice denso)` com `floor_div_i32` (correto para negativos). **Índice denso = layout do registro/Slang (`x | z<<5 | y<<10`)** — usado só no domínio E1/GPU; o mirror usa o y-contíguo (regra 7).

#### `edit_manager_init` / `edit_manager_destroy` (`:457`/`:467`, privadas) — main (boot/teardown)

Init: aloca `queue`, `lookup`, `pending`, staging e `last_flush = tick_now`. Destroy: deleta as listas de cada entrada de `pending` antes do map.

## `voxel_mirror.odin` — o mundo na RAM

### Structs (definidas em `voxel_types.odin`, contratos aqui)

#### `MirrorPageState` (`voxel_types.odin:158-161`)

- `PENDING_READBACK` — página criada, conteúdo ainda desconhecido (export em voo ou aguardando slot de ring). Leitura retorna `ok = false` (tri-state).
- `MATERIALIZED` — aberta a leituras; atualizada pelo journal do E1.

#### `MirrorChunkPage` (`voxel_types.odin:169-183`)

Uma página = um chunk no mirror, ~70 KiB. Endereços estáveis (pool fixo; o hash `pages` guarda ponteiros).

| Campo | Contrato |
| --- | --- |
| `coord: ChunkCoordinate` | chunk dono (reescrito no acquire) |
| `edit_seq: u32` | revisão do journal aplicada (paridade com GPU em debug) |
| `state: MirrorPageState` | ver acima |
| `ring_slot: i32` | slot do ring de export reservado para o preenchimento (−1 = nenhum) |
| `pending: [dynamic]VoxelEditRequest` | edições chegadas enquanto PENDING_READBACK (serão aplicadas no materialize) |
| `applied_log: [dynamic]VoxelEditRequest` | journal otimista aplicado; referência para desfazer rejeições |
| `rejected_log: [dynamic]VoxelEditRequest` | edições rejeitadas pela GPU a desfazer no próximo materialize |
| `solid: [CHUNK_VOXEL_COUNT/32]u32` | bitmask de sólidos por **registry** (VS-14: bit NON_SOLID exclui planta) |
| `ids: [CHUNK_VOXEL_COUNT]u16` | ids densos; índice **y-contíguo** `y | z<<5 | x<<10` (regra 7) |
| `heights: [CHUNK_SIZE*CHUNK_SIZE]u16` | heightmap da coluna (VS-13): índice **z-contíguo** `x | z<<5`; y do sólido mais alto; `0xFFFF` = coluna vazia |

#### `MirrorRingEntry` (`voxel_types.odin:185-189`)

Slot do ring de export GPU→CPU: `{used, coord, generation}`. A `generation` é anti-ABA (regra 3): casa com a geração do slot de GPU no pedido, e `mirror_ring_release`/o materialize só consomem a entrada se coord+geração baterem.

#### `MirrorManager` (`:8-19`)

Estado do mirror, embutido em `VoxelEngine` (`ve.mirror`). Domínio: `ve.mirror.mutex` (segurado pela worker pelo service/publish inteiro — BLK-41).

| Campo | Contrato |
| --- | --- |
| `mutex: sync.Mutex` | guarda páginas, pool, ring e stats |
| `pool: []MirrorChunkPage` | pool fixo (`config.mirror_pages`, VS-08) — endereços estáveis |
| `free_pages: [dynamic]u32` | índices livres do pool |
| `pages: map[ChunkCoordinate]^MirrorChunkPage` | página por chunk na bolha de simulação |
| `ring: []MirrorRingEntry` | ring de export (`config.mirror_ring_slots`, VS-08) |
| `stats_pages_live / stats_pool_misses / stats_ring_misses` | telemetria |

### Índices e bitmask (privadas, contextless)

| Proc | Contrato |
| --- | --- |
| `mirror_chunk_and_local` (`:385`) | mundo → (chunk, local) com `floor_div_i32` |
| `mirror_index_from_local` (`:400`) | local → índice y-contíguo `y \| z<<5 \| x<<10` (regra 7) |
| `mirror_bit_test` (`:24`) / `mirror_bit_write` (`:405`) | get/set de bit em máscara `[]u32` |

### Pool de páginas

#### `mirror_page_acquire` (`:30`) — worker (chamada sob `mirror.mutex`)

Pop de `free_pages`; `nil` (e `stats_pool_misses += 1`) se seco. Reinicializa a página: `edit_seq = 0`, `PENDING_READBACK`, `ring_slot = -1`, heights = `0xFFFF` (colunas vazias), logs vazios; registra em `pages[coord]`, `stats_pages_live += 1`.

#### `mirror_page_release` (`:415`, privada) — worker

Libera a página: deleta `pending`/`applied_log`/`rejected_log`, remove de `pages`, devolve o índice ao pool (calculado por aritmética de ponteiros sobre o pool — válido porque os endereços são estáveis), `stats_pages_live -= 1`.

### Agendamento e serviço (worker, sob `mirror.mutex`)

#### `mirror_request` (`:86`) — worker

Pedido explícito de página: no-op se já existe página ou se o chunk não está no mapa; delega a `mirror_request_page`.

#### `mirror_request_page` (`:490`, privada) — worker

Acquire + roteamento pelo estado do registro: `GENERATING` → `mirror_try_attach_to_generation` (piggyback no generate); `EMPTY` → `mirror_page_fill_empty` (VS-10: conteúdo worldgen conhecido, sem export); caso contrário → `mirror_schedule_export`.

#### `mirror_service_retries` (`:52`) — **worker** (chamada por `voxel_engine_update`)

Varredura de retry: páginas `PENDING_READBACK` sem `ring_slot` cujo registro voltou a existir são re-agendadas (attach a geração / fill_empty / export). Cobre pool de ring seco e janelas de estado.

#### `mirror_schedule_export` (`:469`, privada) — worker

Reserva slot de ring (`mirror_ring_try_reserve`), marca `page.ring_slot`, enfileira `GenerationTask{export_only = true}` em `pending_export_tasks` sob `queue_mutex` + `cond_signal` (a worker drena essa fila como lote de tarefa única — prioridade no claim, [[ref-voxel-engine-worker]]).

#### `mirror_try_attach_to_generation` (`:453`, privada) — worker

Sob `queue_mutex` adicional: procura a tarefa de geração do chunk em `pending_tasks` e anexa o slot de ring (`task.mirror_ring_slot`, `page.ring_slot`). Falso se não achou tarefa ou ring seco.

#### `mirror_ring_try_reserve` (`:431`) / `mirror_ring_release` (`:445`, privadas) — worker

Reserva o primeiro slot livre (marca `used`, grava coord+geração; `stats_ring_misses` se seco) / libera só se `used && coord && geração` baterem (anti-ABA, regra 3). **Nunca se libera slot de ring em voo** (regra 4) — a liberação de fato é no materialize ou nos caminhos de `mirror_forget_chunk`.

#### `mirror_update_bubble` (`:317`) — **worker** (chamada por `voxel_engine_update`)

Mantém a bolha de simulação (raio `config.radius_simulation`, independente da bolha de render):

1. Esquece páginas fora do raio: com registro ativo → `mirror_forget_chunk`; sem registro → `mirror_page_release`.
2. Para chunks dentro do raio sem página → `mirror_request_page`.

#### `mirror_forget_chunk` (`:93`) — worker (chamada no unload)

Desfaz o mirror de um chunk (streaming unload ou saída da bolha):

1. Sob `queue_mutex`: remove tarefas de export pendentes do chunk e libera seus slots de ring; limpa `mirror_ring_slot` de tarefas de geração pendentes.
2. Se nenhuma tarefa do chunk está em voo em `submitted_batches`, libera as entradas de ring correspondentes (coord+geração).
3. Fora do lock: `mirror_page_release`.

### Materialização (worker; a página sai de PENDING_READBACK)

#### `mirror_page_fill_empty` (`:72`) — worker

VS-10 (REQ-VRT-04). Chunk EMPTY tem conteúdo worldgen conhecido (ar puro): zera `ids`/`solid`, heights = `0xFFFF`, aplica o `pending` via `mirror_page_apply` (movendo para `applied_log`), e marca `MATERIALIZED` com `edit_seq += 1` — correto por construção, sem leitura GPU.

#### `mirror_materialize_from_ring` (`:221`) — worker (handler de conclusão do export)

Preenche a página a partir do ring de export:

1. **Validação anti-ABA**: página existe, entrada `used`, `page.ring_slot == ring_slot`, coord+geração da entrada casam com a tarefa **e** com o registro ativo, slot de armazenamento igual. Falhou → só libera a entrada (`used = false`) e sai.
2. Espera a timeline de compute do lote (`vkWaitSemaphores` no valor do lote — o export é o último passo do generate).
3. Invalida o trecho do ring e copia os ids (y-contíguo), reconstruindo o bitmask `solid` por `block_is_solid` (VS-14: planta ocupa o voxel mas não é sólida).
4. Deriva as 1.024 colunas `heights` do bitmask recém-preenchido (topo sólido real, imune a flutuantes; `0xFFFF` = vazia). VS-19: ignora o `mirror_heightmap_ring` (binding 20), que o generate continua escrevendo só como reserva futura (emenda do mantenedor, 2026-11-08).
5. Se há `rejected_log`: remove essas edições do `applied_log`, limpa o log e **re-aplica** o `applied_log` restante do zero (reconstrução do estado).
6. Aplica o `pending` (→ `applied_log`), marca `MATERIALIZED`, `ring_slot = -1`, `edit_seq += 1`, libera a entrada do ring.

#### `mirror_page_apply` (`:506`, privada) — worker

Aplica uma edição à página em estado MATERIALIZED (journal otimista do E1):

- `ids[index] = block_id` (índice y-contíguo); `solid` por `block_is_solid`.
- **Heightmap (VS-13/VS-14)**, índice z-contíguo `x | z<<5` (não aplicar `mirror_index_from_local` aqui): colocar sólido acima do topo (ou em coluna vazia) sobe o topo; remover o bloco do topo faz rescan de 32 leituras para o novo topo sólido; planta acima do topo, sólido em/abaixo do topo e remoção abaixo do topo são no-ops para a coluna.

### Journal e reconciliação (E1 ↔ mirror)

#### `mirror_journal_apply` (`:130`) — worker (chamada por `flush_voxel_edits`, sob `edit.mutex`)

Aplicação otimista no flush: página ausente → no-op; página `PENDING_READBACK` → coalescida em `pending` (última escrita vence); página `MATERIALIZED` → `mirror_page_apply` + append em `applied_log` + `edit_seq += 1`. A GPU é a autoridade final — divergências chegam como rejeição no feedback.

#### `mirror_reconcile_rejection` (`:148`) — worker (via `edit_collect_feedback`)

Desfaz/retifica o otimismo:

- Página `PENDING_READBACK` e sem rejeições anteriores: remove a edição de `pending` (ela nunca chegou a ser aplicada).
- Caso contrário: append em `rejected_log`, volta a `PENDING_READBACK` e agenda re-export (`mirror_schedule_export`); no materialize, o `rejected_log` é desaplicado via reconstrução (ver `mirror_materialize_from_ring`).

### Leituras de gameplay (tri-state)

Toda leitura segura `ve.mirror.mutex` (blk-41: a worker detém o mesmo mutex pelo update inteiro). `ok = false` quando a página está ausente ou `PENDING_READBACK` — o caller decide (nunca um valor inventado).

| Proc | Thread | Contrato |
| --- | --- | --- |
| `voxel_get` (`:168`) | main/física | Amostra `{block_id: u16, solid}` do voxel; tri-state via `ok`. Base do raycast e do solver. |
| `voxel_is_solid` (`:178`) | main/física | Wrapper de `voxel_get` retornando só `solid`. |
| `mirror_column_ground` (`:183`) | main/física | Desce a coluna (x,z) a partir de `y_from` procurando o primeiro sólido; atravessa chunk de ar descendo para o chunk de baixo. `ok = false` se alguma página no caminho não está MATERIALIZED. |
| `mirror_height_get` (`:211`) | main/física | VS-13 (REQ-MIR-04): altura do sólido mais alto da coluna em O(1) via `heights[x \| z<<5]`. `ok = false` se página ausente/em readback; `height = 0xFFFF` = coluna sem sólido. |

### Dreno de pedidos da física

O pedido coalescido da física (`physics_request_voxels`, map dedup na `PhysicsManager`) é consumido pela worker em **`physics_drain_requests`** (`physics.odin:138`), chamada sob `mirror.mutex` logo após `mirror_service_retries` no update. É o que transforma pedidos de corpos no solver em páginas garantidas na bolha antes do publish.

### Telemetria e ciclo de vida

#### `mirror_log_stats` (`:340`) — qualquer thread

Loga páginas vivas (e capacidade do pool), ring misses e pool misses.

#### `debug_heights_parity` (`:353`) — main (diagnóstico)

VS-19 (AC-04): varre todas as páginas MATERIALIZED conferindo `heights[x|z<<5]` contra o topo sólido derivado do bitmask. Loga OK (páginas × 1.024 colunas) ou o número de divergências. Atrelado a uma tecla de debug na main.

#### `mirror_init` / `mirror_destroy` (`:540`/`:554`, privadas) — main (boot/teardown)

Init: aloca pool (`config.mirror_pages`), ring (`config.mirror_ring_slots`), map e `free_pages` (todos os índices, VS-08). Destroy: deleta os logs de cada página viva antes das coleções.

## Invariantes cruzados

- **Regra 3 / anti-ABA** — slots de ring carregam coord+geração e só são consumidos/liberados com casamento total; o materialize valida página, entrada, tarefa e registro antes de tocar no ring.
- **Regra 4 / C2** — slot de ring nunca é liberado por quem submete; só pelos handlers de conclusão (`mirror_materialize_from_ring`, caminhos de `mirror_forget_chunk`) com coord+geração válidas.
- **Regra 2** — slot 0 da paleta é AR e nunca é reciclado; o mirror replica o que a GPU autorizou (rejeições reconciliam o otimismo).
- **Regra 7** — índice denso x-contíguo (`x | z<<5 | y<<10`) é do domínio E1/GPU; o mirror é y-contíguo (`y | z<<5 | x<<10` em `ids`/`solid`) e o heightmap é z-contíguo (`x | z<<5`). Não misturar.
- **Tri-state** — leitura de página ausente/`PENDING_READBACK` retorna `ok = false`; nunca um valor inventado.
- **BLK-41** — `ve.mirror.mutex` é detido pela worker pelo update inteiro (VS-18) e re-requisitado por consulta voxel a voxel da física; contenção conhecida, otimizações no backlog ([[sistema-mirror-fisica]]).

## Leitura sugerida a partir daqui

[[sistema-edicao-eventos]] (E1) · [[sistema-mirror-fisica]] (mirror e física) · [[ref-voxel-engine-worker]] (worker, completions, publish) · [[ref-voxel-gpu]] (rings `voxel_edits`/`edit_results`/`mirror_export_ring`) · [[ref-voxel-types]] (`EditChunkJob`, `VoxelSample`). Specs: VS-03, VS-04, VS-08, VS-10, VS-13, VS-14, VS-18, VS-19.
