---
id: ADR-B11
titulo: Culling de frustum por brick no builder
tipo: decisao
status: aceita
specs_afetadas: [VS-06]
ultima_atualizacao: 2026-11-06
---

# ADR-B11 — Culling de frustum por brick no builder

## Contexto

O culling de frustum ficou no backlog da VS-02 (REQ-VIS-04 registra o TODO; o `build_work_queue` tem o marcador no código). Sem ele, todo brick `RENDERABLE` no raio de visão — até 2.109 chunks × 1.024 bricks — gera itens na fila de trabalho e despacha grupos de mesh shader, inclusive os que estão inteiramente atrás da câmera. O culling existente (vazio + oclusão B2) não leva o frustum em conta. A pergunta é **onde** o frustum entra no pipeline e **quem** deriva os planos.

## Requisitos relacionados

- REQ-CULL-01..05 da [[VS-06-culling-frustum|VS-06]].
- REQ-VIS-04 da [[VS-02-task-mesh-templates|VS-02]] (backlog que esta decisão implementa).

## Opções

### Opção A — Planos derivados na GPU no builder (Gribb-Hartmann)

- O builder compute (`build_work_queue`, fila gráfica) extrai os 6 planos do frustum da `view_projection_matrix` **já presente** nos push constants — a mesma matriz que o mesh shader usa para `clip_position`, então o frustum testado é exatamente o frustum renderizado.
- Culling em dois níveis: early-out do chunk (AABB 32³ fora → workgroup inteiro retorna sem ler ocupação) e por brick (AABB 4×2×4 fora → nenhum item anexado), com teste conservador (p-vertex: só cull se o AABB estiver completamente do lado de fora de um plano).
- Vantagens: zero mudança de contrato (VS-00 intacta, push constants de 88 B preservados), zero custo de CPU por frame, coerência bit a bit com o clip do mesh shader, cai exatamente no ponto onde a fila é montada (nenhum grupo é despachado para brick culpado).
- Desvantagens: a derivação dos planos depende da convenção de clip Vulkan (NDC z ∈ [0,1], y para baixo) e do layout `column_major` — exige validação rigorosa na simulação antes da integração (workflow do AGENTS.md).

### Opção B — Planos calculados na CPU e enviados por push constants

- A CPU extrai os 6 planos por frame e os envia ampliando `VoxelPushConstants` (88 B → ~184 B), revisando o contrato da VS-00.
- Vantagens: derivação testável direto em Odin; o shader só testa AABBs.
- Desvantagens: revisão do contrato fundacional (VS-00) e de todos os pontos que gravam push constants; mais 96 B por `CmdPushConstants` por frame; risco de dessincronia se algum caminho gravar VP e planos de frames diferentes; trabalho de CPU por frame para algo que a GPU faz de graça em ALU ocioso.

## Decisão

**Opção A** — planos derivados na GPU no builder (Gribb-Hartmann sobre a `view_projection_matrix` dos push constants), culling em dois níveis (early-out de chunk + por brick), teste conservador (p-vertex). Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-06.

## Consequências

- Contrato VS-00 preservado; nenhum push constant novo.
- A correção passa a depender da simulação: `tools/sim/render_sim.py` deve provar que a derivação de planos (float32, `column_major`, NDC Vulkan) casa com um oracle independente (projeção dos 8 cantos do AABB para clip space) antes de qualquer integração nos shaders.
- O TODO de frustum no `build_work_queue` é resolvido; a tabela de backlog da arquitetura e a REQ-VIS-04 da VS-02 ganham referência cruzada a esta decisão na implementação.
- Contadores de bricks culpados ficam fora de escopo (backlog; a queda é observável pelo readback do estado da fila, `x` do draw indireto).

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-06 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-06.
