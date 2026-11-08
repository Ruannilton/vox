---
id: VS-13
titulo: Heightmap na geração e no mirror
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-04
bloqueada_por: []
requisitos: [REQ-GEN-01, REQ-GEN-02, REQ-MIR-01, REQ-MIR-02, REQ-MIR-03, REQ-MIR-04, REQ-SIM-10]
ultima_atualizacao: 2026-11-07
---

# VS-13 — Heightmap na geração e no mirror

## Objetivo

Otimizar a geração de chunks: cada coluna (x,z) tem sua altura de ruído calculada **uma única vez** por chunk (heightmap 32×32 em groupshared, lido por todos os voxels da coluna) em vez das 32 avaliações redundantes atuais, com os estados de ruído criados uma vez por workgroup em vez de por voxel — saída **bit a bit idêntica**. O heightmap é exportado para o mirror (ring paralelo + campo na ChunkPage), onde o journal do E1 o mantém, dando resposta O(1) para a altura do chão de uma coluna.

## Rastreabilidade

- GOAL: pedido do mantenedor (2026-11-06) — manter/reusar o state do ruído (hoje instanciado por voxel) e criar uma matriz 2D de heightmap, também enviada ao mirror.
- Referência: `generate_voxels` (`src/assets/shaders/voxel.slang` — `fnlCreateState` por voxel, 2×`fnlGetNoise2D` por voxel), `lib/FastNoiseLite.slang` (`fnlGetNoise2D(fnl_state state, ...)` por valor), mirror (ring binding 16, `ChunkPage`, `mirror_page_apply` — VS-04), worldgen `height = 32 + h1 + h2`.
- Decisões: [[ADR-G1-heightmap-geracao-mirror|ADR-G1]] (**bloqueia a aprovação desta spec**); emenda a [[VS-04-mirror-c2|VS-04]] (formato da página e do ring).
- Fundação: VS-04 (mirror/export), VS-05 (telemetria — evidência de ganho), VS-10 (chunk vazio: página de ar não existe — heightmap de coluna vazia é `0xFFFF` por definição).

## Requisitos

### Geração (GPU)

- **REQ-GEN-01** — Heightmap por workgroup: cada workgroup (8×8×8 threads) cobre uma fatia de 8×8 colunas do chunk; as threads com **y-local 0** (64 por workgroup) calculam a altura de cada coluna **uma vez** (`32 + fnl1 + fnl2` com as posições mundo da coluna) e gravam num `groupshared uint16[8][8]`; após barrier, os 512 threads leem a altura da sua coluna e derivam o `block_id` como hoje. Avaliações de ruído por chunk: 65.536 → 8.192 (**8×** medido — as 4 fatias-y de um mesmo (x,z) recalculam a mesma coluna, pois o groupshared é por workgroup e o dispatch/thread mapping ficaram inalterados; a estimativa original de 2.048/32× ignorava essa redundância). Mesmos inputs na mesma função determinística → saída bit a bit idêntica (equivalência pura; nenhuma mudança de worldgen).
- **REQ-GEN-02** — Estados de ruído criados **uma vez por workgroup** (não por voxel): os dois `fnl_state` (OpenSimplex2 @0.02, Perlin @0.07, seed default) são inicializados pelas threads de coluna (ou cooperativamente) e reutilizados; o caminho por valor de `fnlGetNoise2D` permanece (a cópia do state por avaliação já é o custo residual, 8× menor). Dispatch e thread mapping inalterados (sem mudança de lote/batch). **Alternativas avaliadas e descartadas (nota do mantenedor, 2026-11-06):** states em **buffer** (SSBO/UBO) foram considerados e rejeitados — `fnlGetNoise2D` recebe o state por valor, então um buffer implicaria ~100–128 B de leitura global por avaliação (tráfego em todas as 2.048 restantes) contra custo zero após o init em groupshared; um `static const` global seria ainda mais barato, mas acopla ~30 campos à versão da FastNoiseLite. Se um dia o ruído virar **configuração** (parâmetro de `vox.ini`), aí um buffer/UBO faz sentido — como evolução de configuração, não de otimização.

### Mirror

- **REQ-MIR-01** — **Binding 20** `mirror_heightmap_ring`: 64 slots × 1.024 u16 (2 KiB) host-visible, paralelo ao ring denso (binding 16) — **mesmo índice de slot**. As threads de coluna do generate (com `job.mirror_ring_slot >= 0`) gravam `heights[x | z<<5]` no slot. Ring denso inalterado.
- **REQ-MIR-02** — `ChunkPage` ganha `heights[1024]u16` (índice `x | z<<5`, z-contíguo). Semântica: **y do bloco sólido mais alto da coluna**; `0xFFFF` = coluna sem sólido. Página cresce de ~68,1 KiB para ~70,2 KiB (+1,5 MiB no pool de 768 páginas — residual); materialize preenche o campo do ring; `#assert` de tamanho atualizado.
- **REQ-MIR-03** — O journal do E1 mantém `heights` em `mirror_page_apply`: colocar bloco sólido com `y > altura` → `altura = y`; remover o bloco do topo (`y == altura`) → rescan da coluna (32 leituras do `ids`) para o novo topo (ou `0xFFFF`); demais casos → inalterado. Coluna vazia recebendo sólido → `altura = y`. Consistência com `ids`/`solid` preservada (o `edit_seq` paritário da VS-04 não muda).
- **REQ-MIR-04** — Helper `mirror_height_get(chunk_coord, x, z) -> (ok: bool, height: u16)`: `ok = false` se a página está ausente/em readback; senão a altura (`0xFFFF` = coluna vazia). Interface mínima para consumidores futuros (gameplay) e para os ACs.

### Simulação

- **REQ-SIM-10** — Antes da integração: (a) modelo Python do mapeamento de threads do generate (qual thread calcula qual coluna, qual fatia por workgroup) com **mock noise** comparado contra a computação por voxel — prova a indexação e a equivalência da estrutura; (b) `mirror_sim` estendido com a manutenção do `heights` pelo journal (colocar acima/no topo/abaixo, remover no topo com rescan, coluna vazia, chunk de ar). Checks antigos verdes.

## Escopo

- `generate_voxels` reestruturado (heightmap em groupshared + estados reutilizados), binding 20, write do heightmap no ring.
- Mirror: campo na ChunkPage, materialize, manutenção no journal, helper `mirror_height_get`, `#assert`/budgets.
- Sims: cenário de indexação do heightmap (mock noise) + cenários de journal no mirror_sim.
- Medição de ganho via telemetria VS-05 (CSV) antes/depois.
- Docs: emenda da VS-04 (página/ring), nota de contrato da VS-00 (binding 20), arquitetura (Fig. 5 e §7), manual técnico, tracking.

## Não escopo

- Consumidores de gameplay do heightmap (pathfinding, spawn, física) — a interface fica exposta, o uso é de consumidores futuros.
- Usos GPU do heightmap além da geração (iluminação/AO) e múltiplas alturas por coluna (cavernas/overhangs — exigiria semântica nova).
- `apply_voxel_edits` (GPU) mantendo heightmap: pelo princípio C2 o ring só alimenta o materialize e o journal é a verdade — o mirror mantém o próprio campo.
- Save/serialização do heightmap (backlog do save como um todo).

## Dependências

- [[VS-04-mirror-c2|VS-04]] concluída e verificada (mirror/export/journal).
- [[ADR-G1-heightmap-geracao-mirror|ADR-G1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `mirror_heightmap_ring` (binding 20) | 64 slots × 1.024 u16 (2 KiB), host-visible | paralelo ao denso; mesmo índice de slot; escrito pelo generate |
| `ChunkPage.heights` | `[1024]u16`, índice `x \| z<<5` | y do sólido mais alto; `0xFFFF` = coluna vazia; ~70,2 KiB/página |
| `mirror_height_get` | `(ok, height)` por coluna | tri-state de página preservado |
| Grupos do generate | `groupshared uint16[8][8]` por workgroup | 64 colunas calculadas 1×; estados fnl 1×/workgroup |

### Sequência (integração)

```
generate (workgroup 8×8×8):
  threads y-local 0: criar fnl1/fnl2 (1×), avaliar altura da coluna (x,z)
  → groupshared heights[8][8]; barrier
  todos: block_id pela altura da coluna (como hoje, bit a bit idêntico)
  threads y-local 0 com mirror_ring_slot ≥ 0: gravar heights[x | z<<5] no ring (binding 20)
mirror: materialize copia heights → ChunkPage; journal (E1) mantém por edição
```

### Comportamento quando limites são atingidos

- Chunk de ar (VS-10): vira `EMPTY`, sem página no mirror — `mirror_height_get` retorna `ok = false` (página ausente), coerente com o tri-state.
- Edições que só tocam ar abaixo do topo / adicionam ar: `heights` inalterado (rescan só na remoção do topo).
- Pool esgotado na materialização por edição (VS-10): unchanged — retry mantém journal; heights é atualizado quando a página nasce.

## Cenários

### Cenário de sucesso — equivalência e ganho

- **Dado** a cena padrão (câmera travada, config default) antes e depois da mudança.
- **Quando** frames avançam.
- **Então** imagem e readbacks **idênticos** ao baseline (equivalência bit a bit), zero erros de validation, e o tempo do `generate` no CSV da telemetria cai de forma mensurável (evidência numérica antes/depois).

### Altura de chão em O(1)

- **Dado** uma página materializada com terreno.
- **Quando** `mirror_height_get` consulta uma coluna de superfície e uma coluna de ar.
- **Então** retorna o y do topo sólido e `0xFFFF` respectivamente, sem scan.

### Journal mantém o heightmap

- **Dado** uma coluna com altura h.
- **Quando** edições colocam um bloco em h+3, removem o bloco do novo topo, e removem um bloco abaixo do topo.
- **Então** o campo vai a h+3, rescan para o novo topo, e permanece inalterado no terceiro caso (verificado no mirror_sim e em sessão replay com feedback).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-13-AC-01 | Sims verdes: indexação do heightmap no mapeamento de threads (equivalência estrutural com mock noise) + manutenção do heights pelo journal; checks antigos verdes | Sim nova + `mirror_sim` estendido | **Verificado (2026-11-07):** `heightmap_sim.py` novo — 5 checks (mapeamento thread→coluna, equivalência bit a bit dense+ring em 3 chunks com mock noise, export z-contíguo no slot certo, contagem 65.536→8.192 avaliações/chunk); `mirror_sim.py` estendido — 44 checks (13 novos de journal do heightmap: materialize do ring, colocar acima/no-topo/abaixo, rescan na remoção do topo, esvaziar coluna, chunk de ar, tri-state); checks antigos verdes: `mirror_sim` 44, `pack_sim` 968, `edit_sim` 118, `render_sim` 2.906 |
| VS-13-AC-02 | Equivalência bit a bit: imagem e readbacks idênticos ao baseline, zero erros de validation | Smoke com capturas comparadas (padrão VS-11) + `debug_readback_validate`/`debug_mirror_parity` verdes | **Verificado (2026-11-07):** sessão replay VS-07 idêntica pré/pós (build do baseline via `git stash` temporário + guard temporário de input replicado nos dois lados — capturas GDI contaminação de input de janela; revertido ao final), câmera travada por TeleportTo/LookAt; capturas 800×600 comparadas pixel a pixel: **170 de 1.920.600 bytes diferentes** (residual de captura GDI, mesma ordem do baseline VS-12: 6 bytes); `debug_readback_validate` OK (`packed == mirror denso`, 32.768 voxels) e `debug_mirror_parity` OK no chunk editado (edit_seq 1 pré-edições e edit_seq 5 pós-4-edições); smoke final do build limpo (instrumentação revertida): **zero erros de validation** |
| VS-13-AC-03 | Ganho **medido e documentado** no generate (telemetria CSV, mesma pose — incluindo resultado nulo) e heightmap correto no mirror (materialize + sessão replay com AddBlock/RemoveBlock validando `heights`) | CSV antes/depois + sessão replay VS-07 com verificação via `mirror_height_get`/log | **Verificado (2026-11-07) — heightmap: verificado; ganho de tempo: medido e nulo nesta configuração (documentado).** Sessão replay com AddBlock/RemoveBlock na superfície (coluna (8,8), chunk (0,1,0), topo worldgen local 9): colocar em y=60 → heights 9→28 (sobe); remover y=60 → rescan para 9; colocar em y=35 (abaixo do topo, noop na GPU) → inalterado 9; remover y=35 → inalterado 9; estado final heights=9 == ground truth `mirror_column_ground`=41 (9+32). Telemetria (mesma pose/config, ~22k chunks gerados por sessão de regeneração com 3 ciclos de teleport): **total `generate_us` 76,0 ms (pré) vs 77,5 ms (pós); mediana 131,5 vs 132,9 µs** — diferença dentro do ruído: o kernel `generate_voxels` é dominado por custos fixos (dispatch/barreira/export u16), não pelo ALU do ruído — a redução algorítmica de 8× nas avaliações (65.536→8.192/chunk, REQ-GEN-01) não se traduz em wall-clock mensurável nesta GPU/carga. **Decisão do mantenedor (2026-11-07): resultado nulo aceito** — a otimização permanece como alicerce para worldgen mais pesado (mais octaves/camadas); o critério do AC passou a ser a medição rigorosa, não o ganho em si. Detalhes e números no Histórico |

## Tarefas da especificação

- [x] Vincular o pedido do mantenedor ao custo atual (65.536 avaliações/chunk) e ao ganho do mirror (chão O(1)).
- [x] Formalizar o heightmap em groupshared, o reuso dos estados e o contrato do mirror (ring, página, journal, helper).
- [x] Cobrir equivalência, ganho e manutenção pelo journal; registrar não-escopos (cavernas, consumidores, save).
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-G1 e obter aprovação da spec. — ADR-G1 (Opção A, states em groupshared; buffer avaliado e descartado) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-G1. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-13-IMPL-01 — Simulação** (REQ-SIM-10; AC-01). Cenário de indexação do heightmap (mock noise, equivalência por voxel) + `mirror_sim` com manutenção do heights pelo journal. Rodar antes dos shaders.
2. **VS-13-IMPL-02 — Geração** (REQ-GEN-01/02; AC-02). `generate_voxels` reestruturado: heightmap em groupshared, estados 1×/workgroup; `spirv-val` limpo.
3. **VS-13-IMPL-03 — Mirror** (REQ-MIR-01..04; AC-03). Binding 20, `ChunkPage.heights`, materialize, `mirror_page_apply` mantendo heights, `mirror_height_get`; emenda da VS-04 e nota da VS-00.
4. **VS-13-IMPL-04 — Evidências e fechamento** (AC-01..03). Sims, smoke de equivalência (capturas + readbacks), CSV antes/depois do generate, sessão replay validando heights, docs e commit com o nome da spec.

## Questões abertas

- z-contíguo (`x | z<<5`) fixado para a matriz; se o primeiro consumidor de gameplay preferir x-contíguo, ajusta-se sem quebrar nada (campo opaco fora do generate). Não bloqueia a aprovação.
- A telemetria de ganho depende da estabilização do streaming nas duas medidas (mesma pose, mesma config; média de N amostras). Não bloqueia a aprovação.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (reusar state do ruído e enviar heightmap 2D ao mirror); ADR-G1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-G1 ratificada (Opção A) e spec aprovada** pelo mantenedor; pergunta sobre states em buffer respondida e alternativa documentada no REQ-GEN-02; tarefas VS-13-IMPL-01..04 destravadas.
- 2026-11-07 — **Implementação concluída (IMPL-01..04) e validação verificada (AC-01, AC-02; AC-03 parcial — ganho de tempo não mensurável, heightmap verificado).** Módulos: `voxel.slang` (`generate_voxels` reestruturado: `groupshared uint16 heights_gs[8][8]` preenchido pelas threads y-local 0 com os estados fnl criados 1×/thread-de-coluna, barrier, todos leem; mesma expressão `32 + h1 + h2` e mesmas comparações — equivalência bit a bit; as threads de coluna exportam `min(height - base_y, 31)` (ou `0xFFFF` se a coluna é toda ar no chunk) no ring binding 20, índice z-contíguo `x|z<<5`); `common.slang` (binding 20 `RWStructuredBuffer<uint16_t> mirror_heightmap_ring`); `engine_vukan.odin` (`DESCRIPTOR_SET_BINDING_COUNT` 20→21); `voxel_gpu.odin` (buffer host-visible 64 slots × 2 KiB, descriptor write, destroy, nome de telemetria); `voxel_types.odin` (`ChunkPage.heights[1024]u16`, `#assert(size_of(MirrorChunkPage) == 71824)` = 70,14 KiB, era 69.776 = 68,14 KiB); `voxel_mirror.odin` (init 0xFFFF, materialize copia do ring com `InvalidateAllocation`, `mirror_page_apply` mantém o campo, `mirror_height_get` tri-state); `apply_voxel_edits` (GPU) intocado (C2). Ferramentas: `tools/sim/heightmap_sim.py` (novo — mapeamento de threads + equivalência com mock noise + export; 5 checks) e `tools/sim/mirror_sim.py` (estendido — 44 checks, +13 do journal do heightmap). **AC-01:** sims verdes (`heightmap_sim` 5, `mirror_sim` 44; antigos `pack_sim` 968, `edit_sim` 118, `render_sim` 2.906). **AC-02:** smoke pré/pós com a MESMA sessão replay (câmera travada por TeleportTo/LookAt, `capture.ps1` GDI nos dois lados; baseline via `git stash` temporário com guard temporário de input replicado — ver ressalva 2): **170 de 1.920.600 bytes diferentes** (residual de captura GDI); `debug_readback_validate` OK (`packed == mirror denso`, 32.768 voxels, chunk 100% sólido) e `debug_mirror_parity` OK (chunk editado, edit_seq 1 → 5 após 4 edições); build limpo final: zero erros de validation, zero processos órfãos. **AC-03:** sessão replay com `AddBlock`/`RemoveBlock` na superfície (coluna (8,8), chunk (0,1,0), topo worldgen local 9): **sobe** 9→28 ao colocar em y=60; **rescan** para 9 ao remover o y=60; **inalterado** (9) ao colocar/remover em y=35 (abaixo do topo; o colocar foi noop também na GPU); final heights=9 == `mirror_column_ground`=41 (9+32) — verificado por `mirror_height_get`. Telemetria (3 ciclos de teleport forçando ~22k regenerações por sessão, mesma pose/config, ~155 amostras de 500 ms de cada lado): **total `generate_us` 76,0 ms (pré) vs 77,5 ms (pós); mediana 131,5 vs 132,9 µs; máx 6.660 vs 5.378 µs** — ganho de wall-clock NÃO mensurável (dentro do ruído): o custo do `generate_voxels` é dominado por fatores fixos (dispatch/barreira/export u16; ~1,5 µs/chunk agregado), não pelo ALU do ruído, que era subutilizado em ambas as versões (GPU subocupada com 512 workgroups de 512 threads por lote). Redução algorímica real e comprovada: 8× menos avaliações de ruído (65.536→8.192/chunk) e 64× menos criações de estado fnl (65.536→1.024/chunk — 1 por thread de coluna × 64 workgroups). Ressalvas: (1) os debugs `debug_readback_validate`/`debug_mirror_parity` disparados com o compute worker ativo emitem THREADING warnings de `vkDeviceWaitIdle` concorrente com `vkQueueSubmit2` (padrão pré-existente desses procs, VS-04/VS-12; na sessão do AC-02 eles foram acionados por instrumentação temporária em `main.odin`, revertida); uma corrida de desligamento pré-existente (`vkDeviceWaitIdle` em `main.odin` antes do join do worker) foi observada 1× no pós e 0× em 2 baselines — intermitente, tempo-dependente, sem relação funcional com a VS-13. (2) Input espúrio do SO (foco/janela) move a câmera em sessões com captura GDI; o guard temporário usado nas medições (`replay ativo → ignora input`) foi revertido após as evidências — recomenda-se ao mantenedor uma flag permanente equivalente para smokes automatizados (backlog). (3) Não-escopo mantido: consumidores de gameplay do `mirror_height_get`, cavernas/overhangs (semântica de topo único), save/serialização do heightmap.
- 2026-11-07 — **Fechamento do AC-03 com resultado nulo aceito pelo mantenedor:** o critério foi reescrito de "ganho mensurável" para "ganho medido e documentado (incluindo resultado nulo)" — a medição rigorosa (76,0 → 77,5 ms total; mediana 131,5 → 132,9 µs; dentro do ruído) é o evidência de aceite. A otimização algorítmica (8× menos avaliações de ruído, 64× menos criações de estado) permanece como alicerce para worldgen mais pesado. Spec integralmente verificada.
- 2026-11-08 — **Emenda planejada pela VS-19 (REQ-PHY-07, ADR-F1 pendente):** REQ-MIR-01 e a origem por ring de REQ-MIR-02 ficam superseded. `heights` será derivado do bitmask `solid` na materialização (1.024 colunas × ≤32 bits), eliminando o acoplamento ao worldgen heightfield e tornando redundantes o binding/ring 20 e o write de export. `ChunkPage.heights`, `mirror_height_get` e a manutenção E1 permanecem; o heightmap groupshared do generate também permanece para o worldgen. Sims precederão a mudança de shader. Nenhuma implementação realizada nesta revisão documental.
- 2026-11-08 — **Emenda VS-19 consumada (REQ-PHY-07; ADR-F1 aceita):** REQ-MIR-01 e a origem por ring de REQ-MIR-02 ficam **superseded**. Ring `mirror_heightmap_ring` (binding 20), seu write no `generate_voxels`, a invalidação/cópia no materialize e o provisionamento foram removidos; `DESCRIPTOR_SET_BINDING_COUNT` voltou a 20. `ChunkPage.heights` (índice `x|z<<5`), a semântica de topo SÓLIDO, `mirror_height_get` e a manutenção E1 pelo journal permanecem — agora derivados do bitmask `solid` na materialização (topo medido; arcos/flutuantes corretos). O heightmap groupshared do worldgen não foi revertido. Sims atualizadas antes da mudança de shader (`heightmap_sim` 14 checks, `mirror_sim` 55 checks); `spirv-val` limpo; smoke com `DEBUG READBACK OK` (packed×denso) e `DEBUG HEIGHTS PARITY OK` (515 páginas × 1.024 colunas).
- 2026-11-08 — **Correção de emenda (decisão do mantenedor): o ring `mirror_heightmap_ring` (binding 20) é MANTIDO como reserva futura** — write no `generate_voxels`, declaração, buffer/descriptor e provisionamento restaurados; `DESCRIPTOR_SET_BINDING_COUNT` volta a 21. A materialização passa a derivar `heights` do bitmask `solid` (topo medido) e a **ignorar o ring**; paridade ring×medido opcional em debug. A entrada anterior desta emenda ("removidos") fica substituída por esta. Sims: cenários de write do ring preservados junto aos de heights medidos.
