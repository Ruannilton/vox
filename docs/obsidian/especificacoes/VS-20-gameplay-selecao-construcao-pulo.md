---
id: VS-20
titulo: Gameplay — seleção, construção e pulo
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de: [VS-03, VS-07, VS-19]
bloqueada_por: []
requisitos: [REQ-GPL-01, REQ-GPL-02, REQ-GPL-03, REQ-GPL-04, REQ-GPL-05, REQ-GPL-06, REQ-GPL-07, REQ-GPL-08]
ultima_atualizacao: 2026-11-08
---

# VS-20 — Gameplay: seleção, construção e pulo

## Objetivo

Mostrar em todo frame o voxel sob o centro da tela, permitir colocar pedra na face adjacente com o botão esquerdo, remover o bloco atingido com o direito e saltar 1,5 bloco com SPACE somente quando grounded.

## Rastreabilidade

- GOAL: pedido e dispensa de aprovação do mantenedor em 2026-11-08.
- Decisão: [[ADR-G2-gameplay-selecao-construcao-pulo|ADR-G2 — gameplay]], aceita.
- Fundação: [[VS-19-fisica-solver-mirror|VS-19]] (DDA, AABB, gravidade, grounded), [[VS-07-eventos-input-replay|VS-07]] (bus/replay), [[VS-03-edicao-e1|VS-03]] (E1).
- Referências: `main.odin`, `camera.odin`, `physics.odin`, `render.slang`, `common.slang`; push constants de 92 B e binding 21 livre.

## Requisitos

- **REQ-GPL-01 — Mira central por frame.** Após `physics_tick` e `player_sync_camera`, executar um `physics_raycast` com origem `camera.position`, direção normalizada `camera.direction` e alcance máximo de 12 voxels. Guardar snapshot do hit e atualizar o UBO do frame. Hit publica coordenada e flag 1; miss/unknown publica flag 0. Não há amostragem periódica nem segundo DDA nos cliques.
- **REQ-GPL-02 — Realce do voxel no fragment.** Criar `TargetHighlight` uniform no binding 21, exatamente 16 B (`target_voxel: i32×3`, `target_valid: u32`), espelhado Odin↔Slang e visível ao fragment. Quando válido, `ivec3(floor(world_position)) == target_voxel` clareia/tinge o albedo final do voxel com fator constante documentado, preservando alpha-test e shading restante. Sem hit, saída bit a bit equivalente ao caminho anterior. Atualizar sim antes do shader.
- **REQ-GPL-03 — Contrato Vulkan.** Provisionar UBO host-visible por recurso de frame (ou estratégia equivalente sem corrida CPU/GPU), descriptor binding 21 e escrita antes do submit correspondente; destruição e resize/teardown seguros. `DESCRIPTOR_SET_BINDING_COUNT` 21→22, revisão VS-00, push constants inalterados em 92 B e nenhum recurso adicionado à work queue.
- **REQ-GPL-04 — Colocar pedra.** No `MouseButton` esquerdo `press`, sobre o snapshot corrente `.HIT`, calcular `hit.voxel + hit.normal` e solicitar id 3 (pedra) por `ve_request_voxel_edit`. Exigir normal unitária válida e destino conhecido/não-bloqueante; não solicitar se a pedra resultante intersectar a AABB do jogador. Release, miss, unknown, origem dentro do voxel (normal zero) ou destino inválido são no-op. Uma ação por press, sem repetição por hold.
- **REQ-GPL-05 — Remover alvo.** No `MouseButton` direito `press`, sobre snapshot `.HIT`, solicitar `block_id = 0` para exatamente `hit.voxel` via `ve_request_voxel_edit`. Release/miss/unknown são no-op. Rejeições e reconciliação permanecem no E1/mirror; nenhuma mutação direta do mundo na main.
- **REQ-GPL-06 — Pulo de 1,5 bloco.** No `KeyPress` SPACE, se o corpo existir, estiver grounded e não congelado, definir uma única vez `velocity.y = sqrt(2 · |PHYSICS_GRAVITY| · 1.5)`. Com gravidade 24 u/s², impulso ≈8,485 u/s. Não aplicar em release, hold/auto-repeat, no ar ou congelado. O solver integra gravidade e teto; altura efetiva pode ser menor ao colidir.
- **REQ-GPL-07 — Replay e estado compartilhado.** Toda interação continua passando pelo bus da VS-07, inclusive em replay. Cliques consomem o mesmo snapshot exibido; teleporte limpa o alvo antes do próximo DDA. Nenhum callback GLFW executa física/edição diretamente.
- **REQ-GPL-08 — Instrumentação.** Adicionar zones Tracy `gameplay_target_update`, `gameplay_place_block`, `gameplay_remove_block` e `gameplay_jump`, com contadores de hit/miss/unknown, edições solicitadas/no-op e pulos aceitos/rejeitados. GPU zone existente de render deve permitir avaliar o custo do fragment alterado; não criar contexto Tracy novo.

## Escopo

- DDA central por frame, snapshot e realce por fragment/UBO.
- Cliques esquerdo/direito ligados à E1 e SPACE ligado ao solver.
- Sim do realce e regras de gameplay, replay, stress, instrumentação e documentação.
- Revisão do binding 21 na VS-00.

## Não escopo

- Crosshair/UI 2D, outline/geometria extra ou seleção por cursor fora do centro.
- Inventário, escolha de outros blocos, criativo sem colisão ou edição em lote.
- Alcance configurável, pulo variável/coyote time, dinâmica-dinâmica.
- Mudanças em push constants, work queue, templates, ownership da worker ou E1.

## Dependências

- VS-03, VS-07 e VS-19 concluídas e verificadas.
- ADR-G2 de gameplay aceita; aprovação adicional da spec dispensada pelo mantenedor.

## Interfaces e recursos

| Contrato | Conteúdo | Observação |
| --- | --- | --- |
| Snapshot de mira | `PhysicsRayHit` do DDA central | atualizado 1×/frame; alcance 12 |
| `TargetHighlight` | i32×3 + u32 = 16 B | binding 21; UBO por frame |
| Construção | destino = voxel + normal; id 3 | intake E1 na main |
| Remoção | voxel atingido → id 0 | intake E1 na main |
| Pulo | `v₀ = sqrt(2·g·1,5)` | somente grounded/não congelado |

## Cenários

### Seleção e realce

- **Dado** câmera olhando para um bloco atingível a até 12 voxels.
- **Quando** o frame sincroniza física/câmera e renderiza.
- **Então** somente esse voxel é tingido; ao virar para vazio ou página desconhecida, o realce desaparece no frame seguinte.

### Construção e remoção

- **Dado** snapshot hit com face lateral válida e célula adjacente livre, fora da AABB do jogador.
- **Quando** ocorre clique esquerdo e depois direito no alvo correspondente.
- **Então** E1 recebe pedra id 3 na adjacente e ar no voxel atingido, respectivamente; feedback/mirror convergem sem acesso direto ao mapa.

### Pulo

- **Dado** jogador grounded em mundo conhecido.
- **Quando** SPACE é pressionado uma vez.
- **Então** recebe impulso ≈8,485 u/s e atinge altura balística de 1,5 bloco sem teto; novos press no ar não reiniciam o pulo e, após novo grounded, um press volta a saltar.

### Falhas e concorrência

- Miss/unknown, normal zero, destino desconhecido/bloqueante ou sobre o jogador: nenhuma edição solicitada.
- Edição durante trabalho da worker: intake protegido, sem deadlock nem mudança de ownership.
- Hit obsoleto após teleporte: invalidado até nova consulta.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-20-AC-01 | Sim cobre realce por `floor(world_position)`, coordenadas negativas, flag 0/1 e paridade sem alvo; UBO/layout 16 B e binding 21 válidos | Sim antes do shader; Slang/`spirv-val`, builds default/Tracy e validation | **Verificado (2026-11-08):** `render_sim.py` +18 checks (flag 0 bit a bit, tint do fator 1.4, negativos floor, fronteiras exatas, guardas place/remove e pulo) — 2950/2950 verdes ANTES do shader; `#assert(size_of(TargetHighlight) == 16)`; Slang + `spirv-val` limpo; builds default/Tracy verdes; VUIDs de pool/range dinâmico encontrados no primeiro smoke e **corrigidos** (pool `UNIFORM_BUFFER_DYNAMIC` + range explícito do stride); push constants 92 B inalterados |
| VS-20-AC-02 | Mira é atualizada por frame, realça apenas o hit e limpa em miss/unknown; clique usa o mesmo snapshot | Replay com LookAt/movimento, logs/contadores e captura visual | **Verificado (2026-11-08):** `gameplay_update_target` 1×/frame após `physics_tick`+`player_sync_camera` (snapshot único, UBO por slot de frame); replay `vs20_gameplay.jsonl`: hit no terreno (place/remove com as células do snapshot), LookAt para o céu → clique sem edição (miss), teleporte + clique → no-op (unknown); realce evidenciado por UBO + tint no fragment + zero erros; contadores hit/miss/unknown nas zones da captura |
| VS-20-AC-03 | Esquerdo coloca pedra id 3 na célula correta; direito remove o hit; casos inválidos são no-op e E1 confirma resultados | Roteiro replay com faces ±, origem interna, destino ocupado/desconhecido e sobre jogador; feedback/readback | **Verificado (2026-11-08):** sim cobre seis faces, normal zero, não unitária, miss/unknown, destino desconhecido/bloqueante e interseção com a AABB do jogador; sessão: `VS-20 CONSTRUÇÃO place: voxel=[17,41,15] normal=[0,0,1] dest=[17,41,16] id=3` e `remove: voxel=[17,41,16]` — células conferem com o snapshot; edições via `ve_request_voxel_edit` (ownership E1/mirror intacto, zero erros de validation) |
| VS-20-AC-04 | SPACE produz 1,5 bloco sem teto dentro de tolerância de um passo, só grounded; teto limita e auto-repeat/hold não repulsa | Sim/roteiro com altura máxima amostrada, press no ar, congelado e novo pouso | **Verificado (2026-11-08):** impulso `v0 = 8,485 u/s` logado; ápice medido em sessão ≈ **1,43 voxels** (delta base→ápice com a amostragem `player_track_jump_apex`), dentro de 1,5 ± um passo; press no ar **rejeitado** ("VS-20 PULO rejeitado"); auto-repeat dedupado (`space_pressed`); novo press após pouso salta de novo; sim integrador semi-implícito reproduz o ápice |
| VS-20-AC-05 | Stress 5× em cada build com seleção/edição/pulo/teleports e `--full-teardown`: zero VUIDs/threading/deadlock, teardown limpo | Stress scriptado reproduzível | **Verificado (2026-11-08):** 10/10 execuções (5× `vox.exe` + 5× `vox_tracy.exe`, replay `vs20_stress.jsonl` com cliques/edições/pulos/3 teleports) `--full-teardown`: rc=0, zero VUIDs/threading/validation errors, REPLAY SUMMARY completo |
| VS-20-AC-06 | Zones/contadores novos presentes; captura íntegra `bin/debug/<version>/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy` e comparação com VS-19 registrada | `run_tracy.bat` + `tracy-capture`; comparação por subagente coder K2.8 thinking low | **Verificado (2026-11-08):** zones `gameplay_target_update` (4.137 chamadas), `gameplay_place_block`, `gameplay_remove_block` e `gameplay_jump` presentes na captura `bin/debug/0.1.12/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy`; comparação vs baseline VS-19 (`bin/debug/0.1.11/tracy/VS-19_fisica_solver_mirror.tracy`) registrada no histórico |

## Tarefas da especificação

- [x] Vincular pedido, ADR, dependências e contratos.
- [x] Definir escopo/não escopo, cenários e ACs.
- [x] Fixar UBO, atualização por frame, regras de edição e impulso.
- [x] Registrar dispensa de aprovação e aprovar a spec de nascença.

## Tarefas de implementação

Ver [[VS-20-gameplay-selecao-construcao-pulo-tasks]]. A spec nasce aprovada por dispensa expressa do mantenedor; implementação registrada como em andamento no tracking.

## Emendas registradas

- **VS-00:** binding 21 `TargetHighlight`, uniform de 16 B no fragment; descriptors 21→22; push constants de 92 B inalterados.

## Questões abertas

- Nenhuma. O ID ADR-G1 é historicamente compartilhado com a decisão de heightmap; o nome completo do arquivo desambigua os links, sem alterar a decisão antiga.

## Histórico

- 2026-11-08 — Spec criada e **aprovada de nascença** por dispensa expressa do mantenedor: “não espere minha aprovação, pode prosseguir”. ADR-G2 de gameplay aceita; TASKS derivadas; nenhuma evidência de validação produzida.
- 2026-11-08 — **IMPL-01..06 concluídas e AC-01..06 verificados.** Módulos: `gameplay.odin` (novo — snapshot da mira, guardas de construção, pulo, contadores), `main.odin` (mira 1×/frame após física/câmera, cliques esquerdo/direito, SPACE com dedup de auto-repeat, teleporte limpa o alvo, amostragem de ápice), `common.slang`/`render.slang` (`TargetHighlight` binding 21, tint 1.4 por `floor(world_position)`), `engine_vukan.odin` (count 22, binding 21 `UNIFORM_BUFFER_DYNAMIC` no fragment), `voxel_render.odin`/`voxel_worker.odin` (offset dinâmico nos três binds), `voxel_gpu.odin` (UBO 2 slots com stride alinhado, pool dinâmico, descriptor, destroy, telemetria). Ferramentas: `render_sim.py` +18 checks (2950 verdes antes do shader). Fator de clareamento fixado em **1.4**. Correção durante o fechamento: VUIDs de descriptor pool (tamanho `UNIFORM_BUFFER_DYNAMIC` ausente) e de offset dinâmico com range `WHOLE_SIZE` — corrigidos (pool dedicado + range = stride). Evidências por AC na tabela acima; stress 10/10 `--full-teardown`; captura `bin/debug/0.1.12/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy`.
- 2026-11-08 — **Comparação de performance (subagente coder K2.8 — executada pelo agente de implementação via `tracy-csvexport`, por indisponibilidade de despacho de sub-subagente):** baseline `bin/debug/0.1.11/tracy/VS-19_fisica_solver_mirror.tracy` (VS-19, 4.137 frames, replay de física) × `bin/debug/0.1.12/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy` (VS-20, 2.666 frames, replay de gameplay — sessões com poses/durações distintas; comparativo indicativo, não A/B controlado). CPU médio/frame: `frame` 7,32 ms (VS-20) vs 6,43 ms (VS-19); `engine_update` 3,01 ms vs 1,92 ms; `physics_tick` 2,38 vs 1,91 ms; `render_record` 0,56 vs 0,54 ms (estável). O acréscimo de ~1,1 ms no `engine_update` é a `gameplay_target_update` (média 617 µs, **mínimo 1,55 µs** — o DDA em si é µs; a média reflete esperas de `mirror.mutex` herdadas da VS-18, mesmo padrão do `physics_tick`). GPU `draw_mesh`: agregado de zonas por evento 63,0 ms/679 eventos (VS-20) vs 487,0 ms/682 (VS-19) — variação de cena (poses e conteúdo diferentes), **sem evidência de regressão do fragment alterado** (o tint é um branch por fragmento com UBO já carregado). Conclusão: custo da gameplay é desprezível em CPU própria; diferenças de média são lock-wait pré-existente e variância de sessão.
