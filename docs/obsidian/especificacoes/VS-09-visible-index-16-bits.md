---
id: VS-09
titulo: Visible index de 16 bits na fila de trabalho
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-08
bloqueada_por: []
requisitos: [REQ-WID-01, REQ-WID-02, REQ-WID-03, REQ-SIM-06]
ultima_atualizacao: 2026-11-06
---

# VS-09 — Visible index de 16 bits na fila de trabalho

## Objetivo

Ampliar o `visible_index` do item da fila de trabalho de 12 para 16 bits, elevando o limite de formato do raio de visão de `vision ≤ 9` para `vision ≤ 25` (≈65 mil chunks visíveis), e atualizando o contrato do item (VS-02), a regra de validação (VS-08) e a simulação — sem mudar push constants, estruturas de memória ou a aritmética dos rings.

## Rastreabilidade

- GOAL: pedido do mantenedor (2026-11-06), em continuação da VS-08 — resolve o backlog registrado na consequência da [[ADR-C1-config-ini-provisionamento|ADR-C1]] ("alargar o empacotamento para 16 bits").
- Referência: `pack_work_item` em `src/assets/shaders/common.slang` (linha ~197), decode em `src/assets/shaders/render.slang` (`build_brick_mesh`, linhas ~125-128), espelho em `tools/sim/render_sim.py` (`pack_work_item`/`unpack_work_item`, ~472-478, e o check de fronteira `< (1<<26)` em ~668); regra de formato em `src/engine/config.odin`.
- Decisões: [[ADR-B12-visible-index-16-bits|ADR-B12]] (**bloqueia a aprovação desta spec**); amenda [[VS-02-task-mesh-templates|VS-02]] (contrato do item) e [[VS-08-config-ini-provisionamento|VS-08]] (REQ-CFG-03).
- Fundação: VS-08 concluída (capacidade de visíveis dinâmica via push constant — nada muda nesse mecanismo).

## Requisitos

### Layout do item

- **REQ-WID-01** — Novo empacotamento do item de 32 bits: `visible_index (16b) | brick (10b)<<16 | parte (2b)<<26 | subdivisão (2b)<<28` (30 bits usados, 2 de reserva). Atualizados bit a bit em: `pack_work_item` (`common.slang`), decode no `build_brick_mesh` (`render.slang`) e o par `pack_work_item`/`unpack_work_item` de `tools/sim/render_sim.py` (fonte única de verdade continuada sendo o Slang, sim espelhando). O check de fronteira da sim passa de `< (1<<26)` para `< (1<<30)`.

### Validação

- **REQ-WID-02** — Emenda à REQ-CFG-03 da VS-08: a regra de formato passa a `1 ≤ vision ≤ 25`, justificada pela capacidade `visible_capacity = |esfera(vision)| ≤ 65.535` (16 bits); r=25 ≈ 65 mil visíveis, r=26 estoura. Mensagem de erro correspondente (qual regra, valores, limite). As demais regras da VS-08 — histerese `vision ≤ generation < unload`, teto de slots, limites de lote e a validação de máquina (budget × 0,9, que governa a VRAM da fila linear em visíveis) — ficam **inalteradas**.

### Invariantes verificados

- **REQ-WID-03** — Nenhuma mudança em push constants (`visible_chunk_capacity` já é u32; 65.535 cabe) nem em estruturas de memória. Aritmética do ring conferida para o pior caso: `2 × (8 + 65.535 × 1.024)` words ≈ 134 M < 2³² — offsets e índices permanecem u32 sem risco de estouro; `x` do draw indireto é u32. Brick permanece 10 bits (1.024 bricks/chunk é geometria fixa); parte/subdivisão permanecem 2 bits.

### Simulação

- **REQ-SIM-06** — Antes da integração: `tools/sim/render_sim.py` com as novas máscaras cobrindo fronteiras — roundtrip nos cantos (`visible_index` ∈ {0, 4095, 4096, 65535} × brick {0, 1023} × parte/subdivisão {0, 3}), itens abaixo de `1<<30`, e o cenário VS-08 de capacidade parametrizada rodando com capacidades representativas (default, vision 10, máxima 65.535). Checks antigos seguem verdes.

## Escopo

- `src/assets/shaders/common.slang` (`pack_work_item`) e `src/assets/shaders/render.slang` (decode).
- `tools/sim/render_sim.py` (pack/unpack + checks de fronteira + casos novos).
- `src/engine/config.odin` (regra de formato + mensagem).
- Docs: tabela de contratos e REQ-MESH-01 da VS-02 (layout do item), REQ-CFG-03 da VS-08 (emenda registrada no histórico), consequência da ADR-C1 (marcada como resolvida pela ADR-B12), comentário do `bin/vox.ini`, históricos e tracking.

## Não escopo

- Mais de 16 bits para o `visible_index` (18 bits zeraria a reserva e exigiria fila > 2 GiB para vision ~40 — sem benefício prático).
- Mudança nos campos brick (10b), parte (2b) ou subdivisão (2b), ou item de 64 bits.
- Novos caps arbitrários de `vision` além do de formato (25) — VRAM e custo por frame seguem com a validação de máquina da VS-08 e a escolha do usuário.
- Qualquer mudança em push constants, rings, culling (VS-06) ou edição (VS-03).

## Dependências

- [[VS-08-config-ini-provisionamento|VS-08]] concluída e verificada (config, capacidade dinâmica, validação de máquina).
- [[ADR-B12-visible-index-16-bits|ADR-B12]] — ratificada (Opção A) em 2026-11-06; aprovação desbloqueada.

## Interfaces e recursos

| Contrato | Antes | Depois |
| --- | --- | --- |
| Item da fila (u32) | `visible_index (12b) \| brick (10b)<<12 \| parte (2b)<<22 \| subdiv (2b)<<24` | `visible_index (16b) \| brick (10b)<<16 \| parte (2b)<<26 \| subdiv (2b)<<28` |
| Regra de formato (VS-08 REQ-CFG-03) | `1 ≤ vision ≤ 9` | `1 ≤ vision ≤ 25` |

Nenhum recurso novo; nenhum binding, push constant ou layout de memória alterado.

## Cenários

### Cenário de sucesso — vision 10 liberado

- **Dado** um INI com `vision=10` (≈4,2 mil visíveis — rejeitado antes da VS-09).
- **Quando** a aplicação sobe.
- **Então** inicializa normalmente: itens empacotados com 16 bits, mesh resolve `visible_index` corretamente, readback da fila coerente, render normal.

### Limite de formato novo

- **Dado** `vision=26` (esfera ≈73 mil > 65.535).
- **Quando** a aplicação inicia.
- **Então** erro fatal pré-janela citando o limite de 16 bits (65.535 visíveis, vision ≤ 25); `vision=25` e `vision=9` permanecem válidos.

### Paridade

- **Dado** os defaults (vision=8, 2.109 visíveis — abaixo de 4.096).
- **Quando** a aplicação roda.
- **Então** comportamento e contagens idênticos ao baseline VS-08 (o novo layout só muda bits acima do bit 12, inertes para índices pequenos).

### Falhas e concorrência

- Item com `visible_index > 65.535` jamais é gerado: a capacidade derivada é a própria esfera, validada antes do provisionamento — inalcançável por construção.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-09-AC-01 | Sim verde com as novas máscaras: roundtrip nas fronteiras, itens < 1<<30, cenário de capacidade VS-08 com default/vision 10/máxima, checks antigos verdes | `tools/sim/render_sim.py` + `pack_sim.py` | **Verificada** — `render_sim.py`: 2.712 checks, 0 falhas (baseline pré-mudança: 2.699; +13 novos: roundtrip nos cantos 4×2×2×2 = 32 combinações, não-vazamento 16 bits, itens < 1<<30, bit 12 antigo sem colisão, ring pior caso < 2³², esfera(25)=65.267 ≤ 65.535, esfera(26)=73.525 > 65.535, vision=10 e vision=25 pela regra de formato, finalize/clamp nas capacidades default/4.169/65.535); `pack_sim.py`: 959 checks verdes |
| VS-09-AC-02 | Smoke com `vision=10` sobe e renderiza; readback da fila coerente; validação de máquina OK | Smoke com INI vision=10 (wait ~streaming estabilizar), readback | **Verificada** — smoke 30 s com vision=10/generation=11/unload=12: log "visíveis=4169 slots=5575 itens_fila=4269056", validação de máquina OK (276.508.504 B de 9.534.481.369); readback da fila (instrumentação temporária, revertida): append = x = 1.910–1.940, y = z = 1, overflow = 0 em todos os snapshots; itens decodificados coerentes com o layout 16\|10\|2\|2 (ex.: item 1.048.620 → vis=44, brick=16); render normal por ~25 s (mesh_draw 250–330 µs sustentado); erros de validation apenas o VUID pré-existente de queries não inicializadas (VS-05) |
| VS-09-AC-03 | `vision=26` → erro fatal pré-janela com mensagem do limite de 16 bits; defaults → paridade de contagens com baseline | Bateria de INIs + smoke default comparado | **Verificada** — vision=26: exit 1 pré-janela com "streaming.vision = 26 fora do intervalo válido 1..25 (limite de formato: visible_index tem 16 bits… vision=26 daria 73525 > 65535)"; vision=25: passa pela regra de formato (falha depois no cap resident_slots ≤ 16384 da VS-08, inalterado — por construção, generation ≥ 25 excede 16.384 slots); smoke default (vision=8): 2.109 visíveis, readback 1.910/1.911/1.915/1.940 itens, overflow=0 — distribuição idêntica ao baseline VS-08 |

## Tarefas da especificação

- [x] Vincular o pedido do mantenedor ao backlog da ADR-C1 e ao contrato da VS-02.
- [x] Formalizar o novo layout, a emenda de validação e os invariantes (aritmética u32, push constants).
- [x] Cobrir sucesso, limite novo e paridade.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-B12 e obter aprovação da spec. — ADR-B12 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-B12. Cada tarefa referencia requisitos e critérios de aceitação.

1. [x] **VS-09-IMPL-01 — Simulação** (REQ-SIM-06; AC-01). Novas máscaras/shifts no pack/unpack de `render_sim.py`, check de fronteira `< (1<<30)`, casos de canto, capacidades default/10/máxima. Rodar antes de mexer nos shaders.
2. [x] **VS-09-IMPL-02 — Shaders e validação** (REQ-WID-01, REQ-WID-02; AC-02, AC-03). `pack_work_item` e decode com 16 bits; `config.odin` com `vision ≤ 25` e mensagem; `spirv-val` limpo.
3. [x] **VS-09-IMPL-03 — Evidências e fechamento** (AC-01..03). Smoke vision=10 + readback, bateria vision=26/default, docs (VS-02, VS-08, ADR-C1, vox.ini, tracking) e commit com o nome da spec.

## Questões abertas

- Nenhuma. O cap de formato (25), a justificativa da esfera e a reserva de 2 bits estão fixados na ADR-B12.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (visible_index 16 bits para liberar vision > 9); ADR-B12 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-B12 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-09-IMPL-01..03 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..03) e validação verificada** (AC-01..03; evidências na tabela acima). Sim antes dos shaders: `render_sim.py` 2.699 → 2.712 checks, `pack_sim.py` 959, ambos verdes. Shaders (`pack_work_item` 16|10|2|2 no `common.slang`, decode no `render.slang`) com `spirv-val` limpo nos três SPIR-V e `odin build` OK. `config.odin`: regra de formato `1 ≤ vision ≤ 25`, mensagem citando 16 bits/65.535/esfera(26)=73.525. Readbacks da fila via instrumentação temporária (mesmo padrão do `debug_readback_validate`, revertida ao final): vision=10 → append = x = 1.910–1.940, overflow = 0, decodes coerentes; default → distribuição 1.910–1.940 idêntica ao baseline VS-08. Bateria: vision=26 → exit 1 pré-janela com a mensagem nova; vision=25 aceito pela regra de formato (o cap resident_slots ≤ 16384 da VS-08, inalterado, impede configs completas com generation ≥ 25 — esperado e fora de escopo). Docs: VS-02 (REQ-MESH-01 + tabela de contratos), VS-08 (emenda REQ-CFG-03), ADR-C1 (backlog marcado resolvido), comentário do `bin/vox.ini` (bin/ é gitignored), tracking. Ressalvas: erros de validation observados foram apenas o VUID pré-existente de queries não inicializadas (VS-05); sem screenshots (engine não tem captura — paridade evidenciada por contagens de readback, mesmo critério da VS-08).
