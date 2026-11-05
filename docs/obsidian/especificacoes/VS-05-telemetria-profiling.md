---
id: VS-05
titulo: Telemetria e profiling GPU
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: em-validacao
depende_de:
  - VS-04
bloqueada_por: []
requisitos: [REQ-PROF-01, REQ-PROF-02, REQ-PROF-03, REQ-PROF-04, REQ-PROF-05]
ultima_atualizacao: 2026-11-05
---

# VS-05 — Telemetria e profiling GPU

## Objetivo

Instrumentar as passagens GPU com telemetria consultável em runtime e persistida em arquivo — tempo de execução por operação, consumo de VRAM e regiões nomeadas para o Nsight/RenderDoc — via API Vulkan + VMA, sem dependências externas e com overhead estrutural zero quando desligada.

## Rastreabilidade

- GOAL: observabilidade operacional do pipeline ([Arquitetura](../../arquitetura.md), [Manual Técnico](../../manual-tecnico.md)) — fatia nova, sem requisitos numerados no GOAL; o mantenedor definiu o escopo diretamente (2026-11-05).
- Referência: pontos de gravação do frame em `src/engine/voxel_render.odin` (`voxel_render_prepare`/`voxel_render_record`), worker de compute em `src/engine/voxel_worker.odin` e loop principal em `src/main.odin`.
- Decisões: [[ADR-T1-telemetria-vulkan-vma|ADR-T1]] (análise das opções A–D: core Vulkan + EXT + VMA vs KHR_performance_query vs SDKs externos vs Aftermath).
- Fundação: [[VS-00-fundacao-vulkan|VS-00]] (cadeia de features, `EXT_debug_utils` já no instance); `shared:vma` já expõe `GetHeapBudgets`/`CalculateStatistics`/`BuildStatsString`; `vendor:vulkan` já expõe query pools, `CmdWriteTimestamp2` e labels.

## Requisitos

### Labels e regiões (Nsight/RenderDoc)

- **REQ-PROF-01** — `VK_EXT_debug_utils` no device: `CmdBegin/EndDebugUtilsLabelEXT` delimitando cada passagem GPU gravada — `generate` e `pack` por lote na worker, `apply_voxel_edits`, `build_work_queue`, `finalize_work_queue`, `draw` (mesh), além do render pass como um todo — e `SetDebugUtilsObjectNameEXT` nos objetos-chave (buffers de pool, pipelines, query pools). As regiões devem aparecer nomeadas na captura de frame do Nsight Graphics/RenderDoc.

### Timestamps GPU

- **REQ-PROF-02** — Query pool `TIMESTAMP` por frame em voo (2 slots gráficos + 3 slots de compute da worker), `vkCmdWriteTimestamp2` ao redor de cada passagem listada acima. Leitura por `vkGetQueryPoolResults` com `WITH_AVAILABILITY` sobre o slot de N frames/lotes atrás — **nunca bloqueante**. Calibração por `timestampPeriod` (ns/tick) lido do dispositivo. Fallback: se `timestampComputeAndGraphics`/`timestampPeriod` não permitirem, a telemetria de tempo reporta "indisponível" e o restante continua.

### VRAM

- **REQ-PROF-03** — `VK_EXT_memory_budget` exigida na seleção e habilitada no device; allocator VMA com `EXT_MEMORY_BUDGET_BIT`. Coleta por amostra: `GetHeapBudgets` (usage/budget reais por heap) + `CalculateStatistics` (bytes/blocos/não usados por heap e tipo de memória). `BuildStatsString` alimenta o snapshot JSON (dump completo de alocações).

### Export para arquivo

- **REQ-PROF-04** — Dois destinos em `bin/telemetry/`: (a) snapshot JSON sob demanda (tecla dedicada, ex. F9) com budgets, estatísticas VMA, timings do último frame e o dump do `BuildStatsString`; (b) série temporal CSV anexada a cada `TELEMETRY_CSV_INTERVAL_MS = 500 ms` (configurável; 0 = desligada) com timestamp, frame, tempos por operação (µs) e uso/budget por heap (MiB). Arquivos com timestamp no nome (`telemetry_YYYYMMDD_HHMMSS.json`/`.csv`); rotação por sessão.

### Overhead e opt-in

- **REQ-PROF-05** — Telemetria opt-in em runtime (`telemetry.enabled`, padrão ligada em builds de desenvolvimento): quando desligada, nenhum objeto é criado e nenhum comando extra é gravado nos command buffers (os pontos de instrumentação testam a flag antes de gravar). Quando ligada, a coleta de resultados nunca bloqueia o frame.

## Escopo

- Módulo `telemetry.odin` na engine (estado, pools, coletores, export).
- Labels/nomes nos command buffers e objetos da engine e do motor de voxels.
- Timestamps GPU nas passagens das duas filas (gráfica e compute) com leitura assíncrona.
- VRAM via EXT_memory_budget + VMA (budgets, statistics, dump JSON).
- Export JSON sob demanda + série CSV em `bin/telemetry/`.
- Flag de habilitação em runtime com overhead estrutural zero quando desligada.

## Não escopo

- `VK_KHR_performance_query` (contadores de hardware): backlog — ver ADR-T1, opção B.
- Nsight Aftermath (crash dumps GPU): backlog — ver ADR-T1, opção D.
- SDKs externos (Tracy, Nsight Perf SDK): **adiados** por decisão do mantenedor na ADR-T1 — uma fatia futura integrará um SDK sobre os mesmos pontos de instrumentação desta fatia.
- HUD/GUI de telemetria na janela (imgui ou similar): o arquivo é o destino desta fatia.
- Streaming de telemetria pela rede, alertas ou dashboards.
- Simulação Python: a fatia não altera shaders (o workflow exige simulação apenas para mudanças de shader); a lógica CPU é coberta pelos cenários e ACs.

## Dependências

- [[VS-04-mirror-c2|VS-04]] concluída e verificada (pontos de instrumentação do pipeline completo existem).
- [[ADR-T1-telemetria-vulkan-vma|ADR-T1]] aceita pelo mantenedor em 2026-11-05 (Opção A agora; Opção C numa fatia futura); não há bloqueio de decisão.

## Interfaces e recursos

### Contratos novos (Odin)

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `TelemetryManager` | enabled, query pools por frame (gráfico) e por lote (compute), `timestamp_period_ns`, últimos resultados por operação, contadores CSV | Campo do app da engine; init após o device, destroy com o device |
| Operações medidas | enum: `Generate`, `Pack`, `ApplyEdits`, `BuildWorkQueue`, `FinalizeWorkQueue`, `MeshDraw`, `FrameTotal` | Índice = par de timestamps no pool do slot |
| Snapshot JSON | budgets por heap, statistics VMA, timings do último frame, dump `BuildStatsString` | Escrito com `BuildStatsString` + `FreeStatsString` |
| Série CSV | header fixo; uma linha por amostra: `timestamp_ms, frame, op_*, heap_*_used_mib, heap_*_budget_mib` | Append com flush por amostra |

### Recursos e proprietários

- **Query pools**: 2 slots gráficos × 16 queries e 3 slots de compute × 8 queries (frames/lotes em voo), criados no init quando habilitada; destruídos com o device. Slot de compute segue o ring de lotes da worker (mesmo índice `submitted_batch_count % 3`).
- **EXT_memory_budget**: entra nas extensões obrigatórias do device (seleção rejeita quem não tem — padrão do REQ-FND-DEV) e na flag do allocator VMA.
- **Arquivos**: `bin/telemetry/telemetry_<timestamp>.{json,csv}` criados sob demanda (JSON) e na habilitação (CSV); nunca sobrescrevem a sessão anterior.

### Sequência do frame (integração)

```
worker (compute): BeginLabel lote → [generate] [pack] timestamps → EndLabel
  leitura assíncrona do slot de 3 lotes atrás (nunca bloqueante)
loop principal:
  command buffer do frame: timestamps + labels por passagem
    (apply_voxel_edits, builder, finalize, draw; frame total)
  após o submit: leitura do slot gráfico de 2 frames atrás
  a cada 500 ms (se CSV ligada): append da amostra
  sob demanda (F9): snapshot JSON
```

### Comportamento quando limites são atingidos

- Timestamps indisponíveis (limite do dispositivo): telemetria de tempo reporta `indisponível` no JSON/CSV; VRAM e labels seguem funcionando.
- Resultado de query ainda não disponível: a amostra mantém os últimos valores válidos; nenhum stall.
- `VK_EXT_memory_budget` ausente: dispositivo rejeitado na seleção (feature obrigatória nova) — o alvo de desenvolvimento (RTX 3050) suporta.
- Telemetria desligada: nenhum objeto criado, nenhum comando gravado, nenhum arquivo aberto.
- Swapchain recriada: query pools são por slot de frame em voo — nada a recriar.

## Cenários

### Cenário de sucesso

- **Dado** a telemetria habilitada em uma sessão com streaming e edições roteirizadas.
- **Quando** frames avançam, F9 é pressionado e uma captura Nsight/RenderDoc é feita.
- **Então** as passagens aparecem nomeadas na captura; o CSV acumula amostras com tempos plausíveis por operação (a soma das passagens ≤ frame total) e uso/budget de VRAM por heap; o JSON snapshot contém budgets, estatísticas VMA e o dump completo de alocações.

### Falhas e concorrência

- Readback de query atrasado: amostras reutilizam o último valor válido; nenhum frame bloqueia.
- Timestamps sem suporte na fila: fallback documentado, demais coletores intactos.
- Worker sem lotes pendentes: nenhum pool de compute é lido (não há valores novos; o anel conserva o anterior).
- Telemetria desligada em runtime: os pontos de instrumentação não gravam nada no frame seguinte; objetos já criados permanecem (não há destruição/recriação dinâmica nesta fatia).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-05-AC-01 | Todas as passagens GPU aparecem nomeadas em captura de frame | Captura Nsight Graphics ou RenderDoc do mantenedor com as regiões visíveis | **Pendente de captura do mantenedor** — as regiões gravadas são: `render_pass`, `draw_mesh`, `apply_voxel_edits`, `build_work_queue`, `finalize_work_queue` (fila gráfica) e `generate`, `pack` (fila de compute), além dos nomes nos buffers/pipelines |
| VS-05-AC-02 | Tempos GPU por operação presentes no CSV/JSON, calibrados por `timestampPeriod`, plausíveis (> 0; soma das passagens ≤ frame total) | Inspeção do arquivo gerado em sessão com streaming + flush roteirizado | Verificado — série CSV com amostras a cada 500 ms (ex.: generate 274 µs, pack 210 µs, build_work_queue 36 µs, finalize 3 µs, mesh_draw 636 µs, frame_total 686 µs; soma das partes ≤ frame total em todas as amostras); `apply_edits` = 0 em frames sem flush (comportamento especificado: mantém o último valor) |
| VS-05-AC-03 | Budgets de VRAM por heap presentes e consistentes (`usage ≤ budget`; `statistics.blockBytes ≤ usage` do VMA) | Inspeção do snapshot JSON + linhas do CSV | Verificado — snapshot JSON válido (parseado por json.load): heap 0 (device-local) used 300,6 / budget 3.367,7 MiB, heap 1 (host) used 81,3 / budget 15.479,4 MiB, `blockBytes ≤ usage` nos dois heaps; `vma_detailed_map` (dump completo do `BuildStatsString`) embutido como objeto JSON |
| VS-05-AC-04 | Com a telemetria desligada, nenhum objeto/comando extra existe e a aplicação roda normal | Execução com a flag off: log sem erros de validation e nenhum arquivo criado em `bin/telemetry/` | Verificado — build com `TELEMETRY_DEFAULT_ENABLED :: false`: diretório `bin/telemetry/` não é criado e log sem nenhum erro de validation; após restaurar o default, CSV volta a ser gerado |

## Tarefas da especificação

- [x] Vincular o escopo definido pelo mantenedor (REQ-PROF-01..05).
- [x] Formalizar pools, leitura assíncrona, formatos de arquivo e opt-in.
- [x] Especificar os cenários de fallback e concorrência.
- [x] Definir validação para cada critério de aceitação.
- [x] Submeter à revisão e obter aprovação. — ADR-T1 aceita e spec aprovada pelo mantenedor em 2026-11-05.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação. Só entram na fila após a aprovação desta spec.

1. **VS-05-IMPL-01 — Módulo de telemetria + labels** (REQ-PROF-01, REQ-PROF-05; AC-01, AC-04). `telemetry.odin` (estado, flag, init/destroy), labels nas passagens das duas filas, nomes nos objetos-chave.
2. **VS-05-IMPL-02 — Timestamps GPU** (REQ-PROF-02, REQ-PROF-05; AC-02). Query pools por slot, gravação nas passagens, leitura `WITH_AVAILABILITY` atrasada, calibração `timestampPeriod`, fallback de indisponibilidade.
3. **VS-05-IMPL-03 — VRAM via budget + VMA** (REQ-PROF-03; AC-03). EXT_memory_budget na seleção/device/allocator; coleta de `GetHeapBudgets` + `CalculateStatistics`.
4. **VS-05-IMPL-04 — Export JSON + CSV** (REQ-PROF-04; AC-02, AC-03). Snapshot sob demanda (F9) com `BuildStatsString`; série temporal CSV em `bin/telemetry/`.
5. **VS-05-IMPL-05 — Evidências e fechamento** (AC-01..04). Sessão de validação (log limpo, arquivos inspecionados), captura do mantenedor para o AC-01; atualizar tracking e commitar com o nome da spec.

## Questões abertas

- Tecla do snapshot (proposta: F9) e intervalo padrão do CSV (500 ms): fixados na implementação e registrados aqui. Não bloqueia a aprovação.
- Formato do JSON (estrutura de campos exata): definido na implementação, espelhando os nomes VMA. Não bloqueia a aprovação.

## Histórico

- 2026-11-05 — Rascunho elaborado a partir do pedido do mantenedor (telemetria GPU: tempos por operação, VRAM, export para arquivo; análise de opções na [[ADR-T1-telemetria-vulkan-vma|ADR-T1]]); submetida à revisão.
- 2026-11-05 — Revisão pós-ADR-T1: bloqueio removido (ADR-T1 aceita); não-escopo revisto — SDKs externos deixam de ser "rejeitados" e viram fatia futura planejada (decisão do mantenedor). **Spec aprovada**; tarefas VS-05-IMPL-01..05 destravadas.
- 2026-11-05 — Implementação concluída (IMPL-01..05): módulo `telemetry.odin` (flag de runtime com toggle F8); labels `EXT_debug_utils` em todas as passagens das duas filas + nomes nos buffers/pipelines; timestamps GPU com query pools (2 slots gráficos × 16 queries, 3 slots de compute × 8 queries), leitura assíncrona nunca bloqueante e calibração por `timestampPeriod`; `VK_EXT_memory_budget` na seleção/device + VMA com `EXT_MEMORY_BUDGET_BIT` (`GetHeapBudgets` + `CalculateStatistics` por amostra); série CSV a cada 500 ms e snapshot JSON sob demanda (F9) com o dump completo do `BuildStatsString`, em `bin/telemetry/`.
- 2026-11-05 — Bugs corrigidos durante a integração: (1) `vkGetQueryPoolResults` devolve resultados de 32 bits por padrão — a flag `QUERY_RESULT_64_BIT` (`._64` no binding Odin) é obrigatória para o layout u64 esperado; (2) com `WITH_AVAILABILITY` o stride entre elementos deve ser 16 B (valor u64 + disponibilidade u64) — com stride 8 cada valor sobrescrevia a disponibilidade da query anterior; (3) o driver NVIDIA responde `VK_NOT_READY` para a chamada inteira quando qualquer query da faixa está indisponível (ex.: `apply_edits` em frames sem flush) — a leitura passou a ser por operação (uma chamada por par de queries), mantendo o último valor válido das ausentes; (4) o `fmt` do toolchain trata `{`/`}` como sintaxe de formatação (Python-like) e os escapes `{{`/`}}` se comportaram de forma inconsistente em fim de string — as chaves literais do JSON passaram a ser escritas fora das format strings.
- 2026-11-05 — Validação (AC-02..04 verificados; AC-01 pendente de captura do mantenedor): tempos plausíveis por operação no CSV (mesh_draw domina o frame, soma das partes ≤ frame total), snapshot JSON válido com budgets e dump VMA completo, estado desligado sem nenhum objeto/arquivo gerado. Para fechar o AC-01: abrir uma captura no Nsight Graphics ou RenderDoc e conferir as regiões nomeadas (`render_pass`, `draw_mesh`, `build_work_queue`, `finalize_work_queue`, `apply_voxel_edits`, `generate`, `pack`) e os nomes dos buffers/pipelines.
