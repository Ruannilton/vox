---
id: ADR-B2
titulo: Fronteiras entre chunks
tipo: decisao
status: aceita
specs_afetadas:
  - VS-02
ultima_atualizacao: 2026-11-03
---

# ADR-B2 — Fronteiras entre chunks

## Contexto

Tratar coordenadas fora de um chunk como ar faz com que faces internas entre dois chunks sólidos sejam emitidas em duplicidade.

## Opções

- Manter vizinhos como ar e corrigir geometria por remalhas: rejeitada por introduzir trabalho e estado adicionais.
- Publicar os seis vizinhos por frame e redirecionar leituras de fronteira: escolhida pelo GOAL.

## Decisão

`VisibleChunk` carrega `neighbor_slots[6]`, preenchidos pela CPU a cada frame. O shader redireciona leituras fora do chunk à ocupação real do vizinho correspondente.

Somente vizinhos `CACHED`/`RENDERABLE` são publicados. Vizinho ausente ou em geração usa `NEIGHBOR_SLOT_INVALID` e é tratado como ar; a geometria é naturalmente corrigida em um frame posterior porque é reconstruída on-the-fly.

## Consequências

- A ordem dos vizinhos deve ser a mesma de `FACE_NORMALS`.
- A aposentadoria gráfica de ADR-B1 protege os slots publicados durante frames em voo.
- A espera da timeline de compute deve tornar a ocupação dos vizinhos visível antes de TASK/MESH.
- Integração e validação pertencem a [[VS-02-task-mesh-templates|VS-02]].

## Rastreabilidade

- [Arquitetura — Correção B2](../../arquitetura.md).
- [Manual Técnico — Task e mesh shaders](../../manual-tecnico.md).
- Referência: `VisibleChunk`, publicação de `neighbor_slots` e `is_voxel_solid`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
