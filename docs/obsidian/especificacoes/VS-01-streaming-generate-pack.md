---
id: VS-01
titulo: Streaming, generate e pack
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-00
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-04
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

- Histerese com raio de visão `8`, raio de geração `8` e raio de descarga `16`, conforme ADR-B5.
- Pool físico de 4.096 slots, sem ampliação nesta fatia.
- Fila priorizada, worker e lotes de até 16 chunks.
- Claim atômico, anti-ABA e aposentadoria dual.
- Generate de todos os 32.768 voxels e pack completo.
- Ocupação, coarse, paleta, planos, refcounts, overflow e subdivisão de bricks.

## Não escopo

- Renderização task/mesh, edição de voxels e mirror CPU.
- Persistência do journal e otimizações posteriores de streaming.
- Ampliação do pool ou aumento dos raios definidos pela ADR-B5.

## Dependências

- [[VS-00-fundacao-vulkan|VS-00]] concluída antes da implementação.
- [[ADR-B5-capacidade-streaming|ADR-B5]] aceita e incorporada; não há mais bloqueio de decisão.

## Interfaces e recursos

A especificar: estados e proprietários das filas, formatos dos jobs, valores de timeline, buffers de geração, política de prioridade e comportamento quando slots ou limites forem atingidos.

Como visão e geração possuem o mesmo raio, a especificação detalhada não deve presumir uma faixa adicional de residentes entre esses dois raios. A descarga continua independente, no raio `16`.

## Cenários mínimos a detalhar

- Geração próxima antes do horizonte e lotes com mais de um chunk.
- Movimentação através dos limites `8/8/16`, sem retenção indevida de chunks fora da bolha ativa.
- Capacidade da região de geração dentro do limite de 4.096 slots.
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
| VS-01-AC-04 | Os raios efetivos são visão `8`, geração `8` e descarga `16`, e a enumeração da bolha de geração não excede 4.096 slots | Teste de fronteira e contagem de coordenadas | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [x] Incorporar ADR-B5: geração `8`, descarga `16` e pool de 4.096 slots.
- [ ] Formalizar máquinas de estado e cenários anti-ABA.
- [ ] Definir contratos Odin↔Slang e simulações exigidas.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

Nenhuma decisão de ADR pendente. O catálogo de requisitos, as interfaces e os cenários detalhados ainda precisam ser concluídos antes da revisão.

## Histórico

- 2026-11-03 — Rascunho estrutural criado.
- 2026-11-04 — ADR-B5 incorporada; bloqueio de decisão removido, spec permanece em rascunho.
