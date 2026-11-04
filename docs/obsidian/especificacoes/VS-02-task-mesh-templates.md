---
id: VS-02
titulo: Task/mesh e templates
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-01
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-04
---

# VS-02 — Task/mesh e templates

## Objetivo

Renderizar os chunks materializados por VS-01 com culling hierárquico, fronteiras entre chunks, geometria genérica orientada por templates e shading Lambert + emissão.

## Rastreabilidade

- GOAL: [Arquitetura — Etapas 4 e 5](../../arquitetura.md) e [Manual Técnico — Pipeline de renderização e Caminho B](../../manual-tecnico.md).
- Referência: `MeshTemplate`, `BlockDefinition`, validação de templates e entry points task/mesh/fragment em `docs/examples/`.
- Requisitos: vincular `RENDER-*`, B2 e Caminho B durante o catálogo de requisitos.
- Decisões: [[ADR-B2-fronteiras-chunks|ADR-B2]], [[ADR-B6-culling-alpha-test|ADR-B6]], [[ADR-B7-pbr|ADR-B7]] e [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]].

## Escopo

- Publicação de chunks visíveis e seis vizinhos.
- Culling coarse/brick e payload de task shader.
- Templates, vértices, triângulos packed, rotação e tags de culling.
- Subdivisão de bricks e garantia dos orçamentos de hardware.
- Built-ins de ar, cubo e planta como dados de geometria.
- Shading Lambert + emissão, com triplanar e normais por derivadas.

## Não escopo

- Edição, mirror, LOD, Hi-Z e transparência.
- Correção visual B6 de plantas: `CULL_MODE_NONE` e alpha-test ficam para trabalho posterior.
- PBR e amostragem de roughness/metallic, adiados pela ADR-B7.

## Dependências

- [[VS-01-streaming-generate-pack|VS-01]] concluída antes da implementação.
- [[ADR-B6-culling-alpha-test|ADR-B6]] e [[ADR-B7-pbr|ADR-B7]] aceitas e incorporadas; não há mais bloqueio de decisão.

## Interfaces e recursos

A especificar: buffers de visíveis e templates, payload, push constants, bindings, emissão de vértices/triângulos e comportamento para vizinhos ausentes ou em geração.

O dicionário pode transportar roughness/metallic para manter o contrato de dados, mas seu consumo pelo fragment shader não é requisito desta fatia. A presença do template de planta não implica comportamento visual completo enquanto B6 estiver adiado.

## Cenários mínimos a detalhar

- Chunk e brick vazios.
- Faces internas entre chunks sólidos.
- Vizinho ausente ou em geração.
- Templates com limites máximos e subdivisões de 1, 2 e 4 grupos.
- Rotação yaw e triângulos interiores/sem culling direcional.
- Shading Lambert + emissão, sem presumir roughness/metallic amostrados.
- Plantas verificadas como dados de template, com a limitação visual B6 explicitamente fora do aceite.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-02-AC-01 | Nenhum grupo excede 256 vértices ou 192 triângulos por construção | Simulação de orçamento e testes de templates | Pendente |
| VS-02-AC-02 | Fronteiras entre chunks não emitem faces internas duplicadas | Cena de dois chunks e inspeção visual/dados | Pendente |
| VS-02-AC-03 | Templates obedecem ao voxel unitário e às regras de rotação/culling | Testes de contrato de carga e simulação | Pendente |
| VS-02-AC-04 | O terreno é apresentado com Lambert + emissão; PBR e a correção B6 não são exigidos nesta fatia | Smoke test visual com validation layers | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Formalizar payload, bindings e contratos de carga.
- [ ] Definir cenários de culling, fronteira e orçamento.
- [x] Incorporar ADR-B6: correção visual de plantas adiada.
- [x] Incorporar ADR-B7: Lambert + emissão nesta fatia; PBR posterior.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

Nenhuma decisão de ADR pendente. O catálogo de requisitos, as interfaces e os cenários detalhados ainda precisam ser concluídos antes da revisão.

## Histórico

- 2026-11-03 — Rascunho estrutural criado.
- 2026-11-04 — ADR-B6 e ADR-B7 incorporadas; bloqueios de decisão removidos, spec permanece em rascunho.
