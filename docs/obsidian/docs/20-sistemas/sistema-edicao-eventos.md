---
id: EDICAO-EVENTOS
titulo: Edição e eventos
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Edição e eventos

Este documento apresenta os dois subsistemas que medeiam toda a mutação e toda a interação do motor. O primeiro é o **journal de edição E1** — a única porta por onde o mundo muda depois de gerado. O segundo é o **bus de eventos** — a única porta por onde o usuário, ou um roteiro gravado, fala com a aplicação. Juntos, eles respondem a duas perguntas que todo motor voxel precisa responder: "como um clique vira um bloco trocado?" e "como eu repito exatamente o que o usuário fez?".

Contexto macro: [[visao-geral]]. Os documentos vizinhos assumem o que você vai aprender aqui: [[sistema-mirror-fisica]] (o journal alimenta o mirror), [[sistema-streaming-mundo]] (a worker é dona do pipeline de edição) e [[sistema-renderizacao]] (o flush nasce editado no frame). Detalhes de structs e procedures: [[ref-edit-mirror]] e [[ref-assets-config-events]].

## Journal de edição E1

Comece pelo conceito central: o **journal**. É o registro append-only das edições — nenhuma parte do código altera um voxel diretamente; todo pedido passa por ele. Por quê? Porque o mundo tem duas views materializadas da mesma verdade (VRAM packed e mirror denso na RAM, veja [[visao-geral]]): se cada sistema editasse "do seu jeito", as views divergiam. Com um journal único, ambas aplicam as mesmas edições na mesma ordem e convergem por construção. É a especificação [[VS-03-edicao-e1|VS-03]] e a decisão [[ADR-E1-edicao-bufferizada|ADR-E1]].

O journal mora no `EditManager` (`src/engine/voxel_edit.odin`). A porta de entrada é a API única `ve_request_voxel_edit(ve, world_voxel, block_id)` (`voxel_edit.odin:38`), usada por qualquer origem — input do jogador, IA, física, script. Um detalhe de contrato: `block_id > 65535` é descartado na entrada, porque o registro do lote que viaja para a GPU é de 16 bits.

### Intake na main, pipeline na worker

Aqui entra o primeiro desenho que vale a pena entender. Desde a [[VS-18-mundo-na-worker|VS-18]] (REQ-WKR-03, [[ADR-W1-ownership-mundo-worker|ADR-W1]]), o E1 é bipartido entre as duas threads:

- **Intake (main)**: `ve_request_voxel_edit` apenas trava o mutex do `EditManager`, empurra o pedido na fila (`edit_enqueue`) e sinaliza a worker (`frame_condition`). Não toca em mapa de chunks nem em mirror — a main não é dona do mundo, então não pode decidir nada sobre ele.
- **Pipeline (worker)**: `edit_update` (`voxel_edit.odin:225`, chamada do laço da worker em `voxel_worker.odin:239`) executa o feedback do flush anterior, tenta de novo os pedidos pendentes e decide se está na hora de um flush. Quando está, chama `flush_voxel_edits` (`voxel_edit.odin:328`), que monta o **staging**.

O que é o **staging**? É o pacote intermediário de edições que a worker deixa pronto para a main consumir. A main consome em `edit_ring_write` (`voxel_edit.odin:98`, chamada do `main.odin:247`), que copia jobs e edições para o ring host-visible do frame e retorna quantos jobs foram escritos. Por que esse indireto, em vez de a worker escrever direto no ring? Porque o ring é um recurso do frame, que a main gerencia junto com o command buffer e as timelines — quem grava o ring precisa estar sincronizado com o ciclo de frames, e quem decide *quais* edições entram precisa ser dona do mapa de chunks. O staging separa essas duas responsabilidades. E ele vale por uma única cópia: depois de consumido, é limpo — sem isso, frames seguintes re-despachariam o mesmo flush como no-ops redundantes (bug registrado no histórico da VS-03).

### Fila, dedup e pendências

A fila ativa é um array dinâmico acompanhado de um mapa voxel→índice (`EditManager.queue`/`lookup`). Esse par existe para o **dedup última-escrita-vence**: se você pedir dois blocos diferentes para o mesmo voxel antes do próximo flush, só a segunda intenção sobrevive.

Por que bufferizar edições em vez de aplicar na hora? Porque a edição na GPU é um lote — há custo fixo de montar jobs, copiar para o ring e despachar compute — e porque um jogador num clique pode pedir dezenas de voxels. Agrupando em lotes de 100 ms, o custo é amortizado. E o dedup tem um efeito crucial: garante no máximo 1 edição por voxel por flush. Essa é a invariante que torna os refcounts exatos — cada voxel decrementa exatamente o tipo de bloco que tinha, nunca o mesmo bloco duas vezes (voltamos a isso na paleta, abaixo).

Pedidos cujo chunk ainda está `GENERATING`, está `EMPTY` ou está fora do mapa não podem ser aplicados agora. Em vez de rejeitá-los, eles vão para a estrutura de **pendências** — um mapa `pending[chunk]` que guarda a lista por chunk (com o mesmo dedup dentro da lista). Por quê guardar em vez de devolver erro? Porque esses estados são transitórios: o chunk vai carregar em alguns milissegundos, e a edição do jogador não deveria sumir por causa disso. No primeiro flush em que o chunk está `CACHED`/`RENDERABLE`, a pendência reintegra à fila.

O caso `EMPTY` é especial (VS-10): chunk vazio não tem slot na GPU — é só ar, um registro sem custo de memória. Sem slot não há para onde despachar a edição, então `ve_retry_empty_edits` tenta **materializar** o chunk: faz claim de um slot, sintetiza um mirror de zeros (se dentro da bolha de simulação) e enfileira a task de geração. Uma exceção: edição ar-em-ar sobre EMPTY é descartada, pois não muda nada. Uma ressalva honesta: pendências de chunks que nunca mais carregam ficam em memória — capar por TTL/quantidade é backlog, junto ao save.

### Flush e tetos de segurança

O **flush** é o momento em que as edições acumuladas na fila viram um lote despachável para a GPU. Ele é **temporal**: dispara a cada `EDIT_FLUSH_INTERVAL_MS = 100 ms` (0 = todo frame), ou imediatamente quando `force_next_flush` está marcado — um jogo que responde a clique com até 100 ms de atraso percebível, então a latência mínima fica disponível para quando importa.

Dentro do flush, o staging agrupa edições contíguas por `storage_slot_index` — um `EditChunkJob` por chunk, e como um job vira um workgroup de compute, isso significa exatamente 1 workgroup por chunk editado. O lote obedece a três tetos de segurança: `MAX_EDITS_PER_FLUSH = 4.096` edições no total, `MAX_EDIT_JOBS_PER_FLUSH = 256` chunks por lote e `MAX_EDITS_PER_CHUNK_PER_FLUSH = 1.024` edições num mesmo chunk. O excedente simplesmente permanece na fila para o próximo flush (`stats_deferred` contabiliza quanto) — é o **backpressure** natural do sistema: a fila nunca explode, apenas atrasa. E só chunks `CACHED`/`RENDERABLE` entram no lote, garantindo que a GPU jamais disputa slot com a fila de geração (B1). Uma lição de bug corrigido: o gating (intervalo/force) é consumido aqui no flush — `edit_ring_write` só copia e não toca no carimbo de tempo; quando isso foi violado na VS-07, o flush ficou morto.

### Na GPU: paleta dinâmica com refcount

A GPU guarda chunks comprimidos em bitmask + **paleta dinâmica**: em vez de 16 bits por voxel, cada voxel guarda um índice de slot na paleta do chunk, e a paleta diz qual bloco aquele índice representa. Isso existe para comprimir: terreno natural tem poucos blocos distintos por chunk. A paleta é mantida pelo shader `apply_voxel_edits`, e é dinâmica porque edições podem introduzir blocos que a worldgen nunca colocou ali.

Aqui mora o **refcount**: cada slot da paleta conta quantos voxels o referenciam. Por que contar? Duas decisões de desenho dependem disso (ADR-B3):

- **Reciclagem**: quando um voxel muda de bloco, o slot do tipo antigo perde um refcount; ao chegar em 0, o slot pode ser reciclado — por evicção preguiçosa com tombstone, não imediatamente, para não invalidar slots que outros voxels ainda usam.
- **Exatidão**: como o dedup garante 1 edição por voxel por flush, cada edição decrementa exatamente o tipo antigo — nem mais, nem menos. O refcount nunca sai do sincronizado.

E duas invariantes protegem a integridade: o slot 0 (AR) **nunca é reciclado** (regra 2 do AGENTS.md — ar é o estado default), e `palette_size` só cresce dentro do flush. Os cenários e invariantes foram validados bit a bit pela simulação `tools/sim/edit_sim.py` antes da integração — mudança em shader passa por simulação antes, por convenção do projeto.

O dispatch de `apply_voxel_edits` roda **no command buffer do frame, antes do builder da fila de trabalho**, com barreira COMPUTE(write) → COMPUTE(read). A consequência prática: a geometria já nasce editada no mesmo frame — sem dirty flag e sem re-mesh assíncrono, porque a malha é refeita on-the-fly de qualquer forma (ADR-CAMINHO-B).

### Feedback e reconciliação de rejeições

A GPU não aceita tudo. O **ring de resultados** (binding 15, host-visible) devolve um código por edição: `APPLIED = 0`, `NOOP = 1`, `REJECTED_OVERFLOW` (o chunk está com `CHUNK_FLAG_PALETTE_OVERFLOW` — somente-leitura, regra 6 do AGENTS.md) e `REJECTED_PALETTE_FULL`.

Dois frames depois — o slot do ring fica protegido pela espera de frames em voo — `edit_collect_feedback` (`voxel_edit.odin:204`) lê esses códigos e acumula as estatísticas (`stats_applied/noop/rejected/deferred`). O passo seguinte é a **reconciliação**: o mirror aplica edições otimisticamente no flush, então uma rejeição precisa ser desfeita lá. Como encontrar o voxel a partir da posição no ring? `mirror_reconcile_ring_position` faz a busca reversa slot→coordenada e então `mirror_reconcile_rejection` reverte o bloco no mirror (contrato VS-04, [[sistema-mirror-fisica]]). Resultado: mirror e GPU convergem mesmo quando a GPU recusa.

**Para ir mais fundo:** [[sistema-mirror-fisica]] (journal do mirror e reconciliação) → [[sistema-streaming-mundo]] (worker dona do pipeline, materialização de EMPTY).

## Bus de eventos

O segundo subsistema é o **bus de eventos**: um canal único por onde todo input e todo comando fluem. A especificação é [[VS-07-eventos-input-replay|VS-07]] e a decisão é [[ADR-I1-bus-eventos-input-replay|ADR-I1]] — Opção A: bus central, tempo de parede relativo, JSONL, replay best-effort (determinismo bit-exato é backlog explícito). O módulo vive em `src/engine/events.odin`.

### Modelo: produção contextless, dreno por frame

Todo evento tem três partes: `t` (segundos desde o início da aplicação, calculado como `glfw.GetTime() − t0`), `type` e um payload tipado. Os tipos cobrem **input** (`KeyPress`, `KeyRelease`, `MouseMove`, `MouseButton`, `CloseRequested`) e **comando** (`TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `Wait`, `ToggleTelemetry`, `TelemetrySnapshot`). Comandos usam exatamente o mesmo pipeline que input — essa é a graça do desenho: um roteiro gravado e um teclado vivo são indistinguíveis para o resto do motor.

Os produtores — os callbacks GLFW e o cursor de replay — são funções **contextless** (`events_push_now`, `events_push`). "Contextless" significa: sem `context` de runtime do Odin, sem alocação, sem log — apenas empurram o evento numa fila anel fixa de 4.096 eventos. Por esse desenho? Porque são chamados de dentro de callbacks GLFW, onde o `context` pode não estar disponível e onde qualquer alocação ou log seria um risco desnecessário. O overflow é tratado defensivamente: descarte contado mais um warning único por sessão.

O consumo é o **dreno**, que roda **uma vez por frame** (`events_drain`, chamado no `main.odin:190` logo após `glfw.PollEvents()` e antes do update). Em um único ponto por frame, o dreno: grava a linha JSONL (falamos disso abaixo), aplica o estado derivado de teclas (`pressed` + `scheduled_release`) e despacha o evento ao handler registrado por tipo.

Repare numa consequência elegante: o conjunto de teclas pressionadas é **derivado** dos eventos — o polling `glfw.GetKey` foi eliminado. E aqui entra o **HoldKey/duration**: um `KeyPress` pode vir com `duration`, significando "segurar esta tecla por Y segundos". O dreno agenda um `KeyRelease` sintetizado em `t + duration` (última escrita vence se houver outro evento para a mesma tecla). Por que modelar "segurar tecla" como um evento único em vez de um par press/release gravado? Porque no replay o par se desalinha com o frame rate — o release sintetizado cai exatamente no tempo roteirizado, independentemente de quantos frames passaram entre um e outro.

### Gravação JSONL

A gravação é **default-ligada**: cada evento drenado vira uma linha JSON escrita e com flush imediato. O formato é **JSONL** — JSON Lines, um objeto JSON por linha. Por JSONL? Porque não precisa de trailer de arquivo: se o processo crashar, o arquivo já está íntegro até a última linha escrita, e a validação linha a linha é trivial. O destino default é `bin/debug/<VERSION_STRING>/events/events_YYYYMMDD_HHMMSS.jsonl`, definido por `debug_paths_init` (`src/engine/debug_paths.odin`; a versão vem de `src/version.odin`). Flags: `--record <caminho>` fixa o destino (cria diretórios) e `--no-record` desliga; se as duas aparecerem, `--record` vence. Gravar durante replay usa o tempo da sessão corrente — a invariante "`t` = quando foi emitido" vale sempre. O validador `tools/sim/events_check.py` checa o schema por tipo e o `t` monotônico.

### Replay best-effort

O replay é a leitura de um JSONL gravado como se fosse input vivo. `--replay <arquivo.jsonl>` valida e carrega o arquivo **antes da janela abrir** — arquivo ausente/ilegível ou JSON inválido na linha 1 é erro fatal (exit ≠ 0); linha inválida ou tipo desconhecido depois disso é skip com warning e contagem no sumário. Os eventos são ordenados por `t` e um cursor despacha por frame os devidos (`events_replay_feed`, antes do dreno): cada evento entra na fila com o timestamp da sessão corrente.

O "best-effort" do nome merece explicação: eventos disparam nos mesmos **tempos de parede** da sessão original, mas a integração por `deltaTime` faz trajetórias dependerem do frame rate. Por não ser determinístico? Porque o determinismo bit-exato exigiria fixar o passo de simulação e eliminar toda dependência de tempo real — custo alto para o benefício (Opção C da ADR-I1, registrada como backlog). Para capturas e testes visuais, tempo de parede é suficiente.

Os parâmetros de tempo roteirizam o comportamento:

- **`KeyPress{duration}`** — "segurar tecla X por Y segundos" é um evento único; o release é sintetizado no dreno, como vimos acima.
- **`Wait{seconds}`** — segura o cursor: nada com `t` anterior a `t_emitido + seconds` é despachado antes de o **relógio da sessão** passar desse instante (o app continua renderizando no meio tempo).

Ao fim do stream, um log de sumário (`despachados/pulados/ignorados/duração`) e a sessão continua interativa — a menos que `--exit-after-replay` feche a aplicação (para pipelines automatizados de captura).

### Teardown

O shutdown padrão é **fast-exit**: flush do Tracy e `os.exit` — a worker morre com o processo, sem join. O teardown completo (stop + broadcast + join da worker, esperas de device, validação de vazamentos) só roda com `--full-teardown`, usado em smokes/CI. Detalhes: [[visao-geral]] e [[sistema-engine-fundacao]].

**Para ir mais fundo:** [[visao-geral]] (fast-exit e as três threads) → [[sistema-engine-fundacao]] (sincronização de frames).

## Fronteiras do sistema

Para fechar, o que estes subsistemas **não** fazem hoje:

- O E1 não persiste journal em disco (save é backlog) e não edita concorrente fora do intake main/worker.
- O bus não faz replay determinístico (Opção C da ADR-I1, backlog), gamepad, console interativo nem compactação de `MouseMove`.
- Os comandos `AddBlock`/`RemoveBlock` são a ponte entre os dois mundos deste documento: o handler do evento chama `ve_request_voxel_edit`, e a partir daí vale tudo da primeira seção.

## Leitura sugerida

[[sistema-mirror-fisica]] (journal do mirror e reconciliação) → [[sistema-streaming-mundo]] (worker dona do pipeline, materialização EMPTY) → [[sistema-renderizacao]] (edições antes do builder). Referência de structs: [[ref-edit-mirror]], [[ref-assets-config-events]]. Genealogia: [[VS-03-edicao-e1|VS-03]], [[VS-07-eventos-input-replay|VS-07]], [[VS-18-mundo-na-worker|VS-18]], [[ADR-E1-edicao-bufferizada|ADR-E1]], [[ADR-I1-bus-eventos-input-replay|ADR-I1]].
