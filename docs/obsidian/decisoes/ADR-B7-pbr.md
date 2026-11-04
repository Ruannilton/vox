---
id: ADR-B7
titulo: Escopo do shading PBR
tipo: decisao
status: aceita
specs_afetadas:
  - VS-02
ultima_atualizacao: 2026-11-03
---

# ADR-B7 — Escopo do shading PBR

## Contexto

O dicionário envia roughness e metallic à GPU, mas o shading de referência amostra apenas o necessário para Lambert e emissão. O nome “PBR” não deve ser usado como se a equação completa já estivesse implementada.

## Opções

### Manter Lambert e emissão em VS-02

- Reduz o escopo da primeira renderização integrada.
- Exige documentar roughness/metallic como dados disponíveis, mas não consumidos.

### Incluir PBR em VS-02

- Aproxima a fatia do objetivo visual completo.
- Adiciona amostragem, equação de shading e novos critérios de validação à entrega inicial.

## Decisão

Manter Lambert, vamos seguir com o simples primeiro, PBR é um exemplo de melhoria futura

## Consequências

A decisão define os testes e o fragment shader exigidos em [[VS-02-task-mesh-templates|VS-02]]. Se adiado, PBR permanece backlog explícito e não bloqueia as fatias E1/C2.

## Rastreabilidade

- [Arquitetura — Orientação a dados e PBR](../../arquitetura.md).
- [Manual Técnico — Backlog B7](../../manual-tecnico.md).

## Histórico

- 2026-11-03 — Decisão registrada como pendente; bloqueia aprovação de VS-02.
- 2026-11-03 — Decisão registrada como aceita;
