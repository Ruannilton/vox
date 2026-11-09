---
id: EDICAO-EVENTOS
titulo: Edição e eventos
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Edição e eventos

Dois subsistemas que medeiam toda a mutação e toda a interação do motor: o **journal de edição E1** (a única porta por onde o mundo muda depois de gerado) e o **bus de eventos** (a única porta por onde o usuário — ou um roteiro gravado — fala com a aplicação). Contexto macro: [[visao-geral]]; vizinhos: [[sistema-mirror-fisica]] (o journal alimenta o mirror), [[sistema-streaming-mundo]] (a worker é dona do pipeline de edição), [[sistema-renderizacao]] (o flush nasce editado no frame). Detalhes de structs/procs: [[ref-edit-mirror]] e [[ref-assets-config-events]].

## Journal de edição E1

Especificação: [[VS-03-edicao-e1|VS-03]]; decisão: [[ADR-E1-edicao-bufferizada|ADR-E1]]. Todo pedido de alteração entra pela API única `ve_request_voxel_edit(ve, world_voxel, block_id)` (`src/engine/voxel_edit.odin:38`), de qualquer origem (input, IA, física, script). `block_id > 65535` é descartado na entrada — o registro do lote é de 16 bits.

### Intake na main, pipeline na worker

Desde a [[VS-18-mundo-na-worker|VS-18]] (REQ-WKR-03, [[ADR-W1-ownership-mundo-worker|ADR-W1]]), o E1 é bipartido:

- **Intake (main)**: `ve_request_voxel_edit` apenas trava o mutex do `EditManager`, empurra o pedido na fila (`edit_enqueue`) e sinaliza a worker (`frame_condition`). Não toca em mapa de chunks nem em mirror.
- **Pipeline (worker)**: `edit_update` (`voxel_edit.odin:225`, chamada do laço da worker em `voxel_worker.odin:239`) faz feedback → retry de EMPTYs → flush devido. O flush (`flush_voxel_edits`, `voxel_edit.odin:328`) monta o staging; a **main** consome esse staging em `edit_ring_write` (`voxel_edit.odin:98`, chamada do `main.odin:247`), que copia jobs/edições para o ring host-visible do frame e retorna `job_count`. O staging vale por uma cópia (limpo após o uso) — sem isso, frames seguintes re-despachariam o mesmo flush como no-ops redundantes (bug registrado no histórico da VS-03).

### Fila, dedup e pendências

A fila ativa é um array dinâmico + mapa voxel→índice (`EditManager.queue`/`lookup`): o dedup **última-escrita-vence** garante no máximo 1 edição por voxel por flush — a invariante que torna os refcounts exatos (cada voxel decrementa exatamente o tipo que tinha).

Pedidos cujo chunk está `GENERATING`, `EMPTY` ou fora do mapa vão para `pending[chunk]` (mesmo dedup dentro da lista) e reintegram à fila no primeiro flush em que o chunk está `CACHED`/`RENDERABLE`. O caso EMPTY é especial (VS-10): sem slot não há para onde despachar, então `ve_retry_empty_edits` tenta **materializar** o chunk (claim de slot, mirror sintetizado com zeros se dentro da bolha de simulação, task de geração enfileirada) — edição ar-em-ar sobre EMPTY é descartada. Pendências de chunks que nunca mais carregam ficam em memória (capar por TTL/quantidade é backlog, junto ao save).

### Flush e tetos de segurança

O flush é **temporal**: `EDIT_FLUSH_INTERVAL_MS = 100 ms` (0 = todo frame) mais `force_next_flush` para latência mínima. O staging agrupa edições contíguas por `storage_slot_index` (1 `EditChunkJob` por chunk = 1 workgroup) e obedece aos tetos: `MAX_EDITS_PER_FLUSH = 4.096`, `MAX_EDIT_JOBS_PER_FLUSH = 256`, `MAX_EDITS_PER_CHUNK_PER_FLUSH = 1.024`. O excedente permanece na fila (`stats_deferred` contabiliza) — backpressure natural. Só chunks `CACHED`/`RENDERABLE` entram no lote: a GPU jamais disputa slot com a fila de geração (B1). O gating (intervalo/force) é consumido aqui; `edit_ring_write` só copia e não toca no carimbo (outro bug corrigido na VS-07, que tinha deixado o flush morto).

### Na GPU: paleta dinâmica com refcount

O dispatch de `apply_voxel_edits` roda **no command buffer do frame, antes do builder da fila de trabalho**, com barreira COMPUTE(write) → COMPUTE(read) — a geometria já nasce editada no mesmo frame, sem dirty flag nem re-mesh assíncrono (a malha é refeita on-the-fly de qualquer forma, ADR-CAMINHO-B). O shader mantém a paleta dinâmica (ADR-B3): slot 0 (AR) **nunca** é reciclado; slot com refcount 0 é reciclado por evicção preguiçosa com tombstone; `palette_size` só cresce dentro do flush; refcounts garantem que cada edição decrementa exatamente o tipo antigo. Cenários e invariantes foram validados bit a bit por `tools/sim/edit_sim.py` antes da integração.

### Feedback e reconciliação de rejeições

O ring de resultados (binding 15, host-visible) devolve um código por edição: `APPLIED = 0`, `NOOP = 1`, `REJECTED_OVERFLOW` (chunk com `CHUNK_FLAG_PALETTE_OVERFLOW` — somente-leitura, regra 6) e `REJECTED_PALETTE_FULL`. Dois frames depois (slot protegido pela espera de frames em voo), `edit_collect_feedback` (`voxel_edit.odin:204`) lê os códigos, acumula `stats_applied/noop/rejected/deferred` e **reconcilia as rejeições no mirror**: como o mirror aplica otimisticamente no flush, `mirror_reconcile_ring_position` mapeia a posição do ring de volta a (chunk, voxel, bloco) — busca reversa slot→coordenada — e chama `mirror_reconcile_rejection` para reverter (contrato VS-04, [[sistema-mirror-fisica]]).

## Bus de eventos

Especificação: [[VS-07-eventos-input-replay|VS-07]]; decisão: [[ADR-I1-bus-eventos-input-replay|ADR-I1]] (Opção A: bus central, tempo de parede relativo, JSONL, replay best-effort — determinismo bit-exato é backlog explícito). Módulo: `src/engine/events.odin`.

### Modelo: produção contextless, dreno por frame

Todo evento tem `t` (segundos desde o início da aplicação, `glfw.GetTime() − t0`), `type` e payload tipado. Os tipos cobrem **input** (`KeyPress`, `KeyRelease`, `MouseMove`, `MouseButton`, `CloseRequested`) e **comando** (`TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `Wait`, `ToggleTelemetry`, `TelemetrySnapshot`) — comandos usam exatamente o mesmo pipeline que input.

Os produtores (callbacks GLFW, cursor de replay) são funções **contextless** (`events_push_now`, `events_push`): sem `context` de runtime, sem alocação, sem log — apenas empurram numa fila anel fixa de 4.096 eventos (overflow defensivo: descarte contado + warning único por sessão). O loop drena **uma vez por frame** (`events_drain`, chamada no `main.odin:190` após `glfw.PollEvents()` e antes do update): grava a linha JSONL, aplica o estado derivado de teclas (`pressed` + `scheduled_release`) e despacha ao handler registrado por tipo. O conjunto de teclas pressionadas é **derivado** dos eventos — o polling `glfw.GetKey` foi eliminado; `KeyPress{duration}` agenda um `KeyRelease` sintetizado em `t + duration` no dreno (última escrita vence).

### Gravação JSONL

Gravação **default-ligada**: cada evento drenado vira uma linha JSON escrita e flushed (thread única — JSONL não precisa de trailer, então crash não corrompe o arquivo). O destino default é `bin/debug/<VERSION_STRING>/events/events_YYYYMMDD_HHMMSS.jsonl` (definido por `debug_paths_init`, `src/engine/debug_paths.odin`; versão em `src/version.odin`). Flags: `--record <caminho>` fixa o destino (cria diretórios), `--no-record` desliga (conflito com `--record`: `--record` vence). Gravar durante replay usa o tempo da sessão corrente — a invariante "`t` = quando foi emitido" vale sempre. O validador `tools/sim/events_check.py` checa schema por tipo e `t` monotônico.

### Replay best-effort

`--replay <arquivo.jsonl>` valida e carrega o arquivo **antes da janela** (ausente/ilegível ou JSON inválido na linha 1 → erro fatal, exit ≠ 0; linha inválida ou tipo desconhecido depois disso → skip com warning e contagem no sumário). Os eventos são ordenados por `t` e um cursor despacha por frame os devidos (`events_replay_feed`, antes do dreno): cada evento entra na fila com timestamp da sessão corrente. Os parâmetros de tempo roteirizam o comportamento:

- **`KeyPress{duration}`** — "segurar tecla X por Y segundos" é um evento único; o release é sintetizado.
- **`Wait{seconds}`** — segura o cursor: nada com `t` anterior a `t_emitido + seconds` é despachado antes de o **relógio da sessão** passar desse instante (o app continua renderizando).

O replay é 1× best-effort: eventos disparam nos mesmos tempos de parede, mas a integração por `deltaTime` faz trajetórias dependerem do frame rate. Ao fim do stream, log de sumário (`despachados/pulados/ignorados/duração`) e a sessão continua interativa — a menos que `--exit-after-replay` feche a aplicação (pipelines automatizados de captura).

### Teardown

O shutdown padrão é **fast-exit**: flush do Tracy e `os.exit` — a worker morre com o processo, sem join. O teardown completo (stop + broadcast + join da worker, esperas de device, validação de vazamentos) só roda com `--full-teardown`, usado em smokes/CI. Detalhes: [[visao-geral]] e [[sistema-engine-fundacao]].

## Fronteiras do sistema

- O E1 não persiste journal em disco (save é backlog) e não edita concorrente fora do intake main/worker.
- O bus não faz replay determinístico (Opção C da ADR-I1, backlog), gamepad, console interativo nem compactação de `MouseMove`.
- Comandos `AddBlock`/`RemoveBlock` são a ponte entre os dois mundos deste documento: o handler do evento chama `ve_request_voxel_edit`, e a partir daí vale tudo da primeira seção.

## Leitura sugerida

[[sistema-mirror-fisica]] (journal do mirror e reconciliação) → [[sistema-streaming-mundo]] (worker dona do pipeline, materialização EMPTY) → [[sistema-renderizacao]] (edições antes do builder). Referência de structs: [[ref-edit-mirror]], [[ref-assets-config-events]]. Genealogia: [[VS-03-edicao-e1|VS-03]], [[VS-07-eventos-input-replay|VS-07]], [[VS-18-mundo-na-worker|VS-18]], [[ADR-E1-edicao-bufferizada|ADR-E1]], [[ADR-I1-bus-eventos-input-replay|ADR-I1]].
