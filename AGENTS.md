# AGENTS.md — Motor de Voxels (Vulkan 1.4 / Odin / Slang)

## Contexto
Motor GPU-driven/data-driven. Leia docs/arquitetura.md antes de alterar pipeline.
Constantes e layouts: src/assets/shaders/common.slang é a fonte única de verdade.

## Regras inegociáveis
1. Voxel = 1 unidade³ sempre. Objetos maiores = múltiplos voxels-parte.
2. Slot 0 da paleta é AR. Nunca reciclar.
3. 1 claim = 1 lote = 1 valor de timeline (B1). Anti-ABA por coord+geração.
4. Nunca liberar slot de ring em voo; só o handler de conclusão libera (C2).
5. Orçamento mesh shader 256v/192t garantido por subdivisão — não assumir culling direcional.
6. Chunk com CHUNK_FLAG_PALETTE_OVERFLOW é somente-leitura.
7. Layout do mirror é y-contíguo (y|z<<5|x<<10); o scratch GPU é x-contíguo. Não misturar.

## Workflow
- Mudança de shader → escrever/estender simulação Python em tools/sim/ antes de integrar.
- Marcar integrações pendentes com TODO(E1)/TODO(B)/TODO(C2) (convenção existente).
- Não atualizar docs/ sem atualizar o código correspondente e vice-versa
- Manter documentação do projeto atualizada no formato obsidian dentro do diretorio docs/obsidian/*

## Comandos
- Build: <preencher>
- Simulações: python3 tools/sim/<arquivo>.py