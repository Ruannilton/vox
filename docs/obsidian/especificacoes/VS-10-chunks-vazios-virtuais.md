---
id: VS-10
titulo: Chunks vazios virtuais
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-04
bloqueada_por: []
requisitos: [REQ-VRT-01, REQ-VRT-02, REQ-VRT-03, REQ-VRT-04, REQ-VRT-05, REQ-VRT-06, REQ-SIM-07]
ultima_atualizacao: 2026-11-06
---

# VS-10 — Chunks vazios virtuais

## Objetivo

Chunks compostos apenas de ar (descobertos na geração) deixam de ocupar slot GPU, de serem publicados e de despachar workgroups do builder: viram registros **virtuais** (estado `EMPTY`, sem slot) com custo só de índice na CPU. Slots são liberados no instante da conclusão do pack; edições em chunk `EMPTY` materializam o chunk (gerar → aplicar) pelo mecanismo de pendências do E1; vizinhos os enxergam como ar, sem nenhuma mudança nos shaders de renderização.

## Rastreabilidade

- GOAL: proposta do mantenedor (2026-11-06) — evitar que chunks de ar dentro do raio de visão sejam submetidos ao fluxo de renderização e mantidos no cache com slot. Motivação medida: ~metade da bolha de visão no terreno atual (superfície y≈32–47) é ar puro.
- Referência: `build_work_queue` (early-out em `CHUNK_FLAG_EMPTY`, `render.slang`), `ve_publish_visible` e unload (`voxel_engine.odin`), handler de conclusão (B1), `edit_defer_to_pending` + reintegração no flush (`voxel_edit.odin`), `pack_chunk` (cálculo de `distinct_count`, `voxel.slang`), vizinhos B2 (`NEIGHBOR_SLOT_INVALID` = ar).
- Decisões: [[ADR-V1-chunks-vazios-virtuais|ADR-V1]] (**bloqueia a aprovação desta spec**).
- Fundação: VS-03 (pendências do E1), VS-04 (mirror), VS-08 (slots/config — a derivação do pool não muda; empties apenas usam menos na prática).

## Requisitos

### Estado e transições

- **REQ-VRT-01** — Novo estado `ChunkState.EMPTY`: o registro vive no map de chunks **sem slot** (`storage_slot_index` inválido). Nunca é `RENDERABLE`, nunca é publicado em `visible_chunks`, nunca despacha builder. Custa apenas a entrada no map; unload além do raio de descarga = deletar o registro, **sem aposentadoria** (nada GPU-side). Chunk `EMPTY` dentro do raio de geração não é re-enfileirado (o check `coord in active_chunks` já o cobre).
- **REQ-VRT-02** — Feedback da geração: o pack escreve as flags de cada chunk num buffer host-visible `chunk_result_flags` (**binding 18**, `[resident_slots]u32`, RW) indexado pelo slot. O handler de conclusão — já ordenado pela timeline do lote e validando coord+slot+geração (B1) — lê as flags: `CHUNK_FLAG_EMPTY` e sem edições pendentes → estado `EMPTY` + slot devolvido ao pool **imediatamente**; caso contrário → `CACHED`, como hoje. Se edições pendentes existirem, o chunk materializa normalmente (fica `CACHED`) e o E1 aplica em seguida.

### Renderização (sem mudança de shader)

- **REQ-VRT-03** — `ve_publish_visible` publica somente `CACHED`/`RENDERABLE` **com slot**; a condição de vizinho passa a usar o slot apenas de vizinhos `CACHED`/`RENDERABLE` materializados — vizinho `EMPTY` (ou `GENERATING`, como hoje) = `NEIGHBOR_SLOT_INVALID`. Como o shader já trata invalid como ar (`is_voxel_solid`, B2) e a ocupação de um chunk de ar é zero de qualquer forma, o resultado visual é **idêntico** — nenhuma mudança em `render.slang`, `common.slang` (fora `pack_work_item`, inalterado) ou no mesh.

### Edição em chunk EMPTY

- **REQ-VRT-04** — `request_voxel_edit` em chunk `EMPTY`: se `block_id != 0` → materializar: alocar slot (se o pool estiver vazio, a edição **permanece na fila** e a materialização é tentada novamente a cada update até haver slot — sem erro, sem perda), enfileirar tarefa de geração (com export p/ mirror se na bolha de simulação), estado → `GENERATING`, e a edição vai para `edit.pending` (mecanismo VS-03 existente), reaplicada na conclusão. Se `block_id == 0` (ar em ar) → **no-op**, nem materializa. Mirror: para chunk na bolha de simulação, a página é **sintetizada na CPU** (grid u16 zeros + bitmask vazio — o conteúdo worldgen é ar conhecido) antes do `mirror_journal_apply`; fora da bolha, nada a fazer.

### Observabilidade e recursos

- **REQ-VRT-05** — Contadores: chunks `EMPTY` ativos e slots economizados, expostos no log de estado da engine (e prontos para a telemetria VS-05 numa fatia futura). Provisionamento: `chunk_result_flags` entra no log de bytes provisionados da validação de máquina (4 B × slots — residual).
- **REQ-VRT-06** — Invariantes: (a) nenhum caminho lê/escreve GPU usando o slot de um registro `EMPTY`; (b) liberação do slot na conclusão é tão segura quanto a promoção a `CACHED` (mesma ordenação de timeline, mesmo anti-ABA por geração); (c) o early-out de `CHUNK_FLAG_EMPTY` no builder permanece como defesa (chunks que esvaziam **após** a geração — ver backlog).
- **REQ-SIM-07** — Antes da integração: `tools/sim/pack_sim.py` estendido (flags por slot no modelo do pack; transição EMPTY com/sem pendências) e `tools/sim/render_sim.py` com cenário de publish/vizinhos com chunks EMPTY (visível não publicado, vizinho = INVALID, render idêntico ao chunk de ar com slot). Checks antigos verdes.

## Escopo

- Estado `EMPTY`, transições (conclusão do pack, unload, redescoberta).
- Binding 18 (`chunk_result_flags`) + revisão do descriptor set/layout (nota no histórico da VS-00); write no pack; leitura no handler de conclusão.
- Filtros em `ve_publish_visible` (publish + vizinhos); retry de materialização por edição no `voxel_engine_update`.
- No-op de ar-em-ar; síntese de página do mirror; contadores.
- Sims estendidas (REQ-SIM-07).

## Não escopo

- Chunk que **se torna** ar por edição transitar para `EMPTY` (liberar slot pós-edição) — backlog (mesma máquina).
- Atalho CPU "provavelmente vazio" por teto de worldgen (ADR-V1 Opção C) — backlog.
- Save/serialização: chunks `EMPTY` tratados como "sem dados" — backlog do sistema de save (inexistente hoje).
- Mudança na derivação do pool de slots (VS-08) ou em shaders de render/mesh.

## Dependências

- [[VS-04-mirror-c2|VS-04]] concluída e verificada (pendências E1 + mirror); VS-08 concluída (slots/config).
- [[ADR-V1-chunks-vazios-virtuais|ADR-V1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `ChunkState.EMPTY` | registro sem slot (`storage_slot_index` inválido) | transição só via conclusão do pack (vazio) |
| `chunk_result_flags` (binding 18) | `[resident_slots]u32` — flags do header por slot | host-visible, RW; escrito pelo pack, lido pelo handler de conclusão pós-timeline |
| Publish | só `CACHED`/`RENDERABLE` com slot; vizinho com slot só se `CACHED`/`RENDERABLE` | `EMPTY`/`GENERATING` → `NEIGHBOR_SLOT_INVALID` |

### Sequência (integração)

```
pack_chunk: escreve header.flags em chunk_result_flags[slot]
handler de conclusão (pós timeline, B1): flags & CHUNK_FLAG_EMPTY && sem pendências
  → estado EMPTY, slot devolvido ao pool      | senão → CACHED (como hoje)
ve_publish_visible: skip EMPTY; vizinhos EMPTY = INVALID
request_voxel_edit em EMPTY (block != 0): aloca slot (retry se pool vazio)
  → geração → GENERATING → pending E1 → aplica na conclusão
unload: EMPTY além do raio → delete do map (sem aposentadoria)
```

### Comportamento quando limites são atingidos

- Pool esgotado na materialização por edição: edição fica na fila, retry por frame; nenhum erro, nenhuma perda (a edição também está no journal do mirror).
- Chunk `EMPTY` redescoberto após unload: regenera e re-avalia (custo de uma geração por visita — aceito; o atalho Opção C é o caminho para economizá-lo).

## Cenários

### Cenário de sucesso — bolha cheia de ar

- **Dado** a câmera alta (y≈75), vision=16, terreno com superfície em y≈32–47.
- **Quando** a bolha materializa e frames avançam.
- **Então** ~metade dos chunks da bolha conclui como vazia e vira `EMPTY`: nenhum deles é publicado ou despacha builder; o log mostra os contadores (empties ativos/slots economizados) crescendo até o equilíbrio; FPS melhora ou fica estável.

### Edição no céu

- **Dado** um chunk `EMPTY` (ar puro) e um `AddBlock` no meio dele.
- **Quando** a edição é solicitada.
- **Então** o chunk materializa (geração), a edição aplica na conclusão (pending do E1) e o bloco aparece; o estado final é `CACHED`/`RENDERABLE` com slot. Uma segunda edição `RemoveBlock` volta o chunk a ar, mas ele **permanece materializado** (transição pós-edição é backlog).

### No-op de ar-em-ar

- **Dado** um chunk `EMPTY` e um `RemoveBlock` (block_id=0) nele.
- **Quando** a edição é solicitada.
- **Então** nada acontece: sem geração, sem slot, sem journal efetivo (no-op).

### Vizinhança inalterada

- **Dado** um chunk sólido com vizinho `EMPTY`.
- **Quando** o mesh shader avalia as faces de fronteira.
- **Então** o vizinho INVALID é tratado como ar — faces expostas exatamente como antes da otimização (verificado na simulação, REQ-SIM-07).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-10-AC-01 | Sim verde: pack escreve flags; transição EMPTY com/sem pendências; publish/vizinhos com EMPTY; render idêntico para vizinho EMPTY × ar-com-slot; checks antigos verdes | `tools/sim/pack_sim.py` + `tools/sim/render_sim.py` | 2026-11-06 — `pack_sim.py`: 968 passaram, 0 falharam (cenário novo `scenario_empty_transitions`: flags por slot, EMPTY com/sem pendências, reciclagem de slots); `render_sim.py`: 2.731 passaram, 0 falharam (cenário novo `scenario_empty_neighbors`: EMPTY não publicado, vizinho INVALID × ar-com-slot com fila e geometria idênticas). **Verificado** |
| VS-10-AC-02 | Smoke com câmera alta: contadores de EMPTY crescem (~metade da bolha), zero dispatches de builder para chunks EMPTY (readback da fila: itens apenas de chunks com conteúdo), render correto, zero erros de validation | Smoke vision=16 câmera em y=75, ~30 s: log de contadores + readback | 2026-11-06 — smoke `timeout 40 ./vox.exe` (bin/vox.ini do mantenedor: vision=20, generation=20, unload=21, câmera y=75): contadores crescendo a cada 5 s — 1.775 → 11.172 empties ativos (~35 s, ainda subindo; esfera(generation=20) ≈ 33,5 mil chunks); readback temporário da fila aos ~25 s: append=1.911, x=1.911, overflow=0 (faixa ~metade do baseline 1.910–1.940, só chunks com conteúdo); render correto; zero erros de validation novos (apenas o VUID pré-existente de query pool). **Verificado** |
| VS-10-AC-03 | Edição AddBlock em chunk EMPTY materializa e aplica (bloco visível / feedback E1 applied=1); RemoveBlock em EMPTY é no-op; após unload+redescoberta, chunk vazio volta a EMPTY | Sessão replay (VS-07) com AddBlock no céu + Wait + verificação | 2026-11-06 — replay `ceu.jsonl` (TeleportTo [64,200,64] → chunk (2,6,2), acima do teto do worldgen; AddBlock; Wait; RemoveBlock; teleporte p/ [1024,200,64] + Wait 8 s; retorno + Wait 25 s): log mostra `materializando chunk EMPTY [2,6,2] (slot, geração 2)` (EMPTY→GENERATING), feedback E1 `applied=1` para o AddBlock e `applied=1` para o RemoveBlock (chunk permanece materializado — transição pós-edição é backlog, conforme especificado); após unload (ativos caem a 75) a redescoberta regenera e volta a EMPTY — `slots economizados` sobem 4.207 → 7.437 sem nova materialização; `FINAL edits: applied=2`. **Verificado** |

## Tarefas da especificação

- [x] Vincular a proposta do mantenedor aos hooks existentes (B1, E1-pending, B2-invalid).
- [x] Formalizar o estado vazio, o feedback do pack e as transições.
- [x] Cobrir sucesso, edição, no-op e vizinhança; definir backlog.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-V1 e obter aprovação da spec. — ADR-V1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

1. ~~**VS-10-IMPL-01 — Simulação**~~ **Concluída 2026-11-06** (AC-01). `pack_sim.py`: cenário `scenario_empty_transitions` (flags por slot + transições, 968 checks verdes); `render_sim.py`: cenário `scenario_empty_neighbors` (publish/vizinhos EMPTY + equivalência de render, 2.731 checks verdes). Rodadas antes dos shaders.
2. ~~**VS-10-IMPL-02 — Binding e pack**~~ **Concluída 2026-11-06** (REQ-VRT-02, REQ-VRT-06; AC-01/AC-02). Binding 18 host-visible `chunk_result_flags` (`voxel_gpu.odin`, `DESCRIPTOR_SET_BINDING_COUNT` 19, declaração em `common.slang`); write de flags no `pack_chunk` (`voxel.slang`, thread 0 da fase B3); 4 B × slots no provisionamento (`config.odin`); `spirv-val` limpo.
3. ~~**VS-10-IMPL-03 — Estado e transições**~~ **Concluída 2026-11-06** (REQ-VRT-01, REQ-VRT-03; AC-02). `ChunkState.EMPTY` + `SLOT_INDEX_INVALID`; handler de conclusão lê as flags pós-timeline (B1: mesma ordenação, mesmo anti-ABA) e devolve o slot no instante da conclusão; publish/vizinhos só `CACHED`/`RENDERABLE` com slot; unload de EMPTY = delete do map sem aposentadoria (mirror esquecido normalmente — sem slot GPU).
4. ~~**VS-10-IMPL-04 — Edição e mirror**~~ **Concluída 2026-11-06** (REQ-VRT-04; AC-03). Materialização com retry por update (`ve_try_materialize_empty`/`ve_retry_empty_edits`); no-op de ar-em-ar; flush do E1 trata EMPTY como não-pronto (nunca despacha para slot inválido); mirror sintetiza página zerada (`mirror_page_fill_empty`) para chunk EMPTY na bolha de simulação, sem export GPU.
5. ~~**VS-10-IMPL-05 — Evidências e fechamento**~~ **Concluída 2026-11-06** (AC-01..03). Sims, smoke de contadores + readback (1.911 itens), replay de edição no céu (applied=1 ×2, redescoberta volta a EMPTY), docs e commit.

**Prioridade da materialização:** a tentativa roda no `voxel_engine_update` (domínio da thread principal), na frente do flush do E1 do mesmo frame — edição solicitada e pool seco retenta a cada update até conseguir slot; prioridade da tarefa de geração segue a fila padrão do worker (distância à câmera).

## Histórico

- 2026-11-06 — Rascunho elaborado a partir da proposta do mantenedor (não submeter chunks de ar ao fluxo de render nem mantê-los com slot); ADR-V1 registrada como pendente com recomendação da Opção A (EMPTY virtual sem slot); spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-V1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-10-IMPL-01..05 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..04) e validada (AC-01..03)**. Números do smoke AC-02 (bin/vox.ini do mantenedor, vision=20/generation=20/unload=21, câmera y=75): empties ativos 1.775 (5 s) → 11.172 (35 s), ainda crescendo — ~um terço da esfera de geração já concluída e subindo rumo a ~metade; readback da fila aos ~25 s: append=1.911 / x=1.911 / overflow=0 (baseline anterior 1.910–1.940 com todos os chunks publicados — a fila agora contém só chunks com conteúdo). AC-03 (replay): materialização `EMPTY→GENERATING` do chunk (2,6,2) com geração 2; feedback E1 `applied=1` no AddBlock e no RemoveBlock; pós-unload/redescoberta o chunk volta a EMPTY (slots economizados 4.207 → 7.437, sem nova materialização). Detalhes de código: o materialize do mirror roda antes da transição EMPTY no handler (o valid check deixou de exigir `state != .GENERATING` — a igualdade coord+slot+geração já é o anti-ABA); o flush do E1 e o reconcile tratam EMPTY como "não pronto" para nunca despachar um job com slot inválido; procs de debug readback guardam `EMPTY`. Instrumentação temporária de readback revertida. Zero erros de validation novos (VUID pré-existente de query pool inalterado).

## Questões abertas

- ~~Prioridade da tarefa de materialização por edição~~ — **resolvida 2026-11-06**: a tentativa roda no `voxel_engine_update` (thread principal), à frente do flush do E1 do mesmo frame; a tarefa de geração segue a fila padrão do worker (distância à câmera).
- Exposição dos contadores na telemetria CSV (VS-05): backlog natural, não bloqueia.

## Histórico
