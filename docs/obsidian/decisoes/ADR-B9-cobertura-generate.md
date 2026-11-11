---
id: ADR-B9
titulo: Cobertura completa do generate
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
ultima_atualizacao: 2026-11-03
---

# ADR-B9 — Cobertura completa do generate

## Contexto

O dispatch antigo com `numthreads(4,4,4)` cobria somente 8.192 dos 32.768 voxels por chunk e deixava chunks posteriores do lote sem dados válidos.

## Opções

- Manter workgroups de 4×4×4: rejeitada porque não corresponde ao dispatch nem à cobertura exigida.
- Usar workgroups de 8×8×8 e derivar o job da coordenada Z global: escolhida pelo GOAL.

## Decisão

`generate_voxels` usa `[numthreads(8,8,8)]`, dispatch `(4,4,4·N)` e `job = thread_id.z / 32`. Cada thread materializa um voxel e cada grupo de 32 camadas em Z corresponde a um job do lote.

## Consequências

- Todo chunk deve ter seus 32³ voxels escritos antes do pack.
- A validação deve incluir lotes com mais de oito chunks para cobrir o defeito histórico.
- Integração pertence a [[VS-01-streaming-generate-pack|VS-01]].

## Rastreabilidade

- [Arquitetura — Registro B9](../../arquitetura.md).
- [Manual Técnico — Estágio generate](../../manual-tecnico.md).
- Referência: entry point `generate_voxels` em `docs/examples/voxel.slang`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
