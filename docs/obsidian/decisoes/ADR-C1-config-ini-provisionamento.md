---
id: ADR-C1
titulo: Configuração runtime via INI com provisionamento derivado
tipo: decisao
status: aceita
specs_afetadas: [VS-08]
ultima_atualizacao: 2026-11-06
---

# ADR-C1 — Configuração runtime via INI com provisionamento derivado

## Contexto

Os parâmetros de streaming e compute (`RADIUS_VISION/GENERATION/UNLOAD/SIMULATION`, `MAXIMUM_CHUNKS_PER_BATCH`, `MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT`) são constantes de compilação que dimensionam buffers GPU, rings, pools e arrays — inclusive um usado **pelo shader** (`MAXIMUM_VISIBLE_CHUNKS` no cálculo do ring da fila de trabalho em `common.slang`). O mantenedor quer que venham de um arquivo `.ini`, que a engine provisione os recursos para os valores pedidos (respeitando a máquina) e que valores incoerentes/insuportáveis produzam erro explicativo.

Decisões necessárias: (1) fonte e formato da configuração; (2) como as capacidades derivadas são calculadas e validadas; (3) como o shader passa a conhecer a capacidade de visíveis sem constante de compilação.

## Requisitos relacionados

- REQ-CFG-01..07 e REQ-SIM-05 da [[VS-08-config-ini-provisionamento|VS-08]].

## Opções

### Opção A — INI flat + capacidades derivadas das esferas + validação contra limites reais

- Arquivo `vox.ini` (flat, seções `[streaming]`/`[compute]`, `--config <caminho>` para override; ausente → defaults embutidos + warning). Parse estrito: chave desconhecida → warning; valor malformado → erro fatal com motivo, antes de criar a janela.
- Capacidades **derivadas**, nunca configuradas diretamente: `visible_capacity = |esfera(vision)|` (2109 em r=8), `resident_slots = ⌈|esfera(unload)| × 1,05⌉` (resolve o backlog B5 por construção; emenda 2026-11-06 — era `|esfera(generation)|`, que esgotava o pool estruturalmente), `scratch_chunks = batches_in_flight × chunks_per_batch`, `mirror_pages = |esfera(simulation)| × 1,5`, `mirror_ring = max(64, próxima potência ≥ scratch_chunks)`.
- Limites: coerência (`vision ≤ generation < unload`, mínimos/máximos práticos) + limites de formato (`visible_index` tem **12 bits** no item da fila → visíveis ≤ 4096 → vision ≤ 9) + limites de máquina (bytes device requeridos vs budget da heap device-local via `GetHeapBudgets` da VS-05, margem de 10%).
- Shader: push constant ganha `visible_chunk_capacity` (88 → 92 B); `work_queue_base_words()` passa a usar o push constant. Contrato VS-00 revisado (como já o foi na VS-02).
- Vantagens: cumpre o pedido sem surpresas de provisionamento (tamanho exato das esferas, sem over-allocation), validação honesta contra o hardware real, capacidade de visíveis dinâmica sem recompilar shader.
- Desvantagens: toca no contrato de push constants (todas as gravações) e em ~10 sites de provisionamento; vision fica limitado a 9 sem alargar o empacotamento do item de trabalho.

### Opção B — Flags de linha de comando / variáveis de ambiente

- Cada parâmetro vira `--vision 8` etc. Sem arquivo, sem persistência, sem comentários.
- Vantagens: zero parse de arquivo; fácil em pipelines.
- Desvantagens: polui cada lançamento; não escala com novos parâmetros; o pedido do mantenedor é explicitamente um arquivo `.ini`.

### Opção C — Perfis pré-compilados (enum pequeno/médio/grande)

- Mantém constantes de compilação e escolhe um perfil em runtime.
- Vantagens: provisioning trivial (três conjuntos conhecidos).
- Desvantagens: não dá os valores livres pedidos; três perfis ainda precisam das três variantes de cada buffer testadas — falsa economia.

## Decisão

**Opção A** — INI flat com defaults, capacidades derivadas das esferas, validação de coerência + limites de formato (12 bits do `visible_index`) e de máquina (memory budget da VS-05), push constant estendido para 92 B. Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-08.

## Consequências

- `MAXIMUM_VISIBLE_CHUNKS`, `MAXIMUM_RESIDENT_CHUNKS`, `MIRROR_PAGE_POOL_SIZE`, `MIRROR_RING_SLOTS`, `SCRATCH_CHUNK_COUNT` deixam de existir como constantes de compilação e viram campos de um `Config` carregado antes de `CreateEngine` — nenhum tamanho de buffer pode permanecer ligado a elas.
- O limite vision ≤ 9 (12 bits do `visible_index`) é documentado no erro; alargar o empacotamento para 16 bits (sobram bits no item de 32) fica como backlog explícito. **RESOLVIDO em 2026-11-06 pela [[ADR-B12-visible-index-16-bits|ADR-B12]]/[[VS-09-visible-index-16-bits|VS-09]]**: `visible_index` de 16 bits, cap de formato `vision ≤ 25`.
- O backlog B5 (raio de geração > slots) é absorvido: slots derivados da esfera de unload × 1,05 por construção (emenda 2026-11-06, era `|esfera(generation)|`).
- A VS-05 passa a ser dependência de implementação (memory budget na validação), ainda que sua própria validação esteja em andamento (o uso é de API já integrada, não do AC pendente dela).

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-08 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-08.
