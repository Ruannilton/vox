---
id: VS-02
titulo: Task/mesh e templates
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de:
  - VS-01
bloqueada_por:
  - ADR-B6
  - ADR-B7
requisitos: []
ultima_atualizacao: 2026-11-03
---

# VS-02 — Task/mesh e templates

## Objetivo

Renderizar os chunks materializados por VS-01 com culling hierárquico, fronteiras entre chunks e geometria genérica orientada por templates.

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
- Built-ins de ar, cubo e planta e shading previsto pelo GOAL.

## Não escopo

- Edição, mirror, LOD, Hi-Z, transparência e PBR completo além do escopo aprovado para a fatia.

## Dependências

- [[VS-01-streaming-generate-pack|VS-01]] concluída antes da implementação.

## Interfaces e recursos

A especificar: buffers de visíveis e templates, payload, push constants, bindings, emissão de vértices/triângulos e comportamento para vizinhos ausentes ou em geração.

## Cenários mínimos a detalhar

- Chunk e brick vazios.
- Faces internas entre chunks sólidos.
- Vizinho ausente ou em geração.
- Templates com limites máximos e subdivisões de 1, 2 e 4 grupos.
- Rotação yaw e triângulos interiores/sem culling direcional.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-02-AC-01 | Nenhum grupo excede 256 vértices ou 192 triângulos por construção | Simulação de orçamento e testes de templates | Pendente |
| VS-02-AC-02 | Fronteiras entre chunks não emitem faces internas duplicadas | Cena de dois chunks e inspeção visual/dados | Pendente |
| VS-02-AC-03 | Templates obedecem ao voxel unitário e às regras de rotação/culling | Testes de contrato de carga e simulação | Pendente |
| VS-02-AC-04 | Terreno gerado por VS-01 é apresentado corretamente | Smoke test visual com validation layers | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Formalizar payload, bindings e contratos de carga.
- [ ] Definir cenários de culling, fronteira e orçamento.
- [ ] Delimitar B6/B7 entre escopo desta fatia e backlog.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

- Classificar o alpha-test/CULL_MODE_NONE de B6 e o sombreamento PBR de B7 como aceite desta fatia ou trabalho posterior.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
