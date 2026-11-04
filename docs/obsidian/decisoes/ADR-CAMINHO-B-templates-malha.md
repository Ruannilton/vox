---
id: ADR-CAMINHO-B
titulo: Templates de malha data-driven
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
  - VS-02
ultima_atualizacao: 2026-11-03
---

# ADR-CAMINHO-B — Templates de malha data-driven

## Contexto

Geometria definida por switches hardcoded impede que novos blocos e mods tenham malhas próprias sem alteração dos shaders. Malhas com custos variáveis também podem exceder os limites do mesh shader se não houver um orçamento construtivo.

## Opções

- Manter geometria hardcoded: rejeitada por violar o princípio data-driven.
- Templates globais em SSBO com subdivisão por brick: escolhida pelo GOAL.

## Decisão

`BlockDefinition.mesh_template_index` referencia uma tabela global de templates. Metadados, vértices e triângulos packed usam bindings 10, 11 e 12. Todo voxel ocupa uma unidade cúbica e vértices de template permanecem em `[0,1]³`; objetos maiores são múltiplos voxels-parte.

Templates possuem no máximo 32 vértices e 24 triângulos pior-caso. O pack calcula o custo por brick e grava subdivisão de 1, 2 ou 4 grupos, garantindo 256 vértices e 192 triângulos por grupo.

## Consequências

- Tags de culling e rotação yaw fazem parte do contrato do template.
- O orçamento não pode depender de culling direcional.
- Built-ins são ar, cubo e planta; mods devem passar pela validação de carga.
- Integração atravessa o pack em [[VS-01-streaming-generate-pack|VS-01]] e a renderização em [[VS-02-task-mesh-templates|VS-02]].

## Rastreabilidade

- [Arquitetura — Caminho B](../../arquitetura.md).
- [Manual Técnico — Templates e contrato de carga](../../manual-tecnico.md).
- Referência: `MeshTemplate`, `validate_template`, `compute_worst_case_tris` e shaders pack/task/mesh.

## Histórico

- 2026-11-03 — Decisão do GOAL registrada como aceita; implementação não iniciada.
