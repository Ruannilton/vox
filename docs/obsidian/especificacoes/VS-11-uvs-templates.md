---
id: VS-11
titulo: UVs nos templates de malha
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-02
bloqueada_por: []
requisitos: [REQ-UV-01, REQ-UV-02, REQ-UV-03, REQ-UV-04, REQ-SIM-08]
ultima_atualizacao: 2026-11-06
---

# VS-11 — UVs nos templates de malha

## Objetivo

Migrar o mapeamento de albedo de triplanar (projeção pela posição mundo) para **UVs por vértice providas pelos templates de malha** (Caminho B), com fallback triplanar via sentinela para templates sem UV — habilitando blocos com shapes customizados e texturas reais por face/atlas no futuro, sem quebrar mods procedurais, e sem tocar no orçamento do mesh shader.

## Rastreabilidade

- GOAL: pedido do mantenedor (2026-11-06) — estratégia de UVs em vez de triplanar, preparando blocos de shape customizado; premissa confirmada: com a ADR-B10 não há payload limitando o transporte.
- Referência: `MeshVertex` e `shade_voxel`/`sample_triplanar_albedo` em `src/assets/shaders/render.slang`, `MeshTemplate` e `template_vertices` em `src/assets/shaders/common.slang`, loader de templates built-in em `src/engine/voxel_gpu.odin`, paleta procedural de albedo (VS-02, REQ-SHADE-03).
- Decisões: [[ADR-U1-uvs-templates-malha|ADR-U1]] (**bloqueia a aprovação desta spec**); amenda a [[VS-02-task-mesh-templates|VS-02]] (REQ-SHADE-03, REQ-MESH-04).
- Fundação: VS-02 (templates, `MeshVertex`, paleta), ADR-B10 (fila global — sem limite de bytes no transporte).

## Requisitos

### Atributo e contratos

- **REQ-UV-01** — `MeshVertex` ganha `uv: float2` (`TEXCOORD0`): 8 → 10 componentes de saída por vértice — distante do limite de `maxMeshOutputComponents`; nenhum limite de payload envolvido (ADR-B10). `clip_position`, `world_position` e `block_id` inalterados (`world_position` segue necessário para as normais por derivadas).
- **REQ-UV-02** — Templates ganham pool de UVs: `template_uvs` (**binding 19**, `StructuredBuffer<float2>`, stride 8 B std430, paralelo e indexado como `template_vertices`); `MeshTemplate` ganha `uv_offset` (reusa um campo de padding; struct permanece 32 B). Template sem UV deixa `uv_offset`/`vertex_count` de UVs vazio; o mesh shader emite a **sentinela `uv = float2(-1, -1)`** nesse caso. Built-ins recebem UVs: cubo (cada face [0,1]²), planta (cruz [0,1]²).

### Amostragem

- **REQ-UV-03** — Fragment: se `uv.x >= 0` → `block_albedo_textures.Sample(float3(uv, albedo_texture_index))`; senão → triplanar atual (fallback inalterado). Normais continuam por derivadas espaciais (`dFdx`/`dFdy` — REQ-SHADE-02 inalterado). Com a paleta de cores sólidas atual, o resultado das duas rotas é **idêntico** (camada sólida amostrada em qualquer UV).
- **REQ-UV-04** — Invariantes: (a) validação de carga — UVs em [0,1]² quando presentes (mesma filosofia do voxel unitário; sentinela reservada); (b) orçamento mesh shader **inalterado** — o atributo não adiciona vértices nem triângulos (regra 5 do AGENTS.md preservada por construção); (c) `DESCRIPTOR_SET_BINDING_COUNT` 19 → 20 e revisão da VS-00 (nota no histórico: binding 19).

### Simulação

- **REQ-SIM-08** — Antes da integração: `tools/sim/render_sim.py` estendido cobrindo bounds de UV ([0,1]², sentinela exclusa), roundtrip sentinela → fallback triplanar, e paridade de cor (paleta sólida: amostragem UV × triplanar idênticas por bloco). Checks antigos verdes.

## Escopo

- `MeshVertex` + `uv`, pool `template_uvs` (binding 19), `MeshTemplate.uv_offset`, write no loader dos built-ins.
- Emissão de UV no mesh shader (com sentinela para template sem UV) e amostragem no fragment (UV × fallback triplanar).
- Validação de carga de UVs; sim estendida (REQ-SIM-08).
- Docs: emenda da VS-02 (REQ-SHADE-03 vira "caminho índice→textura→UV; triplanar é fallback", REQ-MESH-04 tabela do `MeshVertex`), nota de contrato na VS-00 (binding 19), arquitetura §6, manual técnico, tracking.

## Não escopo

- Texturas reais/arquivos de asset e atlas (a paleta sólida permanece; o caminho índice→camada é o mesmo).
- Normais/tangentes por atributo (normais seguem por derivadas).
- Semântica de UV sob **rotação yaw** (registrada como questão aberta — ver abaixo).
- Mudanças em templates existentes além da adição de UV (geometria built-in inalterada).

## Dependências

- [[VS-02-task-mesh-templates|VS-02]] concluída e verificada (templates, `MeshVertex`, paleta).
- [[ADR-U1-uvs-templates-malha|ADR-U1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

| Contrato | Antes | Depois |
| --- | --- | --- |
| `MeshVertex` | `clip_position f4 \| world_position f3 \| block_id u32` (8 componentes) | + `uv f2 (TEXCOORD0)` — 10 componentes |
| `MeshTemplate` | 32 B com 2 paddings | `uv_offset` no lugar de um padding (32 B) |
| `template_uvs` | — | binding 19, `float2` por vértice de template |
| Sem UV no template | — | sentinela `(-1,-1)` → fragment usa triplanar |

### Comportamento quando limites são atingidos

- Template com UV fora de [0,1]² (exceto sentinela interna) → **erro de carga** com o índice do template e o vértice (mesmo padrão da validação do voxel unitário).
- Template sem UVs (pool vazio) → válido: fallback triplanal por sentinela, sem erro.
- `maxMeshOutputComponents`: 10 de ~128 — sem risco; registrado para auditoria futura.

## Cenários

### Cenário de sucesso — paridade visual

- **Dado** a cena atual (paleta sólida, cubos/plantas, câmera travada).
- **Quando** a VS-11 entra.
- **Então** a imagem é **idêntica** pixel a pixel à do baseline (camada sólida amostrada por UV = triplanar), com validation layers limpos.

### Template sem UV (fallback)

- **Dado** um template registrado sem pool de UVs.
- **Quando** o mesh shader o emite.
- **Então** os vértices carregam a sentinela e o fragment usa triplanar — mods procedurais seguem funcionando (verificado na simulação).

### Edição e culling inalterados

- **Dado** edições (E1) e culling de faces/tags.
- **Quando** frames avançam.
- **Então** nada muda: UV é atributo de saída, não participa de ocupação, paleta, culling nem orçamento.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-11-AC-01 | Sim verde: bounds de UV, sentinela→fallback, paridade de cor UV × triplanar na paleta sólida; checks antigos verdes | `tools/sim/render_sim.py` | **Verificado (2026-11-06):** `render_sim.py` 2.906 checks (54 novos no cenário VS-11: 10 componentes ≤ 128, bounds dos built-ins, sentinelas, roundtrip emissão→fragmento, paridade de cor 3 blocos × 50 amostras, orçamento inalterado com UV), 0 falhas; `pack_sim.py` 968 checks, 0 falhas |
| VS-11-AC-02 | Paridade visual pixel a pixel com o baseline (câmera travada, 2 capturas ≥10 s) + `spirv-val` limpo + zero erros de validation | Smoke com screenshots (capturas externas, como nas specs anteriores) comparadas ao baseline | **Verificado (2026-11-06):** capturas externas da janela (PowerShell/GDI, `bin/shot_uv_{a,b}.png` pós-VS-11 vs `bin/shot_base_{a,b}.png` baseline pré-VS-11, build com `git stash` revertido): dois frames a 10 s de intervalo **idênticos** em cada build; **0 pixels diferentes** na área cliente (800×593) entre baseline e VS-11 (diferenças residuais apenas no chrome da janela — título/borda do sistema); `spirv-val` limpo nos 3 shaders; smoke de 60 s sem erros de validation novos (os 10 erros `vkGetQueryPoolResults: query not reset` no log são pré-existentes da telemetria VS-05, não introduzidos por esta spec) |
| VS-11-AC-03 | Built-ins com UV: validação rejeita UV fora de [0,1]² (caso injetado) e aceita template sem UV (fallback) | Casos de teste no loader/sim | **Verificado (2026-11-06):** UV `1.5` injetada no vértice 3 do cubo (teste temporário revertido): carga aborta com `[ERROR] template 1: UV do vértice 3 fora de [0,1]²: (1.5, 0.25)` + assert fatal — índice do template e do vértice nomeados, mesmo padrão da validação do voxel unitário; template sem UV (pesado, ar) segue válido com fallback triplanar (sim: `validacao: template sem UVs e valido`, `pesado (sem UV): emissao devolve a sentinela`) |

## Tarefas da especificação

- [x] Vincular o pedido do mantenedor à premissa técnica (ADR-B10, sem payload) e aos contratos atingidos.
- [x] Formalizar o atributo, o pool, a sentinela/fallback e os invariantes (orçamento, validação).
- [x] Cobrir sucesso, fallback e paridade; registrar a questão aberta de rotação.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-U1 e obter aprovação da spec. — ADR-U1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-U1. Cada tarefa referencia requisitos e critérios de aceitação.

1. ~~**VS-11-IMPL-01 — Simulação**~~ **Concluída (2026-11-06).** (REQ-SIM-08; AC-01). `tools/sim/render_sim.py`: bounds/sentinela/paridade de cor. Rodada antes dos shaders — 2.906 checks, 0 falhas.
2. ~~**VS-11-IMPL-02 — Contratos e shaders**~~ **Concluída (2026-11-06).** (REQ-UV-01, REQ-UV-02; AC-02, AC-03). `MeshVertex` + `uv` (TEXCOORD0, 10 componentes), binding 19 (`template_uvs`), `MeshTemplate.uv_offset` (32 B preservados), emissão no mesh shader (sentinela `(-1,-1)` sem pool), amostragem/fallback no fragment; built-ins com UV (cubo: projeção planar (x,z) por vértice — os 8 vértices são compartilhados entre 3 faces; planta: cruz com [0,1]² por quad); nota no histórico da VS-00; `DESCRIPTOR_SET_BINDING_COUNT` 19 → 20; `spirv-val` limpo nos 3 shaders.
3. ~~**VS-11-IMPL-03 — Validação de carga**~~ **Concluída (2026-11-06).** (REQ-UV-04; AC-03). `validate_template_uvs` no espelho Odin: UVs em [0,1]² quando o template tem pool, erro com índice do template e do vértice; caso injetado de rejeição confirmado (carga abortada) e revertido; template sem UV segue válido.
4. ~~**VS-11-IMPL-04 — Evidências e fechamento**~~ **Concluída (2026-11-06).** (AC-01..03). Sims verdes (AC-01), paridade pixel a pixel baseline × VS-11 com capturas externas (AC-02), casos de validação de carga (AC-03); docs (VS-02 emendada, VS-00, arquitetura §6, manual técnico, tracking) e commit com o nome da spec.

## Questões abertas

- **Rotação yaw × UV:** o mesh shader rotaciona as posições; UVs de templates com texturas direcionais (atlas por face) precisam de unwraps simétricos à rotação ou de templates por rotação. Com a paleta sólida atual o efeito é nulo. Backlog — não bloqueia a aprovação.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (UVs em vez de triplanar, preparando shapes customizados); ADR-U1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-U1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-11-IMPL-01..04 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..04) e validação verificada (AC-01..03).** Números: `render_sim.py` 2.906 checks (0 falhas; 54 novos no cenário VS-11: componentes do `MeshVertex` 10 ≤ 128, bounds [0,1]² dos built-ins, sentinela exclusa, roundtrip emissão→fragmento, paridade de cor UV × triplanar na paleta sólida 3 blocos × 50 amostras, orçamento 256v/192t inalterado com UV); `pack_sim.py` 968 checks (0 falhas). Contratos: binding 19 (`template_uvs`, 8 KiB device-local, stride 8 B), `MeshTemplate.uv_offset` (32 B preservados; sentinela interna de ausência `NO_TEMPLATE_UV_OFFSET = 0xFFFFFFFF`), `MeshVertex` 8 → 10 componentes (`TEXCOORD0`), `DESCRIPTOR_SET_BINDING_COUNT` 19 → 20. Built-ins: cubo com projeção planar (x,z) por vértice (simplificação registrada — vértices compartilhados entre 3 faces; unwrap por face exigiria duplicação), planta com [0,1]² por quad da cruz. AC-02: paridade pixel a pixel com o baseline obtida por capturas externas da janela (GDI/PowerShell; `PrintWindow` não funciona com swapchain Vulkan): 2 frames idênticos a 10 s de intervalo em cada build, **0 pixels diferentes** na área cliente (800×593) entre o build pré-VS-11 (via `git stash` temporário) e o pós-VS-11; `spirv-val` limpo nos 3 shaders; smoke de 60 s sem erros de validation novos (os 10 erros `vkGetQueryPoolResults: query not reset` do log pertencem à telemetria da VS-05 e são pré-existentes). AC-03: UV `1.5` injetada no vértice 3 do cubo (teste temporário revertido) abortou a carga com erro nomeando template e vértice; template sem UV (pesado/ar) segue válido via sentinela → triplanar. Capturas em `bin/shot_{uv,base}_{a,b}.png` (gitignored). Questão aberta de rotação yaw × UV mantida em backlog.
