---
id: VS-20
titulo: Gameplay — seleção, construção e pulo
tipo: especificacao
status_spec: aprovada
status_implementacao: em-andamento
status_validacao: nao-iniciada
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
- Decisão: [[ADR-G1-gameplay-selecao-construcao-pulo|ADR-G1 — gameplay]], aceita.
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
- ADR-G1 de gameplay aceita; aprovação adicional da spec dispensada pelo mantenedor.

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
| VS-20-AC-01 | Sim cobre realce por `floor(world_position)`, coordenadas negativas, flag 0/1 e paridade sem alvo; UBO/layout 16 B e binding 21 válidos | Sim antes do shader; Slang/`spirv-val`, builds default/Tracy e validation | Pendente |
| VS-20-AC-02 | Mira é atualizada por frame, realça apenas o hit e limpa em miss/unknown; clique usa o mesmo snapshot | Replay com LookAt/movimento, logs/contadores e captura visual | Pendente |
| VS-20-AC-03 | Esquerdo coloca pedra id 3 na célula correta; direito remove o hit; casos inválidos são no-op e E1 confirma resultados | Roteiro replay com faces ±, origem interna, destino ocupado/desconhecido e sobre jogador; feedback/readback | Pendente |
| VS-20-AC-04 | SPACE produz 1,5 bloco sem teto dentro de tolerância de um passo, só grounded; teto limita e auto-repeat/hold não repulsa | Sim/roteiro com altura máxima amostrada, press no ar, congelado e novo pouso | Pendente |
| VS-20-AC-05 | Stress 5× em cada build com seleção/edição/pulo/teleports e `--full-teardown`: zero VUIDs/threading/deadlock, teardown limpo | Stress scriptado reproduzível | Pendente |
| VS-20-AC-06 | Zones/contadores novos presentes; captura íntegra `bin/debug/<version>/tracy/VS-20_gameplay_selecao_construcao_pulo.tracy` e comparação com VS-19 registrada | `run_tracy.bat` + `tracy-capture`; comparação por subagente coder K2.8 thinking low | Pendente |

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

- 2026-11-08 — Spec criada e **aprovada de nascença** por dispensa expressa do mantenedor: “não espere minha aprovação, pode prosseguir”. ADR-G1 de gameplay aceita; TASKS derivadas; nenhuma evidência de validação produzida.
