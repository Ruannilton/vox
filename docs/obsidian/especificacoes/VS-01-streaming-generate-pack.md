---
id: VS-01
titulo: Streaming, generate e pack
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-00
bloqueada_por:
  - ADR-B5
requisitos: []
ultima_atualizacao: 2026-11-03
---

# VS-01 — Streaming, generate e pack

## Objetivo

Materializar chunks de 32³ na VRAM por streaming priorizado, geração GPU e compactação, preservando o ciclo de vida B1 durante cancelamento, conclusão e descarregamento.

## Rastreabilidade

- GOAL: [Arquitetura — Etapas 1 a 4](../../arquitetura.md) e [Manual Técnico — Chunk Manager e geração](../../manual-tecnico.md).
- Referência: `ChunkManager`, `GenerationTask`, `SubmittedBatch`, `worker_thread_process` e shaders `generate_voxels`/`pack_chunk` em `docs/examples/`.
- Requisitos: vincular `STREAM-*`, `GEN-*`, B1, B3, B4 e B9 durante o catálogo de requisitos.
- Decisões: [[ADR-B1-ciclo-vida-slots|ADR-B1]], [[ADR-B3-pack-paleta|ADR-B3]], [[ADR-B4-batching-compute|ADR-B4]], [[ADR-B5-capacidade-streaming|ADR-B5]], [[ADR-B8-distancia-int64|ADR-B8]], [[ADR-B9-cobertura-generate|ADR-B9]] e [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]].

## Escopo

- Histerese de visão, geração e descarga.
- Fila priorizada, worker e lotes de até 16 chunks.
- Claim atômico, anti-ABA e aposentadoria dual.
- Generate de todos os 32.768 voxels e pack completo.
- Ocupação, coarse, paleta, planos, refcounts, overflow e subdivisão de bricks.

## Não escopo

- Renderização task/mesh, edição de voxels e mirror CPU.
- Persistência do journal e otimizações posteriores de streaming.

## Dependências

- [[VS-00-fundacao-vulkan|VS-00]] concluída antes da implementação.
- [[ADR-B5-capacidade-streaming|ADR-B5]] decidida antes da aprovação desta spec.

## Interfaces e recursos

A especificar: estados e proprietários das filas, formatos dos jobs, valores de timeline, buffers de geração, política de prioridade e comportamento quando slots ou limites forem atingidos.

## Cenários mínimos a detalhar

- Geração próxima antes do horizonte e lotes com mais de um chunk.
- Cancelamento antes do claim e unload após submit.
- Conclusão vencida por coordenada/slot/geração.
- Chunk vazio, paleta cheia e overflow.
- Coordenadas negativas e deslocamento entre regiões do mundo.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-01-AC-01 | Cada chunk gerado cobre 32³ voxels e mantém AR no slot 0 da paleta | Simulação bit a bit e inspeção de dados | Pendente |
| VS-01-AC-02 | Um claim corresponde a um lote e um valor de timeline | Testes de concorrência e instrumentação | Pendente |
| VS-01-AC-03 | Nenhum slot é reutilizado enquanto trabalho de compute ou gráfico ainda o referencia | Cenários anti-ABA e validation layers | Pendente |
| VS-01-AC-04 | Capacidade residente e raios de streaming não se contradizem | Teste de limites baseado na ADR-B5 | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Resolver ADR-B5 e fixar raios/capacidade.
- [ ] Formalizar máquinas de estado e cenários anti-ABA.
- [ ] Definir contratos Odin↔Slang e simulações exigidas.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

- ADR-B5: reduzir o raio de geração ou ampliar o pool físico.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; bloqueado pela ADR-B5 para aprovação.
