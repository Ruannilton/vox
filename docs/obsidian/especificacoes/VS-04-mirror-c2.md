---
id: VS-04
titulo: Mirror C2
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-03
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-03
---

# VS-04 — Mirror C2

## Objetivo

Manter uma view densa do mundo em RAM para consultas de gameplay, materializada pelo export do generate e atualizada pelo mesmo journal de E1, sem criar uma segunda autoridade do mundo.

## Rastreabilidade

- GOAL: [Arquitetura — Mirror CPU-side](../../arquitetura.md) e [Manual Técnico — C2](../../manual-tecnico.md).
- Referência: `MirrorManager`, `MirrorChunkPage`, funções `mirror_*`, consultas `voxel_*` e export no binding 16 em `docs/examples/`.
- Requisitos: vincular `MIRROR-C2-*` durante o catálogo de requisitos.
- Decisões: [[ADR-E1-edicao-bufferizada|ADR-E1]] e [[ADR-C2-mirror-cpu|ADR-C2]].

## Escopo

- Bolha de simulação independente e pool fixo de páginas.
- Export denso u16 y-contíguo direto para ring host-visible.
- Materialização após timeline, replay de pendências e consultas tri-state.
- Dual-apply do journal e reconciliação de rejeições.
- Retry, `export_only`, evicção e anti-ABA por coordenada/geração.
- Validação de paridade entre GPU e mirror.

## Não escopo

- Física, navegação, IA e persistência de saves como consumidores completos do mirror.

## Dependências

- [[VS-03-edicao-e1|VS-03]] concluída antes da implementação.
- Capabilities e recursos de VS-00, incluindo `storageBuffer16BitAccess`, devem estar disponíveis.

## Interfaces e recursos

A especificar: estados da página, reserva e liberação do ring, aquisição host após timeline, ordering do journal, política de retry e semântica de consulta desconhecida.

## Cenários mínimos a detalhar

- Materialização sem edições e com replay de pendências.
- Ring cheio, página fora da bolha e retry por `export_only`.
- Evicção com export pendente e com export em voo.
- Conclusão vencida por coordenada/geração.
- Rejeição de edição pela GPU e reconciliação da página.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-04-AC-01 | O layout do mirror é y-contíguo e não é misturado ao scratch x-contíguo | Testes de indexação e paridade | Pendente |
| VS-04-AC-02 | Nenhum slot de ring em voo é liberado fora do handler de conclusão | Cenários anti-ABA e evicção | Pendente |
| VS-04-AC-03 | `export_only` nunca executa pack nem apaga edições do formato packed | Teste de retry com edições | Pendente |
| VS-04-AC-04 | GPU e mirror convergem para a mesma sequência do journal | Paridade bit a bit em 163.840 voxels | Pendente |
| VS-04-AC-05 | Consultas ausentes/pendentes retornam desconhecido sem inventar bloco | Testes da API tri-state | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Formalizar estados, proprietários e timelines do ring.
- [ ] Definir reconciliação e cenários de retry/evicção.
- [ ] Especificar a simulação de paridade GPU↔mirror.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

- Nenhuma adicional neste rascunho; pendências de catálogo e interfaces ainda precisam ser resolvidas.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
