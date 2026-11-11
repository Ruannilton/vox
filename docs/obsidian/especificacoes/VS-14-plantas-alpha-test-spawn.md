---
id: VS-14
titulo: Plantas — alpha-test e spawn determinístico
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-12
bloqueada_por: []
requisitos: [REQ-PLT-01, REQ-PLT-02, REQ-PLT-03, REQ-PLT-04, REQ-PLT-05, REQ-PLT-06, REQ-SIM-11]
ultima_atualizacao: 2026-11-08
---

# VS-14 — Plantas: alpha-test e spawn determinístico

## Objetivo

Fechar o backlog B6: blocos com transparência (flag `transparente`) passam por **alpha-test** no fragment (descarte de fragmentos com albedo.a < 0,5) — folhagem renderiza recortada, sem blending nem ordenação, pipeline inalterada (`CULL_MODE_NONE` permanece). Junto: o **bloco planta** (id 4) entra no registro via JSON de assets — malha em X (duas quads cruzadas), textura RGBA com recorte — com spawn no worldgen decidido por **hash determinístico da coluna (x,z)**, probabilidade de 10%.

## Rastreabilidade

- GOAL: backlog **B6** (arquitetura §9) + pedido do mantenedor (2026-11-07): bloco planta em X no registro, spawn por número "aleatório" determinístico por coordenada (x,z), 10% de probabilidade.
- Referência: `shade_voxel`/`sample_triplanar_albedo` (`render.slang`), `BlockDefinition.flags` bit 0 = transparente (`common.slang`/`voxel_types.odin`), assets JSON (VS-12: meshes/textures/blocks, validador `assets_check.py`), worldgen `generate_voxels` (`voxel.slang` — heightmap da VS-13), template built-in de planta (cruz) como referência de formato.
- Decisões: [[ADR-P1-plantas-alpha-test-spawn|ADR-P1]] (**bloqueia a aprovação desta spec**).
- Fundação: VS-11 (UVs — a planta amostra por UV), VS-12 (assets), VS-13 (heightmap por coluna no generate e no mirror).

## Requisitos

### Alpha-test (B6)

- **REQ-PLT-01** — Blocos com `BlockDefinition.flags` bit 0 (transparente) descartam fragmentos com `albedo.a < 0.5` no `shade_voxel`, **após a amostragem** (o caminho UV da VS-11 e o fallback triplanar convergem na mesma cor/amostra). O JSON de assets ganha campo opcional `"transparent": true` por bloco (boolean; tipo errado → erro de schema no validador e no loader). Cutout opaco: sem blending, sem ordenação de transparência, `CULL_MODE_NONE` inalterado (as duas faces das cruzes em X continuam necessárias). Limiar 0.5 constante no shader, documentado.

### Bloco e malha planta

- **REQ-PLT-02** — `assets/blocks.json` define: mesh `"planta"` em X — duas quads cruzadas em 45° (4 triângulos, `cull_tags` 7 = nunca culpado, UVs [0,1]² por quad), textura `"planta"` (PNG RGBA com recorte: lâminas verdes opacas em fundo alpha 0 — gerada em `tools/sim/gen_example_textures.py`) e bloco **id 4** `{name: "planta", mesh: "planta", texture: "planta", transparent: true, solid: false}` (emenda 2026-11-07: `solid: false`). Uma malha reaproveitável; orçamento mesh shader intacto (4 ≤ 24 triângulos; regra 5 do AGENTS.md).

### Spawn determinístico

- **REQ-PLT-03** — O worldgen decide por coluna, junto ao cálculo da altura (VS-13): se `hash_u32(world_x, world_z) % 1000 < 100` (10%), o voxel `y = altura+1` da coluna recebe o id da planta (em vez de ar). Hash determinístico documentado (wang hash sobre os 32 bits de x e z) — puro função da coordenada mundial, consistente entre chunks vizinhos (a planta na fronteira vertical nasce igual nos dois chunks). Voxels com `y != altura+1` inalterados; coluna sem grama na superfície não gera planta; `altura+1` fora do chunk → sem planta. Constantes no shader: probabilidade 10% (percentual inteiro 0–100) e limiar alpha 0.5. A planta **ocupa o voxel** (bit de ocupação do brick setado — o pack, a fila e a renderização da geometria em X são inalterados) mas **não é sólida** (REQ-PLT-06).

### Heightmap e contrato

- **REQ-PLT-04** — O heightmap é do **topo sólido** da coluna (VS-13): colunas com planta exportam `heights = altura` (emenda 2026-11-07 — antes `altura+1`; a planta não é sólida e não move a altura). O `mirror_height_get` reporta o topo sólido e o journal do E1 só sobe/rescan para blocos **sólidos** — colocar/remover planta acima da superfície é no-op para o heightmap; remover o topo sólido rescan para o novo topo sólido.
- **REQ-PLT-05** — Contrato do worldgen passa a exigir **ids 1–4** (1 grama, 2 terra, 3 pedra, 4 planta): validador (`assets_check.py`) e loader rejeitam com mensagem listando o que falta; **fallback sem assets** ganha id 4 no registry built-in (template cruz built-in 2 + camada 4 da paleta com verde) para o worldgen nunca emitir id sem definição. O registry built-in marca o id 4 como **non-solid** (bit 1) em paridade com o JSON.
- **REQ-PLT-06** (emenda 2026-11-07) — **Solidez é propriedade do tipo de bloco**, distinta da ocupação do voxel: `BlockDefinition.flags` ganha bit 1 `BLOCK_DEFINITION_FLAG_NON_SOLID` (= 2) (`common.slang`/`voxel_types.odin`); o JSON ganha campo opcional `"solid": false` (default `true`; tipo errado → erro de schema no validador e no loader — campo separado de `"transparent"`: vidro futuro será transparente mas sólido). Solidez alimenta: (a) o **culling de faces de vizinhos** — `is_voxel_solid` (B2) decodifica o id do voxel ocupado (`read_block_identifier`) e exclui o bit NON_SOLID; (b) a **oclusão de bricks** — `is_brick_occluded` só cull um brick `occupancy 0xFFFFFFFF` se os 32 voxels forem sólidos (idem os 6 vizinhos); (c) o **bitmask `solid` do mirror** (`mirror_page_apply`/materialização) — `solid = id != 0 && !NON_SOLID`, consultando o registry carregado (fallback built-in: ids 1..3 sólidos, 4 não). A **ocupação não muda**: plantas continuam setando o bit de ocupação (o brick não perde itens na fila e a geometria em X renderiza — template + `cull_tags` 7 intactos).

### Simulação

- **REQ-SIM-11** — Antes da integração: `heightmap_sim` estendido (colunas com planta → export do topo sólido `altura` — emenda 2026-11-07; decisão por hash com o mesmo algoritmo em Python — espelho, não precisa da FastNoiseLite), `render_sim` com o template X (orçamento, tags 7, UVs, planta não-sólida) e `assets_check.py` com os campos `transparent`/`solid` e a exigência do id 4. Checks antigos verdes.

## Escopo

- Fragment: discard por alpha-test condicional à flag; JSON `transparent`; textura planta RGBA.
- Worldgen: hash por coluna, spawn da planta, heightmap com planta (groupshared + export).
- Assets: mesh/textura/bloco planta no `assets/blocks.json` + gerador de textura; contrato ids 1–4 (validador, loader, fallback built-in).
- Sims estendidas (REQ-SIM-11) e docs (VS-12 emenda do campo `transparent`; arquitetura §9 — B6 fecha; manual; tracking; backlog).

## Não escopo

- Blending/translucidez real (vidro, água) e ordenação de transparência — backlog novo.
- AA de alpha-to-coverage (depende de MSAA) — backlog.
- Probabilidade/config do spawn via `vox.ini` (hoje constante 10% no shader) — backlog.
- Comportamento de planta em gameplay (crescimento, colheita) e save.

## Dependências

- [[VS-12-assets-json|VS-12]] concluída e verificada (assets/JSON/validador); VS-11/VS-13 integradas.
- [[ADR-P1-plantas-alpha-test-spawn|ADR-P1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| JSON de bloco | + `"transparent": true` (opcional) | mapeia para `BlockDefinition.flags` bit 0 |
| Fragment | `if (transparente && albedo.a < 0.5) discard;` | após amostragem; pipeline inalterada |
| Worldgen | hash wang(x,z) % 1000 < 100 → planta em `altura+1` | constante de probabilidade 10% no shader |
| Heightmap | topo SÓLIDO da coluna exporta `altura` (emenda 2026-11-07; planta não move a altura) | semântica VS-13 preservada (topo sólido) |
| JSON de bloco | + `"solid": false` (opcional, default true) | mapeia para `BlockDefinition.flags` bit 1 (NON_SOLID) — separado de `transparent` |
| Contrato worldgen | ids 1–4 obrigatórios no JSON | fallback built-in cobre id 4 |

## Cenários

### Cenário de sucesso — campo com plantas recortadas

- **Dado** o `assets/blocks.json` com a planta e a cena padrão.
- **Quando** frames avançam com a câmera sobre o terreno.
- **Então** ~10% das colunas de grama exibem plantas em X com recorte alpha (céu visível entre as lâminas), folhagem **não** renderiza opaca, zero erros de validation.

### Determinismo

- **Dado** duas execuções da mesma pose.
- **Quando** o mundo materializa.
- **Então** a distribuição de plantas é idêntica (capturas e readback denso iguais); o mirror reporta `heights = altura` nas colunas com planta (topo sólido — emenda 2026-11-07); edições de remover/colocar planta funcionam pelo E1 com feedback normal.

### Falhas de asset

- **Dado** JSON sem o id 4, com `"transparent": "sim"` (tipo errado) ou sem a textura da planta.
- **Quando** o startup roda.
- **Então** erro fatal específico (lista ids faltantes / tipo errado com o bloco / textura ausente), exit ≠ 0.

## Critérios de aceitação

| ID | Critério verifiable | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-14-AC-01 | Sims e validador verdes com os cenários novos (template X, hash/spawn, heightmap com planta, `transparent`, id 4) | `heightmap_sim`, `render_sim`, `assets_check.py` | **Verificado (2026-11-07):** `heightmap_sim` 12 checks (novo cenário spawn: hash puro função de (x,z), taxa 10,0% em 65.536 colunas, id 4 em altura+1, coluna sem spawn sem id 4, heights = altura+1, altura+1 fora do chunk não nasce), `render_sim` 2.919 checks (template X: 4 triângulos ≤ 24, tags 7, UVs [0,1]², brick cheio de plantas dentro de 256v/192t; cutout: alpha 0,4/0,0 descartados, 0,5 mantido, opaco nunca descarta, flags sem bit 0 não disparam), `assets_check` OK no JSON real + bateria `assets_battery` 100% (casos novos: `id4_ausente`, `transparent_tipo_errado` ("deve ser booleano"), `textura_planta_ausente`); antigos verdes: `pack_sim` 968, `edit_sim` 118, `mirror_sim` 44, `streaming_sim`/`frontier_test` 0 falhas, `events_check` OK na sessão |
| VS-14-AC-02 | Plantas recortadas visuais em ~10% das colunas de grama; zero erros de validation; folhagem não opaca | Smoke com capturas (contagem aproximada de plantas por readback denso amostrado) | **Verificado (2026-11-07)** com instrumentação temporária de contagem (revertida): 515 páginas MATERIALIZED, 82.944 colunas com grama no topo, **8.303 plantas = 10,01%** — identidade exata com a expectativa do wang hash computada em Odin (0 divergências GPU×CPU nos dois sentidos); heights das colunas com planta = altura+1 (0 erros); `debug_mirror_parity` OK em chunk com plantas e `debug_readback_validate` OK (packed == mirror denso); smoke final do build limpo: **zero erros de validation** (único ERROR do log = rejeição pré-existente do dispositivo sem mesh shader). **Ressalva de captura:** as capturas GDI (`shot_vs14_runA/runB.png`) saem azul-tela neste ambiente — o compositor GDI não reflete o swapchain Vulkan (padrão idêntico nas evidências VS-11/12/13); o recorte em si é evidenciado por textura RGBA com fundo alpha 0 + discard condicional no fragment (`spirv-val` limpo) + ausência total de erros de validation |
| VS-14-AC-03 | Determinismo (duas execuções iguais), mirror heights confere (altura+1), edição de planta via replay com feedback E1 | Duas sessões replay idênticas + verificação via log/readback | **Verificado (2026-11-07):** duas sessões `vs14_session.jsonl` idênticas (`--exit-after-replay`) produziram contagens **bit a bit iguais** (8.303 plantas / 82.944 gramas / 10,01% / 0 divergências), pose final e journal E1 idênticos (`applied=4 noop=0 rejected=0` — AddBlock/RemoveBlock de planta id 4 com feedback normal); capturas pareadas comparadas pixel a pixel: **região central 0 bytes diferentes** (as diferenças residuais ficam nas bordas, contaminação de janelas do desktop durante o GDI — mesmo padrão de contaminação registrado na VS-13); heights das colunas com planta conferem altura+1 em todas as páginas (0 mismatches em colunas sólidas) |

## Tarefas da especificação

- [x] Vincular o backlog B6 e o pedido do mantenedor (bloco planta, spawn por hash (x,z), 10%).
- [x] Formalizar o alpha-test cutout, o spawn por coluna e o contrato ids 1–4.
- [x] Cobrir sucesso, determinismo e falhas de asset; registrar não-escopos (blending, A2C, config).
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-P1 e obter aprovação da spec. — ADR-P1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-07.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-P1. Cada tarefa referencia requisitos e critérios de aceitação.

1. ~~**VS-14-IMPL-01 — Simulação e validador** (REQ-SIM-11; AC-01).~~ **Concluída 2026-11-07** (antes dos shaders): `heightmap_sim` +12 checks (cenário spawn determinístico), `render_sim` +13 (template X + cutout), `assets_check` (`transparent`, ids 1..4) + bateria com 3 casos novos.
2. ~~**VS-14-IMPL-02 — Assets da planta** (REQ-PLT-02, REQ-PLT-05; AC-01).~~ **Concluída 2026-11-07**: mesh/textura/bloco no JSON, gerador da PNG RGBA com recorte, campo `transparent` no loader (→ `BlockDefinition.flags` bit 0), contrato ids 1..4 no loader e fallback built-in (id 4 = template cruz 2 + camada de paleta 4 verde).
3. ~~**VS-14-IMPL-03 — Alpha-test** (REQ-PLT-01; AC-02).~~ **Concluída 2026-11-07**: discard condicional à flag no `shade_voxel` após a amostragem (UV e triplanar convergem em `float4`); `spirv-val` limpo; pipeline inalterada (`CULL_MODE_NONE`).
4. ~~**VS-14-IMPL-04 — Spawn no worldgen** (REQ-PLT-03/04; AC-02, AC-03).~~ **Concluída 2026-11-07**: wang hash por coluna (`wang(wang(x) ^ z) % 1000 < 100`), planta em `altura+1`, heightmap exporta `altura+1`; `spirv-val` limpo.
5. ~~**VS-14-IMPL-05 — Evidências e fechamento** (AC-01..03).~~ **Concluída 2026-11-07**: sims, smoke com capturas, sessões replay de determinismo e edição, docs (arquitetura §9 fecha B6; VS-12 emenda; tracking; backlog) e commit com o nome da spec.

## Questões abertas

- Probabilidade de 10% e limiar 0.5 são constantes de shader nesta fatia; virarem config (INI/JSON) é backlog. Não bloqueia a aprovação.
- A malha em X usa duas quads a 45° (formato da planta built-in); variações (3 quads, altura < 1) são novos assets sem mudança de código. Não bloqueia a aprovação.

## Histórico

- 2026-11-07 — Rascunho elaborado a partir do backlog B6 + pedido do mantenedor (bloco planta em X, spawn determinístico por (x,z), 10%); ADR-P1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-07 — **ADR-P1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-14-IMPL-01..05 destravadas.
- 2026-11-07 — **Implementação concluída (IMPL-01..05) e validação verificada (AC-01, AC-02, AC-03).** Módulos: `render.slang` (`shade_voxel`: alpha-test cutout — blocos com `BlockDefinition.flags` bit 0 descartam fragmentos com `albedo.a < 0.5` após a amostragem; `sample_triplanar_albedo` passa a devolver `float4` para as duas rotas convergirem na mesma amostra; pipeline inalterada, `CULL_MODE_NONE` permanece); `common.slang` + `voxel_types.odin` (`BLOCK_DEFINITION_FLAG_TRANSPARENT = 1`); `voxel.slang` (`generate_voxels`: `wang_hash`/`plant_spawns` — `wang(wang(uint(x)) ^ uint(z)) % 1000 < 100` = 10%; voxel `y == altura+1` da coluna com spawn recebe id 4, altura+1 fora do chunk nunca casa com y de thread; threads de coluna exportam `altura+1` no heightmap quando a planta cabe no chunk); `assets/blocks.json` (mesh "planta" em X — 8 vértices, 4 triângulos, `cull_tags` 7, UVs [0,1]²; textura "planta"; bloco id 4 com `transparent: true`); `tools/sim/gen_example_textures.py` (PNG 16×16 RGBA, lâminas verdes opacas em fundo alpha 0); `voxel_assets.odin` (campo `transparent` — tipo errado falha o unmarshal com exit ≠ 0; `flags |= BLOCK_DEFINITION_FLAG_TRANSPARENT`; contrato ids 1..4 na mensagem fatal); `voxel_gpu.odin` (fallback sem assets: id 4 = template cruz built-in 2 + camada de paleta 4 verde com alpha-test; paleta ganha cor na camada 4). Ferramentas: `heightmap_sim.py` (12 checks; wang hash espelhado em Python, mock), `render_sim.py` (2.919 checks; template X e cutout), `assets_check.py` + `assets_battery.py` (`transparent` com tipo errado, exigência do id 4, textura ausente). **AC-01:** sims e validador verdes conforme tabela. **AC-02:** smoke com instrumentação temporária de contagem (revertida): 8.303 plantas em 82.944 colunas de grama (**10,01%**, identidade exata com a expectativa do hash em Odin, 0 divergências nos dois sentidos), heights = altura+1 (0 erros), `debug_mirror_parity`/`debug_readback_validate` OK, build limpo com zero erros de validation; ressalva: capturas GDI saem azul-tela neste ambiente (compositor não reflete o swapchain Vulkan — padrão VS-11/12/13). **AC-03:** duas sessões replay idênticas com contagens bit a bit iguais, capturas com região central idêntica (0 bytes; diferenças só nas bordas por contaminação de desktop), edição de planta via replay com feedback E1 normal (applied=4). **Achado na validação (backlog BLK-32):** chunks abaixo de y=0 saem ar no denso (comparador `int`×`uint` pré-existente do generate) mas o export do heightmap grava `min(altura-base, 31)` — sem impacto em plantas/ACs; pré-existente da VS-13. Ressalvas: (1) o único ERROR do log do smoke é a rejeição pré-existente do dispositivo Intel sem `VK_EXT_mesh_shader`; (2) a escolha do chunk para o `debug_mirror_parity` varia entre runs (ordem de iteração do mapa; contagens idênticas); (3) não-escopos mantidos: blending (BLK-29), alpha-to-coverage (BLK-30), probabilidade configurável (BLK-31), gameplay de plantas/save.
- 2026-11-07 — **Correção pós-validação (emenda): plantas não-sólidas — ocupa-voxel × sólido.** Defeito reportado pelo mantenedor na validação da VS-14: blocos de planta estavam sendo tratados como sólidos. Causa: o motor conflacionava "ocupa voxel" (ocupação ≠ ar) com "sólido" — `is_voxel_solid` (culling B2), `is_brick_occluded`, o bitmask `solid` do mirror e o heightmap tratavam qualquer voxel ocupado como sólido. A correção distingue as noções: a **ocupação continua contendo plantas** (o brick não perde itens na fila de trabalho e a geometria em X renderiza — pack, work queue, push constants e edição GPU intocados) e a **solidez vira propriedade do tipo de bloco** (REQ-PLT-06: `BlockDefinition.flags` bit 1 `NON_SOLID`; JSON `"solid": false`; planta id 4 marcada no `assets/blocks.json` e no fallback built-in). Efeitos: (1) face culling — bloco sólido adjacente a planta emite a face voltada para ela (`is_voxel_solid` decodifica o id do vizinho ocupado via `read_block_identifier`); (2) oclusão — brick `0xFFFFFFFF` de plantas empilhadas por edição não é mais culado (`brick_voxels_all_solid` decodifica os 32 ids — só roda em brick cheio); (3) mirror — bitmask `solid` exclui planta (`block_is_solid` no `voxel_assets.odin`, com regra built-in no fallback) e o journal do E1 só move o `heights` para sólidos (worldgen passa a exportar `altura`, não `altura+1`; colocar/remover planta acima da superfície é no-op; `mirror_height_get` reflete o topo sólido). Sims antes dos shaders (workflow AGENTS.md): `render_sim` +cenário planta não-sólida (face voltada à planta, brick cheio de plantas não ocluso, controle com cubos), `heightmap_sim` (export `altura`; topo sólido exclui planta), `mirror_sim` +cenário (bitmask exclui planta, planta não move heights, planta substituindo o topo rescan para baixo), `assets_check`/`assets_battery` (`solid` tipo errado). Verificação: `render_sim` 2.926, `heightmap_sim` 13, `mirror_sim` 53, `pack_sim`/`edit_sim`/`streaming_sim`/`frontier_test`/`events_check` verdes, bateria `assets_battery` 100%; `slangc` ×3 + `spirv-val` + `odin build` limpos; smoke de `bin/` (`--replay vs14_session.jsonl --exit-after-replay`, instrumentação temporária revertida): **zero erros de validation**, 8 eventos despachados, `applied=4 noop=0 rejected=0`, `debug_readback_validate` OK (templates == assets JSON; packed == mirror denso no chunk amostrado); varredura temporária do mirror: **515 páginas MATERIALIZED, 81 com planta, 8.303 plantas — solid_err=0 (bitmask sólido exclui planta), height_err=0 (heights == topo sólido em todas as colunas)**; heights inalterado após AddBlock/RemoveBlock de planta no replay. Spec permanece **verificada** (emenda, não retrabalho de AC); tracking inalterado.
- 2026-11-08 — **Correção de performance: ocupação de solidez O(1).** A emenda anterior eliminou o erro semântico, mas introduziu decode de planos+paleta+registry nos seis testes de vizinho por voxel e nos 32×7 testes de bricks cheios; Tracy no replay de horizonte mostrou `draw_mesh` **mediana 48,865 ms / máximo 129,028 ms / último 96,519 ms**. Fix precedido por sim: `render_sim` 2.930 e `pack_sim` 1.077 checks. O occupancy pool cresce 1.090→2.114 words/chunk, com `SOLID_WORD_BASE=1090`; pack fase A grava o bit sólido junto à ocupação, E1 mantém set/clear por `NON_SOLID`, e mesh/builder consultam um bit ou `==0xFFFFFFFF`, sem decode. Ocupação/coarse/EMPTY e work queue/push constants inalterados. **Depois (mesmo replay):** `draw_mesh` **mediana 0,286 ms / máximo 0,436 ms / último 0,322 ms** (682 amostras, vs 213 no baseline). `spirv-val` limpo ×3; builds default/Tracy e capture sem falhas; smoke `--full-teardown` zero VUIDs/threading; readback packed×mirror estendido para solid words OK (32.768 voxels), mirror parity OK; replay de planta E1 `applied=1 noop=0 rejected=0`; `mirror_sim=53`, `heightmap_sim=13`. Provisionamento default 226.803.208 bytes, validação de máquina OK; o INI vision=20 não estava presente no workspace.
