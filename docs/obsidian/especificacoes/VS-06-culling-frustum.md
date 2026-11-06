---
id: VS-06
titulo: Culling de frustum
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: em-validacao
depende_de:
  - VS-02
bloqueada_por: []
requisitos: [REQ-CULL-01, REQ-CULL-02, REQ-CULL-03, REQ-CULL-04, REQ-CULL-05, REQ-SIM-04]
ultima_atualizacao: 2026-11-06
---

# VS-06 — Culling de frustum

## Objetivo

Não despachar grupos de mesh shader para bricks (nem workgroups de builder para chunks) que estão inteiramente fora do campo de visão da câmera, eliminando o item de backlog deixado pela VS-02 (REQ-VIS-04) — sem alterar nenhum pixel da geometria que intersecta o frustum e sem mudar o contrato de push constants da VS-00.

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 5](../../arquitetura.md) (culling hierárquico; o backlog de otimizações de visibilidade citado na VS-02) e [Manual Técnico](../../manual-tecnico.md) — pipeline de renderização.
- Referência: `build_work_queue` em `src/assets/shaders/render.slang` (contém o TODO de frustum na Fase 1) e os helpers de renderização em `src/assets/shaders/common.slang`; simulação existente `tools/sim/render_sim.py`.
- Decisões: [[ADR-B11-culling-frustum|ADR-B11]] (onde o frustum entra e quem deriva os planos — **bloqueia a aprovação desta spec**).
- Fundação: [[VS-02-task-mesh-templates|VS-02]] fornece o builder da fila de trabalho (ADR-B10), a fila global (binding 17), os push constants com `view_projection_matrix` e o mecanismo de readback do estado da fila; [[VS-05-telemetria-profiling|VS-05]] fornece labels/timestamps já gravados em volta do builder (não é dependência de implementação).

## Requisitos

### Extração de planos

- **REQ-CULL-01** — O builder compute deriva os 6 planos do frustum (método de Gribb-Hartmann) da `view_projection_matrix` dos push constants — a **mesma** matriz que o mesh shader aplica em `clip_position`, então o frustum testado é exatamente o frustum rasterizado. Planos normalizados (divisão pela norma de xyz), na convenção Vulkan (clip = VP × mundo; NDC x,y ∈ [−1,1], z ∈ [0,1]; y para baixo). Nenhum push constant novo; o layout `column_major` e o tamanho de 88 B da VS-00 são preservados.

### Culling hierárquico no builder

- **REQ-CULL-02** — Early-out de chunk: o AABB do chunk (`chunk_world_origin`, extensão 32³) é testado contra o frustum **antes** de qualquer leitura de ocupação; se estiver completamente fora, o workgroup inteiro retorna sem anexar itens (teste de workgroup uniforme, sem divergência).
- **REQ-CULL-03** — Culling por brick: na seleção do builder (Fases 1 e 2 — a Fase 2 rederiva deterministicamente a Fase 1, mesmo padrão do culling de oclusão), um brick cujo AABB (`chunk_world_origin + brick_coord × BRICK_SIZE`, extensão `BRICK_SIZE` = 4×2×4 — **não cúbico**) esteja completamente fora do frustum não gera itens. A decisão é tomada no nível do brick inteiro (não por parte/subdivisão), o que é conservador para as subdivisões do Caminho B. Ordem dos testes por brick: word de ocupação vazia → frustum → oclusão B2 (o frustum vem antes da oclusão para economizar as 6 leituras de vizinhos de bricks fora de tela).

### Conservadorismo e invariantes

- **REQ-CULL-04** — Correção: o teste é o p-vertex clássico — um AABB é culpado **apenas se** estiver inteiramente do lado de fora de um único plano (o vértice mais positivo na direção da normal falha o plano). AABBs que intersectam o frustum ou estão dentro jamais são culpados. Consequência verificável: a seleção de bricks que tocam a tela é **idêntica** à da VS-02 — a imagem renderizada não muda nem um pixel para geometria visível.
- **REQ-CULL-05** — Nenhum impacto no orçamento de mesh shader (regra 5 do AGENTS.md): o culling acontece antes da fila; grupos despachados continuam garantidos ≤ 256 vértices / 192 triângulos pela subdivisão do pack. O determinismo do builder (contagem na Fase 1 = itens escritos na Fase 2) e o protocolo de overflow da fila global permanecem válidos.

### Simulação

- **REQ-SIM-04** — Antes da integração, `tools/sim/render_sim.py` é estendido cobrindo: (a) derivação de planos **bit a bit** (float32, `column_major`, NDC Vulkan) contra um oracle independente — os 8 cantos do AABB projetados para clip space pelo VP, com o box fora sse todos os cantos estão do mesmo lado de um mesmo plano; (b) casos de dados-limite — brick dentro, fora por cada um dos 6 planos, intersectando o frustum, atrás da câmera, atrás do plano near, AABB degenerado; (c) granularidade chunk (early-out) e brick (4×2×4); (d) cenário de câmera no horizonte mostrando a redução da contagem de itens e a **invariância** da seleção dos bricks que intersectam o frustum em relação à simulação sem culling.

## Escopo

- Helpers de frustum no `common.slang` (derivação de planos + teste AABB, espelhados na simulação).
- Modificação do `build_work_queue`: early-out de chunk e culling por brick nas Fases 1 e 2, resolvendo o TODO existente.
- Extensão de `tools/sim/render_sim.py` (REQ-SIM-04).
- Resolução do backlog: referência cruzada na REQ-VIS-04 da VS-02 e atualização da tabela de registros/backlog da arquitetura.
- Validação: smoke test com validation layers, comparação de screenshots com câmera travada (conteúdo em tela inalterado) e readback do estado da fila (queda de `x` do draw indireto).

## Não escopo

- Culling de oclusão por Hi-Z, LOD e qualquer outra otimização de visibilidade.
- Culling no mesh shader ou por parte/subdivisão (a granularidade é o brick).
- Contadores de bricks culpados na telemetria da VS-05 (a queda é observável pelo readback do `x` da fila; backlog).
- Mudança de push constants, de contratos de descritores ou de capacidades da fila de trabalho.
- Edição, mirror e streaming (invariantes B1/B3 e regras do AGENTS.md intactas).

## Dependências

- [[VS-02-task-mesh-templates|VS-02]] concluída e verificada (builder, fila global, push constants com VP, readback do estado).
- [[ADR-B11-culling-frustum|ADR-B11]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: planos derivados na GPU no builder).

## Interfaces e recursos

### Contratos novos (common.slang, espelhados na simulação)

| Contrato | Assinatura | Observação |
| --- | --- | --- |
| `frustum_planes_from_vp` | `float4x4 → float4[6]` | xyz = normal (para dentro), w = offset; plano normalizado. Ordem: left, right, bottom, top, near, far |
| `aabb_outside_frustum` | `(min, max, planes[6]) → bool` | true apenas se o vértice positivo falhar algum plano (conservador) |

- Sem estruturas novas de memória, sem bindings novos, sem push constants novos. A derivação é função pura sobre os push constants existentes.

### Sequência do frame (integração)

Inalterada em relação à VS-02/ADR-B10 — o culling mora **dentro** do dispatch existente do `build_work_queue`:

```
fill do estado do work_queue → barrier → build_work_queue (AGORA COM: early-out de
  chunk + frustum por brick antes da oclusão) → finalize_work_queue → draw indireto
```

### Comportamento quando limites são atingidos

- Todos os casos-limite da VS-02 permanecem: fila vazia ⇒ `x = 0`; overflow sinalizado com clamp pelo finalize; vizinho inválido conservador na oclusão.
- Frustum degenerado (VP singular) não ocorre na prática (matrizes de visão/projeção válidas); mesmo assim o teste p-vertex com AABB que intersecta o volume resultante mantém o comportamento conservador — o pior caso é não culpar.
- Câmera dentro do chunk: o AABB do chunk intersecta o frustum ⇒ nada é culpado no early-out (teste correto por construção).

## Cenários

### Cenário de sucesso

- **Dado** a bolha materializada (VS-01) e a câmera dentro do terreno olhando para o horizonte.
- **Quando** frames avançam com o culling ativo.
- **Então** o readback do estado da fila mostra `x` (itens do draw indireto) significativamente menor que o da VS-02 para a mesma pose (chunks e bricks atrás da câmera não geram itens), o frame renderizado é pixel-identificado ao da versão sem culling para o conteúdo em tela, e não há erros de validation.

### Brick atrás da câmera / atrás do plano near

- **Dado** um brick totalmente atrás do plano near.
- **Quando** o builder avalia o seu AABB.
- **Então** o brick é culpado (os 8 cantos falham o plano near no oracle da simulação; o p-vertex confirma), nenhum item é anexado, e nenhum pixel visível é afetado.

### Brick intersectando a borda do frustum

- **Dado** um brick cujo AABB cruza um plano lateral do frustum.
- **Quando** o builder avalia.
- **Então** o brick **não** é culpado (p-vertex passa no plano) e a seleção é idêntica à da VS-02 — borda da tela sem artefatos nem sumiço de geometria.

### Chunk inteiramente fora (early-out)

- **Dado** um chunk `RENDERABLE` totalmente atrás da câmera.
- **Quando** o seu workgroup do builder inicia.
- **Então** o early-out dispara antes de qualquer leitura de ocupação e nenhum item é anexado — sem custo de memória do chunk.

### Falhas e concorrência

- O culling é função pura dos push constants do frame (VP daquele frame); nenhuma nova corrida é introduzida — o ring de 2 slots da fila e a espera da timeline gráfica seguem governando a reutilização.
- Recriação de swapchain: nada a recriar (viewport/scissor dinâmicos da VS-02).

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-06-AC-01 | A derivação de planos no shader casa bit a bit com o oracle de projeção de cantos (float32, NDC Vulkan), incluindo dados-limite (atrás da câmera, near, degenerado) | Simulação: derivação vs oracle em casos exaustivos por plano + configurações aleatórias com numpy float32; `spirv-val` limpo após a integração | **Verificado (2026-11-06)** — `tools/sim/render_sim.py`: 400 VPs aleatórios float32 × 4 AABBs (1.600 casos decisivos, margem > 1e-6 rel.), decisão GH float32 == oracle exato (f64) em todos; dados-limite por plano (fora/intersectando cada um dos 6), atrás da câmera, atrás do near, AABB degenerado, VP zero (NaN conservador); `spirv-val` limpo em `render.spv`/`edit.spv`/`voxel.spv` |
| VS-06-AC-02 | Bricks que intersectam o frustum são selecionados identicamente à VS-02 (nenhum pixel visível muda); bricks fora não geram itens | Simulação: cenário de câmera no horizonte comparando a seleção com/sem culling (invariância da interseção + redução da contagem) + smoke test com câmera travada comparando screenshots | **Verificado na simulação; em-validação no app (2026-11-06)** — sim: 4 poses de horizonte com invariância da seleção (todo brick intersectante intacto, todo culpado fora pelo oracle exato) e redução 16.377 → 15.546/2.747/14.266/2.668 itens. App: cobertura de tela idêntica nas 3 poses travadas (0 pixels viraram cor de clear, 0 adicionados; `bin/shot_pose{1,2,4}_{before,after}.raw/.png`), mas a comparação pixel a pixel não é idêntica (~147 mil bytes/ pose 1) — ver ressalva de z-fighting no histórico |
| VS-06-AC-03 | O draw indireto despacha menos grupos com a câmera olhando para o horizonte e nenhum grupo a mais em nenhuma pose | Readback do estado da fila (`x` do draw indireto) em poses travadas distintas vs. baseline sem culling, com validation layers limpos | **Verificado (2026-11-06)** — readback sincronizado do estado da fila com o mundo convergido (20 leituras estáveis): baseline sem culling = **43.503** itens (pose-independente, em todas as 3 poses); com frustum = **7.211** (horizonte, −83%), **7.918** (para baixo, −82%), **13.819** (para trás, −68%); nenhuma pose aumentou. Bisecção por plano no app: near culpa ~36,2 mil (atrás da câmera), left 31 bricks, right 15, far 4, top/bottom 0 — coerente com a geometria. Erros de validation: apenas os 10 pré-existentes da VS-05 (`vkGetQueryPoolResults` query not reset); zero erros novos |

## Tarefas da especificação

- [x] Vincular os requisitos (REQ-CULL-01..05, REQ-SIM-04) ao backlog da VS-02 (REQ-VIS-04).
- [x] Definir escopo, não escopo e interfaces (helpers puros; sem contrato novo de memória).
- [x] Cobrir sucesso, dados-limite e concorrência.
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-B11 e obter aprovação da spec. — ADR-B11 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-B11. Cada tarefa referencia requisitos e critérios de aceitação.

1. **VS-06-IMPL-01 — Simulação de frustum** (REQ-SIM-04; AC-01, AC-02). Estender `tools/sim/render_sim.py`: derivação de planos vs oracle de cantos (casos por plano, aleatórios float32), dados-limite, granularidade chunk/brick (4×2×4), cenário de horizonte com invariância da interseção e redução de itens.
2. **VS-06-IMPL-02 — Helpers de frustum no `common.slang`** (REQ-CULL-01, REQ-CULL-04; AC-01). `frustum_planes_from_vp` + `aabb_outside_frustum` na convenção Vulkan, espelhando a simulação; compilar com `run.bat` sem avisos e validar com `spirv-val`.
3. **VS-06-IMPL-03 — Culling no `build_work_queue`** (REQ-CULL-02, REQ-CULL-03, REQ-CULL-05; AC-02, AC-03). Early-out de chunk antes da leitura de ocupação; frustum por brick na Fase 1 e rederivado na Fase 2, na ordem vazio → frustum → oclusão; remover o TODO.
4. **VS-06-IMPL-04 — Resolução do backlog e docs** (REQ-VIS-04 da VS-02). Referência cruzada na VS-02, atualização da tabela de registros/backlog da `docs/arquitetura.md`, frontmatter/tracking.
5. **VS-06-IMPL-05 — Evidências e fechamento** (AC-01..03). Smoke test com validation layers: screenshots com câmera travada (conteúdo em tela inalterado) + readback do `x` da fila em poses distintas vs. baseline; registrar evidências nos ACs, atualizar tracking e commitar com o nome da spec.

## Questões abertas

- Baseline de comparação: as capturas atuais (`bin/shot1..3.png`) foram geradas sem o mecanismo de câmera travada desta spec? Se sim, o AC-03 fixa seu próprio baseline pré-mudança (capturas com o código da VS-02 antes do IMPL-03) — registrado como procedimento do AC-03, não bloqueia a aprovação.
- Ordem canônica dos planos (left, right, bottom, top, near, far): fixada na implementação e registrada aqui. Não bloqueia a aprovação.

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (culling de frustum para não disparar mesh shaders de bricks fora do campo de visão); ADR-B11 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-B11 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-06-IMPL-01..05 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..04)**: (1) `tools/sim/render_sim.py` estendido para 2.659 checks (era 210) — derivação GH float32 vs oracle independente de projeção de cantos (1.600 casos decisivos aleatórios, float32 espelhado via `struct` por operação, numpy indisponível), dados-limite por plano, degenerado, atrás da câmera/near, early-out de chunk, AABB 4×2×4 não cúbico e cenário de horizonte com invariância da seleção (16.377 → 15.546/2.747/14.266/2.668 itens nas 4 poses); (2) `frustum_planes_from_vp` + `aabb_outside_frustum` no `common.slang` (Gribb-Hartmann, NDC Vulkan z ∈ [0,1], ordem left/right/bottom/top/near/far, p-vertex); (3) `build_work_queue` com early-out de chunk (antes de header/ocupação) e culling por brick na ordem vazio → frustum → oclusão nas Fases 1 e 2, TODO removido; (4) docs: tabela de registros da arquitetura (§5 e §9), referência cruzada na REQ-VIS-04 da VS-02.
- 2026-11-06 — **Bugs encontrados e corrigidos durante a validação**: (a) `vp[i]` em `column_major float4x4` no Slang retorna a **coluna** i (verificado por `spirv-dis`: `OpCompositeExtract` direto na matriz), não a linha — a primeira versão do helper derivava os planos das colunas e nunca culpava nada (sintoma: `x` idêntico ao baseline); corrigido rederivando as linhas por transposição dentro do helper, com comentário de contrato; (b) a primeira instrumentação de readback (command buffer da fila compute + `DeviceWaitIdle` na main thread) competia com a worker e gerava erros de threading do validation layer — reescrito com pool/fence próprios na fila gráfica, sem `DeviceWaitIdle`.
- 2026-11-06 — **Validação (IMPL-05)**: `spirv-val` limpo nos três SPIR-V; smoke tests com `VK_LAYER_KHRONOS_validation` ativa em 3 poses travadas (horizonte, para baixo, para trás) com câmera fixada por variável de ambiente e readback sincronizado do estado da fila. Baseline sem culling convergido: 43.503 itens em todas as poses; com frustum: 7.211/7.918/13.819 (nunca acima do baseline). Bisecção plano a plano confirmou as decisões de culling (near ≈ 36,2 mil itens atrás da câmera, left/right/far/top/bottom triviais). **Ressalva AC-02 (em-validação)**: a comparação pixel a pixel antes/depois não é idêntica (~147 mil bytes na pose 1, 1.224 na pose 2, ~268 mil na pose 4) mesmo com a cobertura de tela idêntica (zero pixels viraram cor de clear em todas as poses, zero adicionados). A causa é o z-fighting pré-existente da cena (artefatos em "lâminas" já conhecidos desde a VS-02/B6): qualquer mudança no conjunto/ordem da fila muda os vencedores de profundidade em faces coincidentes — o diff é invariante a qual plano do frustum se desabilite e reproduz byte a byte entre execuções da mesma configuração. Confirmação visual humana da equivalência pendente; evidências em `bin/shot_pose{1,2,4}_{before,after}.raw/.png`. Erros de validation: somente os 10 pré-existentes da telemetria VS-05 (`vkGetQueryPoolResults`: query not reset), zero erros novos; sims `render_sim.py` (2.659) e `pack_sim.py` (959) verdes. Instrumentação temporária do smoke test removida do código ao final.
