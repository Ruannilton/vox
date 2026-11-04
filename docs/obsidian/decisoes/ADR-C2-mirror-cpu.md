---
id: ADR-C2
titulo: Mirror CPU denso com export direto
tipo: decisao
status: aceita
specs_afetadas:
  - VS-04
ultima_atualizacao: 2026-11-03
---

# ADR-C2 — Mirror CPU denso com export direto

## Contexto

Gameplay precisa consultar voxels na CPU sem stalls de readback nem conhecer o formato packed da GPU. VRAM e RAM não podem se tornar autoridades independentes.

## Opções

- Regenerar worldgen na CPU: rejeitada por exigir determinismo bit-exato de ponto flutuante entre CPU e GPU.
- Ler device-local diretamente via Resizable BAR: rejeitada pela latência no hot path.
- View densa alimentada pelo generate e pelo journal, com export direto a ring host-visible: escolhida pelo GOAL.

## Decisão

A verdade é worldgen mais o journal E1. O mirror mantém páginas com IDs diretos `u16`, bitmask de sólidos e layout y-contíguo `y | z<<5 | x<<10`, distinto do scratch x-contíguo.

O generate escreve diretamente no ring host-visible de 64 slots de 64 KiB no binding 16, sem pool device-local nem `vkCmdCopyBuffer`. Após a timeline, o handler copia para a página, reaplica pendências e abre a página para consultas tri-state.

## Consequências

- Requer `storageBuffer16BitAccess` na fundação Vulkan.
- Ring cheio pode gerar retry `export_only`, com uma tarefa e sem pack.
- Slots de ring em voo só são liberados pelo handler de conclusão; anti-ABA usa coordenada e geração.
- Rejeições de E1 exigem reconciliação da aplicação otimista no mirror.
- Integração pertence a [[VS-04-mirror-c2|VS-04]].

## Rastreabilidade

- [Arquitetura — Mirror C2](../../arquitetura.md).
- [Manual Técnico — C2 e readback](../../manual-tecnico.md).
- Referência: `MirrorManager`, `MirrorChunkPage`, funções `mirror_*`, consultas `voxel_*` e `mirror_export_ring`.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
