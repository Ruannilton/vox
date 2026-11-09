---
id: VS-21
titulo: Texturas — nearest, flip Y, stb_image e multi-face
tipo: especificacao
status_spec: em-revisao
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de: [VS-11, VS-12]
bloqueada_por: [ADR-T5]
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
- **REQ-TEX-04 — Schema string ou top/side.** O campo `texture` de cada bloco aceita string (todas as faces, compatível) ou objeto contendo exatamente `top` e `side`, ambos strings. Ausência de chave, chave extra, array/número/null ou tipo errado são erros fatais citando bloco e campo; referências precisam existir na seção textures. `assets_check.py` e loader compartilham a mesma semântica.
- **REQ-TEX-05 — Registry sem crescimento.** Em Odin e Slang, `padding_2` vira `albedo_texture_top: u32`; string simples grava `0xFFFFFFFF`, objeto grava a camada top e `albedo_texture_index` recebe side. `padding_3` permanece padding. `#assert(size_of(BlockDefinition)==48)` e demais offsets/bindings/provisionamento inalterados. Registrar notas nas VS-02/VS-12.
- **REQ-TEX-06 — Seleção de camada no fragment.** Antes de amostrar, escolher top somente se `albedo_texture_top != 0xFFFFFFFF && normal_mundial.y > 0,5`; caso contrário, side/`albedo_texture_index`. A camada selecionada alimenta tanto UV quanto triplanar. Normal continua derivada de `world_position`; topo é +Y mundial mesmo em bloco rotacionado (semântica v1). Alpha-test, highlight VS-20, derivadas e plantas/cruzas permanecem funcionais; planta usa top INVALID.
- **REQ-TEX-07 — Assets e fallback.** `assets/blocks.json` define grama id 1 como `{ "top": "grama", "side": "terra" }`; terra, pedra e planta continuam strings. Sem JSON, fallback built-in mantém todas as definições atuais e atribui à grama top=grama/side=terra, com top INVALID nos demais. Paleta procedural segue coerente com os ids/camadas existentes.
- **REQ-TEX-08 — Simulações e paridade.** Antes do shader, estender sims para flip por pixel, normalização RGBA, sampler e seleção top/side/INVALID em UV e triplanar, incluindo limiar ±Y e coordenadas negativas. Validador/bateria cobrem string compatível e objeto válido/inválido. Checks antigos permanecem verdes.
- **REQ-TEX-09 — Instrumentação e evidência.** Zone Tracy `assets_texture_decode` cobre decode/flip/montagem das camadas, com contagem de texturas/bytes; caminho de render existente mede o fragment. Fechamento usa `bin/debug/<version>/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy` e comparação K2.8 com VS-20, incluindo custo de startup e render.

## Escopo

- Migração stb, liberação correta e flip de linhas.
- Sampler NEAREST nos caminhos JSON/built-in.
- Schema top/side, registry e fragment.
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
| `texture` | string ou `{top,side}` exato | compatibilidade string |
| `albedo_texture_top` | camada top ou `0xFFFFFFFF` | antigo `padding_2`; 48 B total |
| Seleção fragment | top se normal.y > 0,5 | +Y mundial; UV e triplanar |
| Sampler | NEAREST mag/min/mipmap | um mip; dummy PBR incluído |

## Cenários

### Orientação e pixelização

- **Dado** PNG RGBA com quatro cantos distintos e texels adjacentes contrastantes.
- **Quando** decodifica, aplica flip, faz upload e amostra entre texels.
- **Então** os cantos aparecem nas posições esperadas e NEAREST escolhe um texel, sem cor interpolada.

### Grama multi-face

- **Dado** bloco grama com top grama e side terra.
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
| VS-21-AC-03 | Bateria aceita string/objeto e rejeita chaves/tipos/refs inválidos; fallback e registry 48 B íntegros | `assets_check`, bateria e asserts/build | Pendente |
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

- **VS-02:** `BlockDefinition.padding_2` passa a ser `albedo_texture_top`; tamanho/layout de 48 B inalterados.
- **VS-12:** `texture` aceita string ou objeto exato `{top,side}`; decode stb RGBA8 + flip; fallback da grama ganha top/side.

## Questões abertas

- Nenhuma crítica. Ambientes cuja distribuição Odin não inclua `stb_image.lib` devem gerar as libs STB pelo script da distribuição; não é necessário mudar os scripts do projeto no ambiente verificado.

## Histórico

- 2026-11-08 — Spec completa submetida à revisão, bloqueada pela ADR-T5 pendente; nenhuma implementação iniciada.
