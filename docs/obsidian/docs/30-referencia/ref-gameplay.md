---
id: REF-GAMEPLAY
titulo: "Referência: gameplay (mira, construção, pulo)"
tipo: docs
ultima_atualizacao: 2026-11-06
---

# Referência: `gameplay`

Contratos struct-a-struct e proc-a-proc do módulo de gameplay: `src/engine/gameplay.odin` — mira central com realce no fragment, construção/remoção por clique (intake E1) e pulo. Contexto e porquê: [[sistema-edicao-eventos]] (intake E1, input) e [[sistema-mirror-fisica]] (raycast DDA, corpos do jogador); quadro macro: [[visao-geral]]. Genealogia: spec VS-20 (`docs/obsidian/especificacoes/VS-20-gameplay-selecao-construcao-pulo.md`), decisão ADR-G2 (`docs/obsidian/decisoes/ADR-G2-gameplay-selecao-construcao-pulo.md`).

> **Dono das threads**: gameplay roda **inteiro na main**. Raycast e `voxel_get` leem o mirror sob `ve.mirror.mutex` (ver contenção BLK-41 em [[sistema-mirror-fisica]]); as edições saem pela única porta de produção da main, `ve_request_voxel_edit` (domínio `ve.edit.mutex`, consumo na worker — ver [[ref-edit-mirror]]). Nenhum estado do `GameplayManager` é compartilhado com outra thread.

## Constantes

| Constante | Valor | Contrato |
| --- | --- | --- |
| `TARGET_HIGHLIGHT_TINT` (`:11`) | `1.4` | Fator de clareamento do voxel-alvo (REQ-GPL-02). Usado **só no fragment shader** (`render.slang:282`); a CPU não o aplica — é a fonte de verdade do tom. |
| `GAMEPLAY_REACH` (`:12`) | `f32(12.0)` | Alcance máximo do DDA da mira central, em voxels (REQ-GPL-01). Passado como `max_distance` de `physics_raycast`. |
| `GAMEPLAY_BLOCK_PLACE_ID` (`:13`) | `u32(3)` | Block id colocado pelo clique esquerdo: pedra. Não é configurável. |
| `JUMP_HEIGHT_VOXELS` (`:14`) | `f32(1.5)` | Altura-alvo do pulo em voxels (REQ-GPL-06). O impulso é derivado: `v0 = sqrt(2·|gravidade|·h)`. |

## Structs

#### `TargetHighlight` (`:17-20`)

`{target_voxel: [3]i32, target_valid: u32}` — 16 B, espelhamento bit a bit de `TargetHighlight` em `common.slang:216` (REQ-GPL-02). Guardado por `#assert(size_of(TargetHighlight) == 16)`: qualquer mudança de layout quebre a compilação antes de chegar à GPU. É o payload do UBO dinâmico do binding 21 — ver [[ref-shaders]].

#### `GameplayManager` (`:24-34`)

Estado do gameplay, embutido em `VoxelEngine` (`ve.gameplay`). Domínio exclusivo: a thread main; sem mutex.

| Campo | Contrato |
| --- | --- |
| `target: PhysicsRayHit` | Snapshot do DDA central do frame corrente. **Toda ação de clique consome este snapshot** — é o mesmo voxel exibido pelo realce (REQ-GPL-04/05/07). Zeros (`gameplay_clear_target`) até o próximo `gameplay_update_target`. |
| `stats_target_hit/miss/unknown: u64` | Contadores do resultado do DDA por frame (`.HIT` também publica o realce). |
| `stats_edits: u64` | Edições solicitadas ao E1 (place + remove). |
| `stats_noop: u64` | Ações de clique rejeitadas pelas guardas (alvo inválido, normal inválida, destino ocupado, interseção com o jogador). |
| `stats_jumps: u64` | Impulsos de pulo aplicados. |
| `stats_jumps_rejected: u64` | Pulos rejeitados (jogador no ar ou congelado). |
| `stats_jumps_logged: u64` | Âncora de dedup do rastreador de ápice em `main.odin` (`player_track_jump_apex`, AC-04 da spec). |

## Lifecycle

#### `gameplay_init` (`:36`)

`ve.gameplay = GameplayManager{}` — estado zerado. Chamado na inicialização do engine.

#### `gameplay_destroy` (`:40`)

No-op; não há recursos próprios (o UBO pertence a `voxel_gpu`).

## Mira e realce

#### `gameplay_update_target` (`:44`) — **main**, 1×/frame

Chamada na main **após** `physics_tick` + `player_sync_camera` e **antes** do submit do frame (ordem exata em `main.odin:203-209`, REQ-GPL-01):

1. `physics_raycast(ve, origin, direction, GAMEPLAY_REACH)` — DDA sobre o mirror, sob `ve.mirror.mutex` (ver [[ref-physics-tracing]]). `origin`/`direction` vêm da câmera.
2. Grava o resultado em `ve.gameplay.target` (snapshot do frame) e contabiliza `hit/miss/unknown`.
3. Publica o realce: escreve `TargetHighlight` no slot `frame_index` do UBO mapeado (`target_highlight_ubo_mapped[frame_index * alignment]`). Slot `.HIT` → `target_valid = 1` + coordenada; demais → `target_valid = 0` (realce apagado).

O fragment (`render.slang:282-283`) clareia o fragment cujo `floor(world_position)` igualar `target_voxel` — o desenho do realce é 100% GPU; a CPU só publica a coordenada.

**Sincronização**: o UBO é um buffer host-mapped com um slot por frame em voo (`NUM_FRAMES_IN_FLIGHT`); escrever no slot do `frame_index` corrente é seguro porque aquele slot já foi consumido (o frame que o usava já completou). No submit, `voxel_render` (`voxel_render.odin:245-246`) rebinda o descriptor set com offset dinâmico `alignment * frame_index`. Recursos e criação do UBO: [[ref-voxel-gpu]] (binding 21, `DESCRIPTOR_SET_BINDING_COUNT :: 22`).

#### `gameplay_clear_target` (`:64`)

`ve.gameplay.target = {}` — invalida o alvo (REQ-GPL-07). Chamado pela main no handler de `TeleportTo` (`main.odin:156`): após teleportar câmera e corpo, o snapshot antigo ficaria stale até o próximo DDA; zerar evita clique/remoção num alvo que não é mais o exibido. O realce em si apaga no próximo `gameplay_update_target`.

## Cliques (place / remove)

#### `gameplay_mouse_press` (`:70`) — **main** (handler de `MouseButton`)

Consome o snapshot `ve.gameplay.target` — nunca relê o mundo. Guardas rejeitadas somam `stats_noop` e retornam sem efeito.

**`button == 0` — place** (`ZoneN("gameplay_place_block")`):
1. `hit.result != .HIT` ou normal zero → noop.
2. Normal deve ser de **exatamente um eixo unitário** (exatamente 1 componente ≠ 0) — normais compostas não dão destino bem-definido → noop.
3. `destination = hit.voxel + hit.normal`; `voxel_get(ve, destination)` deve ser **conhecido** (`known`) e **não-bloqueante** (`block_is_blocking(block_id)` falso — ar ou não-sólido). Destino desconhecido (chunk fora do mirror) ou ocupado → noop.
4. Anti-autointerseção: se houver corpo de jogador, `gameplay_aabb_intersects_voxel(player.position, player.size, destination)` → noop. A pedra nunca pode nascer dentro da AABB do jogador.
5. Log + `ve_request_voxel_edit(ve, destination, GAMEPLAY_BLOCK_PLACE_ID)` + `stats_edits += 1`.

**`button == 1` — remove** (`ZoneN("gameplay_remove_block")`):
1. `hit.result != .HIT` → noop.
2. Log + `ve_request_voxel_edit(ve, hit.voxel, 0)` — **id 0 é ar** (regra 2 do AGENTS.md: slot 0 da paleta nunca é reciclado, remoção = reescrever para ar). `stats_edits += 1`.

> **Contrato E1**: `ve_request_voxel_edit` (`voxel_edit.odin:38`) é a única porta de edição; não bloqueia além de `ve.edit.mutex`, coalesce por voxel e acorda a worker. O feedback (aplicada/noop) volta via `edit_collect_feedback` na worker — o gameplay não espera confirmação. Detalhes: [[ref-edit-mirror]].

## Pulo

#### `gameplay_jump` (`:114`) — **main** (callback de key press do SPACE)

1. Guarda: `player == nil`, `!player.grounded` ou `player.frozen` → rejeitado (`stats_jumps_rejected`). Só pula quem está apoiado e livre.
2. Impulso único: `velocity.y = sqrt(2·|PHYSICS_GRAVITY|·JUMP_HEIGHT_VOXELS)` = `sqrt(2·24·1.5) ≈ 8,49 u/s` — cinemática invertida para a altura-alvo de 1,5 voxel, com a gravidade do solver ([[ref-physics-tracing]]). `stats_jumps += 1`.

**Dedup do SPACE**: `gameplay_jump` roda **só no press**; o auto-repeat do GLFW é descartado pela main — `space_pressed` (`main.odin:21,525-534`) marca o press e só libera no release. Hold e auto-repeat não geram impulso extra (REQ-GPL-06). O ápice é amostrado por `player_track_jump_apex` (AC-04), ancorado em `stats_jumps_logged`.

## Helpers

#### `gameplay_aabb_intersects_voxel` (`:126`) — `proc "contextless"`

Teste AABB-vs-voxel eixo a eixo (voxel = 1 unidade³ — regra 1 do AGENTS.md): há separação em qualquer eixo → não intersecta. Usado só pela guarda anti-autointerseção do place.

## Contratos e invariantes (resumo)

- Snapshot único por frame: mira, realce e cliques veem **o mesmo** `PhysicsRayHit`; teletransporte zera o alvo até o próximo DDA (REQ-GPL-07).
- Realce é dado, não estado de render: a CPU publica coordenada+validade no binding 21; o tom (`TARGET_HIGHLIGHT_TINT`) e o desenho vivem no fragment.
- Place nunca intersecta o jogador e nunca escreve em voxel desconhecido/ocupado; remove só em hit e sempre escreve ar (id 0).
- Pulo é impulso no press, grounded e não-congelado; altura derivada de `JUMP_HEIGHT_VOXELS` e `PHYSICS_GRAVITY`.
- Todo estado é da main; a única fronteira cross-thread é o intake do E1 (mutex) e as leituras de mirror (mutex) — nunca há write-write.

## Cross-references

- [[ref-main]] — ordem do frame, handlers de input, dedup do SPACE, rastreador de ápice.
- [[ref-physics-tracing]] — `physics_raycast` (DDA), `PhysicsRayHit`, `PhysicsBody`, `PHYSICS_GRAVITY`, `physics_tick`.
- [[ref-edit-mirror]] — `ve_request_voxel_edit`, coalescência, feedback do E1.
- [[ref-voxel-gpu]] / [[ref-voxel-render]] / [[ref-shaders]] — UBO dinâmico do binding 21, offset por frame, `TargetHighlight` no Slang.
- [[sistema-edicao-eventos]], [[sistema-mirror-fisica]], [[visao-geral]].
