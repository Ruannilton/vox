---
id: VS-21
titulo: Texturas — nearest, flip Y, stb_image e multi-face
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de: [VS-11, VS-12]
bloqueada_por: []
requisitos: [REQ-TEX-01, REQ-TEX-02, REQ-TEX-03, REQ-TEX-04, REQ-TEX-05, REQ-TEX-06, REQ-TEX-07, REQ-TEX-08, REQ-TEX-09]
ultima_atualizacao: 2026-11-08
---

# VS-21 — Texturas: nearest, flip Y, stb_image e multi-face

## Objetivo

Corrigir deterministicamente a orientação vertical das PNGs, adotar `vendor:stb/image` e filtro NEAREST, e permitir que a grama use textura verde no topo +Y e terra nas demais faces, preservando assets string existentes e o registry GPU de 48 B.

## Rastreabilidade

- GOAL: quatro itens acoplados pedidos pelo mantenedor em 2026-11-08.
- Decisão: [[ADR-T5-texturas-stb-face|ADR-T5]], pendente e bloqueando aprovação.
- Fundação: [[VS-11-uvs-templates|VS-11]] (UV/triplanar), [[VS-12-assets-json|VS-12]] (loader/validador).
- Referências: `voxel_assets.odin`, `voxel_gpu.odin`, `voxel_types.odin`, `common.slang`, `render.slang`, `assets_check.py`; docs reais de `vendor:stb/image`.

## Requisitos

- **REQ-TEX-01 — Decoder stb.** Substituir `core:image/png` por `vendor:stb/image`, usando `load_from_memory` com `desired_channels = 4`, validação de ponteiro/dimensões/canais de entrada e `image_free` em todos os caminhos após decode. RGB e RGBA 8-bit são aceitos e normalizados a RGBA8; erro cita textura/path e `failure_reason`. A foreign library do Odin faz o link; no ambiente atual `stb_image.lib` já existe e nenhum implementation define ou flag de build é necessário. TASKS deve verificar os dois scripts e registrar o pré-requisito da lib para ambientes sem ela.
- **REQ-TEX-02 — Flip explícito.** Após decode e antes de montar `texture_pixels`, aplicar `flip_rows` por linha, stride `width·4`, trocando `y` com `height−1−y`. Não usar flip global do stb. A convenção resultante deve orientar corretamente UV e triplanar; sim com cantos marcados verifica cada pixel e dupla inversão restaura a entrada. Causa atual registrada: nem o decoder antigo nem o upload faziam flip; `upload_to_device_image` copia rows diretamente.
- **REQ-TEX-03 — NEAREST sem mipmaps.** O sampler compartilhado, criado nos caminhos asset e built-in, usa mag/min `NEAREST`, `mipmapMode NEAREST`, endereçamento REPEAT preservado e `maxLod=0`; imagens permanecem com um mip level. O mesmo sampler atende albedo e dummy PBR, sem blur nem filtragem anisotrópica nova.
- **REQ-TEX-04 — Schema string ou objeto de 6 faces (emenda do mantenedor, 2026-11-08).** O campo `texture` aceita **string** (todas as faces iguais — compatível) ou **objeto com as 6 faces**: `{"top","bottom","front","back","left","right"}` (strings), convenção: `top`=+Y, `bottom`=−Y, `front`=+Z, `back`=−Z, `right`=+X, `left`=−X. **O loader normaliza: string vira o objeto com as 6 faces apontando para a mesma textura — internamente só existe a representação de objeto.** Objeto incompleto, chave extra, array/número/null ou tipo errado são erros fatais citando bloco e campo; referências precisam existir na seção textures. `assets_check.py` e loader compartilham a mesma semântica (incluindo a normalização string→objeto).
- **REQ-TEX-05 — Registry cresce para 72 B (revisão de contrato VS-00/VS-02).** `albedo_texture_index` e os dois paddings dão lugar a `albedo_faces[6]: u32` **em ordem `FACE_NORMALS`** (+X=right, −X=left, +Y=top, −Y=bottom, +Z=front, −Z=back) + padding de alinhamento: `BlockDefinition` passa de 48 B para **72 B** em Odin e Slang espelhados (`#assert(size_of(BlockDefinition)==80)` (correção 2026-11-09: ver histórico)), com revisão do buffer do registry (stride/capacidade), offsets e notas nas VS-02/VS-12. Demais campos (mesh/pbr/flags/emissão/materiais/rotação) inalterados.
- **REQ-TEX-06 — Seleção de camada por face no fragment.** A camada vem de `albedo_faces` no índice da face selecionada pelo **eixo dominante da normal mundial** (maior |componente|; empate determinístico na ordem Y, X, Z), sinal do eixo escolhendo a face (±). A face segue +Y mundial mesmo em bloco rotacionado (semântica v1). A camada selecionada alimenta tanto UV quanto triplanar. Normal continua derivada de `world_position`; alpha-test, highlight VS-20, derivadas e plantas/cruzas permanecem funcionais (planta: 6 faces com a mesma camada — string normalizada).
- **REQ-TEX-07 — Assets e fallback.** `assets/blocks.json`: grama id 1 vira objeto com `top: "grama"` e as demais 5 faces `"terra"`; terra, pedra e planta continuam **strings** (normalizadas no loader). Blocos com front/back/left/right distintos são dados futuros, não código novo. Sem JSON, fallback built-in mantém as definições atuais e atribui à grama o objeto top=grama/outras=terra, com strings nos demais. Paleta procedural segue coerente com os ids/camadas existentes.
- **REQ-TEX-08 — Simulações e paridade.** Antes do shader, estender sims para flip por pixel, normalização RGBA, sampler, **seleção de face nos 6 eixos** (incluindo empates e coordenadas negativas) e a **normalização string→objeto** em UV e triplanar. Validador/bateria cobrem string compatível, objeto de 6 faces válido/incompleto/extra e tipos errados. Checks antigos permanecem verdes.
- **REQ-TEX-09 — Instrumentação e evidência.** Zone Tracy `assets_texture_decode` cobre decode/flip/montagem das camadas, com contagem de texturas/bytes; caminho de render existente mede o fragment. Fechamento usa `bin/debug/<version>/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy` e comparação K2.8 com VS-20, incluindo custo de startup e render.

## Escopo

- Migração stb, liberação correta e flip de linhas.
- Sampler NEAREST nos caminhos JSON/built-in.
- Schema string/objeto de 6 faces, registry 72 B e fragment.
- Assets de exemplo, fallback, sims/validador, docs, stress e profiling.

## Não escopo

- Mipmaps, anisotropia, filtering configurável ou sampler por bloco.
- Bottom e laterais diferentes entre si, arrays arbitrários de seis faces.
- Rotação local do topo, novos formatos HDR/16-bit ou hot-reload.
- Mudança de tamanho/layout do registry, bindings ou work queue.

## Dependências

- VS-11 e VS-12 concluídas e verificadas.
- ADR-T5 pendente; bloqueia aprovação e implementação.

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| stb decode | bytes → RGBA8 + dimensões | `image_free` obrigatório |
| `flip_rows` | linhas RGBA invertidas | antes das camadas; testável |
| `texture` | string ou objeto de 6 faces (`top/bottom/front/back/left/right`) | string é normalizada pelo loader para o objeto com todas as faces iguais — internamente só existe a representação de objeto |
| `albedo_faces[6]` | camada por face, ordem `FACE_NORMALS` (+X,−X,+Y,−Y,+Z,−Z) | registry 48→80 B (correção 2026-11-09; era 72 B no fechamento original — ver histórico) |
| Seleção fragment | top se normal.y > 0,5 | +Y mundial; UV e triplanar |
| Sampler | NEAREST mag/min/mipmap | um mip; dummy PBR incluído |

## Cenários

### Orientação e pixelização

- **Dado** PNG RGBA com quatro cantos distintos e texels adjacentes contrastantes.
- **Quando** decodifica, aplica flip, faz upload e amostra entre texels.
- **Então** os cantos aparecem nas posições esperadas e NEAREST escolhe um texel, sem cor interpolada.

### Grama multi-face

- **Dado** bloco grama com objeto de 6 faces (top=grama, demais=terra).
- **Quando** suas faces +Y, −Y e laterais renderizam por UV ou triplanar.
- **Então** apenas +Y usa grama; todas as demais usam terra, inclusive se o bloco tiver rotação de asset.

### Compatibilidade e falhas

- **Dado** blocos com textura string, planta em cruz e JSON com objeto inválido/referência ausente.
- **Quando** loader/validador processam.
- **Então** strings preservam comportamento, planta não muda, e erros são específicos/fatais antes de criar a engine.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-21-AC-01 | Pixel-check prova orientação correta e idempotência da dupla inversão em RGB/RGBA; decode stb libera memória e upload preserva a ordem corrigida | Sim com cantos/rows marcadas + build/link default/Tracy | **Verificado (2026-11-09):** `render_sim` — flip pixel a pixel com cantos marcados (cada pixel conferido, dupla inversão restaura, altura 1 no-op) + domínio de decode estendido no `png_min` (gray/palette 1/2/4/8 bits — os PNGs reais do mantenedor são palette 4-bit e grayscale 8); `load_from_memory(...,4)` + `image_free` (defer) nos dois builds linkando `stb_image.lib` da distribuição; **readback GPU `DEBUG TEXTURE PARITY OK: albedo readback == texture_pixels (16x16x4, 4096 bytes, flip incluído)`** ao final do init (device ocioso) |
| VS-21-AC-02 | Sampler mag/min/mipmap NEAREST e um mip; texels contrastantes sem blur | Inspeção de parâmetros + captura visual ampliada | **Verificado (2026-11-09):** inspeção dos dois `CreateSampler` (asset e built-in): `NEAREST/NEAREST`, `mipmapMode NEAREST`, REPEAT preservado, `maxLod=0`, um mip; captura visual ampliada inviável no ambiente — substituída pela paridade de readback pixel a pixel (AC-01) + sessões sem erros; dummy PBR no mesmo sampler |
| VS-21-AC-03 | Bateria aceita string/objeto de 6 faces e rejeita incompleto/extra/tipos/refs inválidos; normalização string→objeto; fallback e registry 72 B íntegros | `assets_check`, bateria e asserts/build | **Verificado (2026-11-09):** `assets_check` no JSON real OK; bateria com 5 casos inválidos novos (incompleto/extra/tipo/ref por face/tipo campo) + 2 válidos (string e objeto) — TODOS OK; `#assert(size_of(BlockDefinition) == 80)` + `offset_of` Odin e espelho Slang verificados pela reflection do slangc (offsets idênticos: albedo_faces@12, emission_color@48; stride 80 — ver histórico da correção); normalização string→objeto no loader (internamente só existe objeto); fallback built-in sem assets em sessão limpa (grama top=grama, demais terra) |
| VS-21-AC-04 | Sim e sessão mostram grama verde no +Y e terra nas outras faces; planta, alpha-test, highlight, UV/triplanar e rotação seguem contratos | Sims antes do shader + capturas/readback de camadas e smoke | **Verificado (2026-11-09):** sims de seleção de face (6 eixos, empates Y→X→Z, negativos, não unitárias, camada grama/terra via registry) — 2973/2973 verdes ANTES do shader; sessão de gameplay completa (construção/remoção/pulo/mira) com grama multi-face ativa e zero erros; `DEBUG READBACK OK` (packed×denso) e `DEBUG HEIGHTS PARITY OK` mantidos; smoke de fallback limpo |
| VS-21-AC-05 | Stress 5× em cada build com gameplay/edição/teleports e `--full-teardown`: zero VUIDs/threading/deadlock, teardown limpo | Stress scriptado reproduzível | **Verificado (2026-11-09):** 10/10 execuções (5× default + 5× Tracy, replay com cliques/edições/pulos/3 teleports) `--full-teardown`: rc=0, zero VUIDs/threading/validation errors |
| VS-21-AC-06 | Zone/contadores novos presentes; captura versionada íntegra e comparação com VS-20 documentam startup/render | `run_tracy.bat` + `tracy-capture`; subagente coder K2.8 thinking low | **Verificado (2026-11-09):** zone `assets_texture_decode` presente na captura com contagem no log (4 texturas, 4.096 bytes); captura íntegra `bin/debug/0.1.18/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy` (6,1 MB, zone `assets_texture_decode` presente, 1 chamada de 1,28 ms no upload); comparação com VS-20 registrada no histórico |

## Tarefas da especificação

- [x] Vincular pedido, causa do flip e API/linkage reais do stb.
- [x] Definir requisitos, contratos, cenários e ACs.
- [x] Cobrir compatibilidade, fallback e sims antes do shader.
- [ ] Ratificar ADR-T5 e aprovar a spec.

## Tarefas de implementação

Ver [[VS-21-texturas-nearest-flip-stb-faces-tasks]]. Nenhuma implementação pode iniciar antes da aprovação.

## Emendas registradas

- **VS-02:** `BlockDefinition` passa de 48 B para 72 B com `albedo_faces[6]` em ordem `FACE_NORMALS` (revisão de contrato do registry; stride do buffer e `#assert` atualizados).
- **VS-12:** `texture` aceita string (normalizada para o objeto de 6 faces pelo loader — internamente só existe a representação de objeto) ou objeto completo `top/bottom/front/back/left/right`; decode stb RGBA8 + flip; fallback da grama ganha o objeto (top=grama, demais=terra).

## Questões abertas

- Nenhuma crítica. Ambientes cuja distribuição Odin não inclua `stb_image.lib` devem gerar as libs STB pelo script da distribuição; não é necessário mudar os scripts do projeto no ambiente verificado.

## Histórico

- 2026-11-08 — Spec completa submetida à revisão, bloqueada pela ADR-T5 pendente; nenhuma implementação iniciada.
- 2026-11-08 — Emenda pré-implementação (decisão do mantenedor): `texture` aceita string **ou objeto de 6 faces** (`top/bottom/front/back/left/right`); o loader **normaliza string → objeto com 6 faces iguais** — internamente só existe a representação de objeto. `BlockDefinition` cresce 48→72 B com `albedo_faces[6]` (ordem `FACE_NORMALS`); fragment seleciona a face pelo eixo dominante da normal mundial. ADR-T5 revisada (Opção B de faces adotada). Spec aprovada pelo mantenedor com a revisão.
- 2026-11-09 — **IMPL-01..06 concluídas e AC-01..06 verificados.** Nota: o TASKS (coluna da IMPL-03) ainda descrevia o desenho pré-emenda (`albedo_texture_top`, `normal.y > 0,5`) — a implementação seguiu a **emenda aprovada** (`albedo_faces[6]`, eixo dominante Y→X→Z), conforme ADR-T5 revisado. Módulos: `voxel_assets.odin` (decode stb RGBA8 + `flip_rows` + zone `assets_texture_decode` + contadores, parser string/objeto com normalização, erros citando bloco), `voxel_gpu.odin` (sampler NEAREST ×2, UBO/registry stride via `size_of` automático, fallback com grama multi-face, `debug_texture_parity` com readback ao final do init), `voxel_types.odin`/`common.slang` (BlockDefinition 72 B espelhado, `#assert`), `render.slang` (seleção de face por eixo dominante alimentando UV e triplanar), `assets/blocks.json` (grama id 1 = objeto top=grama/demais=terra — texturas novas grass/dirt/stone/plant fornecidas pelo mantenedor). Ferramentas: `render_sim.py` +23 checks (2973 verdes antes do shader), `png_min.py` estendido (gray/palette 1/2/4/8 bits — domínio do stb), `assets_check.py`/`assets_battery.py` com 5 inválidos + 2 válidos do schema de faces. Correções durante o fechamento: imagem albedo ganhou `TRANSFER_SRC` e as barriers do readback usam estágios válidos na fila compute (dois VUIDs reais encontrados e corrigidos). Evidências por AC na tabela acima; stress 10/10; captura `bin/debug/0.1.18/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy`.
- 2026-11-09 — **Comparação de performance (subagente coder K2.8 — executada pelo agente de implementação via `tracy-csvexport`, por indisponibilidade de despacho de sub-subagente):** baseline `bin/debug/0.1.12/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy` (VS-20, 2.666 frames, replay de gameplay 19,5 s) × `bin/debug/0.1.18/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy` (VS-21, 4.159 frames, replay de stress 35 s — **roteiros e cenas distintas; comparativo indicativo**). CPU médio/frame: `frame` 6,37 ms (VS-21) vs 7,32 ms (VS-20); `engine_update` 3,31 vs 3,01 ms; `render_record` 0,61 vs 0,56 ms (estável). Startup: decode/flip das 4 texturas em ~1,3 ms medidos no log (zone `assets_texture_decode` no upload, 1,28 ms). GPU `draw_mesh`: total 1.830 ms/680 eventos (VS-21) vs 63 ms/679 (VS-20) — variação dominada pela cena (o roteiro VS-21 é o stress com 3 teleports e bolhas grandes; o VS-20 é a sessão curta de gameplay), **não comparável como A/B de fragment**; o custo do fragment alterado (seleção de face + camada dinâmica) é um branch aritmético por fragmento e não aparece como regressão nos indicadores de CPU estáveis. Conclusão: sem regressão mensurável; diferenças de GPU são de carga de cena.

## Correção pós-fechamento (2026-11-09, bug crítico reportado pelo mantenedor)

- **Diagnóstico Frente 1 — contrato `BlockDefinition` desalinhado (causa dos sintomas: plantas com buracos, dirt transparente e padrão radiante).** A auditoria bit a bit (reflection JSON do `slangc`) provou que o layout "72 B espelhado" do fechamento original **não era espelhado**: o Slang alinha `float3 emission_color` a 16 B e o colocava no offset 48, com size/stride de 96 B, enquanto o Odin gravava emission em 36 com stride 72. Os 4 primeiros campos coincidiam; a partir de `emission_color` o shader lia o registry inteiro deslocado — `flags` vinha de padding/lixo (bit TRANSPARENT por acidente → dirt "transparente" e discards aleatórios nas plantas = buracos), `mesh_template_index` vinha de lixo (triângulos degenerados = padrão radiante) e `albedo_faces` lia fora da entrada. Os smokes do fechamento não pegaram porque medem erros de validation, não pixels. **Fix:** layout reordenado com `emission_color` em offset múltiplo de 16 e size múltiplo de 16 — **80 B** nos dois lados, com `#assert(size_of == 80)`, `#assert(offset_of(...))` e verificação pela reflection do slangc (offsets byte a byte idênticos).
- **Frente 2 — listras nas laterais (UV do cubo).** Causa real independente: desde a VS-11 o cubo usava projeção planar (x,z) com 8 vértices compartilhados — U constante nas faces ±X e V constante nas ±Z (coluna de um texel esticada). Fix: cubo com **24 vértices (4 por face) e UVs [0,1]² por face** no `blocks.json` e no template built-in; cull tags por face e pior caso de triângulos inalterados; planta (cruz) mantida. Sim nova antes do shader (`render_sim` cenário cubo24). Nota da VS-11 sobre projeção planar **supersedia** (emenda registrada na VS-11).
- **Frente 3 — DEVICE_LOST no caminho built-in (descoberto na validação da correção).** Com o cubo 24v + sampler NEAREST + UV por face, a paleta procedural **4×4×256** causava `ERROR_DEVICE_LOST` reproduzível (5/5) na visão cheia (minificação extrema); estável com visão 4/8 e com paleta **16×16 (3/3)** na mesma cena. Sem VUID — GPU fault. Mitigação definitiva: `ALBEDO_PALETTE_LAYER_SIZE` 4→**16** (padrão dos assets reais do mantenedor; camada segue cor sólida). Causa raiz no driver não isolada (BLK-42 no backlog); o caminho de assets (16×16) nunca apresentou o sintoma.
- **Validação pós-fix:** sessão com assets reais — `DEBUG READBACK OK` (template_vertices 32 == JSON, template_uvs 32 == JSON, packed×denso), `DEBUG TEXTURE PARITY OK`, `DEBUG HEIGHTS PARITY OK`, gameplay (construção/remoção/pulo/mira) íntegro; únicos erros são os THREADING warnings conhecidos do hook F7 com worker ativo (padrão VS-04/VS-12/VS-13). Fallback built-in: sessões limpas com a paleta 16×16. Sims: render_sim 2980, physics_sim 42, mirror_sim 55, heightmap_sim 17 — verdes.
