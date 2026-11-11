---
id: ADR-T5
titulo: Texturas — stb_image, flip Y, nearest e topo por face
tipo: decisao
status: aceita
specs_afetadas: [VS-02, VS-12, VS-21]
ultima_atualizacao: 2026-11-08
---

# ADR-T5 — Texturas: stb_image, flip Y, nearest e topo por face

## Contexto

As PNGs chegam à GPU com orientação vertical incorreta, o sampler LINEAR suaviza texels e o registry permite uma única camada de albedo por bloco. A VS-21 acopla a troca do decoder por `vendor:stb/image`, correção explícita de orientação, filtro NEAREST e textura de topo da grama, sem ampliar `BlockDefinition`.

A causa do flip foi localizada no carregamento: `assets_build_textures` copia as linhas decodificadas por `core:image/png` sem inversão, enquanto `upload_to_device_image` usa `BufferImageCopy` tightly packed e preserva a ordem. Não há inversão oculta no upload a remover.

## Requisitos relacionados

- REQ-TEX-01..09 da [[VS-21-texturas-nearest-flip-stb-faces|VS-21]].
- Notas semânticas nas [[VS-02-task-mesh-templates|VS-02]] e [[VS-12-assets-json|VS-12]].

## Opções

### Decoder e flip Y

- **Opção A — stb_image + flip explícito pós-decode (recomendada).** `load_from_memory(..., desired_channels=4)` normaliza toda entrada em RGBA8; `image_free` libera o retorno. Uma função `flip_rows` troca linhas `y` e `height−1−y`, com stride `width·4`, antes de copiar às camadas. Não usar o estado global `set_flip_vertically_on_load`: o passo local é determinístico e testável.
- **Opção B — stb_image com flip global.** Mesma orientação, mas estado global/thread-local deixa a convenção menos explícita e dificulta o pixel-check isolado.
- **Opção C — Manter core:image/png e inverter UV.** Não atende à troca de decoder e espalha a correção pelos caminhos UV/triplanar.

A API instalada usa `foreign import` de `../lib/stb_image.lib` no Windows; a biblioteca existe na distribuição do Odin. Não exige implementation define nem flags em `run.bat`/`run_tracy.bat`; a tarefa deve validar ambos os builds e só documentar pré-requisito se outro ambiente não tiver a lib.

### Filtro

- **Opção A — NEAREST mag/min (recomendada).** O sampler único compartilhado por albedo e dummy PBR usa `NEAREST`/`NEAREST`, `mipmapMode = NEAREST`, sem mip levels e `maxLod = 0`. Produz a estética pixelada pedida.
- **Opção B — LINEAR.** Rejeitada por suavizar texels.
- **Opção C — Samplers separados por material.** Complexidade sem necessidade nesta fatia.

### Textura por face

- **Opção A — Reusar `padding_2` como `albedo_texture_top` (top/side).** Registrada como recomendação inicial; **supersedia pela revisão do mantenedor** (abaixo) após a escolha de 6 faces.
- **Opção B — Ampliar BlockDefinition com vetor de seis faces (ADOTADA na revisão do mantenedor, 2026-11-08).** `texture` aceita string — normalizada pelo loader para o objeto com as 6 faces iguais (internamente só existe a representação de objeto) — ou objeto completo `{"top","bottom","front","back","left","right"}` (front=+Z, back=−Z, right=+X, left=−X). `albedo_texture_index` + paddings viram `albedo_faces[6]: u32` em ordem `FACE_NORMALS`; `BlockDefinition` cresce 48→72 B (revisão de contrato VS-00/VS-02). Fragment seleciona a face pelo eixo dominante da normal mundial (empate Y→X→Z), sinal do eixo escolhendo ±; regra vale para UV e triplanar. O custo de contrato é justificado pela generalidade (front/back/left/right distintos viram dados, não código).
- **Opção C — Novo bloco grama-topo.** Rejeitada: multiplica tipos e quebra a semântica de um único bloco.

Face "topo" significa **+Y mundial**, não eixo local após rotação. Plantas usam string normalizada (6 faces iguais); cruzas continuam usando sua textura única e as derivadas existentes, sem efeito colateral intencional.

## Decisão

**Opção A em todos os pontos, com a revisão de textura por face adotada (Opção B de 6 faces — revisão do mantenedor, 2026-11-08):** stb RGBA8 + `flip_rows`, sampler NEAREST e `albedo_faces[6]` no registry (48→72 B). `blocks.json` aceita string (normalizada para o objeto de 6 faces pelo loader) ou objeto completo `top/bottom/front/back/left/right`; grama usa grama no topo e terra nas demais; fallback built-in reproduz a mesma combinação.

## Consequências

- Loader deixa de aceitar RGB de 3 canais como caminho separado: stb sempre entrega quatro canais; RGB/RGBA8 de entrada continuam aceitos, demais profundidades/formatos são rejeitados.
- `BlockDefinition` passa de 48 B para 72 B (`albedo_faces[6]` em ordem `FACE_NORMALS`) — revisão de contrato VS-00/VS-02 (stride do registry, `#assert`, espelho Slang/loader); exige notas nas VS-02/VS-12 e sims antes de `render.slang`.
- A seleção de camada depende da normal mundial por derivadas; eixo dominante com empate determinístico (Y→X→Z). Faces são 6 (top/bottom/4 laterais), todas endereçáveis por dados.
- Todos os blocos, inclusive plantas e dummy PBR, passam pelo sampler NEAREST.
- Fechamento exige pixel-checks, bateria string/objeto-6-faces, evidência visual, stress e captura Tracy versionada com comparação à VS-20.

## Histórico

- 2026-11-08 — ADR registrada como pendente com recomendação consolidada; bloqueia a aprovação da VS-21.
