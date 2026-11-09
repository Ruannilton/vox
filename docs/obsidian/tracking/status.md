# Painel de status

Última revisão geral: 2026-11-08.

Este é o registro central. Ao alterar uma spec ou ADR, atualize esta tabela e o frontmatter correspondente no mesmo trabalho.

## Resumo atual

| Indicador | Quantidade |
| --- | ---: |
| Specs registradas | 22 |
| Specs aprovadas | 21 |
| Specs em elaboração ou revisão | 1 |
| Implementações em andamento | 1 |
| Implementações concluídas | 21 |
| Validações verificadas | 19 |

Vinte e duas especificações registradas; 21 aprovadas/concluídas e **19 integralmente verificadas**; **VS-21 (texturas — nearest, flip Y, stb_image, multi-face) implementação em andamento**. VS-15 e VS-16 aguardam os ACs manuais da UI Tracy. Ver a lista consolidada de itens futuros em [[backlog|Backlog]].

## Tracking das especificações

| ID | Especificação | Spec | Implementação | Validação | Depende de | Bloqueio |
| --- | --- | --- | --- | --- | --- | --- |
| VS-00 | [[VS-00-fundacao-vulkan|Fundação Vulkan]] | `aprovada` | `concluida` | `verificada` | — | — |
| VS-01 | [[VS-01-streaming-generate-pack|Streaming, generate e pack]] | `aprovada` | `concluida` | `verificada` | VS-00 | — |
| VS-02 | [[VS-02-task-mesh-templates|Task/mesh e templates]] | `aprovada` | `concluida` | `verificada` | VS-01 | — |
| VS-03 | [[VS-03-edicao-e1|Edição E1]] | `aprovada` | `concluida` | `verificada` | VS-02 | — |
| VS-04 | [[VS-04-mirror-c2|Mirror C2]] | `aprovada` | `concluida` | `verificada` | VS-03 | — |
| VS-05 | [[VS-05-telemetria-profiling|Telemetria e profiling GPU]] | `aprovada` | `concluida` | `verificada` | VS-04 | — |
| VS-06 | [[VS-06-culling-frustum|Culling de frustum]] | `aprovada` | `concluida` | `verificada` | VS-02 | — |
| VS-07 | [[VS-07-eventos-input-replay|Eventos de input, comandos e replay]] | `aprovada` | `concluida` | `verificada` | VS-03 | — |
| VS-08 | [[VS-08-config-ini-provisionamento|Configuração via INI e provisionamento runtime]] | `aprovada` | `concluida` | `verificada` | VS-05 | — |
| VS-09 | [[VS-09-visible-index-16-bits|Visible index de 16 bits na fila de trabalho]] | `aprovada` | `concluida` | `verificada` | VS-08 | — |
| VS-10 | [[VS-10-chunks-vazios-virtuais|Chunks vazios virtuais]] | `aprovada` | `concluida` | `verificada` | VS-04 | — |
| VS-11 | [[VS-11-uvs-templates|UVs nos templates de malha]] | `aprovada` | `concluida` | `verificada` | VS-02 | — |
| VS-12 | [[VS-12-assets-json|Assets data-driven via JSON]] | `aprovada` | `concluida` | `verificada` | VS-11 | — |
| VS-13 | [[VS-13-heightmap-geracao-mirror|Heightmap na geração e no mirror]] | `aprovada` | `concluida` | `verificada` | VS-04 | — |
| VS-14 | [[VS-14-plantas-alpha-test-spawn|Plantas — alpha-test e spawn determinístico]] | `aprovada` | `concluida` | `verificada` | VS-12 | — |
| VS-15 | [[VS-15-tracy-profiler|Tracy profiler (CPU zones)]] | `aprovada` | `concluida` | `em-validacao` | VS-05 | AC-02 manual da UI Tracy (passo a passo no manual técnico §11) |
| VS-16 | [[VS-16-instrumentacao-detalhada|Instrumentação detalhada (CPU + GPU)]] | `aprovada` | `concluida` | `em-validacao` | VS-15 | AC-02 manual da UI Tracy (manual técnico §11) |
| VS-17 | [[VS-17-streaming-incremental|Streaming incremental]] | `aprovada` | `concluida` | `verificada` | VS-01 | — |
| VS-18 | [[VS-18-mundo-na-worker|Mundo na worker (world ownership)]] | `aprovada` | `concluida` | `verificada` | VS-17 | — |
| VS-19 | [[VS-19-fisica-solver-mirror|Física de gameplay — solver CPU sobre o mirror]] | `aprovada` | `concluida` | `verificada` | VS-04, VS-13, VS-14, VS-18 | — |
| VS-20 | [[VS-20-gameplay-selecao-construcao-pulo|Gameplay — seleção, construção e pulo]] | `aprovada` | `concluida` | `verificada` | VS-03, VS-07, VS-19 | — |
| VS-21 | [[VS-21-texturas-nearest-flip-stb-faces|Texturas — nearest, flip Y, stb_image e multi-face]] | `aprovada` | `em-andamento` | `nao-iniciada` | VS-11, VS-12 | — |

## Decisões

O índice completo e suas justificativas estão em [[00-indice|Índice de ADRs]]. `aceita` descreve a decisão arquitetural, não a implementação.

| ID | Decisão | Status | Specs afetadas |
| --- | --- | --- | --- |
| ADR-B1 | [[ADR-B1-ciclo-vida-slots|Ciclo de vida dos slots]] | `aceita` | VS-01 |
| ADR-B2 | [[ADR-B2-fronteiras-chunks|Fronteiras entre chunks]] | `aceita` | VS-02 |
| ADR-B3 | [[ADR-B3-pack-paleta|Pack completo e paleta]] | `aceita` | VS-01, VS-03 |
| ADR-B4 | [[ADR-B4-batching-compute|Batching de compute]] | `aceita` | VS-01 |
| ADR-B5 | [[ADR-B5-capacidade-streaming|Capacidade do streaming]] | `aceita` | VS-01 |
| ADR-B6 | [[ADR-B6-culling-alpha-test|Culling e alpha-test]] | `aceita` | VS-02 |
| ADR-B7 | [[ADR-B7-pbr|Escopo do shading PBR]] | `aceita` | VS-02 |
| ADR-B8 | [[ADR-B8-distancia-int64|Distância com inteiros de 64 bits]] | `aceita` | VS-01 |
| ADR-B9 | [[ADR-B9-cobertura-generate|Cobertura completa do generate]] | `aceita` | VS-01 |
| ADR-CAMINHO-B | [[ADR-CAMINHO-B-templates-malha|Templates de malha data-driven]] | `aceita` | VS-01, VS-02 |
| ADR-E1 | [[ADR-E1-edicao-bufferizada|Edição bufferizada por journal]] | `aceita` | VS-03, VS-04 |
| ADR-C2 | [[ADR-C2-mirror-cpu|Mirror CPU denso com export direto]] | `aceita` | VS-04 |
| ADR-B10 | [[ADR-B10-fila-trabalho-global|Fila de trabalho global no lugar do payload]] | `aceita` | VS-02 |
| ADR-T1 | [[ADR-T1-telemetria-vulkan-vma|Telemetria GPU via API Vulkan + VMA]] | `aceita` | VS-05 |
| ADR-B11 | [[ADR-B11-culling-frustum|Culling de frustum por brick no builder]] | `aceita` | VS-06 |
| ADR-I1 | [[ADR-I1-bus-eventos-input-replay|Bus de eventos de input com gravação e replay]] | `aceita` | VS-07 |
| ADR-C1 | [[ADR-C1-config-ini-provisionamento|Configuração runtime via INI com provisionamento derivado]] | `aceita` | VS-08 |
| ADR-B12 | [[ADR-B12-visible-index-16-bits|visible_index de 16 bits no item da fila de trabalho]] | `aceita` | VS-09 |
| ADR-V1 | [[ADR-V1-chunks-vazios-virtuais|Chunks vazios virtuais sem slot]] | `aceita` | VS-10 |
| ADR-U1 | [[ADR-U1-uvs-templates-malha|UVs nos templates de malha]] | `aceita` | VS-11 |
| ADR-A1 | [[ADR-A1-assets-json|Assets data-driven via JSON]] | `aceita` | VS-12 |
| ADR-G1 | [[ADR-G1-heightmap-geracao-mirror|Heightmap na geração e no mirror]] | `aceita` | VS-13 |
| ADR-P1 | [[ADR-P1-plantas-alpha-test-spawn|Plantas — alpha-test e spawn determinístico]] | `aceita` | VS-14 |
| ADR-T3 | [[ADR-T3-tracy-profiler|Tracy profiler via odin-tracy, opt-in por define]] | `aceita` | VS-15 |
| ADR-T4 | [[ADR-T4-instrumentacao-detalhada|Instrumentação detalhada — GPU zones e CPU aprofundada]] | `aceita` | VS-16 |
| ADR-W1 | [[ADR-W1-ownership-mundo-worker|Ownership do mundo na worker thread]] | `aceita` | VS-18 |
| ADR-F1 | [[ADR-F1-fisica-solver-mirror|Física de gameplay — solver CPU sobre o mirror]] | `aceita` | VS-00, VS-13, VS-19 |
| ADR-G2 | [[ADR-G2-gameplay-selecao-construcao-pulo|Gameplay — seleção, construção e pulo]] | `aceita` | VS-00, VS-20 |
| ADR-T5 | [[ADR-T5-texturas-stb-face|Texturas — stb_image, flip Y, nearest e topo por face]] | `aceita` | VS-02, VS-12, VS-21 |

## Vocabulário de status

### Especificação

- `rascunho`: estrutura registrada, sem elaboração ativa.
- `em-elaboracao`: conteúdo e critérios sendo definidos.
- `em-revisao`: conteúdo completo aguardando revisão.
- `aprovada`: pronta para gerar tarefas de implementação; sem questões críticas abertas.
- `obsoleta`: substituída ou retirada do planejamento, com motivo no histórico.

### Implementação

- `nao-iniciada`: nenhuma implementação iniciada.
- `em-andamento`: existe trabalho de implementação ativo.
- `concluida`: escopo implementado e critérios de aceitação executados.

### Validação

- `nao-iniciada`: nenhuma evidência produzida.
- `em-validacao`: verificação em execução ou evidências incompletas.
- `verificada`: critérios comprovados por testes/simulações reproduzíveis.
- `falhou`: há evidência de critério não atendido; registrar a falha na spec.

Uma fatia somente está integralmente concluída quando possui `status_spec: aprovada`, `status_implementacao: concluida` e `status_validacao: verificada`.

## Regras de atualização

1. Não marcar spec como aprovada apenas porque o arquivo existe.
2. Não iniciar implementação com spec não aprovada ou dependência de implementação pendente.
3. Uma ADR pendente listada em `bloqueada_por` impede a aprovação da spec, não a escrita do rascunho.
4. Registrar data e resultado no histórico da spec a cada transição.
5. Vincular evidências de validação nos critérios de aceitação antes de marcar `verificada`.
6. Recalcular o resumo sempre que uma linha do tracking mudar.
