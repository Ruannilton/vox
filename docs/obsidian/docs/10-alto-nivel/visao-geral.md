---
id: VISAO-GERAL
titulo: Visão geral do motor
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Visão geral

Motor de voxels **GPU-driven/data-driven** (Vulkan 1.4 / Odin / Slang). Princípio central: a CPU orquestra, a GPU fabrica — a geometria não é armazenada, é gerada por mesh shader a partir de dicionários de blocos e templates de malha; e o mundo tem **duas views materializadas** de uma mesma verdade (worldgen + journal de edições): uma packed na VRAM (render) e uma densa na RAM (gameplay).

## Os dois mundos e a ponte

```
VERDADE = worldgen determinístico + JOURNAL de edições (append-only)
   │                                          │
   ▼                                          ▼
VRAM (packed: bitmask+paleta+planos)     RAM (mirror: grid u16 denso,
   bolha de render (raio configurável)     bitmask solid, heightmap)
   — GPU gera, pack comprime              bolha de simulação (raio próprio)
   │                                          │
   mesh shader fabrica a malha a           física, IA, queries leem aqui
   cada frame, on-the-fly                  (O(1) por voxel; chão O(1))
```

- A ponte GPU→RAM é o **export denso** escrito pelo próprio generate (a escrita do shader *é* o readback) + o journal, que ambas as views aplicam na mesma ordem — convergem por construção ([[sistema-mirror-fisica]]).
- Fora da bolha de simulação, a resposta honesta é "desconhecido" (tri-state) — a política é de cada consumidor.

## As três threads

| Thread | Dona de | Ritmo |
| --- | --- | --- |
| **main** | input/eventos, render (grava o CB, submit, present), física (tick fixo), gameplay | por frame (~2-7 ms) |
| **worker** (`voxel_worker`) | **o mundo**: mapa de chunks, streaming (cursor incremental com orçamento), completions/aposentadoria de slots, publish do conjunto visível, journal do mirror, flush de edições | por pedido de frame + sob demanda |
| **GPU** | generate/pack (lotes de compute), builder da fila de trabalho, mesh/fragment | filas gráfica e de compute |

Handoff main↔worker por atomics + condições (publish **sob demanda** — só quando o mundo publicável muda; a main renderiza com o último publish válido e nunca espera uma rodada inteira). Detalhes: [[sistema-streaming-mundo]].

## Pipeline de um frame (main)

1. **Events**: dreno do bus (input, comandos de replay, cliques de construção).
2. **Update de engine**: telemetria; a worker foi acordada com o pedido de frame (câmera).
3. **Física**: passos fixos do acumulador (corpos AABB contra o mirror) + raycast da mira + gameplay (cliques → journal E1).
4. **Publish consumido**: `visible_count` do último publish compatível com o `camera_chunk`.
5. **Render**: grava o CB — edições do flush (se houver) → builder da fila de trabalho → finalize → draw mesh indireto — espera a timeline de compute com o valor do publish, submit, present.
6. **Tracy**: FrameMark + zones; fechamento do frame.

A worker, no mesmo instante: service do mundo (streaming slice ≤ orçamento, completions, mirror) → produce publish quando o mundo muda → pipeline de lotes de compute (claim de até N chunks, jobs, submit, 3 lotes em voo). Detalhes: [[sistema-renderizacao]], [[sistema-streaming-mundo]].

## O que existe no mundo

- **Chunks** 32³ de voxels; 1 voxel = 1 unidade³ sempre. Blocos são dados (`assets/blocks.json`: mesh, 6 texturas por face, física, alpha-test).
- **Slots** GPU dimensionados por config (`vox.ini`): raios de visão/geração/descarga derivam capacidades (esferas exatas + folga); validação de coerência e de máquina antes de provisionar.
- **Estados do chunk**: GENERATING → CACHED ⇄ RENDERABLE; EMPTY (só ar, sem slot — virtual). Aposentadoria dual (B1): só o handler de conclusão libera slot, com anti-ABA por coord+geração.
- **Chunks vazios** não custam GPU: viram registros sem slot (VS-10).

## Renderização em 5 passos (tudo no frame, sem cache de malha)

1. **generate** (compute): ruído → scratch denso (id por voxel) + export denso pro mirror.
2. **pack** (compute): comprime em ocupação (bitmask por brick) + paleta (slot 0 = ar) + planos de material + subdivisão por brick (orçamento mesh shader 256v/192t garantido por construção).
3. **builder** (compute, fila gráfica): culling vazio → frustum → oclusão; anexa itens `(chunk visível, brick, parte, subdivisão)` na fila global.
4. **mesh shader**: 1 workgroup por item; monta a geometria do brick a partir do template do bloco (UVs por face, alpha-test).
5. **fragment**: seleção de camada por face (normal orientada), amostragem NEAREST, Lambert + emissão, highlight do voxel-alvo.

Culling de frustum por brick (VS-06) e texturas multi-face reais (VS-21) vivem aqui. Detalhes: [[sistema-renderizacao]].

## Coordenação sem corrida

- Rings de 2 frames (visíveis, fila de trabalho, edições, highlight) só são reescritos após a timeline gráfica confirmar o uso anterior.
- O mapa de chunks é de **dono único** (worker); a main lê o mundo só pelo mirror (mutexes de página) e pelo publish.
- Fast-exit no shutdown: flush do Tracy e `os.exit` — teardown completo só com `--full-teardown` (smokes/CI).

## Leitura sugerida a partir daqui

[[sistema-engine-fundacao]] → [[sistema-streaming-mundo]] → [[sistema-renderizacao]] → [[sistema-mirror-fisica]] → [[sistema-edicao-eventos]] → [[sistema-suporte]]. Decisões de desenho: `../decisoes/00-indice.md`; genealogia: `../especificacoes/`.
