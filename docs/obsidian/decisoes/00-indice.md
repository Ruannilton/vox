# Índice de ADRs

As ADRs registram decisões do GOAL e decisões ainda pendentes. `aceita` significa que a direção arquitetural foi escolhida, **não** que existe implementação integrada. O estado de implementação permanece no [[status|painel das specs]].

## Registro

| ID | Decisão | Status | Specs afetadas |
| --- | --- | --- | --- |
| ADR-B1 | [[ADR-B1-ciclo-vida-slots|Ciclo de vida dos slots]] | `aceita` | VS-01 |
| ADR-B2 | [[ADR-B2-fronteiras-chunks|Fronteiras entre chunks]] | `aceita` | VS-02 |
| ADR-B3 | [[ADR-B3-pack-paleta|Pack completo e paleta]] | `aceita` | VS-01, VS-03 |
| ADR-B4 | [[ADR-B4-batching-compute|Batching de compute]] | `aceita` | VS-01 |
| ADR-B5 | [[ADR-B5-capacidade-streaming|Capacidade do streaming]] | `aceita` | VS-01 |
| ADR-B6 | [[ADR-B6-culling-alpha-test|Culling e alpha-test de plantas]] | `pendente` | VS-02 |
| ADR-B7 | [[ADR-B7-pbr|Escopo do shading PBR]] | `pendente` | VS-02 |
| ADR-B8 | [[ADR-B8-distancia-int64|Distância com inteiros de 64 bits]] | `aceita` | VS-01 |
| ADR-B9 | [[ADR-B9-cobertura-generate|Cobertura completa do generate]] | `aceita` | VS-01 |
| ADR-CAMINHO-B | [[ADR-CAMINHO-B-templates-malha|Templates de malha data-driven]] | `aceita` | VS-01, VS-02 |
| ADR-E1 | [[ADR-E1-edicao-bufferizada|Edição bufferizada por journal]] | `aceita` | VS-03, VS-04 |
| ADR-C2 | [[ADR-C2-mirror-cpu|Mirror CPU denso com export direto]] | `aceita` | VS-04 |

## Resumo

- 12 decisões registradas.
- 9 decisões aceitas no GOAL.
- 3 decisões pendentes: ADR-B5, ADR-B6 e ADR-B7.
- Nenhuma decisão representa, por si só, implementação concluída ou validação verificada.

## Bloqueios

- ADR-B5 bloqueia a aprovação de [[VS-01-streaming-generate-pack|VS-01]].
- ADR-B6 e ADR-B7 bloqueiam a aprovação de [[VS-02-task-mesh-templates|VS-02]].

Novas decisões devem usar [[modelo-decisao|o modelo de ADR]], receber um ID único e ser adicionadas a este índice, ao painel de status e ao grafo quando bloquearem uma spec.
