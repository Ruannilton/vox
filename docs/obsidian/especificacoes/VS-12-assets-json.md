---
id: VS-12
titulo: Assets data-driven via JSON
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-11
bloqueada_por: []
requisitos: [REQ-AST-01, REQ-AST-02, REQ-AST-03, REQ-AST-04, REQ-AST-05, REQ-AST-06, REQ-VAL-07]
ultima_atualizacao: 2026-11-06
---

# VS-12 — Assets data-driven via JSON

## Objetivo

Blocos, malhas e texturas deixam de ser hardcoded: um arquivo `assets/blocks.json` define objetos de malha reaproveitáveis (vértices, triângulos, UVs), objetos de textura (path de uma PNG única que cobre o mapeamento UV completo) e blocos (id, nome, referências por nome); o startup os carrega e formata **exatamente nos formatos que o pipeline de renderização já consome** — sem mudança de shader.

## Rastreabilidade

- GOAL: pedido do mantenedor (2026-11-06) — sistema simples de assets em JSON, melhorias posteriores. Formaliza o Caminho B (geometria e materiais como dados).
- Referência: `upload_block_registry` (ids 1..3 hardcoded), `upload_builtin_templates` (cubo/planta), `upload_palette_textures` (paleta procedural) em `src/engine/voxel_gpu.odin`; contratos `MeshTemplate`/`BlockDefinition` em `src/engine/voxel_types.odin` e `src/assets/shaders/common.slang`; amostragem por índice de camada + UV (VS-11); worldgen do `generate_voxels` (`voxel.slang`, ids 1=grama/2=terra/3=pedra).
- Decisões: [[ADR-A1-assets-json|ADR-A1]] (**bloqueia a aprovação desta spec**).
- Fundação: VS-02 (templates, registry, validações), VS-11 (UVs nos templates — o JSON alimenta o pool de UVs).

## Requisitos

### Arquivo e schema

- **REQ-AST-01** — Arquivo único `assets/blocks.json` (no cwd; `assets/` versionado na raiz do repo e copiado para `bin/assets` pelo `run.bat`), com três seções e referências **por nome**:

```json
{
  "meshes": [
    { "name": "cubo",
      "vertices":  [[0,0,0], [1,0,0], "..."],
      "triangles": [[0,1,2], "..."],
      "cull_tags": [0, "..."],
      "uvs":       [[0,0], "..."] }
  ],
  "textures": [ { "name": "grama", "path": "textures/grama.png" } ],
  "blocks":   [ { "id": 1, "name": "grama", "mesh": "cubo", "texture": "grama" } ]
}
```

`cull_tags` é opcional por triângulo (default `7` = nunca culpar); `uvs` é opcional por malha (ausente → fallback triplanar da VS-11, sentinela). **Ausente → comportamento atual** (built-ins + paleta procedural) com warning no log.

### Malhas reaproveitáveis

- **REQ-AST-02** — Cada objeto de malha vira uma entrada de template + pools (`template_vertices` float4, `template_triangles` u32 com tag nos bits 24–26, `template_uvs` float2). `MeshTemplate.flags`: `HAS_FLUSH_FACES` derivado (qualquer tag 0–5); `worst_case_tris` computado na carga. Validações existentes reaproveitadas, agora com **nome do objeto e índice** na mensagem: vértices em [0,1]³, UVs em [0,1]², ≤ 32 vértices / ≤ 24 triângulos por template, índices dentro do range. Uma malha pode ser referenciada por vários blocos.

### Texturas

- **REQ-AST-03** — Objeto de textura = `{name, path}` para uma **PNG única** que cobre o mapeamento UV completo da malha (por-face/atlas interno à imagem é responsabilidade do UV da malha — fora de escopo). Decode via `core:image/png`. Todas as PNGs de blocos devem ter a **mesma dimensão** (erro explicativo listando as dimensões encontradas; máx. 256×256 nesta fatia). Upload em `Texture2DArray` com **uma camada por textura, na ordem de definição**, substituindo a paleta procedural (o caminho de amostragem — índice de camada + UV — é o mesmo da VS-11: **nenhuma mudança de shader**). Dummy PBR inalterado. Sem mipmaps nesta fatia.

### Blocos e contrato do worldgen

- **REQ-AST-04** — Bloco = `{id, name, mesh, texture}` → `BlockDefinition{mesh_template_index, albedo_texture_index = camada da textura}`. Regras: `id` em 1..255, sem duplicatas; **id 0 é AR e jamais pode ser definido** (regra 2 do AGENTS.md); refs por nome com erro de resolução citando o bloco e o nome não encontrado; **contrato do worldgen**: os ids 1, 2 e 3 devem estar definidos (o generate os usa para grama/terra/pedra) — ausente → erro fatal listando o que falta. `name` é metadado (log/debug; uso em UI fica para depois).

### Formatação e erros

- **REQ-AST-05** — A saída do carregador é bit a bit o que o pipeline espera hoje: `MeshTemplate` 32 B, `BlockDefinition` 48 B, pools de templates, array de camadas de albedo. Quando o JSON existe, ele **substitui** built-ins de malha/bloco e a paleta (o fallback só ocorre com arquivo ausente).
- **REQ-AST-06** — Erros fatais com mensagens no estilo do config.ini: JSON sintaticamente inválido (path + linha/mensagem do parser), campo obrigatório ausente, referência por nome não resolvida, dimensões de PNG divergentes, PNG ilegível/ausente, validação de malha/bloco — cada um citando o objeto e o motivo. Parse e validação rodam **antes** de `CreateEngine` (sem janela); upload GPU no init do motor de voxels.

### Validação offline

- **REQ-VAL-07** — `tools/sim/assets_check.py <arquivo.json>`: valida o schema, referências por nome, limites e bounds sem rodar a engine (exit 0/1, mensagens idênticas ao carregador) — usado nos ACs e por quem autora assets.

## Escopo

- Módulo `src/engine/voxel_assets.odin` (parse, validação, formatação, upload GPU de templates/registry/texturas).
- `assets/blocks.json` + PNGs de exemplo (grama/terra/pedra, dimensão única) versionados na raiz; passo de cópia no `run.bat`.
- Fallback para built-ins + paleta quando o arquivo está ausente.
- Validador offline `tools/sim/assets_check.py`.
- Docs: arquitetura §6 (materiais como dados), manual técnico, tracking; nota no histórico da VS-02 sobre o fim do hardcode.

## Não escopo

- Texturas por face/atlas interno, mipmaps, transparência/emissão/PBR via JSON, blocos com múltiplas texturas.
- Worldgen data-driven (o contrato ids 1–3 permanece no generate; desacoplamento é backlog).
- Hot-reload, pacotes/mods com dependências, formato binário.
- Save/serialização.

## Dependências

- [[VS-11-uvs-templates|VS-11]] concluída e verificada (pool de UVs alimentado pelo JSON).
- [[ADR-A1-assets-json|ADR-A1]] — **ratificada (Opção A) em 2026-11-06** junto à aprovação desta spec.

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| `assets/blocks.json` | seções `meshes`/`textures`/`blocks`, refs por nome | ausente → fallback built-ins + paleta |
| Saída do loader | formatos atuais (`MeshTemplate`, `BlockDefinition`, pools, array de camadas) | zero mudança de shader/contrato GPU |
| Textura | PNG única por bloco, dimensão uniforme (máx 256×256) | 1 camada por textura, ordem de definição |

### Comportamento quando limites são atingidos

- Mais de 256 texturas ou 256 templates → erro (capacidade dos arrays).
- PNG com dimensão diferente das demais → erro listando as dimensões.
- Bloco referenciando malha/textura inexistente → erro citando bloco e nome.
- Ausência do arquivo → warning + comportamento atual (paridade com builds anteriores).

## Cenários

### Cenário de sucesso — blocos texturizados

- **Dado** um `assets/blocks.json` com malha "cubo", três PNGs 16×16 (grama/terra/pedra) e blocos id 1–3.
- **Quando** a aplicação sobe.
- **Então** o terreno renderiza com as texturas (blocos corretos por camada via UV), zero erros de validation, readback de `template_vertices`/`template_uvs` casando com o JSON.

### Reaproveitamento de malha

- **Dado** dois blocos referenciando a mesma malha "cubo" com texturas diferentes.
- **Quando** carregado.
- **Então** uma única entrada de template serve aos dois (registry aponta o mesmo índice; camadas de textura distintas).

### Falhas de asset

- **Dado** JSON com ref quebrada, PNG de dimensão divergente, id duplicado, UV fora de [0,1]², ou ids 1–3 ausentes.
- **Quando** o startup roda.
- **Então** erro fatal com objeto + motivo (antes da janela, quando possível), exit ≠ 0.

### Fallback

- **Dado** `assets/blocks.json` ausente.
- **Quando** a aplicação sobe.
- **Então** warning + built-ins + paleta procedural — imagem idêntica ao baseline anterior.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-12-AC-01 | Validador offline e carregador rejeitam cada classe de erro com mensagem específica (JSON quebrado, ref por nome, dimensão divergente, id duplicado/0, limites, bounds, ids 1–3 ausentes) | Bateria de arquivos inválidos via `assets_check.py` + execuções | **Verificado (2026-11-06):** bateria de 12 classes em `tools/sim/assets_battery.py` — validador (`assets_check.py`) rejeitou todas com exit 1 e mensagens por classe; carregador (`vox.exe` a partir de `bin/`) rejeitou todas com exit ≠ 0 e as mesmas mensagens (log): JSON quebrado (`assets/blocks.json: JSON inválido: Invalid_Data`), ref quebrada (`bloco 'grama': malha 'inexistente' não encontrada`), PNG ausente, dimensão divergente (`texturas com dimensões divergentes: grama 16x16, terra 16x8, pedra 16x16`), id duplicado, id 0 (reservado AR), UV fora de [0,1]², vértice fora de [0,1]³, >32 vértices, índice fora de range, cull_tag inválido, ids 1–3 ausentes |
| VS-12-AC-02 | Cena com assets reais: terreno texturizado pelas PNGs (screenshot), readback de templates casando com o JSON, zero erros de validation | Smoke com assets de exemplo + captura comparada a baseline de cor sólida equivalente | **Verificado (2026-11-06):** smoke de 12 s com `assets/` copiado em `bin/`: log `VS-12: assets carregados de assets/blocks.json — 1 malhas, 3 texturas (16x16x3), 3 blocos`; readback `template_vertices (8 vértices) == assets JSON` e `template_uvs (8 UVs) == assets JSON` OK; **zero erros de validation** (VUID) no log; captura GDI (`bin/shot_vs12_assets.png`) mostra terreno com variação de textura por voxel (vs. cor sólida do baseline); comparação pixel a pixel vs. baseline pré-VS-12: 1.227.239 de 1.920.000 bytes diferentes (texturas aplicadas). Sims de shader sem regressão: `render_sim.py` 2.906 checks / `pack_sim.py` 968 checks, 0 falhas |
| VS-12-AC-03 | Fallback com arquivo ausente → imagem idêntica ao baseline anterior + warning | Smoke sem `assets/` | **Verificado (2026-11-06):** smoke com `bin/assets` renomeado: warning `assets/blocks.json não encontrado; usando built-ins (templates cubo/planta, registry ids 1..3, paleta procedural)` + readback `template_vertices (16 vértices) == built-ins` OK + zero VUIDs; capturas comparadas pixel a pixel (mesmo cliente 800×600): fallback pós-VS-12 vs. baseline pré-VS-12 (build via `git stash` temporário, mesmo protocolo da VS-11): **6 bytes de 1.920.000 diferentes** (≤2 pixels — ruído residual de captura GDI; cena idêntica) |

## Tarefas da especificação

- [x] Vincular o pedido do mantenedor aos pontos hardcoded atuais e aos contratos do pipeline.
- [x] Formalizar schema, regras de validação e o contrato do worldgen (ids 1–3).
- [x] Cobrir sucesso, reaproveitamento, falhas e fallback.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-A1 e obter aprovação da spec. — ADR-A1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-A1. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-12-IMPL-01 — Validador offline** (REQ-VAL-07; AC-01). `tools/sim/assets_check.py`: schema, refs, limites, bounds, contrato worldgen. — **concluída**
2. **VS-12-IMPL-02 — Parser e formatação** (REQ-AST-01, REQ-AST-02, REQ-AST-04, REQ-AST-06; AC-01). `voxel_assets.odin`: parse pré-janela, validações com nome de objeto, saída nos formatos atuais (templates + registry em memória). — **concluída**
3. **VS-12-IMPL-03 — Texturas** (REQ-AST-03, REQ-AST-05; AC-02). Decode PNG, array de camadas substituindo a paleta, upload, integração no init (fallback quando ausente). — **concluída**
4. **VS-12-IMPL-04 — Assets de exemplo e evidências** (AC-01..03). `assets/blocks.json` + PNGs 16×16, bateria de erros, smokes (com assets/fallback), docs e commit com o nome da spec. — **concluída**

## Questões abertas

- Dimensão máxima 256×256 nesta fatia (suficiente para voxels; ampliação com mipmaps é backlog). Não bloqueia a aprovação.
- `name` do bloco sem consumidor além de log nesta fatia (UI/debug futuros). Não bloqueia a aprovação.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (assets de blocos/malhas/texturas via JSON, malhas reaproveitáveis, PNG única por bloco); ADR-A1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-A1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-12-IMPL-01..04 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..04) e validação verificada (AC-01..03).** Módulos: `src/engine/voxel_assets.odin` (parse `core:encoding/json` + validações pré-janela chamado de `main.odin` antes de `CreateEngine`; PNG via `core:image/png`, RGB/RGBA 8-bit expandido para RGBA8; saída em memória nos formatos atuais), integração em `voxel_gpu_init` (branch: assets → `upload_asset_templates/registry/textures`; ausente → built-ins + paleta inalterados), `template_uvs` ganhou `TRANSFER_SRC` (necessário ao readback de validação; `template_vertices` já tinha). Ferramentas: `tools/sim/assets_check.py` (validador offline, mensagens espelhadas), `tools/sim/assets_battery.py` (bateria de 12 classes), `tools/sim/png_min.py` (mini codec PNG stdlib — decode p/ validação, encode p/ geração), `tools/sim/gen_example_textures.py` (PNGs 16×16 grama/terra/pedra), `tools/sim/capture.ps1` (captura GDI com TOPMOST). Assets versionados na raiz: `assets/blocks.json` (malha "cubo" = geometria do built-in com UVs + cull_tags) + `assets/textures/*.png`; `run.bat` copia `assets` → `bin/assets`. AC-01: bateria de 12 classes rejeitada por validador e carregador com exit ≠ 0 e mensagens por classe (tabela nos ACs). AC-02: smoke 12 s com assets — readback `template_vertices`/`template_uvs` == JSON, zero VUIDs, captura texturizada (1.227.239/1.920.000 bytes diferentes do baseline sólido). AC-03: smoke sem `assets/` — warning + built-ins, captura vs. baseline pré-VS-12 (build via `git stash` temporário): 6 bytes/1.920.000 de diferença residual de captura. Sims `render_sim.py` (2.906 checks) e `pack_sim.py` (968 checks) sem regressão; zero mudança de shader. Ressalvas: (1) a checagem de chunk do `debug_readback_validate` tem modelo de mundo defasado (estratos planos y<0/==0/==1) — o worldgen atual é noise-based; a divergência (32768/32768) é pré-existente e não relacionada a esta spec — o readback de templates/UVs (relevante à VS-12) passa; correção do modelo de mundo fica em backlog. (2) `name` do bloco ainda sem consumidor além de log (questão aberta mantida). Capturas em `bin/shot_vs12_{assets,fallback,pre}.png` (gitignored).
- 2026-11-07 — **Emenda VS-14 (REQ-PLT-01/05): campo `transparent` e contrato ids 1..4.** O bloco ganha campo opcional `transparent` (bool) — tipo errado falha o `json.unmarshal` do loader (fatal, exit ≠ 0) e é rejeitado pelo validador com "campo 'transparent' deve ser booleano"; quando `true`, o loader seta `BlockDefinition.flags |= BLOCK_DEFINITION_FLAG_TRANSPARENT` (bit 0), consumido pelo alpha-test do fragment (`shade_voxel`, discard com `albedo.a < 0.5`). O contrato de ids obrigatórios do worldgen passa de 1..3 para **1..4** (planta = 4) no validador e no loader; o fallback sem assets ganha id 4 (template cruz built-in 2 + camada 4 da paleta, verde). Detalhes e evidências na [[VS-14-plantas-alpha-test-spawn|VS-14]].
- 2026-11-08 — **Emenda planejada pela [[VS-21-texturas-nearest-flip-stb-faces|VS-21]] (ADR-T5 pendente):** decode migra para `vendor:stb/image` RGBA8 com flip explícito de linhas; `texture` aceita string ou objeto exato `{top,side}`; grama usa grama no topo e terra nas demais faces, com fallback equivalente. Registry permanece 48 B.

- 2026-11-09 — **Emenda VS-21 consumada (REQ-TEX-01/02/04/07):** decode de texturas migra para `vendor:stb/image` (`load_from_memory` com `desired_channels = 4`, `image_free` em todos os caminhos) com `flip_rows` explícito pós-decode; campo `texture` aceita **string (normalizada pelo loader para o objeto de 6 faces iguais — internamente só existe a representação de objeto)** ou objeto completo `top/bottom/front/back/left/right` (front=+Z, back=−Z, right=+X, left=−X); fallback built-in reproduz a grama multi-face (top=grama, demais=terra).

- 2026-11-09 — **Correção VS-21:** cubo do `blocks.json` com 24 vértices (4 por face) e UVs [0,1]² por face; decode/sampler/schema inalterados.
