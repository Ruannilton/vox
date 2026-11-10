---
id: VISAO-GERAL
titulo: Visão geral do motor
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Visão geral

Bem-vindo. Este é o primeiro documento da documentação do motor, escrito para quem nunca viu o código. A única coisa que assumimos é que você programa e conhece o básico de Vulkan (o que é um command buffer, uma fila, um descriptor). Tudo o mais será apresentado antes de ser usado — e todo nome interno aparece com crase e arquivo, para você conferir com um clique.

Vamos começar pelo que o motor *é*, depois ver as peças em movimento: as duas cópias do mundo, as três threads e o pipeline de um frame.

## O que é o motor

É um motor de voxels **GPU-driven/data-driven** (Vulkan 1.4 / Odin / Slang). As duas palavras-chave explicam quase tudo:

- **GPU-driven** significa que a GPU decide e fabrica a geometria. Não existe malha pronta na memória: a cada frame, um *mesh shader* monta os triângulos visíveis a partir de dicionários de blocos e templates de malha. A CPU nunca toca num único vértice do terreno.
- **Data-driven** significa que o que um bloco *é* (malha, texturas, física) é dado, não código. Esse dado vive em `assets/blocks.json`, carregado pela rotina de assets em `voxel_assets.odin`.

Um voxel é sempre **1 unidade³** — sem exceção. Se um objeto precisa ser maior, ele é composto por múltiplos voxels-parte (regra nº 1 do `AGENTS.md`).

## Os dois mundos e a ponte

O ponto mais importante para entender a arquitetura: **não existe um único mundo**. Existe uma única *verdade*, e duas cópias materializadas dela, cada uma otimizada para um consumidor.

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

Vamos apresentar cada termo desse diagrama:

- **Worldgen determinístico** é a função de geração de terreno (ruído). "Determinística" é o que importa: dada uma coordenada de chunk, ela *sempre* produz os mesmos 32³ voxels. Isso é o que permite não guardar o mundo em lugar nenhum — ele pode ser **regenerado** sob demanda, em vez de armazenado.
- **Journal** é o log append-only de edições do jogador. A cada bloco quebrado ou colocado, um registro é anexado ao journal (a rotina de edição em `voxel_edit.odin`). Como o worldgen é determinístico, "o mundo atual" é sempre definível como *o mundo que o worldgen geraria, mais o journal aplicado na ordem*. Detalhes em [[sistema-edicao-eventos]].
- A cópia na **VRAM** é *packed* (compactada): cada chunk ocupa pouca memória porque vive como bitmask de ocupação + paleta de blocos + planos de material. Quem gera e comprime essa cópia é a própria GPU, em passos de compute que veremos adiante.
- A cópia na **RAM** é o **mirror**: uma grade densa de `u16` (um id de bloco por voxel), com bitmask de solid e heightmap, mantida pela worker em `voxel_mirror.odin`. Física, gameplay e queries leem só dela — e por ser densa, a resposta é O(1) por voxel.

A **ponte GPU→RAM** funciona assim: quando o compute de geração escreve um chunk na VRAM, ele já escreve ao mesmo tempo o *export denso* para o mirror — a escrita do shader **é** o readback, não há uma cópia extra depois. Como as duas views aplicam o mesmo journal na mesma ordem, elas **convergem por construção**: nunca é preciso reconciliar. Isso é explorado a fundo em [[sistema-mirror-fisica]].

Uma consequência honesta: fora da *bolha de simulação* (o raio de chunks mantido no mirror), o mundo "existe" mas não sabemos o que é. A resposta para uma query ali é "desconhecido" (tri-state); cada consumidor decide o que fazer com isso.

## As três threads

O motor executa três linhas de execução em paralelo. Cada uma tem um **dono exclusivo** de um conjunto de dados — é isso que elimina a maior parte das corridas:

| Thread | Dona de | Ritmo |
| --- | --- | --- |
| **main** | input/eventos, render (grava o command buffer, submit, present), física (tick fixo), gameplay | por frame (~2-7 ms) |
| **worker** (`voxel_worker`, em `voxel_worker.odin`) | **o mundo**: mapa de chunks, streaming, completions/aposentadoria de slots, publish do conjunto visível, journal do mirror, flush de edições | por pedido de frame + sob demanda |
| **GPU** | generate/pack (lotes de compute), builder da fila de trabalho, mesh/fragment | filas gráfica e de compute |

Alguns conceitos que aparecem na tabela e que precisam de apresentação:

- O **publish** é o snapshot imutável do conjunto de chunks visíveis que a worker entrega à main. A rotina `voxel_engine_publish_visible` (em `voxel_engine.odin`) grava os campos `published_*` — entre eles `published_visible_count`, `published_camera_chunk` e o `published_compute_value`, um número de *timeline* da fila de compute. Por que timeline? É o mecanismo anti-ABA (regra nº 3 do `AGENTS.md`): cada publish carrega um valor de timeline que a render usa para esperar exatamente os lotes de compute daquele mundo, nem mais nem menos.
- A main **só lê o mundo pelo publish e pelo mirror** — nunca pelo mapa de chunks, que é da worker. O handoff main↔worker é feito por atomics + variáveis de condição: a main acorda a worker com o pedido de frame (que carrega a câmera), e a worker publica **sob demanda**, ou seja, só quando o mundo publicável mudou. Se nada mudou, a main renderiza com o último publish válido e nunca espera uma rodada inteira da worker. Os detalhes desse protocolo são de [[sistema-streaming-mundo]].
- "Completions" é o processamento dos lotes que a GPU terminou — veremos na seção de coordenação.

## Pipeline de um frame (main)

Agora que os conceitos existem, um frame da thread main é uma passada nesta lista:

1. **Events**: dreno do bus de eventos (input, comandos de replay, cliques de construção). O bus vive em `events.odin`.
2. **Update de engine**: telemetria; a worker já foi acordada com o pedido de frame (câmera).
3. **Física**: passos fixos do acumulador (corpos AABB testados contra o mirror, em `physics.odin`) + raycast da mira + gameplay (cliques → journal E1, em `gameplay.odin`).
4. **Publish consumido**: `voxel_engine_wait_published` (em `voxel_engine.odin`) devolve o `published_visible_count` do último publish compatível com o `camera_chunk`. "Compatível" significa: mesmo chunk central de câmera e publicado há menos de 2 frames — caso contrário a main segue com o conjunto anterior e registra um aviso.
5. **Render**: grava o command buffer — edições pendentes do flush (se houver) → builder da fila de trabalho → finalize → draw mesh indireto — espera a timeline de compute com o valor do publish, submit, present.
6. **Tracy**: FrameMark + zones; fechamento do frame.

No mesmo instante, a worker executa o *service* do mundo: um slice de streaming dentro do orçamento de tempo, as completions, e a atualização do mirror. Quando o mundo muda, ela produz um publish novo; em paralelo, cuida do pipeline de lotes de compute (claim de até N chunks, submissão dos jobs, com 3 lotes em voo). Os detalhes de cada metade estão em [[sistema-renderizacao]] e [[sistema-streaming-mundo]].

## O que existe no mundo

- **Chunks** de 32³ voxels. Blocos são dados (`assets/blocks.json`: mesh, 6 texturas por face, física, alpha-test).
- **Slots** GPU dimensionados por config (`vox.ini`, lido por `voxel_assets.odin`/`config.odin`): os raios de visão/geração/descarga derivam das capacidades (esferas exatas + folga), e há validação de coerência e de máquina antes de provisionar os buffers.
- **Estados do chunk**: GENERATING → CACHED ⇄ RENDERABLE; EMPTY (só ar, sem slot — virtual). A **aposentadoria dual** (B1) garante que só o *handler de conclusão* — a rotina `voxel_engine_service_completions` em `voxel_engine.odin`, que a worker chama a cada frame para processar os lotes que a GPU terminou — é quem libera o slot de um chunk, com anti-ABA por coord+geração (regras nº 3 e 4 do `AGENTS.md`).
- **Chunks vazios** não custam GPU: viram registros sem slot (decisão VS-10).

## Renderização em 5 passos (tudo no frame, sem cache de malha)

Nenhum vértice do terreno é armazenado — a malha é fabricada a cada frame nesta sequência:

1. **generate** (compute): o ruído do worldgen produz um *scratch* denso (um id de bloco por voxel) + o export denso para o mirror, na mesma escrita.
2. **pack** (compute): comprime em ocupação (bitmask por brick) + paleta (o **slot 0 da paleta é ar** — regra nº 2 do `AGENTS.md`) + planos de material + subdivisão por brick. A subdivisão garante por construção o orçamento do mesh shader (256 vértices / 192 triângulos por trabalho — regra nº 5).
3. **builder** (compute, rodando na fila **gráfica**): culling de vazio → frustum → oclusão; anexa itens `(chunk visível, brick, parte, subdivisão)` na fila de trabalho global.
4. **mesh shader**: 1 workgroup por item; monta a geometria do brick a partir do template do bloco (UVs por face, alpha-test).
5. **fragment**: seleção de camada por face (normal orientada), amostragem NEAREST, Lambert + emissão, highlight do voxel-alvo.

Os shaders desses passos estão em `src/assets/shaders/` (fonte Slang; o pipeline de build compila para `bin/*.spv`). O culling de frustum por brick (VS-06) e as texturas multi-face reais (VS-21) vivem aqui. Detalhes: [[sistema-renderizacao]].

## Coordenação sem corrida

Três mecanismos mantêm as threads de se pisarem:

- **Rings de 2 frames**: os buffers visíveis, a fila de trabalho, as edições e o highlight só são reescritos depois que a timeline **gráfica** confirma que o frame anterior já os usou. "Timeline" é o recurso do Vulkan de sincronização por valores monotônicos — o motor versiona cada uso de um ring com um valor e espera esse valor antes de reescrever.
- **Dono único**: o mapa de chunks é da worker; a main lê o mundo só pelo mirror (que tem mutexes por página) e pelo publish.
- **Fast-exit no shutdown**: em vez de um teardown elaborado, o motor faz flush do Tracy e chama `os.exit` — o teardown completo só acontece com a flag `--full-teardown` (usada nos smokes/CI).

## Leitura sugerida a partir daqui

[[sistema-engine-fundacao]] → [[sistema-streaming-mundo]] → [[sistema-renderizacao]] → [[sistema-mirror-fisica]] → [[sistema-edicao-eventos]] → [[sistema-suporte]]. Decisões de desenho: `../decisoes/00-indice.md`; genealogia das specs: `../especificacoes/`.
