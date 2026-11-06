---
id: VS-08
titulo: Configuração via INI e provisionamento runtime
tipo: especificacao
status_spec: aprovada
status_implementacao: implementada
status_validacao: verificada
depende_de:
  - VS-05
bloqueada_por: []
requisitos: [REQ-CFG-01, REQ-CFG-02, REQ-CFG-03, REQ-CFG-04, REQ-CFG-05, REQ-CFG-06, REQ-CFG-07, REQ-SIM-05]
ultima_atualizacao: 2026-11-06
---

# VS-08 — Configuração via INI e provisionamento runtime

## Objetivo

Os seis parâmetros de streaming/compute — `RADIUS_VISION` (8), `RADIUS_GENERATION` (9), `RADIUS_UNLOAD` (10), `RADIUS_SIMULATION` (5), `MAXIMUM_CHUNKS_PER_BATCH` (16) e `MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT` (3) — deixam de ser constantes de compilação e passam a ser carregados de um arquivo `.ini`; a engine provisiona **em runtime** todos os buffers, rings e pools dimensionados por eles, garantindo coerência e o suporte da máquina; parâmetros incoerentes ou insuportáveis encerram a inicialização com mensagem de erro explicando o motivo.

## Rastreabilidade

- GOAL: novo requisito do mantenedor (2026-11-06); relaciona-se ao backlog B5 ([Arquitetura — §2/§9](../../arquitetura.md): raio de geração vs slots) que esta fatia absorve por construção.
- Referência: constantes em `src/engine/voxel_types.odin` (raios, `MAXIMUM_VISIBLE_CHUNKS`, `MAXIMUM_RESIDENT_CHUNKS`, `MIRROR_PAGE_POOL_SIZE`, `MIRROR_RING_SLOTS`); provisionamento em `src/engine/voxel_gpu.odin` (`scratch`, `generation_jobs`, pools do slot, `visible_chunks`, `work_queue`, `mirror_export_ring`), `src/engine/voxel_engine.odin` (publicação/cap), `src/engine/voxel_worker.odin` (ring de lotes), `src/engine/voxel_mirror.odin` (pool de páginas), `src/engine/telemetry.odin` (pools de compute); uso em shader: `MAXIMUM_VISIBLE_CHUNKS` em `src/assets/shaders/common.slang` (`work_queue_base_words`).
- Decisões: [[ADR-C1-config-ini-provisionamento|ADR-C1]] (**bloqueia a aprovação desta spec**); B5 absorvida (slots derivados de `|esfera(generation)|`).
- Fundação: VS-00 (pipeline layouts, push constants), [[VS-05-telemetria-profiling|VS-05]] (`GetHeapBudgets` para o limite de máquina), [[VS-07-eventos-input-replay|VS-07]] (parsing de parâmetros de inicialização, para `--config`).

## Requisitos

### Fonte e formato

- **REQ-CFG-01** — Configuração em `vox.ini` flat (seções `[streaming]` e `[compute]`), procurado no diretório de trabalho; flag `--config <caminho>` sobrescreve o caminho (mesmo parsing de flags da VS-07). Arquivo ausente → **defaults embutidos** (os valores atuais: 8/9/10/5, 16, 3) + warning no log. Parse estrito: chave desconhecida → warning e segue; valor malformado (não inteiro, fora do domínio do tipo) → **erro fatal** com o motivo, antes da criação da janela (exit ≠ 0, mesmo padrão do replay VS-07).

```ini
[streaming]
vision=8        ; raio da bolha de visão (chunks)
generation=9    ; raio da bolha de geração
unload=10       ; raio de descarga (histerese)
simulation=5    ; raio da bolha do mirror CPU-side

[compute]
chunks_per_batch=16          ; chunks por lote de compute (B4)
batches_in_flight=3          ; lotes de compute concorrentes
```

### Capacidades derivadas

- **REQ-CFG-02** — Capacidades são sempre **derivadas** dos seis parâmetros, nunca configuradas diretamente. `visible_capacity = |esfera(RADIUS_VISION)|` (chunks com `x²+y²+z² ≤ r²`; 515 em r=5, 2.109 em r=8, 7.153 em r=12); `resident_slots = |esfera(RADIUS_GENERATION)|`; `scratch_chunks = batches_in_flight × chunks_per_batch`; `mirror_pages = ⌈|esfera(RADIUS_SIMULATION)| × 1,5⌉` (773 para r=5 nos defaults — antes: 768 fixas); `mirror_ring_slots = max(64, próxima potência de 2 ≥ scratch_chunks)` (48 → 64 hoje). Todas calculadas em `u64` intermediário com checagem de overflow antes de virar tamanho de alocação.

### Validação

- **REQ-CFG-03** — Regras de coerência, cada uma com mensagem de erro própria (qual regra, valores recebidos, limites): `1 ≤ vision ≤ 9` (limite de **formato**: `visible_index` tem 12 bits no item da fila de trabalho — 4.096 visíveis máx.; r=9 ⇒ 3.071, r=10 ⇒ 4.169 > 4.096); `1 ≤ simulation`; `vision ≤ generation < unload` (histerese estrita); `1 ≤ chunks_per_batch ≤ 64`; `1 ≤ batches_in_flight ≤ 8`; `scratch_chunks ≤ 256`; `resident_slots ≤ 16384`.
- **REQ-CFG-04** — Limite de máquina: bytes device requeridos (pools derivados: slots residentes ≈ 42,7 KiB/slot ocupação+planos+headers+records, fila de trabalho `2 × (8 + visible_capacity × 1.024) × 4 B`, scratch `scratch_chunks × 131 KiB`, pools fixos) são somados e comparados ao **budget da heap device-local** (`GetHeapBudgets`, VS-05) com margem de segurança de 10%; excedeu → erro fatal informando requisito × disponível e sugerindo o ajuste (ex.: reduzir `generation` para ≤ X cabe).
- **REQ-CFG-07** — Carregamento e validação acontecem **antes** de `engine.CreateEngine` (o device ainda não existe: o budget é consultado logo após `create_vma_allocator`, antes do provisionamento dos buffers do motor de voxels — a validação de máquina falha rápido e limpo, sem janela).

### Provisionamento

- **REQ-CFG-05** — Nenhum tamanho de buffer/array permanece ligado às constantes antigas. Dimensionados em runtime a partir das capacidades derivadas: `visible_chunks` (`2 × visible_capacity × 48 B`), `work_queue` (`2 × (8 + visible_capacity × 1.024) × 4 B`), pools do slot (`occupancy_pool`, `material_plane_pool`, `chunk_headers`, `special_voxel_records` × `resident_slots`), `scratch` e `generation_jobs` (× `scratch_chunks`), `mirror_export_ring` (× `mirror_ring_slots`), pool de páginas do mirror (× `mirror_pages`); arrays Odin fixos passam a alocações dinâmicas: `compute_command_buffers`, `telemetry.compute_pools`, `claimed_batch.tasks` (worker). `ve_publish_visible` publica até `visible_capacity` (excedente nunca ocorre por construção — a bolha de visão É a capacidade).
- **REQ-CFG-06** — Contrato shader: `PushConstants` ganha `visible_chunk_capacity: u32` (**88 → 92 B**; `#assert`, `PUSH_CONSTANTS_SIZE` e os dois pipeline layouts atualizados, todas as gravações `CmdPushConstants` — `voxel_render` ×2, `voxel_worker` ×1). `common.slang`: `work_queue_base_words()` passa a `(visible_chunk_offset / push_constants.visible_chunk_capacity) × (WORK_QUEUE_STATE_WORDS + visible_chunk_capacity × BRICKS_PER_CHUNK)`; `MAXIMUM_VISIBLE_CHUNKS`/`WORK_ITEM_CAPACITY`/`WORK_QUEUE_SLOT_WORDS` deixam de ser constantes no Slang. Revisão registrada no histórico da VS-00. `pack_work_item` inalterado (12 bits, cap validado em CFG-03).

### Simulação

- **REQ-SIM-05** — Antes da integração: `tools/sim/render_sim.py` parametrizado por `visible_capacity` (ring da fila, offsets de slot, overflow) cobrindo capacidades distintas (padrão 2.109, mínima 33 em r=2, máxima 3.071 em r=9); `tools/sim/` ganha casos espelhando as regras de validação (contagens de esfera, caps, ordem de histerese). Checks existentes seguem passando.

## Escopo

- Módulo `src/engine/config.odin`: parse do INI, defaults, derivações, validação (coerência + máquina), `Config` global consumido pelos módulos do motor.
- Remoção das seis constantes de compilação e de todas as constantes derivadas (`MAXIMUM_VISIBLE_CHUNKS`, `MAXIMUM_RESIDENT_CHUNKS`, `MIRROR_PAGE_POOL_SIZE`, `MIRROR_RING_SLOTS`, `SCRATCH_CHUNK_COUNT`, `GENERATION_JOB_COUNT`, `WORK_ITEM_CAPACITY`, `WORK_QUEUE_SLOT_WORDS`), substituídas por campos do `Config`.
- Provisionamento runtime de todos os recursos listados em REQ-CFG-05 e atualização dos sites de uso (worker, engine, render, mirror, telemetry, gpu).
- Extensão do contrato de push constants (92 B) e do `common.slang` (REQ-CFG-06).
- Flags `--config`; logs de config efetiva na inicialização (valores escolhidos, capacidades derivadas, bytes provisionados).
- Docs: arquitetura (§2 e registro — alinhando os raios que hoje divergem do código: doc diz 12/16, código 9/10), manual técnico, tracking; B5 movida de pendente para "absorvida pela VS-08".

## Não escopo

- Novos parâmetros além dos seis (edição, telemetria, eventos, janela ficam como estão).
- Alargar o `visible_index` para 16 bits (liberaria vision > 9): backlog — sobram bits no item de 32, mas muda o contrato da fila de trabalho (VS-02/ADR-B10) sem necessidade imediata.
- Configuração em runtime (mudar raios com o mundo carregado): exige drenar/descarregar — backlog.
- Perfis/presets, UI de configuração, validação cruzada com o memory budget do host (só device-local nesta fatia; host é residual: mirror + rings host-visible).
- Alterar `NUM_FRAMES_IN_FLIGHT` (2) ou os limites do journal de edição (frame-based, independentes dos raios).

## Dependências

- [[VS-05-telemetria-profiling|VS-05]] implementada (`GetHeapBudgets`/VMA — a validação de máquina o usa; o AC-01 pendente dela não bloqueia este uso).
- [[ADR-C1-config-ini-provisionamento|ADR-C1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

### Contratos novos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `Config` (Odin) | os 6 parâmetros + capacidades derivadas (`visible_capacity`, `resident_slots`, `scratch_chunks`, `mirror_pages`, `mirror_ring_slots`) + bytes provisionados | global do package engine; imutável após o load |
| INI | seções `[streaming]`/`[compute]`, chaves da REQ-CFG-01; `;` comentários | parser pequeno e estrito, sem dependências externas |
| `PushConstants` | + `visible_chunk_capacity: u32` → **92 B** | revisão da VS-00 (terceira: já fora 88 B desde a VS-02) |

### Sequência de inicialização (integração)

```
main: logger → parse de flags (VS-07 + --config) → config_load()
      → erro fatal pré-janela se inválida
CreateEngine → create_vma_allocator → validação de máquina (budget × 0,9)
      → voxel_gpu_init provisiona tudo do Config → log da config efetiva
```

### Comportamento quando limites são atingidos

- Qualquer violação de REQ-CFG-03/04 → mensagem enumerando regra, valores e limites; exit ≠ 0 sem criar janela.
- INI ausente → defaults + warning; chave desconhecida → warning com nome da chave.
- Capacidade derivada zero ou overflow u32 → tratada como violação (erro, não alocação de tamanho zero).

## Cenários

### Cenário de sucesso — defaults e INI custom

- **Dado** ausência de `vox.ini` (defaults) e, numa segunda execução, um INI com `vision=5`, `generation=6`, `unload=7`, `simulation=3`, `chunks_per_batch=8`, `batches_in_flight=2`.
- **Quando** a aplicação sobe.
- **Então** ambas inicializam sem erros; com defaults o comportamento é idêntico ao baseline (2.109 visíveis, mesmas contagens de itens — readback: 1.910–1.940 grupos estáveis nos dois binários, overflow=0 — paridade VS-06); com o INI custom o log mostra as capacidades derivadas (515 visíveis, 925 slots, 16 scratch, 185 páginas, ring 64) e o readback da fila reflete a capacidade menor (cap de 527.360 itens vs 2.159.616 nos defaults).

### Coerência violada

- **Dado** um INI com `vision=6`, `generation=5` (visão maior que geração).
- **Quando** a aplicação inicia.
- **Então** erro fatal pré-janela: "streaming.generation (5) deve ser ≥ streaming.vision (6)" (ou regra equivalente), exit ≠ 0, nenhum objeto Vulkan do motor criado.

### Limite de formato e de máquina

- **Dado** `vision=10` (esfera 4.169 > 4.096) ou `generation=14` (esfera 11.513 slots ≈ 476 MiB — acima do limite de 16.384 slots em heaps pequenas, ou do budget em GPUs modestas).
- **Quando** a aplicação inicia.
- **Então** erro explicando o limite respectivo: de formato (12 bits do visible_index, máx. 4.096 visíveis, vision ≤ 9) ou de máquina (requerido × disponível, sugestão de ajuste).

### Falhas e concorrência

- Worker e render leem o `Config` somente após o load; imutável depois — sem corrida.
- B1 (aposentadoria dual) e todos os invariantes do AGENTS.md independem dos tamanhos: rings menores/maiores não alteram o protocolo de slots, da fila (overflow sinalizado) nem do mirror.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-08-AC-01 | Todas as regras de validação (coerência, formato, máquina) rejeitam com mensagem específica e exit ≠ 0; INI ausente → defaults; chave desconhecida → warning | Bateria de INIs inválidos (uma por regra) + casos ausente/desconhecida; sim espelhando as regras (REQ-SIM-05) | **Verificada** — bateria de 10 INIs inválidos (vision=10/0, simulation=0, generation<vision, unload≤generation, batch=65, bif=9, scratch=512, slots=73.525, valor malformado): mensagem específica + exit 1 em todos, sem janela; INI ausente → defaults+warning; chave desconhecida → warning. Regra de máquina (REQ-CFG-04) implementada e logada nos smokes, mas o caminho de falha não é exercitável nesta GPU (requerido máx ~750 MiB × budget ×0,9 de 9,5 GiB); sim espelha as 9 regras (render_sim.py, cenário VS-08) |
| VS-08-AC-02 | Paridade com defaults: comportamento idêntico ao baseline (2.109 visíveis, contagens de itens da VS-06, zero erros de validation) | Smoke com defaults vs baseline; readbacks comparados | **Verificada** — smoke default (INI ausente): 2.109 visíveis, 3.071 slots; readback da fila (instrumentação temporária, revertida): itens 1.910/1.915/1.936/1.940, overflow=0 — distribuição idêntica ao binário baseline (mesmos valores 1.910–1.940); erros de validation apenas o VUID pré-existente de queries não inicializadas (presente também no baseline VS-07, 17 ocorrências) |
| VS-08-AC-03 | INI custom (vision=5, batch=8, batches=2) sobe, provisiona os tamanhos derivados corretos e renderiza normalmente | Smoke com INI custom: log de capacidades, readback da fila, screenshots | **Verificada** (screenshots dispensadas — engine não tem captura; substituídas por readbacks da fila) — INI custom sobe com 515 visíveis, 925 slots, 16 scratch, 185 páginas, ring 64 (45,5 MiB provisionados); readback da fila coerente (capacidade 527.360 itens), overflow=0, render normal por 20 s |
| VS-08-AC-04 | Shader integrado sem constantes de capacidade: `spirv-val` limpo, `render_sim.py` parametrizado passa (incluindo caps mínimo/máximo), checks antigos verdes | Simulação estendida + build + `spirv-val` | **Verificada** — `spirv-val` limpo em render/voxel/edit.spv; sim VS-08: 2.699 checks, 0 falhas (ring/offsets/overflow para caps 33/2.109/3.071 + regras de validação); checks antigos (orçamento, frustum, B2, rotação) verdes; build Odin limpo |

## Tarefas da especificação

- [x] Vincular o escopo do mantenedor (INI, provisionamento, validação) às interfaces afetadas (constantes, buffers, shader, VS-05).
- [x] Formalizar capacidades derivadas, regras de validação e limites (formato 12 bits, budget device).
- [x] Cobrir sucesso, dados-limite e falhas (erro pré-janela, defaults, warnings).
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-C1 e obter aprovação da spec. — ADR-C1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-C1. Cada tarefa referencia requisitos e critérios de aceitação.

1. [x] **VS-08-IMPL-01 — Módulo de config** (REQ-CFG-01, REQ-CFG-02, REQ-CFG-03; AC-01). `src/engine/config.odin`: parser INI estrito, defaults, derivações das esferas (u64 + overflow), validação de coerência com mensagens, `--config` (estendendo o parsing de flags da VS-07), load antes de `CreateEngine`. — Implementada: parser estrito (seção malformada/linha sem `=` também são fatais), defaults+warning, derivações u64, 9 mensagens de erro próprias.
2. [x] **VS-08-IMPL-02 — Simulação** (REQ-SIM-05; AC-01, AC-04). `tools/sim/render_sim.py` parametrizado por `visible_capacity` (mín/máx/default) + casos das regras de validação; executar antes de qualquer mudança de shader. — Implementada e executada: 2.699 checks verdes. `frontier_test.py` atualizado (raios 8/9/10, slots derivados — ADR-B5 absorvida).
3. [x] **VS-08-IMPL-03 — Contrato shader** (REQ-CFG-06; AC-04). Push constant 92 B (`visible_chunk_capacity`), `common.slang` sem constantes de capacidade, `#assert`/layouts/todas as gravações, revisão no histórico da VS-00; `spirv-val` limpo. — Implementada: `work_queue_base_words()` usa o push constant; `render.slang` sem `WORK_ITEM_CAPACITY`; `spirv-val` limpo nos 3 .spv; VS-00 revisada.
4. [x] **VS-08-IMPL-04 — Provisionamento runtime** (REQ-CFG-05, REQ-CFG-04; AC-02, AC-03). Remover as constantes derivadas; dimensionar todos os buffers/arrays do Config; validação de máquina (budget × 0,9) após o VMA, antes do provisionamento; log da config efetiva. — Implementada: 15 constantes removidas, todos os buffers/arrays dimensionados (inclusive `compute_command_buffers`, `telemetry.compute_pools`, `claimed_batch.tasks`, ring/pool do mirror), validação de máquina + log de capacidades.
5. [x] **VS-08-IMPL-05 — Evidências e fechamento** (AC-01..04). Bateria de INIs inválidos, smoke default (paridade) e custom, docs (arquitetura/manual/tracking, B5 absorvida) e commit com o nome da spec. — Executada: ver ACs.

## Questões abertas

- Nome/caminho do INI (`vox.ini` no cwd; `--config` para override): fixado na spec, ajustável sem mudança de contrato. Não bloqueia a aprovação.
- Fator de folga do mirror (1,5×) e margem de budget (10%): fixados na spec; tuneáveis por constante interna. Não bloqueiam a aprovação.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (seis parâmetros via INI, provisionamento garantido, erros explicativos); ADR-C1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-C1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-08-IMPL-01..05 destravadas.
- 2026-11-06 — **IMPL-01..05 implementadas e validadas** (AC-01..04 verificados; ver tabela). Correção de tabela nesta spec: as contagens de esfera de referência originais (523/3.053/4.189/7.238 para r=5/9/10/12) divergiam da fórmula definida `x²+y²+z² ≤ r²` — os valores corretos são **515/3.071/4.169/7.153** (r=2→33 e r=8→2.109 já estavam certos); todos os números derivados do cenário de sucesso foram recalculados (INI custom: 515 visíveis, 925 slots, 185 páginas; defaults: 773 páginas). O caminho de falha da regra de máquina (REQ-CFG-04) não foi exercitável nesta GPU (budget × 0,9 de 9,5 GiB contra requisito máximo válido de ~750 MiB); implementado e coberto em simulação.
