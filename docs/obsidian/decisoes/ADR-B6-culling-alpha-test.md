---
id: ADR-B6
titulo: Culling e alpha-test de plantas
tipo: decisao
status: aceita
specs_afetadas:
  - VS-02
ultima_atualizacao: 2026-11-04
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

- `CULL_MODE_NONE` e alpha-test não fazem parte dos critérios de aceitação de VS-02.
- O template de planta pode ser validado como dado geométrico, mas a limitação visual permanece explícita.
- B6 permanece como melhoria posterior e não bloqueia VS-02, E1 ou C2.
- Triângulos tag 7 continuam proibidos de alterar a garantia de orçamento, que depende da subdivisão.

## Rastreabilidade

- [Arquitetura — Backlog B6](../../arquitetura.md).
- [Manual Técnico — Contrato de carga e backlog](../../manual-tecnico.md).

## Histórico

- 2026-11-03 — Decisão registrada como pendente.
- 2026-11-03 — Decisão aceita: adiar a correção.
- 2026-11-04 — Escopo e critérios incorporados a VS-02.
