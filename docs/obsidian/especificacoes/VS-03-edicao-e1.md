---
id: VS-03
titulo: Edição E1
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-02
bloqueada_por: []
requisitos: [REQ-EDIT-01, REQ-EDIT-02, REQ-EDIT-03, REQ-EDIT-04, REQ-EDIT-05, REQ-EDIT-06, REQ-EDIT-07, REQ-EDIT-08, REQ-EDIT-09, REQ-EDIT-10, REQ-SIM-04]
ultima_atualizacao: 2026-11-05
---

# VS-03 — Edição E1

## Objetivo

Aplicar edições de voxels por journal bufferizado (dedup última-escrita-vence, flush em lote), mantendo paleta, refcounts, ocupação, coarse cells, flag EMPTY e subdivisão consistentes, refletindo o flush na geometria do mesmo frame — sem dirty flag nem re-mesh assíncrono, porque a malha é reconstruída on-the-fly a cada frame.

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 6 (E1)](../../arquitetura.md) e [Manual Técnico — E1](../../manual-tecnico.md).
- Referência: `EditManager`, `request_voxel_edit`, `flush_voxel_edits`, `edit_ring_write` em `docs/examples/voxel.odin`; `apply_voxel_edits` e helpers `edit_hash_*`/`edit_resolve_slot` em `docs/examples/voxel.slang`.
- Decisões: [[ADR-B3-pack-paleta|ADR-B3]], [[ADR-E1-edicao-bufferizada|ADR-E1]], [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]] e [[ADR-B10-fila-trabalho-global|ADR-B10]] (a barreira do flush é COMPUTE → COMPUTE(builder) | MESH — não existe estágio task).
- Fundação: [[VS-02-task-mesh-templates|VS-02]] fornece o render por fila de trabalho global, o `ChunkHeader` com refcounts (256 × u32, slot 0 = AR), o pool de planos e a subdivisão por brick; bindings 13/14/15 hoje ocupados por dummies; push constants de 88 B já incluem `edit_job_offset`.

## Requisitos

### Journal CPU e flush

- **REQ-EDIT-01** — API única `request_voxel_edit(world_voxel, block_id)` na thread principal (qualquer origem: input, IA, física, script). `block_id` fora do domínio de 16 bits (> 65535) é descartado na entrada. A fila ativa tem dedup última-escrita-vence por voxel de mundo (mapa voxel → índice da fila), garantindo **no máximo 1 edição por voxel por flush** — a invariante que torna os refcounts exatos (cada voxel decrementa exatamente o tipo que tinha).
- **REQ-EDIT-02** — Pedidos cujo chunk está `GENERATING` ou ausente vão para `pending[chunk]` (com o mesmo dedup por voxel dentro da lista) e são reintegrados à fila ativa no início do primeiro flush em que o chunk estiver pronto (`CACHED`/`RENDERABLE`). Pendências de chunks nunca recarregados permanecem em memória (capar por TTL/quantidade fica no backlog, junto ao save).
- **REQ-EDIT-03** — Flush temporal: `EDIT_FLUSH_INTERVAL_MS = 100 ms` (0 = todo frame) mais flag de flush forçado para ações de latência mínima. O flush agrupa por `storage_slot_index` com edições contíguas (1 `EditChunkJob` por chunk = 1 workgroup) e obedece aos tetos: `MAX_EDITS_PER_FLUSH = 4.096`, `MAX_EDIT_JOBS_PER_FLUSH = 256`, `MAX_EDITS_PER_CHUNK_PER_FLUSH = 1.024` — o excedente permanece na fila para o próximo ciclo (backpressure natural, contabilizado em `stats_deferred`). Somente chunks `CACHED`/`RENDERABLE` entram no lote (preserva o B1: a GPU jamais disputa slot com a fila de geração).
- **REQ-EDIT-04** — Rings host-visible de 2 slots de frame (mesmo padrão do `visible_chunks`): `edit_jobs` 2 × 256 × 16 B (binding 13), `voxel_edits` 2 × 4.096 × 4 B (binding 14), `edit_results` 2 × 4.096 × 4 B (binding 15). O staging é montado antes da espera de frames em voo e copiado ao ring **depois** dela (`edit_ring_write`), quando o slot está livre; `edit_job_offset = frame_atual × MAX_EDIT_JOBS_PER_FLUSH` e os `first_edit` são rebatidos para índices globais do ring na cópia.

### Compute de edição (apply_voxel_edits)

- **REQ-EDIT-05** — Compute `[numthreads(128,1,1)]`, um workgroup por job, executado **no command buffer do frame, antes do builder da fila de trabalho**, com barreira COMPUTE(write) → COMPUTE(read) entre o dispatch de edição e o `build_work_queue`; a barreira existente COMPUTE → MESH | DRAW_INDIRECT torna as escritas visíveis ao mesh shader do mesmo frame (a geometria já nasce editada; B2 se ajusta sozinho porque o vizinho lê a ocupação ao vivo).
- **REQ-EDIT-06** — Fases do shader (espelhadas da referência): Fase 0 cacheia o header em groupshared (paleta, refcounts normalizados — slots além da paleta = 0 —, plane_count, flags) e semente do hash `block_id → slot` com as entradas vivas (slot 0 = AR sempre entra, mesmo com refcount 0); Fase 1 resolve o slot de cada `new_block` (no-op se `old == new`; alocação por CAS com tombstones, claims de refcount e reciclagem preguiçosa — `EDIT_HASH_CAPACITY = 512`, load factor ≤ 0,5, hash reconstruído a cada dispatch); Fase 1.5 cresce planos zerando as words novas quando `palette_size` exige; Fase 2 aplica planos por RMW atômico bit a bit, ocupação (sólido = bloco ≠ 0), refcounts (incremento só se não contado na Fase 1; decremento sempre) e grava o resultado por edição; Fase 2.5 recompõe coarse cells, flag EMPTY, refcounts e escalares do header; Fase 3 recalcula a subdivisão (Caminho B) dos bricks sujos lendo os planos atualizados.
- **REQ-EDIT-07** — Invariantes da paleta dinâmica (ADR-B3 preservada): o slot 0 (AR) **nunca** é reciclado; slot com refcount 0 é candidato à reciclagem (evicção preguiçosa com tombstone do id antigo no hash); `palette_size` cresce por `InterlockedMax`, nunca encolhe dentro do flush; o claim usa sentinela `EDIT_REFCLAIMED` fora do domínio de refcounts válidos.
- **REQ-EDIT-08** — Chunks com `CHUNK_FLAG_PALETTE_OVERFLOW` são somente-leitura (regra 6): o workgroup rejeita todas as edições do job com `EDIT_RESULT_REJECTED_OVERFLOW` sem tocar nos dados. Palesta cheia (sem slot livre para bloco novo) rejeita a edição individual com `EDIT_RESULT_REJECTED_PALETTE_FULL`. Demais códigos: `EDIT_RESULT_APPLIED = 0`, `EDIT_RESULT_NOOP = 1`.

### Feedback e contrato com VS-04

- **REQ-EDIT-09** — `edit_ring_write` colhe o feedback do uso anterior do slot do ring (2 frames atrás, protegido pela espera de frames em voo) acumulando estatísticas (`applied`, `noop`, `rejected`, `deferred`) expostas no log de diagnóstico. O layout do ring de resultados e os códigos são o contrato de reconciliação que a VS-04 consumirá (o mirror aplicará otimisticamente e reverterá por replay do journal nas rejeições) — nesta fatia o feedback é estatístico/observacional, sem consumidor de gameplay.
- **REQ-SIM-04** — Antes da integração do shader de edição, simulação Python em `tools/sim/edit_sim.py` cobrindo: alocação/reciclagem de slots com refcounts exatos, AR nunca reciclado, tombstones e ressurreição de slot no mesmo flush, crescimento de planos, atualização de ocupação/coarse/EMPTY/subdivisão contra uma verdade densa, no-op, chunk em overflow somente-leitura, dedup última-escrita-vence e reintegração de pendências na ordenação especificada.

## Escopo

- API de edição, dedup última-escrita-vence e pendências por chunk com reintegração.
- Flush temporal ou forçado, agrupamento por chunk e tetos de segurança com backpressure.
- Rings de jobs, edições e resultados por frames em voo (bindings 13/14/15 reais, substituindo os dummies).
- Compute de edição com paleta dinâmica, refcounts, tombstones, planos, ocupação, coarse, EMPTY e subdivisão.
- Feedback aplicado/no-op/rejeitado lido 2 frames depois (estatísticas) e barreira COMPUTE → COMPUTE(builder) | MESH.
- Gancho de depuração para evidência visual: edições roteirizadas (esculpir uma caixa de ar e depositar uma caixa de pedra à frente da câmera) em tick fixo, com screenshot antes/depois e leitura das estatísticas.

## Não escopo

- Persistência do journal em disco (save) e TTL de pendências.
- Mirror CPU (VS-04), exceto pelo contrato de feedback documentado (códigos + layout do ring).
- Replay/reconciliação de rejeições no consumidor (é VS-04); aqui as rejeições são apenas contabilizadas.
- Edição concorrente fora da thread principal (se gameplay ganhar threads, proteger fila+lookup — nota da referência).
- Capacidade acima de 255 tipos por chunk (chunk em overflow permanece somente-leitura, caso patológico do B3).

## Dependências

- [[VS-02-task-mesh-templates|VS-02]] concluída e verificada (render por fila de trabalho, headers com refcounts, planos, subdivisão; bindings 13–15 dummy prontos para substituição).
- [[ADR-E1-edicao-bufferizada|ADR-E1]] e [[ADR-B10-fila-trabalho-global|ADR-B10]] aceitas; não há bloqueio de decisão.

## Interfaces e recursos

### Contratos novos (common.slang, espelhados no Odin)

| Contrato | Layout | Observação |
| --- | --- | --- |
| `EditChunkJob` | 16 B: `storage_slot_index` u32, `first_edit` u32, `edit_count` u32, `padding` u32 | Binding 13; indexado por `edit_job_offset + group_id.x`; `first_edit` é índice **global** no ring de edições |
| Edição packed | u32: `voxel_index (15 bits) \| block_id<<16` (bit 15 reservado) | Binding 14; `voxel_index` no layout denso x-contíguo (`x \| z<<5 \| y<<10`) |
| Resultado | u32 por edição, mesma posição do ring | Binding 15 (RW); códigos 0..3; lido pela CPU 2 frames depois |
| Constantes | `EDIT_FLUSH_INTERVAL_MS = 100`, `MAX_EDITS_PER_FLUSH = 4.096`, `MAX_EDIT_JOBS_PER_FLUSH = 256`, `MAX_EDITS_PER_CHUNK_PER_FLUSH = 1.024`, `EDIT_HASH_CAPACITY = 512`, sentinelas (`EDIT_HASH_EMPTY/TOMBSTONE`, `EDIT_REFCLAIMED`, `EDIT_SLOT_NOOP/REJECTED`, `EDIT_COUNTED_FLAG`), códigos `EDIT_RESULT_*` | Compartilhadas Odin↔Slang (as de shader no common.slang; as de fluxo só no Odin) |
| Helper | `read_palette_index_at(slot, plane_count, coord)` | Decode do índice de paleta sem resolver a paleta (usado nas fases 1 e 3) |

### Recursos e proprietários

- **Fila ativa + pendências + staging** (`EditManager` na `VoxelEngine`, novo módulo `voxel_edit.odin`): domínio exclusivo da thread principal; staging montado no flush e copiado ao ring após a espera de frames em voo.
- **`edit_jobs` / `voxel_edits`** (bindings 13/14): host-visible, escritos pela CPU em `edit_ring_write`; lidos pelo compute de edição no mesmo frame.
- **`edit_results`** (binding 15): host-visible + coerente (readback sem invalidate), escrito pelo shader; lido pela CPU no `edit_ring_write` do slot seguinte (2 frames depois).
- **Pipeline de edição**: compute criada no init do motor de voxels (entry `apply_voxel_edits` do `voxel.spv`), layout `computePipelineLayout` da VS-00.

### Sequência do frame (integração)

```
ve_update (streaming + conclusões)            [thread principal]
se flush devido: flush_voxel_edits()          [staging: drena pendências, agrupa, tetos]
aguardar frame em voo / adquirir imagem
publicar visible_chunks do frame
edit_ring_write(frame): colhe feedback do slot (2 frames atrás)
                        e copia staging → ring deste frame
command buffer do frame:                      [se job_count > 0]
  push constants (edit_job_offset) + dispatch apply_voxel_edits(job_count)
  barreira COMPUTE(write) → COMPUTE(read)
  fill do estado do work_queue → barreiras → build_work_queue → finalize
  barreira COMPUTE → MESH | DRAW_INDIRECT
  CmdBeginRendering → draw indireto → CmdEndRendering
submit gráfico (esperas da VS-02 inalteradas)
```

### Comportamento quando limites são atingidos

- Fila vazia e sem pendências: nenhum flush é montado; frame não despacha edição.
- Excedente dos tetos: permanece na fila (`kept`) com lookup reconstruído; `stats_deferred` cresce; o próximo ciclo drena.
- Chunk sai do raio e volta: pendências reintegram no flush seguinte à conclusão; edições aplicadas sobre o chunk recém-gerado (a geração recomeça o terreno do zero — a edição cai DEPOIS do pack).
- Palesta cheia / chunk em overflow: rejeição explícita com código próprio; dados intocados (somente-leitura).
- `job_count = 0` com flush montado: ring é atualizado (feedback colhido) e nenhum dispatch é gravado.

## Cenários

### Inserção, remoção e no-op

- **Dado** um chunk `RENDERABLE` com grama/terra/pedra.
- **Quando** um flush traz: remover um voxel de grama (→ AR), inserir pedra em voxel de ar e reescrever um voxel com o mesmo bloco.
- **Então** a remoção limpa o bit nos planos/ocupação e decrementa o refcount da grama; a inserção reutiliza ou aloca slot e marca a ocupação; o no-op não toca em nada e reporta `EDIT_RESULT_NOOP`; a malha do mesmo frame reflete as mudanças.

### Edições repetidas no mesmo voxel e limites de flush

- **Dado** vários pedidos para o mesmo voxel entre dois flushes (blocos distintos).
- **Quando** o flush é montado.
- **Então** somente a última escrita é staged (dedup), os refcounts ficam exatos (1 decremento do tipo antigo, 1 incremento do final) e o excedente dos tetos permanece na fila, drenado nos ciclos seguintes na ordem original.

### Chunk em geração e posterior reintegração

- **Dado** um pedido cujo chunk está `GENERATING` (ou fora do raio).
- **Quando** flushes acontecem antes e depois da conclusão do chunk.
- **Então** o pedido espera em `pending`, reintegra à fila no primeiro flush pós-conclusão e é aplicado sobre o chunk recém-gerado — nenhuma edição é aplicada a slot em geração (B1 preservado).

### Crescimento de planos, reciclagem de paleta e proteção do AR

- **Dado** um chunk com paleta pequena.
- **Quando** edições introduzem um bloco novo (exigindo plano extra) e removem o último voxel de um tipo existente.
- **Então** o novo plano é zerado antes do uso, `plane_count`/`palette_size` sobem no header, o slot esvaziado (refcount 0) é reciclado por uma edição posterior (mesmo em outro flush) com tombstone do id antigo — e o slot 0 jamais é reciclado, mesmo com refcount 0.

### Chunk somente-leitura por overflow e feedback dois frames depois

- **Dado** um chunk com `CHUNK_FLAG_PALETTE_OVERFLOW` e um flush com edições para ele e para um chunk sadio.
- **Quando** o compute roda e dois frames passam.
- **Então** as edições do chunk em overflow reportam `EDIT_RESULT_REJECTED_OVERFLOW` e os dados permanecem intactos; as do chunk sadio reportam aplicado/no-op; as estatísticas colhidas no `edit_ring_write` refletem exatamente esses códigos.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-03-AC-01 | Flush aplicado antes do draw reflete a edição no mesmo frame | Cenário roteirizado (caixa de ar + caixa de pedra à frente da câmera) com screenshots antes/depois no mesmo tick do flush + readback da ocupação dos chunks afetados | Verificado — flush forçado no tick 300 (8 jobs, 2.937 edições) aplicado no mesmo frame; screenshot pós-flush mostra o bloco de pedra flutuante e a caixa esculpida na superfície do terreno; readback de decode confirma os voxels (ar→pedra no bloco, pedra/terra→ar na caixa esculpida) |
| VS-03-AC-02 | Decode, refcounts, ocupação, EMPTY e subdivisão permanecem consistentes | `tools/sim/edit_sim.py` bit a bit contra verdade densa cobrindo os cenários mínimos (incl. reciclagem, planos, subdivisão) | Verificado — `edit_sim.py`: 118 checks OK (decode == verdade densa após cada flush, refcounts exatos por slot, ocupação/coarse/EMPTY/subdivisão exatas, incl. 6 flushes aleatórios × 300 edições) |
| VS-03-AC-03 | Dedup, pendências e tetos obedecem à ordenação especificada | Simulação do modelo CPU (dedup última-escrita-vence, reintegração, backpressure) + estatísticas do ring no log do cenário roteirizado | Verificado — `edit_sim.py`: dedup (3 escritas → última staged), tetos 4.096/256/1.024 com dreno ordenado no ciclo seguinte, pendência em GENERATING reintegrada na conclusão; log do smoke: `applied=1002 noop=1935 rejected=0 deferred=0 (fila=0, pendências=0)` |
| VS-03-AC-04 | AR nunca é reciclado e overflow rejeita edição com código próprio | Simulação (alocações nunca tomam o slot 0; chunk em overflow intocado) + leitura do ring de resultados evidenciando `REJECTED_OVERFLOW`/`REJECTED_PALETTE_FULL` | Verificado (simulação) — `edit_sim.py`: chunk 100% sólido (refcount[0]=0) aloca id novo fora do slot 0 e ressuscita o AR com refcount exato; paleta lotada rejeita com `REJECTED_PALETTE_FULL` sem tocar os dados; chunk em overflow rejeita todas com `REJECTED_OVERFLOW` e permanece intacto |

## Tarefas da especificação

- [x] Vincular todos os requisitos do GOAL (REQ-EDIT-01..10, REQ-SIM-04).
- [x] Formalizar journal, rings, ordering e backpressure.
- [x] Especificar os cenários e invariantes da simulação E1.
- [x] Definir contrato de feedback necessário a VS-04.
- [x] Submeter à revisão e obter aprovação. — aprovada pelo mantenedor em 2026-11-04.

## Tarefas de implementação

Ordem sugerida; cada tarefa referencia requisitos e critérios de aceitação. Só entram na fila após a aprovação desta spec.

1. **VS-03-IMPL-01 — Contratos de edição no `common.slang` + espelho Odin** (REQ-EDIT-04/07/08; AC-04). `EditChunkJob`, formato da edição packed, códigos `EDIT_RESULT_*`, sentinelas e constantes do hash, helper `read_palette_index_at`; bindings 13/14/15 declarados; espelho e `#assert` no `voxel_types.odin`.
2. **VS-03-IMPL-02 — Simulação E1** (REQ-SIM-04; AC-02, AC-03, AC-04). `tools/sim/edit_sim.py`: fases do shader contra verdade densa + modelo CPU (dedup, pendências, tetos) nos cenários mínimos.
3. **VS-03-IMPL-03 — Compute `apply_voxel_edits`** (REQ-EDIT-05..08; AC-02, AC-04). Port das fases 0–3 e helpers `edit_hash_*`/`edit_resolve_slot` para `voxel.slang`; compilar com `spirv-val` limpo.
4. **VS-03-IMPL-04 — Rings e pipeline de edição** (REQ-EDIT-04; AC-01). Buffers host-visible 13/14/15 (results coerente) substituindo os dummies, pipeline compute, descriptors e destroy.
5. **VS-03-IMPL-05 — Journal CPU (`voxel_edit.odin`)** (REQ-EDIT-01..03; AC-03). `request_voxel_edit` + dedup, pendências com reintegração, `flush_voxel_edits` com tetos e backpressure, `edit_ring_write` com feedback.
6. **VS-03-IMPL-06 — Integração no frame** (REQ-EDIT-05/09; AC-01). Flush no loop principal, `edit_ring_write` após a espera, dispatch antes do builder com a barreira COMPUTE → COMPUTE, `edit_job_offset` nos push constants.
7. **VS-03-IMPL-07 — Evidências e fechamento** (AC-01..04). Cenário roteirizado com screenshots, readback de ocupação, estatísticas do ring no log; atualizar tracking e commitar com o nome da spec.

## Questões abertas

- Intervalo padrão do flush (100 ms da referência) permanece configurável por constante; o cenário roteirizado usa flush forçado para evidência determinística. Não bloqueia a aprovação.
- Gancho interativo (mouse/raycast) fica fora desta fatia — a evidência visual usa edições roteirizadas; a API pública já permite ligar input depois sem mudar contratos. Não bloqueia a aprovação.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
- 2026-11-04 — Elaboração completa: 11 requisitos (EDIT/SIM), contratos de edição, sequência do frame (com a barreira da ADR-B10), cenários e ACs; submetida à revisão do mantenedor.
- 2026-11-04 — **Aprovada pelo mantenedor**; tarefas VS-03-IMPL-01..07 destravadas.
- 2026-11-05 — Implementação concluída (IMPL-01..07): contratos de edição no `common.slang` + espelho Odin (`#assert(size_of(EditChunkJob) == 16)`); `tools/sim/edit_sim.py` com 118 checks; `apply_voxel_edits` portado com as 6 fases (cache do header, hash block_id→slot com tombstones e reciclagem preguiçosa, crescimento de planos, RMW de planos/ocupação/refcounts, coarse/EMPTY, subdivisão dos bricks sujos); rings host-visible reais nos bindings 13/14/15 (results com `HOST_ACCESS_RANDOM` + `InvalidateAllocation`); journal CPU em `voxel_edit.odin` (dedup, pendências, tetos, backpressure, feedback); dispatch no command buffer do frame antes do builder com barreira COMPUTE→COMPUTE (ADR-B10).
- 2026-11-05 — Bugs corrigidos durante a integração: (1) `edit_ring_write` re-copiava e re-despachava o staging a cada frame (feedback acumulava no-ops redundantes: 532 = 7×76) — staging passa a ser limpo após a cópia ao ring; (2) `groupshared` em escopo de módulo no Slang é a UNIÃO de todas as entry points — com o shader de edição no mesmo módulo, o mesh shader estourou `maxMeshSharedMemorySize` (37.924 B > 28.672 B): os shaders foram separados em três módulos (`voxel.spv` = generate+pack, `edit.spv` = edição, `render.spv` = builder+finalize+mesh+fragment; atenção: módulo de entry única é emitido como `"main"` pelo slangc). Readback da VS-01 movido do tick 120 para o 240 (no 120 ele corria o command buffer compartilhado da worker durante o streaming — corrida do harness de debug).
- 2026-11-05 — Validação verificada: evidências nos ACs acima. Notas: o worldgen passou a terreno por ruído (FastNoiseLite, alteração do mantenedor não commitada nesta fatia — o cenário roteirizado e a câmera foram ajustados para a superfície do terreno de ruído); o `debug_readback_validate` da VS-01 segue comparando contra a verdade do mundo plano e falha sob o terreno de ruído (pendente de atualização, decisão do mantenedor); o processo encerrou-se sozinho duas vezes durante as sessões de depuração (exit gracioso ~30–60 s, possivelmente interação de foco/ghost window durante o uso da máquina — não reproduzido em uso normal, backlog).
