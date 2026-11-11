---
id: ADR-T1
titulo: Telemetria GPU via API Vulkan + VMA (sem SDKs externos)
tipo: decisao
status: aceita
specs_afetadas:
  - VS-05
ultima_atualizacao: 2026-11-05
---

# ADR-T1 — Telemetria GPU via API Vulkan + VMA (sem SDKs externos)

## Contexto

O mantenedor depura com NVIDIA Nsight Graphics e quer telemetria integrada à aplicação: tempo de execução de cada operação na GPU, consumo de VRAM e persistência desses dados em arquivo — preferencialmente via API Vulkan, complementando (não substituindo) o Nsight.

## Requisitos relacionados

- VS-05: REQ-PROF-01..05.

## Opções

### Opção A — Core Vulkan + EXT + VMA (recomendada)

- **Timestamps**: `vkCmdWriteTimestamp(2)` + `VkQueryPool` (TIMESTAMP), core Vulkan. Um pool por frame em voo, leitura com `vkGetQueryPoolResults` + `WITH_AVAILABILITY` N frames depois (sem stall), calibração por `timestampPeriod` (ns/tick). Mede execução GPU por passagem: generate/pack por lote (fila de compute), apply_voxel_edits, builder/finalize da fila de trabalho, draw mesh, frame gráfico total.
- **VRAM**: `VK_EXT_memory_budget` (heapBudget/heapUsage reais do driver) + VMA: `GetHeapBudgets` (rápido, por frame), `CalculateStatistics` (bytes/blocos por heap e tipo) e `BuildStatsString` (dump JSON completo de todas as alocações — perfeito para o snapshot em arquivo).
- **Labels**: `VK_EXT_debug_utils` (já no instance para a validation) — `CmdBegin/EndDebugUtilsLabelEXT` por passagem e `SetDebugUtilsObjectNameEXT` em buffers/pipelines: as regiões aparecem nomeadas nas capturas do Nsight/RenderDoc, elevando o fluxo que o mantenedor já usa.
- **Export**: snapshot JSON sob demanda + série temporal CSV em intervalo configurável, em `bin/telemetry/`.
- Vantagens: zero dependências novas, tudo já exposto nos bindings Odin (vendor:vulkan e shared:vma), overhead controlado e opt-in. Desvantagem: timestamps medem tempo de GPU wall-clock da passagem, não contadores internos (utilização de SM, throughput de memória).

### Opção B — VK_KHR_performance_query

- Contadores de hardware ricos (ocupação de SM, L2, throughput de memória...). Contras: suporte e unidades variam por driver; no Windows parte dos contadores NVIDIA exige modo de desenvolvedor/privilégio elevado desde 2019; setup complexo (passes de contadores, disponibilidade por família de fila). O Nsight Graphics já cobre esse nível de detalhe — duplicar na aplicação tem custo alto e valor marginal. **Backlog.**

### Opção C — SDKs de profiling externos (Tracy, Nsight Perf SDK)

- Tracy tem integração Vulkan excelente, mas exige biblioteca C linkada e interop no Odin; Nsight Perf SDK é proprietário, C, e mirado a contadores (mesma classe da Opção B). Ambos criam dependência nova. **Adiada**: o mantenedor decidiu implementá-la numa fatia futura, após a VS-05 (ver Decisão).

### Opção D — Nsight Aftermath (crash dumps GPU)

- Diagnóstico de device-lost, ortogonal a profiling contínuo. **Backlog** (teria ajudado no TDR da correção 3 da VS-02 — registrar como melhoria futura).

## Decisão

Seguiremos com a Opção A por enquanto, posteriormente implementaremos a opção C

*(Registro: aprovada pelo mantenedor em 2026-11-05 — Opção A na VS-05; Opção C (SDK externo, ex. Tracy) planejada para uma fatia futura; Opções B e D permanecem no backlog.)*

## Consequências

- O dispositivo passa a exigir e habilitar `VK_EXT_memory_budget`; o allocator VMA ganha `EXT_MEMORY_BUDGET_BIT`.
- Query pools de timestamp entram no ciclo de frames em voo (2 slots), com leitura atrasada e nunca bloqueante.
- A telemetria é opt-in em runtime com overhead estrutural zero quando desligada (nenhum objeto criado, nenhum comando gravado).
- A Opção C (SDK externo, ex. Tracy) gera uma fatia futura de integração que consumirá os mesmos pontos de instrumentação; B e D ficam no backlog.
- Integração principal pertence a [[VS-05-telemetria-profiling|VS-05]].

## Histórico

- 2026-11-05 — Decisão registrada como pendente (análise das opções A–D completa).
- 2026-11-05 — **Aceita pelo mantenedor** com o texto da Decisão: Opção A agora (VS-05); Opção C (SDK externo) numa fatia futura; B e D no backlog.
