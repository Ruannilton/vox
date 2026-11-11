---
id: SISTEMA-STREAMING-MUNDO
titulo: Streaming e mundo
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Streaming e mundo

Bem-vindo ao subsistema que decide **quais chunks existem, onde vivem e quando morrem**. Neste documento você vai aprender como o mundo de chunks 32³ é materializado, mantido e descarregado — e, mais importante, por que cada mecanismo existe do jeito que existe.

Se esta é a sua primeira visita, comece por [[visao-geral]]: lá estão o quadro macro das três threads e o pipeline de um frame. Aqui aprofundamos a visão de **Sistema**. Para os contratos struct-a-struct de `voxel_engine.odin` e `voxel_worker.odin`, a Referência [[ref-voxel-engine-worker]] é a parada certa. As decisões de desenho têm genealogia própria: specs [[VS-01-streaming-generate-pack|VS-01]], [[VS-08-config-ini-provisionamento|VS-08]], [[VS-10-chunks-vazios-virtuais|VS-10]], [[VS-17-streaming-incremental|VS-17]], [[VS-18-mundo-na-worker|VS-18]]; ADRs [[ADR-B1-ciclo-vida-slots|B1]], [[ADR-B5-capacidade-streaming|B5]], [[ADR-C1-config-ini-provisionamento|C1]], [[ADR-W1-ownership-mundo-worker|W1]].

## Ownership: a worker é dona do mundo

Comece por uma regra simples que organiza tudo o que vem depois: **só uma thread mexe no mundo**.

Desde a VS-18, a **worker thread** — o laço em `worker_service_frame` (`voxel_worker.odin:229`) — é a única que itera ou modifica o mapa de chunks, `VoxelEngine.active_chunks` (`voxel_engine.odin:61`). Por quê? Porque antes era a thread principal quem fazia esse trabalho, e a captura `tracy_view_22` mostrou que ela carregava ~7 ms por frame de trabalho de mundo, inflando o frame inteiro para ~11,5 ms. A migração para a worker (a Opção A do [[ADR-W1-ownership-mundo-worker|ADR-W1]]) levou a mediana do frame da main para ~1 ms.

O serviço do mundo inteiro roda no laço da worker, disparado pelo pedido de frame que a main envia a cada frame via `voxel_engine_request_frame`. Nesse laço cabem: processamento de completions (explicado na seção sobre aposentadoria), avanço do cursor de streaming, materialização por edição, o serviço do mirror e a produção do publish. A main fica com o que é barato e interativo: input/eventos, consumo do publish, gravação do command buffer e present.

Consequência direta para quem lê o código: os comentários de domínio no `VoxelEngine` que ainda dizem "thread principal" descrevem o mundo pré-VS-18 — hoje tudo isso executa na thread `voxel_worker`. E como a main precisa enxergar o mundo sem ser dona dele, existem exatamente dois caminhos de leitura: o mirror (que usa mutexes de página, ver [[sistema-mirror-fisica]]) e o publish (que veremos na seção do handoff).

## O mapa de chunks e seus estados

O mundo na CPU é um dicionário: `active_chunks`, um `map[ChunkCoordinate]ChunkRecord` (`voxel_engine.odin:61-69`). Cada registro carrega três coisas: `state` (em que ponto do ciclo de vida o chunk está), `storage_slot_index` (qual slot da GPU ele ocupa — ou nenhum) e `generation` (um contador anti-ABA, explicado mais abaixo). A máquina de estados (`voxel_engine.odin:15-20`) tem este desenho:

```
(UNLOADED) → GENERATING → CACHED ⇄ RENDERABLE
                  │
                  └→ EMPTY   (VS-10: ar puro, registro sem slot)
```

Vamos passar por cada estado como um tour:

- **GENERATING** — o registro nasce quando o cursor de streaming (seção abaixo) visita a coordenada, claima um slot da GPU e enfileira a tarefa de geração. Enquanto a tarefa está pendente ou num lote submetido, o chunk fica neste estado. Nunca é publicado: um chunk meio-gerado não pode ir para a tela.
- **CACHED** — o chunk já foi materializado, mas está fora da bolha de visão. Por que mantê-lo? Porque a câmera volta. O custo de recarregar um chunk do zero é muito maior que o custo de mantê-lo residente, então aplicamos **histerese**: chunks saem de RENDERABLE para CACHED quando saem da visão, mas só são descarregados de verdade ao cruzar o raio de descarga, maior que o raio de visão.
- **RENDERABLE** — dentro da bolha de visão e elegível ao publish, o handoff para a thread de render.
- **EMPTY** — um caso especial da VS-10: quando a geração descobre que o chunk é ar puro do primeiro ao último voxel, em vez de ocupar um slot da GPU com zeros, o registro vive no map **sem slot** (`storage_slot_index` inválido). Nunca é publicado, nunca despacha builder. Quando a câmera se afasta além do raio de descarga, o registro é simplesmente deletado — sem aposentadoria GPU, porque não há nada para aposentar. Se o jogador editar um chunk EMPTY colocando um bloco que não é ar, o chunk se materializa de volta via geração mais o mecanismo de pendências E1 (ver [[sistema-edicao-eventos]]), com retry por update se o pool de slots estiver seco.

Um detalhe de desempenho que vale a pena conhecer: a transição CACHED⇄RENDERABLE acontece numa única passada fundida com o publish, em `voxel_engine_publish_visible` (`voxel_engine.odin:308`). Antes da VS-17 eram duas varreduras separadas de ~40 mil entradas por frame (REQ-STR-03).

## Cursor espiral incremental com orçamento

Agora a pergunta prática: como o motor decide *quais* chunks gerar? A resposta é um **cursor em espiral persistente** (`StreamingCursor`, `voxel_engine.odin:51-57`): uma enumeração ordenada das coordenadas ao redor da câmera, que o motor consome em fatias ao longo de vários frames.

O streaming já teve um gatilho diferente: "a câmera mudou de chunk? então gere a vizinhança inteira de uma vez". Esse modelo sincrono produzia picos catastróficos — chegamos a medir spikes de 312–746 ms no handler, com 16 chamadas somando 7,5 s numa única captura baseline. A VS-17 trocou isso por quatro mecanismos que funcionam juntos:

1. **Geração e descarga fundidas numa única espiral.** Os offsets do cubo de `radius_unload` são pré-ordenados uma vez, por distância quadrada crescente, em `streaming_cursor_init` (`voxel_engine.odin:391`; desempates determinísticos por x, y, z). A cada coordenada visitada na fatia: se está dentro da esfera de geração e ausente do map → claim de slot + tarefa de geração; se está fora da esfera de descarga e presente → descarga. Um único laço para as duas direções elimina os dois loops que, em separado, varriam o map inteiro **e** a esfera inteira a cada cruzamento.

2. **Orçamento de tempo, não de iterações** (REQ-STR-04). Cada fatia tem no máximo `STREAMING_SLICE_BUDGET_MS = 6,0` ms de trabalho de CPU, verificado com um tick a cada 64 coordenadas — e a cada descarga, desde a VS-18, porque as descargas da reancoragem dominavam o slice. Estourado o orçamento, o cursor suspende e retoma no próximo pedido de frame; o estado dele (onde parou) persiste no `VoxelEngine`. O streaming nunca rouba mais que isso do frame.

3. **Reancoragem ao fim do ciclo.** Completada a volta inteira na espiral, os chunks que ficaram fora do raio de descarga entram em `pending_unload` (descarga também orçada, consumida antes da próxima espira) e o cursor reancora no `camera_chunk` atual (`streaming_cursor_advance`, `voxel_engine.odin:462-470`). Com a câmera parada, os ciclos ficam baratos e o custo de streaming por frame tende a zero — o cursor só faz trabalho real quando há trabalho real a fazer.

4. **Prioridade de graça** (REQ-STR-02). Não existe cota especial para os chunks vizinhos à câmera: a fila de tarefas é puxada pela worker em ordem de distância, então o chunk sob os pés do jogador é gerado primeiro naturalmente, sem mecanismo extra.

## Fila priorizada por distância e lotes de compute

As tarefas novas de geração vão para `pending_tasks`, protegidas por `queue_mutex` (`voxel_engine.odin:476-481`). Quem as consome é a worker, em `worker_thread_process` (`voxel_worker.odin:9`).

O ponto sutil está em *como* ela consome. Em vez de tirar tarefas de uma e submeter de outra, a worker faz o **claim do lote na mesma seção crítica** em que retira as tarefas da fila (REQ-SYNC-01). O que é o "claim"? É o momento em que a worker escolhe as até `chunks_per_batch` tarefas mais próximas de `priority_camera_chunk` — por varredura linear, de propósito simples (a VS-01 registrou uma heap como backlog de performance) — e publica o `SubmittedBatch` em `submitted_batches`. Daí nasce um invariante que vale para sempre neste sistema: **toda tarefa está em exatamente um dos conjuntos {pendente, submetida}**, nunca nos dois, nunca em nenhum.

O claim obedece a uma regra de identidade que o projeto trata como inegociável (regra 3 do AGENTS.md, fundamentada no [[ADR-B1-ciclo-vida-slots|ADR-B1]]): **1 claim = 1 lote = 1 valor de timeline**. O valor do lote é `submitted_batch_count + 1`, publicado no claim; o mesmo valor é sinalizado no `vkQueueSubmit2`. Como os dois são derivados do mesmo contador, são deterministicamente iguais — e é por isso que a CPU consegue saber, olhando a timeline, exatamente quais lotes a GPU já terminou.

Há também um limite de concorrência: **no máximo 3 lotes em voo** (`config.batches_in_flight`, fundamentado nos ADRs B4/B5). O ring de jobs/scratch tem uma posição por lote; antes de regravar a posição `lote % 3`, a worker espera a timeline do lote de 3 atrás (`wait_batch_slot`, `voxel_worker.odin:89-93`). Isso é backpressure natural: a CPU para de submeter quando a GPU está ocupada, sem semáforos extras.

Um lote, fisicamente, é um único command buffer de compute: um dispatch de generate `(4,4,4·N)`, uma barreira, e um dispatch de pack `(N,1,1)` — ou só o generate nos lotes `export_only` do mirror. Um único submit na fila de compute. O que a GPU executa dentro de cada dispatch é assunto de [[sistema-renderizacao]].

## Completions e aposentadoria dual (B1)

Aqui chegamos à parte mais delicada do ciclo de vida: **quem libera um slot de GPU, e quando**. A regra é curta e absoluta (regra 4 do AGENTS.md): só o handler de conclusão libera slot — nunca o caminho de unload. Por quê? Porque um slot pode ainda estar **em uso pela GPU** quando o mundo decide que o chunk deve morrer. Liberar na hora do unload faria o pool reutilizar um slot que a GPU está escrevendo. A solução é adiar a liberação para o momento em que se sabe, com certeza, que a GPU terminou — e como chunks em situações diferentes terminam em tempos diferentes, existem **duas filas de aposentadoria** (daí o nome "aposentadoria dual"):

- **`retiring_compute_slots`** — para o slot de um chunk que foi descarregado enquanto ainda estava em GENERATING e cujo lote já foi submetido: a GPU de compute ainda está (ou vai estar) escrevendo nele. Liberado quando a timeline de **compute** do lote avança.
- **`retiring_slots`** — para o slot de um chunk CACHED/RENDERABLE que já foi publicado: a GPU **gráfica** ainda pode estar lendo os dados dele no frame em curso. Liberado quando a timeline **gráfica** avança.

Quem drena as duas filas é a rotina `voxel_engine_service_completions` (`voxel_engine.odin:200`), que a worker executa a cada frame. Ela lê o contador da timeline de compute **sem bloqueio** (`vkGetSemaphoreCounterValue`) e, para cada lote com valor ≤ contador, promove seus chunks de GENERATING para CACHED/RENDERABLE e materializa o export do mirror. Depois drena as filas de aposentadoria. O caminho de unload, por sua vez, escolhe entre três rotas em `retire_generating_slot` (`voxel_engine.odin:527`): (a) a tarefa ainda está pendente → cancela e libera na hora, porque nada foi submetido à GPU; (b) já foi submetida → aposenta pela timeline do lote, o caso dual acima; (c) um caso defensivo → libera na hora.

### Anti-ABA: como o slot não "troca de dono" sem que ninguém perceba

Considere esta cilada clássica: o chunk A claima o slot 7; A é descarregado antes de a GPU terminar; o slot 7 volta ao pool e o chunk B o claima; então a conclusão atrasada do lote de A chega e, sem proteção, promoveria o slot 7 — agora de B — como se fosse de A. Esse fenômeno chama-se ABA, e a defesa dele aqui é o campo `generation`.

Cada alocação de slot incrementa `slot_generations[slot]`. Toda conclusão e todo cancelamento passa por `task_matches` (`voxel_engine.odin:130`), que confere **coordenada + slot + geração** contra o registro ativo antes de agir. Se a conclusão que chegou descreve uma geração que não é a atual do slot, ela é vencida e é descartada — uma conclusão velha nunca promove (nem esvazia) o chunk novo que reutilizou o slot. É a regra 3 do AGENTS.md na forma de código.

### Chunks EMPTY virtuais na conclusão

O pack — o dispatch de compute que comprime o chunk — escreve uma flag por chunk em `chunk_result_flags` (binding 18, host-visible, indexado por slot). Na conclusão, com a mesma ordenação de timeline e o mesmo anti-ABA, o motor lê essas flags: `CHUNK_FLAG_EMPTY` sem edições pendentes significa que o chunk é ar puro, então o estado vira EMPTY e o slot é devolvido ao pool **no instante da conclusão** — nem chega a nascer como chunk residente.

E como a renderização lida com um vizinho que é EMPTY ou ainda GENERATING? O publish marca esses casos como `NEIGHBOR_SLOT_INVALID`, que o shader já interpreta como ar (fundamentado no [[ADR-B2-fronteiras-chunks|ADR-B2]]). Resultado: render idêntico, zero mudança de shader.

## Handoff: publish sob demanda

Falta a ponte com a thread de render. Como a main recebe o conjunto de chunks visíveis sem esperar a worker rodar inteira?

A resposta é o **publish sob demanda**: a worker produz um novo conjunto publicado **apenas quando o mundo publicável mudou**, e a main renderiza com o último publish válido. A palavra "sob demanda" é importante — a main nunca espera uma rodada inteira da worker. Esse detalhe é uma emenda pós-VS-18: a primeira versão da migração usava lockstep por frame (as duas threads se sincronizavam a cada frame), o que serializava as threads e piorou o ritmo. A conservação de trabalho substituiu o lockstep.

O handoff tem três atores, coordenados por `voxel_engine_wait_published` (`voxel_engine.odin:292`) na main e `worker_service_frame` (`voxel_worker.odin:229`) na worker:

- **Pedido (main→worker)**: a cada frame, a main escreve `requested_frame` + `camera_chunk` + `frame_index` sob `frame_mutex` e acorda a worker.
- **Publish (worker→main)**: a worker decide se o mundo mudou. Publica de novo apenas se: (a) `published_camera_chunk` difere do pedido corrente, ou (b) `world_revision` mudou (completions ou edições alteraram o conjunto), ou (c) `publish_bump` explícito — a main pede keepalive quando o publish ficou velho demais. A reescrita do slot só ocorre após `vkGetSemaphoreCounterValue` não-bloqueante confirmar que o uso anterior (duas frames atrás) completou.
- **Consumo (main)**: a main usa o último publish cujo `published_camera_chunk` é igual ao chunk da câmera corrente e que não tem mais de 2 frames de idade (a guarda de staleness). E se a main acabou de cruzar de chunk e a worker ainda não publicou nada para o novo? Ela espera no máximo **2 ms**, loga "publish atrasado" e renderiza com o conjunto anterior — nunca um deadlock silencioso. Nos frames entre cruzamentos, não espera nada: render puro com input fresco.

Por que nunca há deadlock? O [[ADR-W1-ownership-mundo-worker|ADR-W1]] chama isso de **liberdade de deadlock**: todas as dependências apontam para trás no tempo. O publish do frame N depende do slot de N−2 (já submetido, já garantido); a main depende apenas de um publish que já existe. Nenhum ciclo é possível.

O publish carrega consigo um número-chave: `published_compute_value`, que é o `highest_completed_compute_value` no momento da publicação. É com ele que a main espera a timeline de compute antes de desenhar (passo 5 do pipeline de um frame em [[visao-geral]]) — ou seja, a main só usa chunks que a GPU já terminou de gerar.

## Configuração INI → capacidades derivadas

Por fim, a pergunta "quantos slots cabem?" não tem resposta fixa no código: **nada do que vimos acima é constante de compilação**. Seis parâmetros vêm de `vox.ini` (seções `[streaming]`/`[compute]`, override via `--config`, defaults embutidos com warning se ausente, parse estrito com erro fatal antes de abrir a janela). E todas as capacidades são **derivadas** das esferas discretas `x²+y²+z² ≤ r²` por `config_derive_and_validate` (`config.odin:187` — a fundamentação completa está no [[ADR-C1-config-ini-provisionamento|ADR-C1]]). O motivo histórico é o [[ADR-B5-capacidade-streaming|B5]]: no desenho antigo, o raio de geração podia exigir mais slots do que o pool tinha — uma contradição estrutural. Derivando tudo do raio de descarga (o maior de todos), o pool cabe o conjunto vivo **por construção**, para qualquer config válida.

| Derivada | Fórmula | Por quê |
| --- | --- | --- |
| `visible_capacity` | \|esfera(vision)\| | o publish publica até esse teto; excedente nunca ocorre por construção |
| `resident_slots` | ⌈\|esfera(unload)\| × 1,05⌉ | o conjunto vivo é a esfera de **unload** (CACHED incluído, histerese até lá) + o transitório de aposentadoria B1; a emenda da VS-08 absorve o backlog B5 |
| `scratch_chunks` | `batches_in_flight × chunks_per_batch` (≤ 256) | ring de jobs/scratch dos lotes |
| `mirror_pages` | ⌈\|esfera(simulation)\| × 1,5⌉ | folga de 50% no pool de páginas do mirror |
| `mirror_ring_slots` | `max(64, 2^⌈log2(scratch)⌉)` | ring de export do mirror |
| `work_item_capacity` | `visible_capacity × BRICKS_PER_CHUNK` | fila de trabalho do builder |

A histerese é validada estritamente: `vision ≤ generation < unload`, `1 ≤ vision ≤ 25` (limite de formato do `visible_index` de 16 bits da VS-09), `resident_slots ≤ 65535`, `chunks_per_batch ≤ 64`, `batches_in_flight ≤ 8`. E depois do VMA vem a **validação de máquina** (REQ-CFG-04): `config_device_bytes_required` (`config.odin:156`) soma os bytes device requeridos (pools de slots, fila de trabalho, scratch, visíveis, jobs, flags) e compara com o budget da heap device-local (`GetHeapBudgets`) × 0,9. Excedeu → erro fatal sugerindo reduzir `unload` (piso `generation + 1`). Configuração impossível morre antes de janela, não em runtime.

## Para ir mais fundo

- [[visao-geral]] — o contexto macro das três threads.
- [[sistema-renderizacao]] — o que acontece com os chunks publicados.
- [[sistema-mirror-fisica]] — a outra view do mundo e o journal.
- [[sistema-edicao-eventos]] — E1 e a materialização de chunks EMPTY.
- [[sistema-suporte]] — config INI e telemetria.
- [[ref-voxel-engine-worker]] — referência struct-a-struct de `voxel_engine.odin` + `voxel_worker.odin`.
