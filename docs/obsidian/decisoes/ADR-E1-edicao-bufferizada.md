---
id: ADR-E1
titulo: Edição bufferizada por journal
tipo: decisao
status: aceita
specs_afetadas:
  - VS-03
  - VS-04
ultima_atualizacao: 2026-11-03
---

# ADR-E1 — Edição bufferizada por journal

## Contexto

Edições podem vir de input, IA, física ou scripts e precisam atualizar a view de render sem disputar chunks em geração nem exigir remalha assíncrona.

## Opções

- Edição imediata e independente por consumidor: rejeitada por criar ordenações e autoridades divergentes.
- Journal único com dedup, flush em lote e compute antes do render: escolhida pelo GOAL.

## Decisão

Toda alteração entra por `request_voxel_edit(world_voxel, block_id)`. O journal CPU faz dedup última-escrita-vence, retém pedidos de chunks indisponíveis e agrupa o flush por chunk.

O compute `apply_voxel_edits` executa no command buffer do frame antes do render pass, seguido de barreira COMPUTE → TASK|MESH. Rings de dois frames transportam jobs, edições e resultados. Os tetos são 4.096 edições, 256 chunks e 1.024 edições por chunk por flush.

## Consequências

- Chunks em geração não participam do flush; pendências reintegram após a conclusão.
- Refcounts, tombstones, planos e subdivisão precisam preservar ADR-B3 e ADR-CAMINHO-B.
- Chunks em overflow são somente-leitura e produzem rejeição explícita.
- O mesmo stream ordenado alimenta o mirror em ADR-C2.
- Integração principal pertence a [[VS-03-edicao-e1|VS-03]].

## Rastreabilidade

- [Arquitetura — Edição E1](../../arquitetura.md).
- [Manual Técnico — E1](../../manual-tecnico.md).
- Referência: `EditManager`, funções `request_voxel_edit`/`flush_voxel_edits` e `apply_voxel_edits`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
