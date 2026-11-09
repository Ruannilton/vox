---
id: VS-21
titulo: Texturas — nearest, flip Y, stb_image e multi-face
tipo: especificacao
status_spec: aprovada
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
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
- **REQ-TEX-05 — Registry cresce para 72 B (revisão de contrato VS-00/VS-02).** `albedo_texture_index` e os dois paddings dão lugar a `albedo_faces[6]: u32` **em ordem `FACE_NORMALS`** (+X=right, −X=left, +Y=top, −Y=bottom, +Z=front, −Z=back) + padding de alinhamento: `BlockDefinition` passa de 48 B para **72 B** em Odin e Slang espelhados (`#assert(size_of(BlockDefinition)==72)`), com revisão do buffer do registry (stride/capacidade), offsets e notas nas VS-02/VS-12. Demais campos (mesh/pbr/flags/emissão/materiais/rotação) inalterados.
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
| `albedo_faces[6]` | camada por face, ordem `FACE_NORMALS` (+X,−X,+Y,−Y,+Z,−Z) | registry cresce 48→72 B (revisão VS-00/VS-02) |
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
| VS-21-AC-01 | Pixel-check prova orientação correta e idempotência da dupla inversão em RGB/RGBA; decode stb libera memória e upload preserva a ordem corrigida | Sim com cantos/rows marcadas + build/link default/Tracy | Pendente |
| VS-21-AC-02 | Sampler mag/min/mipmap NEAREST e um mip; texels contrastantes sem blur | Inspeção de parâmetros + captura visual ampliada | Pendente |
| VS-21-AC-03 | Bateria aceita string/objeto de 6 faces e rejeita incompleto/extra/tipos/refs inválidos; normalização string→objeto; fallback e registry 72 B íntegros | `assets_check`, bateria e asserts/build | Pendente |
| VS-21-AC-04 | Sim e sessão mostram grama verde no +Y e terra nas outras faces; planta, alpha-test, highlight, UV/triplanar e rotação seguem contratos | Sims antes do shader + capturas/readback de camadas e smoke | Pendente |
| VS-21-AC-05 | Stress 5× em cada build com gameplay/edição/teleports e `--full-teardown`: zero VUIDs/threading/deadlock, teardown limpo | Stress scriptado reproduzível | Pendente |
| VS-21-AC-06 | Zone/contadores novos presentes; captura versionada íntegra e comparação com VS-20 documentam startup/render | `run_tracy.bat` + `tracy-capture`; subagente coder K2.8 thinking low | Pendente |

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
