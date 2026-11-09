---
id: SISTEMA-MIRROR-FISICA
titulo: Mirror e física
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Mirror e física

O mundo existe em uma única verdade — **worldgen determinístico + journal de edições E1** — com duas views materializadas: a packed na VRAM (render) e a densa na RAM (**mirror**). Este documento cobre a view densa (o que ela é, como se preenche e como permanece convergente) e o **solver de física** de gameplay que roda sobre ela. Contexto macro: [[visao-geral]]; detalhes por procedimento: [[ref-edit-mirror]], [[ref-physics-tracing]].

## Por que existe (princípio C2)

Gameplay precisa consultar voxels na CPU em O(1) por voxel — colisão, raycast, spawn, saves — sem readbacks de VRAM e sem conhecer o formato packed (bitmask de brick + paleta + planos). As alternativas rejeitadas: regenerar worldgen na CPU (exigiria determinismo bit-exato de ponto flutuante CPU↔GPU) e ler device-local via Resizable BAR (latência no hot path). Decisão: [[ADR-C2-mirror-cpu|ADR-C2]], especificada em [[VS-04-mirror-c2|VS-04]].

Duas consequências estruturais definem tudo aqui:

- **Convergência por construção** — a verdade é worldgen + journal; as views apenas a materializam. O mirror não é uma segunda autoridade: o generate GPU *é* o readback (a escrita do shader alimenta o ring), e o **journal E1 é dual-aplicado** (GPU e mirror na mesma ordem, mesmo dedup, mesmo teto), com `edit_seq` paritário por página (paridade bit a bit verificável em debug). Como o export contém só worldgen, edições feitas enquanto a página está pendente são **retidas e replayadas** na materialização.
- **Mundo fora da bolha é desconhecido, nunca ar** — a consulta é tri-state e a política é do consumidor. Nenhuma ausência de página produz queda através do mundo.

## Formato da ChunkPage

Cada página (`MirrorChunkPage`, `src/engine/voxel_types.odin:169`) espelha um chunk 32³:

| Campo | Tamanho | Layout / semântica |
| --- | --- | --- |
| `ids` | 64 KiB (`[32768]u16`) | grid denso **sem paleta**, índice **y-contíguo** `y \| z<<5 \| x<<10` (regra 7 — nunca misturar com o índice x-contíguo do scratch GPU); uma coluna vertical = 64 B contíguos = 1 linha de cache |
| `solid` | 4 KiB (`[1024]u32`) | bitmask de sólido derivado do registry por id (`block_is_solid` — planta ocupa mas não sólida); é a broadphase binária da física |
| `heights` | 2 KiB (`[1024]u16`) | heightmap de coluna, índice **z-contíguo** `x \| z<<5` (propositalmente diferente do grid); y do sólido mais alto da coluna, `0xFFFF` = vazia |
| cabeçalho + logs | — | `coord`, `state`, `ring_slot`, `edit_seq`; `pending` / `applied_log` / `rejected_log` para o journal |

Página ≈ 70,1 KiB (`#assert(size_of(MirrorChunkPage) == 71824)`), pool fixo de `config.mirror_pages` páginas (768 no default; a bolha raio 5 tem ~523 chunks) com endereços estáveis — o mapa `coord → ^página` guarda ponteiros.

### Heights medidos, não exportados

A VS-13 ([[ADR-G1-heightmap-geracao-mirror|ADR-G1]]) introduziu o `heights` preenchido de um ring GPU paralelo (binding 20). A VS-19 ([[ADR-F1-fisica-solver-mirror|ADR-F1]], REQ-PHY-07) o **derivou do bitmask `solid` na materialização**: cada uma das 1.024 colunas é varrida (≤ 32 bits) e o topo sólido real é medido — imune a topologias não-heightfield (arcos, blocos flutuantes), que dessincronizariam uma fórmula analítica. O ring `mirror_heightmap_ring` (binding 20) e seu write no `generate_voxels` **permanecem como reserva futura** (ex.: validação cruzada em debug), mas o materialize o ignora. O journal do E1 mantém o campo em `mirror_page_apply` (`voxel_mirror.odin:506`): sólido acima do topo sobe; remoção do topo rescanza a coluna (32 leituras); os demais casos são no-op. Paridade verificável por `debug_heights_parity` (`voxel_mirror.odin:353`).

## Estados, ring e bolha de simulação

Estados da página (`MirrorPageState`):

```
PENDING_READBACK ──(materialize)──▶ MATERIALIZED
      │                                    │
      └──────────(evicção: chunk saiu da bolha)──▶ página devolvida ao pool
```

- **PENDING_READBACK** — página recém-adquirida; a leitura retorna desconhecido. O preenchimento vem do **ring de export** (binding 16): 64 slots × 64 KiB host-visible. O `generate_voxels` escreve o grid u16 diretamente no slot quando `job.mirror_ring_slot >= 0` — a escrita do shader *é* o readback, sem pool device-local nem `vkCmdCopyBuffer`. Chunk já gerado agenda um re-export **`export_only`** (fila `pending_export_tasks`, 1 por lote, **nunca roda pack** — repackar a partir do scratch apagaria edições já aplicadas no packed). Chunk `EMPTY` (só ar, VS-10) nem precisa de export: a página é preenchida com zeros + replay do journal na CPU (`mirror_page_fill_empty`).
- **Materialização** (`mirror_materialize_from_ring`, `voxel_mirror.odin:221`) — roda no handler de conclusão de lote: validação anti-ABA completa (página viva com o mesmo `ring_slot`; entrada do ring casa (coord, geração); chunk ativo com mesma (slot, geração) e fora de `GENERATING`), acquire de host por `WaitSemaphores(0)` no valor da timeline (visibilidade das escritas do compute) + `InvalidateAllocation`, cópia ring→página, reconstrução da bitmask, derivação do `heights`, replay de `rejected_log`/`applied_log`/`pending`, abertura (`edit_seq += 1`) e **liberação do slot** — nenhum slot em voo é liberado fora do handler (regra 4).
- **Bolha de simulação** — raio próprio (`RADIUS_SIMULATION = 5`, independente da bolha de render), gerenciada por `mirror_update_bubble`: páginas fora do raio são evictadas (`mirror_forget_chunk`, que também cancela/agenda exports e respeita a regra 4 para slots em voo); chunks dentro do raio sem página são pedidos (`mirror_request_page`); páginas `PENDING` sem slot tentam todo frame em `mirror_service_retries` (attach à geração pendente ou re-export). Pool/ring cheios só contam miss e tentam de novo — nunca falham o frame.
- **Reconciliação** — edição rejeitada pela GPU (`REJECTED_*`, overflow de paleta) volta pelo feedback do E1: a página marca `PENDING_READBACK` de novo e, na rematerialização, replaya o `applied_log` **sem** as rejeitadas — convergência exata com o packed.

## Journal E1 mantendo a página

`mirror_journal_apply` (`voxel_mirror.odin:130`) roda no ponto de staging do flush do E1 — a mesma edição alimenta GPU e mirror. Página `PENDING`: a edição vai para `pending` (dedup última-escrita-vence). Página `MATERIALIZED`: aplica direto em `ids`/`solid`/`heights` e registra em `applied_log`. Chunks fora da bolha não têm página: só a GPU recebe o journal. Detalhes do journal em si: [[sistema-edicao-eventos]] e [[VS-03-edicao-e1|VS-03]].

## API tri-state

Toda consulta pública do mirror é protegida por `ve.mirror.mutex` (a worker é dona da mutação desde a VS-18; a main lê só por estas APIs):

- `voxel_get(world_voxel) -> (VoxelSample{id, solid}, ok)` — `ok=false` = desconhecido (sem página ou `PENDING_READBACK`); `voxel_is_solid` deriva dele.
- `mirror_column_ground(world_x, world_z, y_from) -> (ground_y, ok)` — varredura para baixo cruzando fronteiras de chunk; `ok=false` se tocar página desconhecida.
- `mirror_height_get(chunk, x, z) -> (ok, height)` — O(1) por coluna; `0xFFFF` = coluna vazia.
- `mirror_request(chunk)` — pedido de página sob demanda, não bloqueante.

O desconhecido nunca inventa bloco; cada consumidor define sua política (a física congela — abaixo).

## Física

Solver CPU autoritativo de gameplay sobre o mirror (VS-19, [[ADR-F1-fisica-solver-mirror|ADR-F1]]; módulo `src/engine/physics.odin`). GPU fica fora da física; não há segunda representação estática.

**Dados.** `PhysicsDefinition` por id de bloco, exclusivamente CPU-side, carregada do `blocks.json` (com validador e fallback built-in): flags `BLOCKING`/`HITTABLE` (+ `CLIMBABLE`/`LIQUID` reservadas), fricção e restituição. O bitmask `solid` filtra candidatos; `ids` + a tabela resolvem a semântica. `BlockDefinition` std430 de 48 B não muda — shaders não consomem física.

**Tempo** (`physics_tick`). Passo fixo `PHYSICS_FIXED_DT = 1/60` com acumulador na main; `frame_dt` é clampado em 0,25 s e o excesso além de 5 passos por frame é **descartado documentado** (anti espiral de morte). Mesmo estado inicial + mesma sequência de inputs ⇒ mesmo resultado no processo; replay best-effort (VS-07), sem bit-exatidão entre plataformas.

**Movimento** (`physics_step`). Cada corpo é uma AABB alinhada à grade (`PhysicsBody`). Por passo: gravidade (−24, velocidade terminal −60) → grounded via `physics_ground_probe` (fast-path de chão — abaixo) → sweep **eixo a eixo na ordem estável X→Y→Z** (`physics_sweep_axis`), com subdivisão do deslocamento em incrementos ≤ 0,4 unidade (anti-tunneling: nunca atravessa um voxel sem teste). Contatos param só o componente do eixo (sliding), zero a velocidade (ou aplicam restituição do bloco de contato) e alimentam o step-up: no máximo 1 voxel, só com espaço livre para a AABB inteira na altura elevada **e** apoio bloqueante no destino — caso contrário reverte. `grounded` é recalculado por contato real a cada passo, nunca persistido.

**Fast-path de chão** (`physics_ground_probe`). Quando todas as colunas cobertas pela AABB têm topo conhecido ≠ `0xFFFF`, estão no mesmo chunk XZ e o corpo está inteiramente acima do topo mais alto (fora de interiores/cavernas/sobreposição), o apoio é decidido em O(1)/coluna via `heights`. Qualquer ambiguidade (coluna vazia, travessia de chunk, corpo abaixo do topo, página ausente, deslocamento vertical) cai no sweep completo — a equivalência com o sweep é provada por `tools/sim/physics_sim.py`. O heightmap nunca elimina testes de teto/paredes.

**Mundo desconhecido** (REQ-PHY-06). Se qualquer consulta do passo tocar página ausente/em readback: o **passo inteiro é descartado** — a posição/velocidade/grounded voltam ao estado inicial do passo, o corpo marca `frozen` e a coordenada entra no map coalescido `pending_requests` (dedup; `physics_drain_requests`, chamado pela worker sob `mirror.mutex` dentro do `mirror_update_bubble`, converte em `mirror_request_page`). Sem stall síncrono, sem teleporte, sem presumir ar; ao materializar, o movimento retoma nos passos seguintes. O raycast usa o mesmo padrão: página desconhecida antes do limite ⇒ `UNKNOWN`, nunca `MISS`.

**Raycast** (`physics_raycast`). Amanatides & Woo sobre coordenadas inteiras do mirror: percorre só os voxels atravessados, consulta `HITTABLE` (planta é atingível sem bloquear movimento), retorna coordenada/id, distância e normal da face. Rejeições definidas: distância ≤ 0 ou direção nula ⇒ `MISS` sem percorrer; origem dentro de voxel ⇒ célula da origem testada primeiro (normal nula).

## Contenção conhecida: mutex de página (BLK-41)

O solver consulta voxel a voxel, cada consulta pegando `ve.mirror.mutex`, e a worker detém o mesmo mutex pelo update inteiro (VS-18). Resultado medido no fechamento da VS-19: ~1,9 ms/frame de lock-wait no `engine_update` (máximos de 151 ms na travessia de bolha). O custo CPU do solver em si é mínimo (µs). Candidatos de otimização no backlog: batch de consultas sob um único lock por corpo/passo, snapshot de página para o passo, ou redução da região crítica da worker. Ver `docs/obsidian/tracking/backlog.md` (BLK-41).

## Coordenação com os demais sistemas

- [[sistema-streaming-mundo]] — a worker dona do mundo executa os pedidos de página e o materialize no handler de conclusão; anti-ABA por coord+geração segue o ciclo de vida B1.
- [[sistema-edicao-eventos]] — journal E1 (dual-apply, feedback de rejeições, reconciliação).
- [[sistema-renderizacao]] — o mirror nunca toca a fila gráfica; a bolha de simulação é independente da bolha de render.

Genealogia: [[VS-04-mirror-c2|VS-04]] (mirror), [[VS-13-heightmap-geracao-mirror|VS-13]] (heightmap, emendado pela VS-19), [[VS-19-fisica-solver-mirror|VS-19]] (física); decisões [[ADR-C2-mirror-cpu|ADR-C2]], [[ADR-G1-heightmap-geracao-mirror|ADR-G1]], [[ADR-F1-fisica-solver-mirror|ADR-F1]].
