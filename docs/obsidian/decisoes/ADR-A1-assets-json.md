---
id: ADR-A1
titulo: Assets data-driven via JSON
tipo: decisao
status: aceita
specs_afetadas: [VS-12]
ultima_atualizacao: 2026-11-06
---

# ADR-A1 — Assets data-driven via JSON

## Contexto

Blocos, malhas e texturas são hardcoded no init (`upload_block_registry` — ids 1..3 → template 1, camada = id; `upload_builtin_templates` — cubo/planta; `upload_palette_textures` — paleta procedural de cores sólidas). O mantenedor quer um sistema simples de assets: um arquivo JSON define **objetos de malha** (vértices, triângulos, UVs — reaproveitáveis por vários blocos), **objetos de textura** (path de uma PNG única que cobre o mapeamento UV completo da malha) e **blocos** (id, nome, referência à malha e à textura), carregados no startup já formatados do jeito que o pipeline espera (pools de templates, registry, array de camadas de albedo). Melhorias ficam para depois.

## Requisitos relacionados

- REQ-AST-01..06 e REQ-VAL-07 da [[VS-12-assets-json|VS-12]].

## Opções

### Opção A — JSON único com seções nomeadas, formatando para os formatos atuais

- `assets/blocks.json` com `meshes[]`, `textures[]`, `blocks[]`, referências por nome entre seções. O carregador (novo `voxel_assets.odin`, parser `core:encoding/json`, PNG via `core:image/png`) produz exatamente os formatos de hoje: `MeshTemplate` 32 B + pools (vertices float4 / triangles u32 com tags / uvs float2), registry `BlockDefinition` 48 B, e **Texture2DArray de albedo com uma camada por PNG** no lugar da paleta procedural — o caminho de amostragem (índice de camada + UV da VS-11) não muda, **zero alteração de shader**.
- Ausente → comportamento atual (built-ins + paleta) com warning. PNGs precisam ter todas a mesma dimensão (erro explicativo senão). Contrato do worldgen (ids 1=grama, 2=terra, 3=pedra no generate) é validado: JSON deve definir esses ids.
- Vantagens: cumpre o pedido com o menor diff possível; reaproveitamento de malha por nome; validações existentes (bounds, limites 32v/24t, unitário) reaproveitadas; sem toque no pipeline de render.
- Desvantagens: texturas precisam de dimensão uniforme (v1); mipmaps/transparência/emissão por JSON ficam fora.

### Opção B — Um arquivo por asset + sistema de pacotes

- Diretório com `meshes/*.json`, `textures/*.json`, `blocks/*.json`, manifest. Mais escalável, mas overkill para o "simples inicialmente" pedido.

### Opção C — Formato binário próprio ou engine de mods completa

- Serialização binária, hot-reload, dependências entre mods. Prematuro.

## Decisão

**Opção A** — JSON único com seções nomeadas, formatando para os contratos atuais do pipeline (zero mudança de shader); PNG única por bloco em camadas de `Texture2DArray`; fallback built-ins + paleta quando ausente. Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-12.

## Consequências

- `assets/` na raiz do repo (versionado); `run.bat` ganha passo de cópia para `bin/assets` (o app roda com cwd em bin/). Loader lê `assets/blocks.json` relativo ao cwd.
- O contrato do worldgen (ids 1–3) fica explícito na validação do JSON; desacoplá-lo é backlog.
- Validação offline em `tools/sim/assets_check.py` (schema, refs, limites, bounds) — usada nos ACs e reutilizável por quem autora assets.
- A paleta procedural vira fallback, não caminho principal; as PNGs de exemplo (grama/terra/pedra) entram como assets do repo.

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-12 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-12.
