---
id: SISTEMA-MIRROR-FISICA
titulo: Mirror e física
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Mirror e física

Bem-vindo a um dos documentos mais importantes do motor. Até aqui você viu, na [[visao-geral]], que o mundo tem **duas views materializadas** de uma mesma verdade: uma compacta na VRAM, para a GPU renderizar, e uma densa na RAM, para a CPU jogar. Este documento é um tour guiado pela segunda — o **mirror** — e pelo **solver de física** que roda em cima dela. Vamos devagar: cada conceito interno aparece primeiro com o que é, onde vive e por que existe, e só depois entra no raciocínio.

Contexto macro: [[visao-geral]]; detalhes por procedimento: [[ref-edit-mirror]], [[ref-physics-tracing]].

## Os conceitos que você precisa antes de começar

Leia esta seção primeiro; daqui em diante usamos tudo sem cerimônia.

- **Journal (E1)** — o log append-only de edições do jogador (quebrar, colocar bloco), o segundo termo da verdade do mundo: `VERDADE = worldgen determinístico + journal`. Vive no subsistema de edição (`voxel_edit`, ver [[sistema-edicao-eventos]] e [[VS-03-edicao-e1|VS-03]]). Por que existe? Porque não se persiste o mundo inteiro: ele se *reconstrói* do worldgen, e o journal reaplica por cima só o que o jogador mudou — poucos bytes em vez de megabytes de voxels.
- **ChunkPage** (`MirrorChunkPage`, `src/engine/voxel_types.odin:169`) — a estrutura que espelha um chunk 32³ na RAM: grid denso de ids, bitmask de sólido, heightmap e cabeçalho com logs de edição. É a "página" de um chunk no mirror. Por que página e não só um array? Porque uma página é uma unidade de vida: ela nasce, fica pronta, recebe edições e é evictada como um todo, num pool de endereços estáveis — muito mais simples de gerenciar do que alocar voxels avulsos.
- **`edit_seq`** — um contador por página, incrementado a cada abertura de materialização. É o "relógio" que diz *esta página já viu até qual edição?* Por que importa? Porque edição e worldgen chegam por caminhos diferentes e fora de ordem; o `edit_seq` permite deduplicar e ordenar sem comparar coordenadas de voxel.
- **Tri-state** — toda consulta ao mirror responde três coisas: `id`+`solid` conhecidos, ou `ok=false` = **desconhecido**. Por que não um booleano? Porque "fora da bolha de simulação" não significa "ar": significa "não sabemos". Se mentíssemos "ar", o jogador cairia através de um chão que simplesmente não foi gerado ainda.
- **Bitmask** — aqui, um mapa de bits com 1 bit por voxel (32³ = 32.768 bits = 4 KiB por chunk), dizendo só "sólido/não-sólido". É a **broadphase** da física: uma pergunta binária baratíssima ("há *algo* aqui?") antes da pergunta cara ("o que é?"). Por que duas views em vez de uma? Porque o formato packed da GPU (bitmask de brick + paleta + planos) é ótimo para fabricar culling e péssimo para responder "que bloco está aqui?"; o mirror denso responde isso em O(1), mas custaria caro na VRAM — cada view é otimizada para o seu cliente.
- **Heightmap medido** — uma tabela de 1.024 entradas (32×32 colunas XZ) com a altura do sólido mais alto de cada coluna, **calculada varrendo a bitmask** no momento em que a página é materializada — não exportada de fórmula nem copiada de um ring. Por que medido e não calculado? Porque o mundo não é heightfield: existem arcos e blocos flutuantes, e uma fórmula analítica dessincronizaria na primeira caverna. Medir o bitmask é imune a isso.
- **Timestep com acumulador** — a física não roda "uma vez por frame": o tempo real de cada frame vai para um acumulador, e enquanto houver `1/60` s acumulado, roda um passo fixo. Por quê? Porque frames variam (2 ms, 7 ms, um engasgo de 100 ms) e a simulação precisa de passos iguais para ser determinística e estável — a variabilidade fica no *número* de passos, nunca no tamanho deles.
- **AABB** — a caixa alinhada aos eixos (eixo X paralelo ao mundo, etc.) que é a forma de colisão de cada corpo. Por que AABB e não malha arbitrária? Porque testar uma AABB contra um grid de voxels é aritmética inteira simples; testar malha genérica contra voxels custaria ordens de magnitude mais e nada no gameplay precisa de mais que uma caixa.
- **Sweep eixo a eixo** — o movimento não é resolvido de uma vez: a AABB se desloca primeiro no eixo X (inteiro), depois Y, depois Z, e cada eixo resolve suas próprias colisões antes de o próximo começar. Por que? Porque resolver os três eixos juntos cria contatos ambíguos (diagonais falsas, cantos que grudam); eixo a eixo dá sliding natural (bater na parede não te par no ar) e é a ordem estável que torna o replay reproduzível.
- **DDA** (Amanatides & Woo) — o algoritmo de raycast que atravessa um grid voxel a voxel, saltando de célula em célula pelo plano de borda mais próximo, sem amostragem. Por que DDA e não amostragem contínua? Porque amostragem pula voxels finos (planta, parede de 1); o DDA visita *exatamente* os voxels que a linha toca.
- **Freeze** — quando a física toca uma página desconhecida, o **passo inteiro é descartado**: posição, velocidade e estado de apoio voltam ao início do passo e o corpo marca `frozen`. Por que congelar em vez de esperar? Porque esperar síncrono é stall de frame (regra: a main nunca trava), e presumir "ar" é cair através do mundo. Congelar é a terceira opção: honesta e barata — a página é pedida, e quando chega o movimento retoma.

## Por que existe (princípio C2)

Gameplay precisa consultar voxels na CPU em O(1) por voxel — colisão, raycast, spawn, saves — sem readbacks de VRAM e sem conhecer o formato packed. As alternativas rejeitadas: regenerar worldgen na CPU (exigiria determinismo bit-exato de ponto flutuante CPU↔GPU) e ler device-local via Resizable BAR (latência no hot path). Decisão: [[ADR-C2-mirror-cpu|ADR-C2]], especificada em [[VS-04-mirror-c2|VS-04]].

Duas consequências estruturais definem tudo aqui:

- **Convergência por construção** — a verdade é worldgen + journal; as views apenas a materializam. O mirror não é uma segunda autoridade: o generate GPU *é* o readback (a escrita do shader alimenta o ring de export, como veremos), e o journal E1 é **dual-aplicado** (GPU e mirror na mesma ordem, mesmo dedup, mesmo teto), com `edit_seq` paritário por página (paridade bit a bit verificável em debug). Como o export contém só worldgen, edições feitas enquanto a página está pendente são **retidas e replayadas** na materialização.
- **Mundo fora da bolha é desconhecido, nunca ar** — a consulta é tri-state e a política é do consumidor (a física escolheu freeze, lá embaixo). Nenhuma ausência de página produz queda através do mundo.

## O formato da ChunkPage

Cada página (`MirrorChunkPage`, `src/engine/voxel_types.odin:169`) espelha um chunk 32³. Estes são os campos, um a um:

| Campo | Tamanho | Layout / semântica |
| --- | --- | --- |
| `ids` | 64 KiB (`[32768]u16`) | grid denso **sem paleta**, índice **y-contíguo** `y \| z<<5 \| x<<10` (regra 7 — nunca misturar com o índice x-contíguo do scratch GPU); uma coluna vertical = 64 B contíguos = 1 linha de cache |
| `solid` | 4 KiB (`[1024]u32`) | bitmask de sólido derivado do registry por id (`block_is_solid` — planta ocupa mas não sólida); é a broadphase binária da física |
| `heights` | 2 KiB (`[1024]u16`) | heightmap de coluna, índice **z-contíguo** `x \| z<<5` (propositalmente diferente do grid); y do sólido mais alto da coluna, `0xFFFF` = vazia |
| cabeçalho + logs | — | `coord`, `state`, `ring_slot`, `edit_seq`; `pending` / `applied_log` / `rejected_log` para o journal |

Repare no desenho: os três primeiros campos são exatamente as três velocidades de consulta que a gameplay precisa — "que bloco é?" (`ids`, via bitmask de ocupação implícita), "há algo aqui?" (`solid`, 1 bit), "onde está o chão da coluna?" (`heights`, 1 leitura). Página ≈ 70,1 KiB (`#assert(size_of(MirrorChunkPage) == 71824)`), num pool fixo de `config.mirror_pages` páginas (768 no default; a bolha raio 5 tem ~523 chunks) com endereços estáveis — o mapa `coord → ^página` guarda ponteiros.

### Heights medidos, não exportados

Uma história de duas specs que vale contar. A VS-13 ([[ADR-G1-heightmap-geracao-mirror|ADR-G1]]) introduziu o `heights` preenchido de um ring GPU paralelo (binding 20). A VS-19 ([[ADR-F1-fisica-solver-mirror|ADR-F1]], REQ-PHY-07) o **derivou do bitmask `solid` na materialização**: cada uma das 1.024 colunas é varrida (≤ 32 bits) e o topo sólido real é medido — imune a topologias não-heightfield (arcos, blocos flutuantes), que dessincronizariam uma fórmula analítica. O ring `mirror_heightmap_ring` (binding 20) e seu write no `generate_voxels` **permanecem como reserva futura** (ex.: validação cruzada em debug), mas o materialize o ignora. O journal do E1 mantém o campo em `mirror_page_apply` (`voxel_mirror.odin:506`): sólido acima do topo sobe; remoção do topo rescanza a coluna (32 leituras); os demais casos são no-op. Paridade verificável por `debug_heights_parity` (`voxel_mirror.odin:353`).

## Estados, ring e bolha de simulação

A vida de uma página é curta e bem definida (`MirrorPageState`):

```
PENDING_READBACK ──(materialize)──▶ MATERIALIZED
      │                                    │
      └──────────(evicção: chunk saiu da bolha)──▶ página devolvida ao pool
```

- **PENDING_READBACK** — a página nasce vazia; toda consulta nela responde "desconhecido" (tri-state) até que ela seja preenchida. O preenchimento vem do **ring de export** (binding 16): 64 slots × 64 KiB host-visible. Aqui está o truque elegante do desenho: o `generate_voxels` escreve o grid u16 diretamente no slot quando `job.mirror_ring_slot >= 0` — a escrita do shader *é* o readback, sem pool device-local nem `vkCmdCopyBuffer`. Chunk já gerado agenda um re-export **`export_only`** (fila `pending_export_tasks`, 1 por lote, **nunca roda pack** — repackar a partir do scratch apagaria edições já aplicadas no packed). Chunk `EMPTY` (só ar, VS-10) nem precisa de export: a página é preenchida com zeros + replay do journal na CPU (`mirror_page_fill_empty`).
- **Materialização** (`mirror_materialize_from_ring`, `voxel_mirror.odin:221`) — roda no handler de conclusão de lote (a rotina `voxel_engine_service_completions`, em `voxel_engine.odin`, que a worker executa para processar os lotes que a GPU terminou — e a única com licença para liberar slot). O que ela faz, em ordem: validação anti-ABA completa (página viva com o mesmo `ring_slot`; entrada do ring casa coord+geração; chunk ativo com mesma (slot, geração) e fora de `GENERATING`), acquire de host por `WaitSemaphores(0)` no valor da timeline (visibilidade das escritas do compute) + `InvalidateAllocation`, cópia ring→página, reconstrução da bitmask, derivação do `heights` medido, replay de `rejected_log`/`applied_log`/`pending`, abertura (`edit_seq += 1`) e **liberação do slot** — nenhum slot em voo é liberado fora do handler (regra 4).
- **Bolha de simulação** — o mirror tem raio próprio (`RADIUS_SIMULATION = 5`, independente da bolha de render: você pode ver longe mas só *tocar* perto), gerenciada por `mirror_update_bubble`: páginas fora do raio são evictadas (`mirror_forget_chunk`, que também cancela/agenda exports e respeita a regra 4 para slots em voo); chunks dentro do raio sem página são pedidos (`mirror_request_page`); páginas `PENDING` sem slot tentam todo frame em `mirror_service_retries` (attach à geração pendente ou re-export). Pool/ring cheios só contam miss e tentam de novo — nunca falham o frame.
- **Reconciliação** — nem toda edição é aceita: a GPU pode rejeitar (overflow de paleta, `REJECTED_*`), e essa rejeição volta pelo feedback do E1. A página marca `PENDING_READBACK` de novo e, na rematerialização, replaya o `applied_log` **sem** as rejeitadas — convergência exata com o packed, porque ambos partiram da mesma verdade e só divergiram por edições que a GPU recusou.

## O journal E1 mantendo a página quente

Uma edição nunca toca só a GPU ou só o mirror: `mirror_journal_apply` (`voxel_mirror.odin:130`) roda no ponto de staging do flush do E1 — a mesma edição alimenta as duas views. E aqui o `edit_seq` e os logs ganham sentido:

- Página `PENDING`: a edição não pode ser aplicada em dados que ainda não chegaram, então vai para `pending` (dedup última-escrita-vence — duas edições no mesmo voxel antes da materialização colapsam numa).
- Página `MATERIALIZED`: aplica direto em `ids`/`solid`/`heights` e registra em `applied_log`.
- Chunks fora da bolha não têm página: só a GPU recebe o journal — quando a página nascer, o `pending` estará lá.

Detalhes do journal em si: [[sistema-edicao-eventos]] e [[VS-03-edicao-e1|VS-03]].

## A API tri-state

Toda consulta pública do mirror é protegida por `ve.mirror.mutex` (a worker é dona da mutação desde a VS-18; a main lê só por estas APIs):

- `voxel_get(world_voxel) -> (VoxelSample{id, solid}, ok)` — `ok=false` = desconhecido (sem página ou `PENDING_READBACK`); `voxel_is_solid` deriva dele.
- `mirror_column_ground(world_x, world_z, y_from) -> (ground_y, ok)` — varredura para baixo cruzando fronteiras de chunk; `ok=false` se tocar página desconhecida.
- `mirror_height_get(chunk, x, z) -> (ok, height)` — O(1) por coluna; `0xFFFF` = coluna vazia.
- `mirror_request(chunk)` — pedido de página sob demanda, não bloqueante.

O desconhecido nunca inventa bloco; cada consumidor define sua política (a física congela — a seguir).

## Física

Agora simulamos. O solver é CPU autoritativo de gameplay sobre o mirror (VS-19, [[ADR-F1-fisica-solver-mirror|ADR-F1]]; módulo `src/engine/physics.odin`). GPU fica fora da física; não há segunda representação estática — a mesma página que a gameplay edita é a que o corpo bate.

**Dados.** `PhysicsDefinition` por id de bloco, exclusivamente CPU-side, carregada do `blocks.json` (com validador e fallback built-in): flags `BLOCKING`/`HITTABLE` (+ `CLIMBABLE`/`LIQUID` reservadas), fricção e restituição. Lembre do desenho da página: a bitmask `solid` filtra candidatos (broadphase binária); `ids` + a tabela resolvem a semântica (o que é grama, o que é planta). `BlockDefinition` std430 de 48 B não muda — shaders não consomem física.

**Tempo** (`physics_tick`). O timestep com acumulador na prática: passo fixo `PHYSICS_FIXED_DT = 1/60`; `frame_dt` é clampado em 0,25 s e o excesso além de 5 passos por frame é **descartado documentado** (anti espiral de morte — em um engasgo de 1 s, simular 60 passos de uma vez seria pior que pular). Mesmo estado inicial + mesma sequência de inputs ⇒ mesmo resultado no processo; replay best-effort (VS-07), sem bit-exatidão entre plataformas.

**Movimento** (`physics_step`). Cada corpo é uma AABB alinhada à grade (`PhysicsBody`). Um passo, na ordem: gravidade (−24, velocidade terminal −60) → grounded via `physics_ground_probe` (o fast-path de chão — abaixo) → sweep eixo a eixo na ordem estável X→Y→Z (`physics_sweep_axis`), com subdivisão do deslocamento em incrementos ≤ 0,4 unidade (anti-tunneling: a AABB nunca atravessa um voxel sem ser testada contra ele). Contatos param só o componente do eixo (é isso que produz o sliding natural), zeram a velocidade (ou aplicam restituição do bloco de contato) e alimentam o step-up: subir 1 degrau só vale a pena se houver espaço livre para a AABB inteira na altura elevada **e** apoio bloqueante no destino — caso contrário o movimento reverte. `grounded` é recalculado por contato real a cada passo, nunca persistido (persistir apoio é como acordar caindo: um frame de lag e o corpo acha que está no ar).

**Fast-path de chão** (`physics_ground_probe`). Quando todas as colunas cobertas pela AABB têm topo conhecido ≠ `0xFFFF`, estão no mesmo chunk XZ e o corpo está inteiramente acima do topo mais alto (fora de interiores/cavernas/sobreposição), o apoio é decidido em O(1)/coluna via `heights` medido — sem varrer voxel nenhum. Qualquer ambiguidade (coluna vazia, travessia de chunk, corpo abaixo do topo, página ausente, deslocamento vertical) cai no sweep completo — e a equivalência entre os dois caminhos é provada por `tools/sim/physics_sim.py`. O heightmap nunca elimina testes de teto/paredes.

**Mundo desconhecido** (REQ-PHY-06). Aqui acontece o freeze: se qualquer consulta do passo tocar página ausente/em readback, o **passo inteiro é descartado** — posição/velocidade/grounded voltam ao estado inicial do passo, o corpo marca `frozen` e a coordenada entra no map coalescido `pending_requests` (dedup; `physics_drain_requests`, chamado pela worker sob `mirror.mutex` dentro do `mirror_update_bubble`, converte em `mirror_request_page`). Sem stall síncrono, sem teleporte, sem presumir ar; ao materializar, o movimento retoma nos passos seguintes. O raycast usa o mesmo padrão: página desconhecida antes do limite ⇒ `UNKNOWN`, nunca `MISS`.

**Raycast** (`physics_raycast`). O DDA (Amanatides & Woo) sobre coordenadas inteiras do mirror: percorre só os voxels atravessados, consulta `HITTABLE` (planta é atingível sem bloquear movimento), retorna coordenada/id, distância e normal da face. Rejeições definidas: distância ≤ 0 ou direção nula ⇒ `MISS` sem percorrer; origem dentro de voxel ⇒ célula da origem testada primeiro (normal nula).

## Contenção conhecida: o mutex de página (BLK-41)

Nada aqui é de graça, e o preço conhecido é este: o solver consulta voxel a voxel, cada consulta pegando `ve.mirror.mutex`, e a worker detém o mesmo mutex pelo update inteiro (VS-18). Resultado medido no fechamento da VS-19: ~1,9 ms/frame de lock-wait no `engine_update` (máximos de 151 ms na travessia de bolha). O custo CPU do solver em si é mínimo (µs) — o gargalo é a contenção, não o trabalho. Candidatos de otimização no backlog: batch de consultas sob um único lock por corpo/passo, snapshot de página para o passo, ou redução da região crítica da worker. Ver `docs/obsidian/tracking/backlog.md` (BLK-41).

## Para ir mais fundo

Coordenação com os demais sistemas:

- [[sistema-streaming-mundo]] — a worker dona do mundo executa os pedidos de página e o materialize no handler de conclusão; anti-ABA por coord+geração segue o ciclo de vida B1.
- [[sistema-edicao-eventos]] — journal E1 (dual-apply, feedback de rejeições, reconciliação).
- [[sistema-renderizacao]] — o mirror nunca toca a fila gráfica; a bolha de simulação é independente da bolha de render.

Genealogia: [[VS-04-mirror-c2|VS-04]] (mirror), [[VS-13-heightmap-geracao-mirror|VS-13]] (heightmap, emendado pela VS-19), [[VS-19-fisica-solver-mirror|VS-19]] (física); decisões [[ADR-C2-mirror-cpu|ADR-C2]], [[ADR-G1-heightmap-geracao-mirror|ADR-G1]], [[ADR-F1-fisica-solver-mirror|ADR-F1]].
