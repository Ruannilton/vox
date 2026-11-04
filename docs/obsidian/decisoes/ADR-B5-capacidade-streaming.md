---
id: ADR-B5
titulo: Capacidade do streaming
tipo: decisao
status: aceita
specs_afetadas:
  - VS-01
ultima_atualizacao: 2026-11-03
---

# ADR-B5 — Capacidade do streaming

## Contexto

O GOAL registra que o raio de geração 12 descreve aproximadamente 7.238 chunks, enquanto o pool físico possui 4.096 slots. A especificação de VS-01 precisa eliminar essa contradição antes de definir seus critérios de capacidade e descarregamento.

## Requisitos relacionados

- B5 e requisitos `STREAM-*` a catalogar.
- [[VS-01-streaming-generate-pack|VS-01 — Streaming, generate e pack]].

## Opções

### Reduzir o raio de geração para aproximadamente 9

- Mantém o pool de 4.096 slots e o orçamento atual de VRAM.
- Reduz a distância de dados residentes e exige revisão da histerese entre visão, geração e descarga.

### Ampliar o pool para aproximadamente 8.000 slots

- Preserva a bolha de geração descrita no GOAL.
- Aumenta VRAM, metadados e trabalho potencial de streaming; exige recalcular todos os orçamentos afetados.

## Decisão

Reduzir o raio de geração para 8

## Consequências

Enquanto pendente, VS-01 pode permanecer em rascunho ou elaboração, mas não pode ser aprovada nem iniciar implementação. Após a decisão, atualizar os critérios de aceitação, constantes normativas e testes de limite da spec.

## Histórico

- 2026-11-03 — Decisão registrada como pendente a partir do backlog B5 do GOAL.
- 2026-11-03 — Decisão registrada, reduzir o raio para 8
