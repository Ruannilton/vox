---
id: ADR-T5
titulo: Texturas — stb_image, flip Y, nearest e topo por face
tipo: decisao
status: pendente
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

- **Opção A — Reusar `padding_2` como `albedo_texture_top` (recomendada).** `0xFFFFFFFF` indica ausência de topo e usa `albedo_texture_index`; `padding_3` permanece preservado. O tamanho std430 continua 48 B e offsets/binding não mudam. No fragment, a camada é top apenas quando o campo é válido e `normal_mundial.y > 0,5`; demais fragmentos usam side. A regra é aplicada à amostra UV e ao triplanar.
- **Opção B — Ampliar BlockDefinition com vetor de seis faces.** Rejeitada: muda contrato/memória para uma necessidade top/side.
- **Opção C — Novo bloco grama-topo.** Rejeitada: multiplica tipos e quebra a semântica de um único bloco.

Topo significa **+Y mundial**, não eixo local após rotação. Plantas e demais blocos mantêm top INVALID; cruzas continuam usando sua textura única e as derivadas existentes, sem efeito colateral intencional.

## Decisão

**Pendente de ratificação.** Recomendação: Opção A em todos os pontos — stb RGBA8 + `flip_rows`, sampler NEAREST e `albedo_texture_top` no antigo padding. `blocks.json` aceita string ou objeto exatamente `{top, side}`; grama usa grama no topo e terra nas laterais; fallback built-in reproduz a mesma combinação.

## Consequências

- Loader deixa de aceitar RGB de 3 canais como caminho separado: stb sempre entrega quatro canais; RGB/RGBA8 de entrada continuam aceitos, demais profundidades/formatos são rejeitados.
- `BlockDefinition` permanece 48 B; mudança é semântica, sem revisão de bindings, mas exige notas nas VS-02/VS-12 e sims antes de `render.slang`.
- A seleção de camada depende da normal mundial por derivadas; o limiar 0,5 é constante documentado. Não há suporte a bottom ou quatro laterais distintas.
- Todos os blocos, inclusive plantas e dummy PBR, passam pelo sampler NEAREST.
- Fechamento exige pixel-checks, bateria string/objeto, evidência visual, stress e captura Tracy versionada com comparação à VS-20.

## Histórico

- 2026-11-08 — ADR registrada como pendente com recomendação consolidada; bloqueia a aprovação da VS-21.
