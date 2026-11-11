---
id: ADR-B3
titulo: Pack completo e paleta com AR reservado
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
  - VS-03
ultima_atualizacao: 2026-11-03
---

# ADR-B3 — Pack completo e paleta com AR reservado

## Contexto

O pack precisa transformar o scratch denso em ocupação, coarse, paleta e planos sem busca linear por voxel. Também deve tratar chunks com mais tipos de bloco do que a paleta comporta sem corromper dados.

## Opções

- Busca linear na paleta e ausência de slot reservado: rejeitada pelo custo e pelo risco de decodificar ar como bloco sólido.
- Ranking por prefixo popcount, AR fixo no slot 0 e overflow explícito: escolhida pelo GOAL.

## Decisão

O pack executa quatro fases: ocupação/presença/custo; coarse e prefixo; paleta; planos e subdivisão. O índice no plano é `rank + 1`, mantendo o slot 0 sempre como AR.

A capacidade efetiva é 255 tipos sólidos mais AR. Excedentes recebem `CHUNK_FLAG_PALETTE_OVERFLOW` e `SpecialVoxelRecord`; chunks em overflow são somente-leitura para edição.

## Consequências

- AR nunca pode ser reciclado, inclusive pela edição E1.
- Refcounts e crescimento de planos devem preservar a decodificação dos voxels existentes.
- O caminho de leitura de `SpecialVoxelRecord` permanece backlog separado.
- Integração ocorre em [[VS-01-streaming-generate-pack|VS-01]] e [[VS-03-edicao-e1|VS-03]].

## Rastreabilidade

- [Arquitetura — Correção B3](../../arquitetura.md).
- [Manual Técnico — Pack e edição](../../manual-tecnico.md).
- Referência: `pack_chunk`, `palette_rank_of_block`, `ChunkHeader` e `apply_voxel_edits`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
