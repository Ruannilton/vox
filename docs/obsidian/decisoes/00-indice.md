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
| ADR-B6 | [[ADR-B6-culling-alpha-test|Culling e alpha-test de plantas]] | `aceita` | VS-02 |
| ADR-B7 | [[ADR-B7-pbr|Escopo do shading PBR]] | `aceita` | VS-02 |
| ADR-B8 | [[ADR-B8-distancia-int64|Distância com inteiros de 64 bits]] | `aceita` | VS-01 |
| ADR-B9 | [[ADR-B9-cobertura-generate|Cobertura completa do generate]] | `aceita` | VS-01 |
| ADR-CAMINHO-B | [[ADR-CAMINHO-B-templates-malha|Templates de malha data-driven]] | `aceita` | VS-01, VS-02 |
| ADR-E1 | [[ADR-E1-edicao-bufferizada|Edição bufferizada por journal]] | `aceita` | VS-03, VS-04 |
| ADR-C2 | [[ADR-C2-mirror-cpu|Mirror CPU denso com export direto]] | `aceita` | VS-04 |
| ADR-B10 | [[ADR-B10-fila-trabalho-global|Fila de trabalho global no lugar do payload task→mesh]] | `aceita` | VS-02 |
| ADR-T1 | [[ADR-T1-telemetria-vulkan-vma|Telemetria GPU via API Vulkan + VMA]] | `aceita` | VS-05 |
| ADR-T2 | [[ADR-T2-modelos-por-tipo-de-tarefa|Modelo e thinking por tipo de tarefa]] | `aceita` | — |
| ADR-B11 | [[ADR-B11-culling-frustum|Culling de frustum por brick no builder]] | `aceita` | VS-06 |
| ADR-I1 | [[ADR-I1-bus-eventos-input-replay|Bus de eventos de input com gravação e replay]] | `aceita` | VS-07 |
| ADR-C1 | [[ADR-C1-config-ini-provisionamento|Configuração runtime via INI com provisionamento derivado]] | `aceita` | VS-08 |
| ADR-B12 | [[ADR-B12-visible-index-16-bits|visible_index de 16 bits no item da fila de trabalho]] | `aceita` | VS-09 |
| ADR-V1 | [[ADR-V1-chunks-vazios-virtuais|Chunks vazios virtuais sem slot]] | `aceita` | VS-10 |
| ADR-U1 | [[ADR-U1-uvs-templates-malha|UVs nos templates de malha]] | `aceita` | VS-11 |
| ADR-G1 | [[ADR-G1-heightmap-geracao-mirror|Heightmap na geração e no mirror]] | `aceita` | VS-13 |
| ADR-T4 | [[ADR-T4-instrumentacao-detalhada|Instrumentação detalhada — GPU zones e CPU aprofundada]] | `aceita` | VS-16 |

## Resumo

- 26 decisões registradas e aceitas.
- Nenhuma decisão pendente.
- Nenhuma decisão representa, por si só, implementação concluída ou validação verificada.

## Bloqueios

Não há bloqueios de aprovação por ADR. As escolhas foram incorporadas às suas specs.

Novas decisões devem usar [[modelo-decisao|o modelo de ADR]], receber um ID único e ser adicionadas a este índice, ao painel de status e ao grafo quando bloquearem uma spec.
