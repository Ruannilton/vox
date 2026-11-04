---
id: ADR-B1
titulo: Ciclo de vida dos slots
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
ultima_atualizacao: 2026-11-03
---

# ADR-B1 — Ciclo de vida dos slots

## Contexto

Descarregar um chunk em geração e devolver imediatamente seu slot ao pool permite que trabalho de compute em voo escreva em um slot reutilizado. A recriação na mesma coordenada também introduz o problema ABA em conclusões antigas.

## Opções

- Liberar slots imediatamente no unload: rejeitada por permitir corrida e reutilização insegura.
- Proteger todos os slots somente pela timeline gráfica: rejeitada porque chunks em geração ainda não possuem proteção gráfica.
- Geração por slot, claim atômico e aposentadoria dual: escolhida pelo GOAL.

## Decisão

Cada alocação incrementa a geração do slot. Conclusões só são aceitas quando coordenada, slot e geração correspondem ao registro ativo. A worker publica o lote submetido na mesma seção crítica em que retira suas tarefas da fila.

Slots de chunks `GENERATING` aposentam pela timeline de compute; slots `CACHED`/`RENDERABLE` aposentam pela timeline gráfica. Um claim corresponde a um lote e a um valor de timeline.

## Consequências

- Toda tarefa deve estar exatamente em um dos conjuntos: pendente ou submetida.
- Cancelamento e conclusão devem considerar somente `tasks[:task_count]`.
- Nenhum slot pode ser liberado enquanto uma timeline que o referencia não tiver avançado.
- A decisão está presente na referência, mas sua integração na reescrita permanece pendente em [[VS-01-streaming-generate-pack|VS-01]].

## Rastreabilidade

- [Arquitetura — Correção B1](../../arquitetura.md).
- [Manual Técnico — Correção B1](../../manual-tecnico.md).
- Referência: `ChunkRecord`, `GenerationTask`, `SubmittedBatch`, `retire_generating_slot` e `worker_thread_process`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
