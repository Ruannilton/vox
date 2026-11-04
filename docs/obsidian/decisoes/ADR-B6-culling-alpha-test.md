---
id: ADR-B6
titulo: Culling e alpha-test de plantas
tipo: decisao
status: aceita
specs_afetadas:
  - VS-02
ultima_atualizacao: 2026-11-03
---

# ADR-B6 — Culling e alpha-test de plantas

## Contexto

Triângulos com tag 7, usados pelas plantas, não devem sofrer culling direcional. O GOAL registra que o pipeline precisa `CULL_MODE_NONE` e que ainda falta alpha-test.

## Opções

### Incluir a correção em VS-02

- Entrega os built-ins de planta com comportamento visual completo.
- Amplia o escopo do pipeline gráfico e exige critérios de alpha-test.

### Adiar a correção

- Reduz o escopo inicial de VS-02.
- Exige declarar explicitamente a limitação das plantas e impedir que o resultado seja tratado como visualmente completo.

## Decisão

Adiar a correção

## Consequências

A decisão altera o escopo, os testes visuais e a configuração do pipeline de [[VS-02-task-mesh-templates|VS-02]]. Independentemente da escolha, triângulos tag 7 não podem ser usados para justificar culling direcional fora do orçamento garantido por subdivisão.

## Rastreabilidade

- [Arquitetura — Backlog B6](../../arquitetura.md).
- [Manual Técnico — Contrato de carga e backlog](../../manual-tecnico.md).

## Histórico

- 2026-11-03 — Decisão registrada como pendente; bloqueia aprovação de VS-02.
- 2026-11-03 — Decisão registrada como aceita;
