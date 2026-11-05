# Painel de status

Última revisão geral: 2026-11-04.

Este é o registro central. Ao alterar uma spec ou ADR, atualize esta tabela e o frontmatter correspondente no mesmo trabalho.

## Resumo atual

| Indicador | Quantidade |
| --- | ---: |
| Specs registradas | 5 |
| Specs aprovadas | 5 |
| Specs em elaboração ou revisão | 0 |
| Implementações em andamento | 0 |
| Implementações concluídas | 4 |
| Validações verificadas | 4 |

Cinco especificações registradas; VS-00, VS-01, VS-02 e VS-03 estão integralmente concluídas; VS-04 está aprovada para implementação.

## Tracking das especificações

| ID | Especificação | Spec | Implementação | Validação | Depende de | Bloqueio |
| --- | --- | --- | --- | --- | --- | --- |
| VS-00 | [[VS-00-fundacao-vulkan|Fundação Vulkan]] | `aprovada` | `concluida` | `verificada` | — | — |
| VS-01 | [[VS-01-streaming-generate-pack|Streaming, generate e pack]] | `aprovada` | `concluida` | `verificada` | VS-00 | — |
| VS-02 | [[VS-02-task-mesh-templates|Task/mesh e templates]] | `aprovada` | `concluida` | `verificada` | VS-01 | — |
| VS-03 | [[VS-03-edicao-e1|Edição E1]] | `aprovada` | `concluida` | `verificada` | VS-02 | — |
| VS-04 | [[VS-04-mirror-c2|Mirror C2]] | `aprovada` | `nao-iniciada` | `nao-iniciada` | VS-03 | — |

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
