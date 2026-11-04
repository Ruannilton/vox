---
id: ADR-B8
titulo: Distância de chunks com inteiros de 64 bits
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
ultima_atualizacao: 2026-11-03
---

# ADR-B8 — Distância de chunks com inteiros de 64 bits

## Contexto

`calculate_squared_distance` usa coordenadas inteiras e pode exceder a faixa de `int32` ao elevar diferenças ao quadrado ou somar os termos.

## Opções

- Manter intermediários de 32 bits: rejeitada por permitir overflow e ordenação incorreta.
- Usar intermediários de 64 bits: escolhida pelo backlog normativo do GOAL.

## Decisão

As diferenças e os cálculos de distância quadrada devem usar intermediários de 64 bits na nova implementação de streaming. A referência existente ainda contém o cálculo antigo e não deve ser copiada sem aplicar esta decisão.

## Consequências

- Os testes de VS-01 devem incluir coordenadas suficientemente distantes para demonstrar ausência de overflow.
- A decisão corrige cálculo de prioridade/distância; não altera os raios definidos por ADR-B5.
- Integração pertence a [[VS-01-streaming-generate-pack|VS-01]].

## Rastreabilidade

- [Arquitetura — Backlog B8](../../arquitetura.md).
- [Manual Técnico — Pendentes](../../manual-tecnico.md).
- Referência: `calculate_squared_distance` em `docs/examples/voxel.odin`.

## Histórico

- 2026-11-03 — Direção do GOAL registrada como aceita; correção não implementada.
