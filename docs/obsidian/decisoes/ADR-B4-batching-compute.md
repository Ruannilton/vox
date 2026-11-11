---
id: ADR-B4
titulo: Batching de compute
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
ultima_atualizacao: 2026-11-03
---

# ADR-B4 — Batching de compute

## Contexto

Submeter um chunk por `vkQueueSubmit2` faz o custo fixo de submissão dominar o streaming, apesar de a estrutura de lote comportar várias tarefas.

## Opções

- Manter uma submissão por chunk: rejeitada pelo custo fixo e pela baixa utilização da fila.
- Drenar até 16 tarefas por claim e submeter um único lote: escolhida pelo GOAL.

## Decisão

A worker drena tarefas por prioridade, grava todos os jobs e despacha generate com dimensão `(4, 4, 4·N)` e pack com `(N, 1, 1)`. Cada claim produz exatamente um lote e um valor de timeline.

## Consequências

- Cancelamento e conclusão precisam varrer todas as tarefas válidas do lote.
- O anti-ABA de ADR-B1 é aplicado individualmente a cada tarefa.
- Lotes `export_only` do mirror possuem regra própria: uma tarefa e nenhum pack, conforme ADR-C2.
- Integração pertence a [[VS-01-streaming-generate-pack|VS-01]].

## Rastreabilidade

- [Manual Técnico — Pipeline de geração](../../manual-tecnico.md).
- Referência: `worker_thread_process`, `SubmittedBatch` e `MAXIMUM_CHUNKS_PER_BATCH`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
