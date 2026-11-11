---
id: REF-EDIT-MIRROR
titulo: "Referência: voxel_edit + voxel_mirror"
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Referência: `voxel_edit` + `voxel_mirror`

Você chegou à referência dos dois arquivos que sustentam o mundo na CPU: `src/engine/voxel_edit.odin` — o **journal de edição E1**, a única porta por onde o mundo muda depois de gerado — e `src/engine/voxel_mirror.odin` — o **mirror**, a cópia densa do mundo na RAM (o princípio C2: a CPU precisa consultar voxels em O(1) sem readbacks de VRAM).

Antes de continuar, duas coisas. Primeiro: este é um documento de **consulta** — ele presume que você já leu as narrativas principais, e elas respondem o "por quê" que aqui é só linkado: [[sistema-edicao-eventos]] (E1), [[sistema-mirror-fisica]] (mirror e física) e [[visao-geral]] (o quadro macro). Segundo: desde a VS-18, **as threads têm donos** — e isso muda como você lê cada procedure abaixo:

> **Quem roda onde (pós-VS-18)**: o serviço do E1 — `edit_update` e tudo que ela chama — roda **na worker**, dentro da seção sob `mirror.mutex` de `worker_service_frame`. A **main** é a única produtora de edições (via `ve_request_voxel_edit*`, sob `ve.edit.mutex`) e a consumidora do staging (`edit_ring_write`, a cada frame, antes de gravar o command buffer). Leituras de gameplay (`voxel_get`, `mirror_height_get`, raycast) vêm da main/física sob `ve.mirror.mutex` — a contenção resultante é o BLK-41, detalhado em [[sistema-mirror-fisica]].

Vizinhos úteis: dona do mundo e handoff em [[ref-voxel-engine-worker]]; recursos e rings GPU em [[ref-voxel-gpu]]; structs compartilhadas em [[ref-voxel-types]]. Genealogia: specs VS-03 (edição), VS-04 (mirror), VS-08 (config dos pools/rings), VS-10 (chunks vazios), VS-13 (heightmap), VS-14 (sólido por registry), VS-18 (mundo na worker), VS-19 (física/heights).

---

## `voxel_edit.odin` — o journal E1

Começamos pelo journal. Recorde a ideia central de [[sistema-edicao-eventos]]: nenhum código altera um voxel diretamente — todo pedido vira um `VoxelEditRequest` anexado ao journal, e as duas views do mundo (VRAM packed e mirror denso) aplicam as mesmas edições na mesma ordem, convergindo por construção. As structs abaixo são os tijolos desse mecanismo.

### Structs

#### `VoxelEditRequest` (`voxel_edit.odin:9-12`)

A unidade do E1 — um pedido mínimo de "troque o voxel X para o bloco Y": `{world_voxel: [3]i32, block_id: u32}`. O `block_id` é validado no intake contra o domínio de 16 bits do registro denso que viaja para a GPU (`> 65535` é rejeitado) — é por isso que o campo é `u32` na CPU mas `u16` no wire.

#### `EditRingCounts` (`voxel_edit.odin:14-17`)

`{job_count, edit_count}` — quantos jobs e edições o flush que usou cada slot de ring escreveu (indexado por `frame_index % NUM_FRAMES_IN_FLIGHT`). É a âncora do feedback: `edit_collect_feedback` sabe exatamente quantos resultados ler de `edit_results` no slot NUM_FRAMES_IN_FLIGHT frames depois, sem adivinhação.

#### `EditManager` (`voxel_edit.odin:19-33`)

O estado inteiro do E1, embutido em `VoxelEngine` como `ve.edit`. Domínio exclusivo: `ve.edit.mutex` — quem trava esse mutex (a main no intake, a worker no serviço) é quem pode tocar em qualquer campo.

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

Estas são as procedures que a **main** chama quando algo (input do jogador, IA, script) quer editar o mundo. O padrão é sempre o mesmo: travar `ve.edit.mutex`, empurrar na fila, acordar a worker.

#### `ve_request_voxel_edit` (`voxel_edit.odin:38`) — **main**

O intake do E1 — a API única de edição. Rejeita `block_id > 65535`; enfileira sob `ve.edit.mutex` com coalescência por `lookup` (duas intenções para o mesmo voxel antes do flush colapsam: **a última escrita vence**); `cond_signal` na `frame_condition` acorda a worker. Nunca bloqueia além do mutex — a main nunca espera o mundo.

#### `ve_request_voxel_edits_in_box` (`voxel_edit.odin:85`) — **main**

Fan-out volumétrico sobre o intake: itera min..=max em x,y,z chamando `ve_request_voxel_edit`. Uma caixa de N³ voxels vira N³ requests coalescidos pela fila — é como um clique de "preencher área" chega ao journal.

#### `edit_enqueue` (`voxel_edit.odin:76`, privada) — worker (sob `edit.mutex`)

O coração do dedup. Se o voxel já está na fila, sobrescreve `block_id`; senão, faz append e registra o índice em `lookup`. Usada pelo intake e pelo `flush_voxel_edits` (quando pendências voltam à fila) — é a rotina que garante a invariante "no máximo 1 edição por voxel por flush", de que a exatidão dos refcounts da paleta depende.

### Serviço do update (worker)

Tudo aqui roda na **worker**, chamado por `worker_service_frame`, sob `ve.edit.mutex`. É o pipeline que transforma intenções acumuladas em lote despachável.

#### `edit_update` (`voxel_edit.odin:225`) — **worker** (sob `edit.mutex`)

Um tick do E1, na ordem:

1. `edit_collect_feedback` — lê os resultados do slot de ring NUM_FRAMES_IN_FLIGHT frames atrás (a GPU já teve tempo de responder).
2. `ve_retry_empty_edits` — VS-10: retenta materialização de edições em chunks EMPTY.
3. Se `edit_flush_due` → `flush_voxel_edits` (o staging do journal).

#### `edit_collect_feedback` (`voxel_edit.odin:204`, privada) — worker (sob `edit.mutex`)

O retorno do que a GPU fez com o flush antigo no slot:

1. `InvalidateAllocation` no `edit_results` (HOST_ACCESS_RANDOM; no-op em memória coerente — faz a escrita do compute visível à CPU).
2. Por edição, conta `EDIT_RESULT_APPLIED`/`NOOP`/rejeitado; cada **rejeição** dispara `mirror_reconcile_ring_position` — porque o mirror aplicou otimisticamente no flush e precisa desfazer o que a GPU recusou (VS-04/REQ-MIRROR-09).
3. Acumula nos `stats_*` e loga diagnóstico.

#### `ve_retry_empty_edits` (`voxel_edit.odin:53`) — worker (sob `edit.mutex`)

VS-10 (REQ-VRT-04) — o mecanismo de retry do pool seco. Varre a fila: para cada edição cujo chunk está `EMPTY`, chama `ve_try_materialize_empty` (claim de slot + volta a GENERATING); descarta o no-op ar-em-ar (`block_id == 0` em chunk EMPTY — trocar ar por ar não muda nada). Se filtrou algo, reconstrói `queue`/`lookup` (o índice denso muda ao remover itens). Chamado a cada update.

#### `ve_try_materialize_empty` (`voxel_edit.odin:265`, privada) — worker (sob `edit.mutex`)

Materializa um chunk EMPTY para que a edição tenha para onde ir. `false` se `free_storage_slots` estiver vazio (o retry vem de `ve_retry_empty_edits` num tick futuro). No sucesso: claim (pop do pool, `slot_generations[slot] += 1` — **regra 3 do AGENTS.md: 1 claim = 1 lote = 1 valor de timeline, anti-ABA por coord+geração**), registro volta a `GENERATING` com slot+geração, `empty_chunks_active -= 1`. Se o chunk está na bolha de simulação e sem página, sintetiza página de mirror com zeros (`mirror_page_acquire` + `mirror_page_fill_empty`). Enfileira `GenerationTask` em `pending_tasks` sob `queue_mutex` + `cond_signal`.

#### `edit_defer_to_pending` (`voxel_edit.odin:304`, privada) — worker (sob `edit.mutex`)

Move uma edição para `pending[chunk]`, com coalescência por voxel (última escrita vence) dentro da lista do chunk. Por guardar em vez de descartar? Porque GENERATING/EMPTY são transitórios — o chunk carrega em poucos milissegundos e a intenção do jogador não deve sumir. Ressalva honesta: pendências de chunks que nunca mais carregam ficam em memória (cap por TTL/quantidade está no backlog). A saída da pendência acontece só no flush, quando o chunk está CACHED/RENDERABLE.

#### `edit_flush_due` (`voxel_edit.odin:320`, privada) — worker (sob `edit.mutex`)

O gatilho do flush, em ordem de prioridade: `force_next_flush` (se houver conteúdo) > fila/pendências vazias (não) > `EDIT_FLUSH_INTERVAL_MS <= 0` (sempre) > intervalo decorrido desde `last_flush`.

#### `flush_voxel_edits` (`voxel_edit.odin:328`, privada) — worker (sob `edit.mutex`)

O coração do E1 — monta o staging do journal, editado, para a main consumir:

1. Re-promove pendências cujo chunk chegou a CACHED/RENDERABLE de volta à `queue`.
2. Orçamento por edição: `MAX_EDITS_PER_FLUSH` no total, `MAX_EDIT_JOBS_PER_FLUSH` buckets (chunks/slots) e `MAX_EDITS_PER_CHUNK_PER_FLUSH` por chunk; o que excede fica na `queue` como `kept` (`stats_deferred += 1`) — o backpressure natural: a fila atrasa, nunca explode.
3. Chunk GENERATING/EMPTY (ou ausente do mapa) → `edit_defer_to_pending` (VS-10: sem slot não há para onde despachar).
4. Edição staged → `mirror_journal_apply` (o otimismo do mirror, que o feedback pode reconciliar depois) e packed em bucket por `storage_slot_index`.
5. Buckets viram `EditChunkJob{slot, first_edit, count}` + `staged_edits` contíguos — 1 job = 1 chunk = 1 workgroup de compute na GPU.
6. Reconstrói `queue`/`lookup` só com `kept`; se houve staging, `world_revision += 1` (gatilho de republicação do publish).

Detalhe de contrato: `last_flush`/`force_next_flush` só são tocados aqui — `edit_ring_write` não consome o intervalo (quando isso foi violado na VS-07, o flush morreu).

### Consumo do staging (main)

Aqui ocorre a troca de bastão: a worker deixou o staging pronto, e a main o copia para os rings do frame.

#### `edit_ring_write` (`voxel_edit.odin:98`) — **main**, todo frame (passo pré-submit do CB)

Sob `ve.edit.mutex`: copia `staged_jobs`/`staged_edits` para os rings mapeados no slot `frame_index % NUM_FRAMES_IN_FLIGHT` (ajustando `first_edit` para o índice global do ring), grava `ring_counts[frame_idx]` e **limpa o staging** — sem limpar, frames seguintes re-copiariam e re-despachariam o mesmo flush (no-ops redundantes no feedback). Retorna `job_count` (a main usa no dispatch). Nunca toca em `last_flush`/`force_next_flush`. Por que a main copia em vez da worker? Porque o ring é um recurso do frame, que a main gerencia junto com o command buffer e as timelines — o staging separa "quais edições" (worker, dona do mundo) de "quando no ring" (main, dona do frame).

#### `edit_ring_write_legacy` (`voxel_edit.odin:119`, privada) — **obsoleta** (@private)

A versão antiga, que coletava o feedback inline antes de copiar. Substituída pela dupla `edit_collect_feedback` (na worker) + `edit_ring_write` puro. Mantida só como histórico — não chamar.

### Reconciliação de rejeição (worker)

#### `mirror_reconcile_ring_position` (`voxel_edit.odin:422`, privada) — worker (sob `edit.mutex`)

O caminho raro — só dispara quando o shader rejeitou uma edição no feedback. O problema a resolver: o feedback sabe a *posição no ring*, e o mirror precisa de *(chunk, voxel, bloco)*. A procedure faz a busca reversa:

1. Localiza o `EditChunkJob` cuja faixa `[first_edit, first_edit+count)` cobre a posição `i`.
2. Busca reversa slot → coordenada em `active_chunks` (linear; caminho frio, não otimizado de propósito).
3. Desempacota o voxel (layout denso do registro: `x | z<<5 | y<<10` — **regra 7: o índice denso x-contíguo é do domínio E1/GPU, nunca o y-contíguo do mirror**) e delega a `mirror_reconcile_rejection`.

### Telemetria e ciclo de vida

#### `edit_log_stats` (`voxel_edit.odin:233`) — qualquer thread (mutex próprio)

Loga `applied/noop/rejected/deferred` + tamanhos de fila/pendências. Chamada pela main no teardown (`FINAL edits:`).

#### `voxel_chunk_and_index` (`voxel_edit.odin:251`, privada, contextless) — qualquer

Mundo → `(chunk, índice denso)` com `floor_div_i32` (correto para coordenadas negativas). O índice devolvido é o layout do registro/Slang (`x | z<<5 | y<<10` — regra 7, domínio E1/GPU); o mirror usa o y-contíguo, e confundir os dois é o clássico bug de desenho cruzado.

#### `edit_manager_init` / `edit_manager_destroy` (`voxel_edit.odin:457`/`:467`, privadas) — main (boot/teardown)

Init: aloca `queue`, `lookup`, `pending`, staging e `last_flush = tick_now`. Destroy: deleta as listas de cada entrada de `pending` antes do map (as listas dinâmicas são alocação por entrada).

---

## `voxel_mirror.odin` — o mundo na RAM

Agora o mirror. Recorde de [[sistema-mirror-fisica]]: cada chunk 32³ espelhado vive numa **página** (`MirrorChunkPage`), nascendo em `PENDING_READBACK`, abrindo leituras ao virar `MATERIALIZED`, e sendo evictada quando sai da bolha de simulação. As structs abaixo são definidas em `voxel_types.odin` e contratadas aqui.

### Structs (definidas em `voxel_types.odin`, contratos aqui)

#### `MirrorPageState` (`voxel_types.odin:158-161`)

Os dois estados de vida de uma página:

- `PENDING_READBACK` — página criada, conteúdo ainda desconhecido (export em voo ou aguardando slot de ring). Leitura retorna `ok = false` (tri-state — "desconhecido", nunca um valor inventado).
- `MATERIALIZED` — aberta a leituras; atualizada pelo journal do E1.

#### `MirrorChunkPage` (`voxel_types.odin:169-183`)

Uma página = um chunk no mirror, ~70 KiB. Endereços estáveis (pool fixo; o hash `pages` guarda ponteiros — é por isso que `mirror_page_release` pode recuperar o índice por aritmética de ponteiros).

| Campo | Contrato |
| --- | --- |
| `coord: ChunkCoordinate` | chunk dono (reescrito no acquire) |
| `edit_seq: u32` | revisão do journal aplicada (paridade com GPU em debug — o "relógio" que diz até qual edição esta página já viu) |
| `state: MirrorPageState` | ver acima |
| `ring_slot: i32` | slot do ring de export reservado para o preenchimento (−1 = nenhum) |
| `pending: [dynamic]VoxelEditRequest` | edições chegadas enquanto PENDING_READBACK (serão aplicadas no materialize) |
| `applied_log: [dynamic]VoxelEditRequest` | journal otimista aplicado; referência para desfazer rejeições |
| `rejected_log: [dynamic]VoxelEditRequest` | edições rejeitadas pela GPU a desfazer no próximo materialize |
| `solid: [CHUNK_VOXEL_COUNT/32]u32` | bitmask de sólidos por **registry** (VS-14: bit NON_SOLID exclui planta — a planta ocupa o voxel mas não é sólida) |
| `ids: [CHUNK_VOXEL_COUNT]u16` | ids densos, sem paleta; índice **y-contíguo** `y | z<<5 | x<<10` (regra 7 — uma coluna vertical = 64 B contíguos = 1 linha de cache) |
| `heights: [CHUNK_SIZE*CHUNK_SIZE]u16` | heightmap da coluna (VS-13), índice **z-contíguo** `x | z<<5`; y do sólido mais alto; `0xFFFF` = coluna vazia |

Repare no desenho: os três arrays grandes são exatamente as três velocidades de consulta da gameplay — "que bloco é?" (`ids`), "há algo aqui?" (`solid`, 1 bit), "onde está o chão da coluna?" (`heights`, 1 leitura O(1)).

#### `MirrorRingEntry` (`voxel_types.odin:185-189`)

Um slot do ring de export GPU→CPU: `{used, coord, generation}`. A `generation` existe por causa da **regra 3 (anti-ABA por coord+geração)**: ela casa com a geração do slot de GPU no pedido, e `mirror_ring_release`/o materialize só consomem a entrada se coord+geração baterem — sem isso, um slot reutilizado poderia entregar conteúdo de um chunk errado.

#### `MirrorManager` (`voxel_mirror.odin:8-19`)

O estado do mirror, embutido em `VoxelEngine` como `ve.mirror`. Domínio: `ve.mirror.mutex` — segurado pela worker pelo service/publish inteiro (é a raiz do BLK-41).

| Campo | Contrato |
| --- | --- |
| `mutex: sync.Mutex` | guarda páginas, pool, ring e stats |
| `pool: []MirrorChunkPage` | pool fixo (`config.mirror_pages`, VS-08) — endereços estáveis |
| `free_pages: [dynamic]u32` | índices livres do pool |
| `pages: map[ChunkCoordinate]^MirrorChunkPage` | página por chunk na bolha de simulação |
| `ring: []MirrorRingEntry` | ring de export (`config.mirror_ring_slots`, VS-08) |
| `stats_pages_live / stats_pool_misses / stats_ring_misses` | telemetria |

### Índices e bitmask (privadas, contextless)

Helpers puros de aritmética de índice, sem thread dona — chamados de quem já segura o mutex apropriado:

| Proc | Contrato |
| --- | --- |
| `mirror_chunk_and_local` (`voxel_mirror.odin:385`) | mundo → (chunk, local) com `floor_div_i32` (correto para negativos) |
| `mirror_index_from_local` (`voxel_mirror.odin:400`) | local → índice y-contíguo `y \| z<<5 \| x<<10` (regra 7) |
| `mirror_bit_test` (`voxel_mirror.odin:24`) / `mirror_bit_write` (`voxel_mirror.odin:405`) | get/set de bit em máscara `[]u32` |

### Pool de páginas

#### `mirror_page_acquire` (`voxel_mirror.odin:30`) — worker (chamada sob `mirror.mutex`)

O nascimento de uma página: pop de `free_pages`; `nil` (e `stats_pool_misses += 1`) se o pool está seco — miss só conta e tenta de novo, nunca falha o frame. Reinicializa a página: `edit_seq = 0`, `PENDING_READBACK`, `ring_slot = -1`, heights = `0xFFFF` (colunas vazias), logs vazios; registra em `pages[coord]`, `stats_pages_live += 1`.

#### `mirror_page_release` (`voxel_mirror.odin:415`, privada) — worker

A morte da página: deleta `pending`/`applied_log`/`rejected_log`, remove de `pages`, devolve o índice ao pool (calculado por aritmética de ponteiros sobre o pool — válido porque os endereços são estáveis), `stats_pages_live -= 1`.

### Agendamento e serviço (worker, sob `mirror.mutex`)

#### `mirror_request` (`voxel_mirror.odin:86`) — worker

Pedido explícito de página (usado por exemplo pelo dreno da física): no-op se já existe página ou se o chunk não está no mapa; delega a `mirror_request_page`.

#### `mirror_request_page` (`voxel_mirror.odin:490`, privada) — worker

Acquire + roteamento pelo estado do registro do chunk: `GENERATING` → `mirror_try_attach_to_generation` (piggyback no generate — o export sai junto com a geração); `EMPTY` → `mirror_page_fill_empty` (VS-10: conteúdo worldgen conhecido, sem export); caso contrário → `mirror_schedule_export` (chunk já gerado precisa de re-export).

#### `mirror_service_retries` (`voxel_mirror.odin:52`) — **worker** (chamada por `voxel_engine_update`)

A varredura de retry, todo update: páginas `PENDING_READBACK` sem `ring_slot` cujo registro voltou a existir são re-agendadas (attach a geração / fill_empty / export). Cobre pool de ring seco e janelas de estado — de novo, miss não falha o frame.

#### `mirror_schedule_export` (`voxel_mirror.odin:469`, privada) — worker

Agenda um re-export de chunk já gerado: reserva slot de ring (`mirror_ring_try_reserve`), marca `page.ring_slot`, enfileira `GenerationTask{export_only = true}` em `pending_export_tasks` sob `queue_mutex` + `cond_signal`. A worker drena essa fila como lote de tarefa única — com prioridade no claim, detalhe em [[ref-voxel-engine-worker]]. O task é `export_only` de propósito: **nunca roda pack**, porque repackar a partir do scratch apagaria edições já aplicadas no packed.

#### `mirror_try_attach_to_generation` (`voxel_mirror.odin:453`, privada) — worker

O piggyback: sob `queue_mutex` adicional, procura a tarefa de geração do chunk em `pending_tasks` e anexa o slot de ring (`task.mirror_ring_slot`, `page.ring_slot`). Falso se não achou tarefa ou ring seco — o retry vem de `mirror_service_retries`.

#### `mirror_ring_try_reserve` (`voxel_mirror.odin:431`) / `mirror_ring_release` (`voxel_mirror.odin:445`, privadas) — worker

Reserva o primeiro slot livre (marca `used`, grava coord+geração; `stats_ring_misses` se seco) / libera só se `used && coord && geração` baterem (**regra 3, anti-ABA**). E atenção à **regra 4 (C2): nunca se libera slot de ring em voo** — a liberação de fato acontece só no materialize ou nos caminhos de `mirror_forget_chunk`, nunca por quem submete.

#### `mirror_update_bubble` (`voxel_mirror.odin:317`) — **worker** (chamada por `voxel_engine_update`)

O zelador da bolha de simulação (raio `config.radius_simulation`, independente da bolha de render — você vê longe mas só toca perto):

1. Esquece páginas fora do raio: com registro ativo → `mirror_forget_chunk`; sem registro → `mirror_page_release`.
2. Para chunks dentro do raio sem página → `mirror_request_page`.

#### `mirror_forget_chunk` (`voxel_mirror.odin:93`) — worker (chamada no unload)

Desfaz o mirror de um chunk (streaming unload ou saída da bolha):

1. Sob `queue_mutex`: remove tarefas de export pendentes do chunk e libera seus slots de ring; limpa `mirror_ring_slot` de tarefas de geração pendentes.
2. Se nenhuma tarefa do chunk está em voo em `submitted_batches`, libera as entradas de ring correspondentes (coord+geração — regra 3).
3. Fora do lock: `mirror_page_release`.

### Materialização (worker; a página sai de PENDING_READBACK)

#### `mirror_page_fill_empty` (`voxel_mirror.odin:72`) — worker

VS-10 (REQ-VRT-04) — o caminho sem GPU. Chunk EMPTY tem conteúdo worldgen conhecido (ar puro): zera `ids`/`solid`, heights = `0xFFFF`, aplica o `pending` via `mirror_page_apply` (movendo para `applied_log`), e marca `MATERIALIZED` com `edit_seq += 1` — correto por construção, sem leitura de ring.

#### `mirror_materialize_from_ring` (`voxel_mirror.odin:221`) — worker (handler de conclusão do export)

A rotina mais importante do mirror: preenche a página a partir do ring de export, no handler de conclusão. Em ordem:

1. **Validação anti-ABA (regra 3)**: página existe, entrada `used`, `page.ring_slot == ring_slot`, coord+geração da entrada casam com a tarefa **e** com o registro ativo, slot de armazenamento igual. Falhou → só libera a entrada (`used = false`) e sai — conteúdo estranho nunca entra na página.
2. Espera a timeline de compute do lote (`vkWaitSemaphores` no valor do lote — o export é o último passo do generate).
3. Invalida o trecho do ring e copia os ids (y-contíguo, regra 7), reconstruindo o bitmask `solid` por `block_is_solid` (VS-14: planta ocupa o voxel mas não é sólida).
4. Deriva as 1.024 colunas `heights` do bitmask recém-preenchido (topo sólido real, imune a flutuantes — medido, não exportado; `0xFFFF` = vazia). VS-19: ignora o `mirror_heightmap_ring` (binding 20), que o generate continua escrevendo só como reserva futura (emenda do mantenedor, 2026-11-08).
5. Se há `rejected_log`: remove essas edições do `applied_log`, limpa o log e **re-aplica** o `applied_log` restante do zero (reconstrução do estado) — é assim que a rejeição da GPU é desfeita.
6. Aplica o `pending` (→ `applied_log`), marca `MATERIALIZED`, `ring_slot = -1`, `edit_seq += 1` e libera a entrada do ring — a liberação legítima, aqui no handler de conclusão (regra 4).

#### `mirror_page_apply` (`voxel_mirror.odin:506`, privada) — worker

Aplicação de uma única edição à página em estado MATERIALIZED (o journal otimista do E1):

- `ids[index] = block_id` (índice y-contíguo); `solid` por `block_is_solid`.
- **Heightmap (VS-13/VS-14)**, índice z-contíguo `x | z<<5` (atenção: não aplicar `mirror_index_from_local` aqui — são layouts diferentes de propósito): colocar sólido acima do topo (ou em coluna vazia) sobe o topo; remover o bloco do topo faz rescan de 32 leituras para o novo topo sólido; planta acima do topo, sólido em/abaixo do topo e remoção abaixo do topo são no-ops para a coluna.

### Journal e reconciliação (E1 ↔ mirror)

Estas duas procedures são a ponte: a mesma edição alimenta as duas views, e quando a GPU recusa, o mirror desfaz.

#### `mirror_journal_apply` (`voxel_mirror.odin:130`) — worker (chamada por `flush_voxel_edits`, sob `edit.mutex`)

A aplicação otimista no flush: página ausente → no-op (a GPU recebe só o journal; quando a página nascer, o `pending` estará lá); página `PENDING_READBACK` → coalescida em `pending` (última escrita vence); página `MATERIALIZED` → `mirror_page_apply` + append em `applied_log` + `edit_seq += 1`. A GPU é a autoridade final — divergências chegam como rejeição no feedback e são reconciliadas abaixo.

#### `mirror_reconcile_rejection` (`voxel_mirror.odin:148`) — worker (via `edit_collect_feedback`)

O desfaz/retifica do otimismo, por estado da página:

- Página `PENDING_READBACK` e sem rejeições anteriores: remove a edição de `pending` (ela nunca chegou a ser aplicada — simples).
- Caso contrário: append em `rejected_log`, volta a `PENDING_READBACK` e agenda re-export (`mirror_schedule_export`); no materialize, o `rejected_log` é desaplicado via reconstrução (ver `mirror_materialize_from_ring`, passo 5).

### Leituras de gameplay (tri-state)

Toda leitura segura `ve.mirror.mutex` (a worker detém o mesmo mutex pelo update inteiro — BLK-41). O contrato tri-state: `ok = false` quando a página está ausente ou `PENDING_READBACK` — "desconhecido", e o caller decide o que fazer (a física congela o passo; nunca um valor inventado).

| Proc | Thread | Contrato |
| --- | --- | --- |
| `voxel_get` (`voxel_mirror.odin:168`) | main/física | Amostra `{block_id: u16, solid}` do voxel; tri-state via `ok`. Base do raycast e do solver. |
| `voxel_is_solid` (`voxel_mirror.odin:178`) | main/física | Wrapper de `voxel_get` retornando só `solid`. |
| `mirror_column_ground` (`voxel_mirror.odin:183`) | main/física | Desce a coluna (x,z) a partir de `y_from` procurando o primeiro sólido; atravessa chunk de ar descendo para o chunk de baixo. `ok = false` se alguma página no caminho não está MATERIALIZED. |
| `mirror_height_get` (`voxel_mirror.odin:211`) | main/física | VS-13 (REQ-MIR-04): altura do sólido mais alto da coluna em O(1) via `heights[x \| z<<5]`. `ok = false` se página ausente/em readback; `height = 0xFFFF` = coluna sem sólido. |

### Dreno de pedidos da física

O pedido coalescido da física (`physics_request_voxels`, map dedup na `PhysicsManager` — quando um corpo congela por tocar página desconhecida, a coordenada entra lá) é consumido pela worker em **`physics_drain_requests`** (`physics.odin:138`), chamada sob `mirror.mutex` logo após `mirror_service_retries` no update. É o que transforma pedidos de corpos no solver em páginas garantidas na bolha antes do publish.

### Telemetria e ciclo de vida

#### `mirror_log_stats` (`voxel_mirror.odin:340`) — qualquer thread

Loga páginas vivas (e capacidade do pool), ring misses e pool misses.

#### `debug_heights_parity` (`voxel_mirror.odin:353`) — main (diagnóstico)

VS-19 (AC-04): varre todas as páginas MATERIALIZED conferindo `heights[x|z<<5]` contra o topo sólido derivado do bitmask. Loga OK (páginas × 1.024 colunas) ou o número de divergências. Atrelado a uma tecla de debug na main.

#### `mirror_init` / `mirror_destroy` (`voxel_mirror.odin:540`/`:554`, privadas) — main (boot/teardown)

Init: aloca pool (`config.mirror_pages`), ring (`config.mirror_ring_slots`), map e `free_pages` (todos os índices, VS-08). Destroy: deleta os logs de cada página viva antes das coleções.

---

## Invariantes cruzados (a cola de tudo)

As regras do `AGENTS.md` que este módulo honra, num só lugar para consulta rápida:

- **Regra 3 / anti-ABA** — slots de ring carregam coord+geração e só são consumidos/liberados com casamento total; o materialize valida página, entrada, tarefa e registro antes de tocar no ring.
- **Regra 4 / C2** — slot de ring nunca é liberado por quem submete; só pelos handlers de conclusão (`mirror_materialize_from_ring`, caminhos de `mirror_forget_chunk`) com coord+geração válidas.
- **Regra 2** — slot 0 da paleta é AR e nunca é reciclado; o mirror replica o que a GPU autorizou (rejeições reconciliam o otimismo).
- **Regra 7** — índice denso x-contíguo (`x | z<<5 | y<<10`) é do domínio E1/GPU; o mirror é y-contíguo (`y | z<<5 | x<<10` em `ids`/`solid`) e o heightmap é z-contíguo (`x | z<<5`). Não misturar.
- **Tri-state** — leitura de página ausente/`PENDING_READBACK` retorna `ok = false`; nunca um valor inventado.
- **BLK-41** — `ve.mirror.mutex` é detido pela worker pelo update inteiro (VS-18) e re-requisitado por consulta voxel a voxel da física; contenção conhecida (~1,9 ms/frame medidos na VS-19), otimizações no backlog ([[sistema-mirror-fisica]]).

## Leitura sugerida a partir daqui

[[sistema-edicao-eventos]] (E1) · [[sistema-mirror-fisica]] (mirror e física) · [[ref-voxel-engine-worker]] (worker, completions, publish) · [[ref-voxel-gpu]] (rings `voxel_edits`/`edit_results`/`mirror_export_ring`) · [[ref-voxel-types]] (`EditChunkJob`, `VoxelSample`). Specs: VS-03, VS-04, VS-08, VS-10, VS-13, VS-14, VS-18, VS-19.
