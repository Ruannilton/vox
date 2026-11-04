---
id: VS-03
titulo: Edição E1
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-02
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-03
---

# VS-03 — Edição E1

## Objetivo

Aplicar edições de voxels por journal bufferizado, mantendo paleta, ocupação e subdivisão consistentes e refletindo o flush na geometria do mesmo frame.

## Rastreabilidade

- GOAL: [Arquitetura — Edição de voxels](../../arquitetura.md) e [Manual Técnico — E1](../../manual-tecnico.md).
- Referência: `EditManager`, `request_voxel_edit`, `flush_voxel_edits`, `edit_ring_write` e `apply_voxel_edits` em `docs/examples/`.
- Requisitos: vincular `EDIT-E1-*` durante o catálogo de requisitos.
- Decisões: [[ADR-B3-pack-paleta|ADR-B3]] e [[ADR-E1-edicao-bufferizada|ADR-E1]].

## Escopo

- API de edição, dedup última-escrita-vence e pendências por chunk.
- Flush temporal ou forçado, agrupamento e tetos de segurança.
- Rings de jobs, edições e resultados por frames em voo.
- Compute de edição, paleta dinâmica, refcounts e tombstones.
- Atualização de ocupação, coarse, EMPTY e subdivisão.
- Feedback aplicado/no-op/rejeitado e barreira COMPUTE → TASK|MESH.

## Não escopo

- Persistência do journal em disco e mirror CPU, exceto pelos contratos necessários à futura reconciliação de VS-04.

## Dependências

- [[VS-02-task-mesh-templates|VS-02]] concluída antes da implementação.

## Interfaces e recursos

A especificar: formatos packed, offsets do ring, política de excedente, reintegração de pendências, leitura atrasada de resultados e comportamento diante de chunk ausente, em geração ou overflow.

## Cenários mínimos a detalhar

- Inserção, remoção e no-op.
- Edições repetidas no mesmo voxel e limites de flush.
- Chunk em geração e posterior reintegração.
- Crescimento de planos, reciclagem de paleta e proteção do AR.
- Chunk somente-leitura por overflow e feedback dois frames depois.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-03-AC-01 | Flush aplicado antes do draw reflete a edição no mesmo frame | Teste de integração visual e de dados | Pendente |
| VS-03-AC-02 | Decode, refcounts, ocupação, EMPTY e subdivisão permanecem consistentes | Simulação bit a bit dos cenários E1 | Pendente |
| VS-03-AC-03 | Dedup, pendências e tetos obedecem à ordenação especificada | Testes da CPU | Pendente |
| VS-03-AC-04 | AR nunca é reciclado e overflow rejeita edição com código próprio | Simulação e leitura do ring de resultados | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Formalizar journal, rings, ordering e backpressure.
- [ ] Especificar os cenários e invariantes da simulação E1.
- [ ] Definir contrato de feedback necessário a VS-04.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

- Nenhuma adicional neste rascunho; pendências de catálogo e interfaces ainda precisam ser resolvidas.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
