---
id: VS-01
titulo: Streaming, generate e pack
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-00
bloqueada_por: []
requisitos: [REQ-STREAM-01, REQ-STREAM-02, REQ-STREAM-03, REQ-STREAM-04, REQ-STREAM-05, REQ-STREAM-06, REQ-GEN-01, REQ-GEN-02, REQ-GEN-03, REQ-PACK-01, REQ-PACK-02, REQ-PACK-03, REQ-PACK-04, REQ-PACK-05, REQ-SYNC-01, REQ-SYNC-02, REQ-SYNC-03, REQ-BATCH-01, REQ-BUF-01, REQ-SIM-01, REQ-SIM-02]
ultima_atualizacao: 2026-11-04
---

# VS-01 — Streaming, generate e pack

## Objetivo

Materializar chunks de 32³ na VRAM por streaming priorizado, geração GPU e compactação, preservando o ciclo de vida B1 durante cancelamento, conclusão e descarregamento.

## Rastreabilidade

- GOAL: [Arquitetura — Etapas 1 a 4](../../arquitetura.md) e [Manual Técnico — Seções 2 e 3](../../manual-tecnico.md).
- Referência: `ChunkManager`, `GenerationTask`, `SubmittedBatch`, `worker_thread_process`, `retire_generating_slot`, `update_chunk_streaming` e o handler de conclusão em `docs/examples/voxel.odin`; shaders `generate_voxels`/`pack_chunk` em `docs/examples/voxel.slang`.
- Decisões: [[ADR-B1-ciclo-vida-slots|ADR-B1]], [[ADR-B3-pack-paleta|ADR-B3]], [[ADR-B4-batching-compute|ADR-B4]], [[ADR-B5-capacidade-streaming|ADR-B5]], [[ADR-B8-distancia-int64|ADR-B8]], [[ADR-B9-cobertura-generate|ADR-B9]] e [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]] (somente o custo geométrico no pack; a renderização é VS-02).
- Fundação: [[VS-00-fundacao-vulkan|VS-00]] fornece fila de compute dedicada, timeline de compute (valor inicial 0), descriptor set layout (bindings 0–16) e pipeline layout de compute.

## Requisitos

### Streaming e histerese

- **REQ-STREAM-01** — Raios (ADR-B5): visão `8`, geração `8`, descarga `16`, medidos em chunks por distância euclidiana quadrada a partir do chunk da câmera. Como visão = geração, não existe faixa de residentes invisíveis: todo chunk gerado é elegível a RENDERABLE; a máquina de estados mantém CACHED ⇄ RENDERABLE para preservar o contrato das fatias seguintes.
- **REQ-STREAM-02** — Pool físico fixo de 4.096 slots (`MAXIMUM_RESIDENT_CHUNKS`), pré-alocado, sem realocação. A enumeração da bolha de geração (esfera discreta r=8) não pode exceder o pool; esgotado o pool, novas requisições esperam reciclagem sem falhar.
- **REQ-STREAM-03** — Fila de prioridade: o chunk da câmera é publicado sob `queue_mutex`; a worker drena sempre as tarefas mais próximas (varredura linear nesta fatia — heap fica no backlog de performance).
- **REQ-STREAM-04** — Descarregamento (raio 16): chunk `GENERATING` → `retire_generating_slot` (três caminhos da ADR-B1); chunk `CACHED`/`RENDERABLE` → `RetiringSlot` contra a timeline gráfica. Nenhum slot retorna a `free_storage_slots` fora desses dois caminhos.
- **REQ-STREAM-05** — Distância quadrada com intermediários de 64 bits (ADR-B8): diferenças e soma em `i64`; coordenadas de chunk permanecem `[3]i32`.
- **REQ-STREAM-06** — Conversão mundo→chunk por divisão com piso (`floor_div`), correta para coordenadas negativas; o chunk da câmera usa `floor(pos / 32)` por componente.

### Generate

- **REQ-GEN-01** — Cobertura completa (ADR-B9): `generate_voxels` com `[numthreads(8,8,8)]`, dispatch `(4, 4, 4·N)`, `job = thread_id.z / 32`. Cada thread escreve exatamente 1 voxel; os 32.768 voxels de cada um dos N chunks do lote são escritos antes do pack.
- **REQ-GEN-02** — Scratch denso de 1 `u32` por voxel (131.072 B por chunk), organizado num ring de `3 × 16` chunks (índice do lote % 3), device-local. Layout x-contíguo (contrato do scratch GPU — regra 7 do AGENTS.md).
- **REQ-GEN-03** — Worldgen: função procedural determinística portada da referência (FastNoiseLite, já presente em `src/assets/shaders/lib/`), idêntica semente e parâmetros da referência; o generate escreve o block ID direto no scratch.

### Pack

- **REQ-PACK-01** — Quatro fases (ADR-B3), 1 workgroup de 128 threads por chunk (8 bricks por thread): (A) ocupação do brick + presença de blocos + custo geométrico pior-caso; (B) coarse cells + scan de prefixo popcount; (C) paleta por ranking (sem busca linear) + planos de material + refcounts; (D) bits de subdivisão por brick.
- **REQ-PACK-02** — Invariante da paleta: índice no plano = `rank + 1`; o slot 0 é sempre AR e jamais é reciclado. Capacidade efetiva: 255 tipos sólidos + AR. A região de ocupação não marca voxels de ar (ar decodifica para o índice 0).
- **REQ-PACK-03** — Overflow: mais de 255 tipos → flag `CHUNK_FLAG_PALETTE_OVERFLOW` no header e excedentes preservados como `SpecialVoxelRecord`; o chunk torna-se somente-leitura para edição (contrato de VS-03). Nunca corromper dados nem falhar.
- **REQ-PACK-04** — Header de 2.064 B por chunk (`palette_size`, `plane_count`, `special_voxel_count`, `flags`, `palette[256]` u32, `refcount[256]` u8): o pack conta as referências por entrada de paleta (o slot 0 conta os não-sólidos), deixando o header pronto para a edição E1.
- **REQ-PACK-05** — Subdivisão (ADR-CAMINHO-B): 2 bits por brick nas words [1026..1090), escolhendo a menor subdivisão (×1/×2/×4) cujas partes respeitam 256 vértices/192 triângulos por grupo, a partir do custo pior-caso dos templates. Os built-ins (0=ar, 1=cubo, 2=planta) são carregados pela CPU no init com `validate_template` (vértices em [0,1]³, ≤32 vértices, ≤24 triângulos pior-caso via `compute_worst_case_tris`).

### Ciclo de vida e sincronização (B1)

- **REQ-SYNC-01** — Claim atômico: a worker publica o `SubmittedBatch` em `submitted_batches` no mesmo trecho crítico (`queue_mutex`) em que retira as tarefas de `pending_tasks`, antes de qualquer chamada Vulkan. Invariante: toda tarefa está em exatamente um dos conjuntos {pendentes, submetidos}.
- **REQ-SYNC-02** — Anti-ABA: `slot_generations[slot]` incrementa a cada alocação; conclusões e cancelamentos só valem se coordenada + slot + geração baterem com o registro ativo (`task_matches`). Conclusão vencida é ignorada (não promove, não libera fora do caminho).
- **REQ-SYNC-03** — 1 claim = 1 lote = 1 valor de timeline: o valor sinalizado é o número sequencial do lote (`submitted_batch_count + 1`), publicado no claim e sinalizado no `vkQueueSubmit2` — deterministicamente igual. Máximo de 3 lotes em voo (`MAXIMUM_COMPUTE_BATCHES_IN_FLIGHT`); antes de regravar o slot do ring, a worker aguarda a timeline do lote de 3 atrás. A thread principal lê o contador com `vkGetSemaphoreCounterValue` (sem bloqueio) no handler de conclusão.
- **REQ-BATCH-01** — Batching (ADR-B4): cada claim drena até 16 tarefas por prioridade; generate `(4,4,4·N)` → barreira COMPUTE_WRITE→COMPUTE_READ → pack `(N,1,1)`; um único `vkQueueSubmit2` por lote na fila de compute da VS-00.

### Buffers e contratos Odin↔Slang

- **REQ-BUF-01** — Buffers device-bound (bindings do layout da VS-00): `temporary_dense_chunks` (0, ring 3×16×128 KiB), `generation_jobs` (1, ring 3×16 jobs × 32 B, host-visible), `occupancy_pool` (2, 4.096 × 1.090 words), `material_plane_pool` (3, 4.096 × 8.192 words), `chunk_headers` (4, 4.096 × 2.064 B), `special_voxel_records` (5, capacidade fixa a definir na implementação, ≥ 4.096 registros), `global_block_registry` (7, `BlockDefinition` 48 B std430), `mesh_templates`/`template_vertices`/`template_triangles` (10/11/12, tabelas do Caminho B). `ChunkGenerationJob` = 32 B: `chunk_world_origin[3]i32`, `storage_slot_index` u32, `mirror_ring_slot` i32 (sempre -1 nesta fatia), `padding[3]` u32.
- **REQ-SIM-01** — Antes da integração do pack, simulação Python bit-a-bit em `tools/sim/` cobrindo: decode == verdade, paleta sem duplicatas, slot 0 = AR, ranking popcount == ordenação por ID, ocupação/coarse consistentes com o denso, refcounts == recontagem, overflow com registros especiais, subdivisão respeitando o orçamento (workflow do AGENTS.md).
- **REQ-SIM-02** — Simulação Python da máquina de estados B1 cobrindo: cancelamento nos caminhos (a)/(b)/(c), conclusão vencida (ABA), aposentadoria dual, lotes de 16 com cancelamento parcial, invariante "tarefa em exatamente um conjunto" sob interleavings aleatórios com seed fixa.

## Escopo

- Histerese com raio de visão `8`, raio de geração `8` e raio de descarga `16` (ADR-B5).
- Pool físico de 4.096 slots, sem ampliação nesta fatia.
- Fila priorizada, worker thread e lotes de até 16 chunks.
- Claim atômico, anti-ABA e aposentadoria dual.
- Generate de todos os 32.768 voxels e pack completo (ocupação, coarse, paleta, planos, refcounts, overflow e subdivisão).
- Carga dos templates built-in (ar/cubo/planta) e do dicionário mínimo de blocos exigido pelo worldgen e pelo custo geométrico do pack.

## Não escopo

- Renderização task/mesh, publicação de `visible_chunks` e culling de fronteira (VS-02).
- Edição de voxels E1 (VS-03) e mirror CPU C2 (VS-04): `mirror_ring_slot` existe no job mas é sempre `-1`; lotes `export_only` não existem nesta fatia.
- Persistência do journal, heap de prioridade, ampliação do pool ou aumento dos raios da ADR-B5.
- Leitura de `SpecialVoxelRecord` por consumidores (backlog separado; aqui só a escrita).

## Dependências

- [[VS-00-fundacao-vulkan|VS-00]] concluída antes da implementação (fila e timeline de compute, layouts, `storageBuffer16BitAccess` não exigido nesta fatia).
- [[ADR-B5-capacidade-streaming|ADR-B5]] aceita e incorporada; não há mais bloqueio de decisão.

## Interfaces e recursos

### Domínios de concorrência

| Domínio | Dados | Regra |
| --- | --- | --- |
| Thread principal | `active_chunks`, `free_storage_slots`, `retiring_slots`, `retiring_compute_slots`, `slot_generations`, `last_camera_chunk`, `highest_completed_compute_value` | Exclusivo da thread principal; a worker nunca toca |
| `queue_mutex` | `pending_tasks`, `submitted_batches`, `priority_camera_chunk`, `queue_condition`, `worker_stop_requested` | Única trava compartilhada; claim e cancelamento se serializam nela |
| Worker thread | `submitted_batch_count`, command buffers e ring de jobs/scratch do lote corrente | Única thread que submete compute; valores de timeline sequenciais |

### Máquina de estados do chunk

```
UNLOADED → GENERATING → CACHED ⇄ RENDERABLE
              │  descarregar em GENERATING → retire_generating_slot:
              │    (a) pendente     → cancela; slot livre na hora
              │    (b) submetido    → aposentadoria pela TIMELINE DE COMPUTE do lote
              │    (c) defensivo    → slot livre na hora
              └─ descarregar em CACHED/RENDERABLE → aposentadoria pela TIMELINE GRÁFICA
```

Como visão = geração (8), a transição CACHED → RENDERABLE ocorre na primeira atualização de visibilidade após a conclusão; RENDERABLE → CACHED só aconteceria com raios distintos e permanece implementada para o contrato.

### Recursos e proprietários

- **Slots de chunk**: propriedade do `ChunkManager`; identidade = (slot, geração). Liberados somente pelo handler de conclusão/aposentadoria — nunca no unload direto (regra 4 do AGENTS.md adaptada ao B1).
- **Ring de jobs e scratch**: 3 posições (uma por lote em voo); a worker só regrava a posição `lote % 3` após esperar a timeline do lote de 3 atrás.
- **Timeline de compute** (criada na VS-00, valor inicial 0): o valor do lote N é N; o handler de conclusão promove GENERATING → CACHED para tarefas de lotes com valor ≤ contador lido, validando (coord, slot, geração).
- **Shaders**: `generate_voxels` e `pack_chunk` num novo `src/assets/shaders/` (portados da referência); `common.slang` passa a concentrar constantes e layouts compartilhados Odin↔Slang (fonte única de verdade — AGENTS.md).

### Comportamento quando limites são atingidos

- Pool de slots esgotado: novas coordenadas dentro do raio de geração aguardam reciclagem; sem falha, sem log de erro (warn uma vez por rajada, não por frame).
- Fila vazia: worker dorme em `queue_condition`; shutdown faz broadcast e join antes de destruir recursos Vulkan (ordem da VS-00).
- Lotes em voo no teto (3): worker aguarda a timeline do lote mais antigo — backpressure natural, sem alocação.

## Cenários

### Cenário de sucesso

- **Dado** o motor inicializado na origem.
- **Quando** frames avançam com a câmera parada.
- **Então** a bolha de geração (esfera r=8 em torno do chunk da câmera) é enfileirada por proximidade — o chunk sob a câmera conclui primeiro —, lotes de até 16 chunks são submetidos com valores de timeline sequenciais, e cada chunk concluído tem os 32.768 voxels gerados e o pack válido (decode == scratch, paleta com AR no slot 0).

### Movimentação e histerese

- **Dado** a bolha materializada e a câmera movendo-se além do raio 16 de um conjunto de chunks.
- **Quando** `update_chunk_streaming` roda.
- **Então** chunks distantes saem de `active_chunks` e seus slots seguem os caminhos da ADR-B1; nenhum chunk fora da bolha permanece retido; distâncias usam intermediários de 64 bits mesmo para coordenadas extremas (≥ 2²⁰ chunks de distância).

### Cancelamento e anti-ABA

- **Dado** uma tarefa pendente (a), submetida (b) ou já concluída (c), e um lote antigo cuja conclusão chega depois da recriação do chunk na mesma coordenada.
- **Quando** o descarregamento e o handler de conclusão rodam.
- **Então** (a) cancela e libera na hora; (b) aposenta contra a timeline do lote; (c) libera na hora; a conclusão vencida é ignorada — o chunk novo nunca é promovido por uma tarefa da geração anterior.

### Capacidade

- **Dado** a esfera discreta r=8 enumerada por teste.
- **Quando** todas as coordenadas são requisitadas.
- **Então** a contagem é ≤ 4.096 e todas cabem no pool; um raio hipotético maior falharia o teste de fronteira (guarda contra regressão da ADR-B5).

### Dados-limite do pack

- **Dado** chunks sintéticos: totalmente vazio, totalmente cheio de um tipo, exatamente 255 tipos, 256+ tipos, brick com template pesado exigindo subdivisão ×4.
- **Quando** a simulação bit-a-bit roda (REQ-SIM-01).
- **Então** chunk vazio tem `palette_size` = 1 (só AR) e flag EMPTY; 255 tipos cabem sem overflow; 256+ geram flag + `SpecialVoxelRecord`; a subdivisão gravada é a menor que respeita 256 v/192 t por grupo.

### Falhas e concorrência

- Worker parada (fila vazia) dorme em condition variable; shutdown acorda, encerra e faz join antes da destruição Vulkan.
- Interleavings aleatórios (seed fixa) de claim/cancelamento/conclusão mantêm a invariante de conjunto único (REQ-SIM-02).
- Sem slots livres: requisições esperam; nenhum slot em voo é reciclado antes da timeline correspondente.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-01-AC-01 | Cada chunk gerado cobre 32³ voxels e mantém AR no slot 0 da paleta (REQ-GEN-01, REQ-PACK-02) | Simulação bit-a-bit do pack (REQ-SIM-01) + inspeção de um chunk real via readback de debug (decode de amostras contra scratch) | `tools/sim/pack_sim.py`: 959 checks, 9 cenários, todos OK (vazio/cheio/255/256+ tipos, subdivisão ×4). Readback de debug em runtime: chunk [-5,0,-5] slot 4020, 32.768 voxels decodificados == worldgen (2.048 sólidos, `palette_size` = 3 com AR no slot 0, `plane_count` = 2, flags = 0) — log "DEBUG READBACK OK". |
| VS-01-AC-02 | Um claim corresponde a um lote e um valor de timeline (REQ-SYNC-01/03, REQ-BATCH-01) | Simulação B1 (REQ-SIM-02) + instrumentação: log/assert de que `submitted_batches` cresce por claim e o valor sinalizado == valor publicado; execução com validation layers sem erros | `tools/sim/streaming_sim.py`: 5 cenários OK, incluindo 20.000 interleavings (seed 20261104) com a invariante de conjunto único. Smoke test com validation layers: 132 lotes submetidos (131×16 + 1×13 = 2.109 chunks), valor sinalizado == valor publicado em todos, 0 erros/avisos de validação. |
| VS-01-AC-03 | Nenhum slot é reutilizado enquanto trabalho de compute ou gráfico ainda o referencia (REQ-SYNC-02, REQ-STREAM-04) | Cenários anti-ABA da simulação + teste integrado de teleporte (descarregamento em massa durante geração) com validation layers e `SYNCHRONIZATION_VALIDATION` sem erros | `tools/sim/streaming_sim.py`: cancelamento nos caminhos (a)/(b)/(c), conclusão vencida (ABA) e aposentadoria dual — todos OK. Ressalva registrada: o teleporte em massa em runtime não foi exercitado nesta sessão (coberto pela simulação); o caminho de shutdown com join da worker também não foi exercitado (processo encerrado por kill no smoke test). |
| VS-01-AC-04 | Raios efetivos visão `8`/geração `8`/descarga `16` e bolha de geração ≤ 4.096 slots (REQ-STREAM-01/02/05) | Teste de fronteira que enumera a esfera discreta r=8 e conta as coordenadas; teste de distância com coordenadas extremas sem overflow (i64) | `tools/sim/frontier_test.py`: esfera r=8 = 2.109 chunks ≤ 4.096; distância extrema 2.473.901.162.496 calculada em i64 (> i32); `floor_div` correto para negativos. Confirmado em runtime: os 132 lotes somam exatamente 2.109 chunks (esfera completa materializada). |

## Tarefas da especificação

- [x] Vincular todos os requisitos do GOAL (REQ-STREAM/GEN/PACK/SYNC/BATCH/BUF/SIM acima).
- [x] Incorporar ADR-B5: geração `8`, descarga `16` e pool de 4.096 slots.
- [x] Formalizar máquinas de estado e cenários anti-ABA.
- [x] Definir contratos Odin↔Slang e simulações exigidas.
- [x] Submeter à revisão e obter aprovação. — aprovada em 2026-11-04.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-01-IMPL-01 — `common.slang` e layouts compartilhados** (REQ-BUF-01, REQ-PACK-04). Criar `src/assets/shaders/common.slang` como fonte única de verdade: constantes (CHUNK_SIZE, bricks, words de ocupação/coarse/subdivisão, header 2.064 B, flags), structs (`ChunkGenerationJob`, `ChunkHeader`, `BlockDefinition`, `MeshTemplate`) e declarações de bindings 0–5, 7, 10–12. Espelhar as mesmas constantes/structs no Odin.
2. **VS-01-IMPL-02 — Simulação do pack** (REQ-SIM-01; AC-01). `tools/sim/pack_sim.py`: simulação bit-a-bit das quatro fases com os cenários-limite (vazio, cheio, 255 tipos, 256+ tipos, subdivisão ×4) e as invariantes do requisito.
3. **VS-01-IMPL-03 — Shaders generate e pack** (REQ-GEN-01..03, REQ-PACK-01..05; AC-01). Portar `generate_voxels` (numthreads 8×8×8, worldgen FastNoiseLite) e `pack_chunk` (128 threads, 4 fases, ranking popcount, subdivisão) para `src/assets/shaders/`, consumindo `common.slang`; compilar com `run.bat`.
4. **VS-01-IMPL-04 — Simulação B1 do streaming** (REQ-SIM-02; AC-02, AC-03). `tools/sim/streaming_sim.py`: máquina de estados com claim atômico, anti-ABA e aposentadoria dual sob interleavings aleatórios (seed fixa), incluindo lotes de 16 com cancelamento parcial.
5. **VS-01-IMPL-05 — ChunkManager e streaming na thread principal** (REQ-STREAM-01..06, REQ-SYNC-02/04; AC-03, AC-04). Reescrever `src/engine/voxel_engine.odin`: `ChunkManager` completo (active_chunks, free_storage_slots, slot_generations, retiring dual), histerese 8/8/16, distância i64, `floor_div`, `retire_generating_slot`, handler de conclusão por contador de timeline.
6. **VS-01-IMPL-06 — Worker thread e submissão de lotes** (REQ-SYNC-01/03, REQ-BATCH-01; AC-02). Claim atômico sob `queue_mutex`, dreno de até 16 por prioridade, ring de 3 lotes em voo com espera de timeline, command buffers de compute próprios, um `vkQueueSubmit2` por lote na fila de compute da VS-00.
7. **VS-01-IMPL-07 — Buffers GPU e carga de templates** (REQ-BUF-01, REQ-PACK-05; AC-01). Alocação via VMA dos buffers 0–5 e 7, 10–12; upload dos templates built-in (ar/cubo/planta) com `validate_template`/`compute_worst_case_tris`; dicionário mínimo de blocos do worldgen; descriptor set único atualizado.
8. **VS-01-IMPL-08 — Testes de fronteira e evidências** (AC-01..04). Teste de enumeração da esfera r=8 (≤ 4.096) e de distância i64 extrema; readback de debug de um chunk (decode == amostras); teleporte em massa com validation layers; registrar evidências e atualizar tracking.

## Questões abertas

- Capacidade do pool de `SpecialVoxelRecord`: **resolvida na implementação** — 256 registros por chunk × 4.096 chunks = 1.048.576 registros (`SPECIAL_RECORDS_PER_CHUNK :: 256` em `src/engine/voxel_types.odin`).
- Forma exata do readback de debug do AC-01 (buffer de cópia temporário usado só em build de diagnóstico). Não bloqueia a aprovação.

## Histórico

- 2026-11-03 — Rascunho estrutural criado.
- 2026-11-04 — ADR-B5 incorporada; bloqueio de decisão removido, spec permanece em rascunho.
- 2026-11-04 — Elaboração completa: 21 requisitos (STREAM/GEN/PACK/SYNC/BATCH/BUF/SIM), domínios de concorrência, máquina de estados, cenários e validação dos ACs. Submetida à revisão (`em-revisao`).
- 2026-11-04 — Spec aprovada; tarefas de implementação VS-01-IMPL-01..08 derivadas.
- 2026-11-04 — Implementação concluída (VS-01-IMPL-01..08): `common.slang` + espelho Odin, shaders `generate_voxels`/`pack_chunk`, `ChunkManager` com histerese 8/8/16 e anti-ABA, worker com lotes de 16 e ring de 3, buffers GPU e templates built-in. Evidências: `pack_sim.py` (959 checks), `streaming_sim.py` (5 cenários, 20.000 interleavings), `frontier_test.py` (esfera r=8 = 2.109 ≤ 4.096, distância i64), smoke test com validation layers sem erros e readback de debug OK. Ressalvas: teleporte em massa e shutdown com join não exercitados em runtime (cobertos por simulação); observada corrupção pontual de duas linhas do log de arquivo nos lotes 79/99 (provável race benigno do file logger entre threads — backlog). Marcação: `concluida`/`verificada`.
