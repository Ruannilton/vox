# Motor de Voxels Next-Gen

## Arquitetura Data-Driven com Vulkan 1.4, Compute Assíncrono e Mesh Shaders

**Versão 3.0 — novembro de 2026** · incorpora a edição de voxels (E1) e o mirror CPU-side (C2)

**Resumo executivo:** este motor inverte o paradigma clássico. Para renderizar, a CPU não sabe o que há dentro de um bloco — ela apenas orquestra onde os dados devem ir. A geometria não é armazenada em memória; ela é fabricada instantaneamente no silício da placa de vídeo, usando Task/Mesh Shaders que leem dicionários de blocos e templates de malha. A v3.0 completa o desenho com o verso dessa moeda: tudo que não é desenho — física, IA de NPCs, ferramentas, persistência — passa a ter onde morar, num mirror CPU-side do mundo (C2). As duas pontas deixam de ser cópias que precisam se reconciliar: a verdade é a função de geração mais o journal de edições (E1), e GPU e RAM são views materializadas dessa mesma fonte. Dois princípios continuam governando tudo: **GPU-driven** (a GPU decide o que existe e o que é desenhado) e **data-driven** (geometria e materiais são dados, não código).

## 1. Visão geral do pipeline (macro)

O trabalho é dividido estritamente entre a CPU (orquestração e estado) e a GPU (força bruta, geração procedural e montagem de geometria). A ponte entre os dois mundos é um par de **timeline semaphores** — um para a fila de computação, outro para a fila gráfica.

```
Thread Principal (streaming de chunks, draw, journal de edições E1)
        │  fila de prioridade
        ▼
Worker Thread (lotes de até 16 chunks — B4)
        │
        ▼
Timeline Semaphores (Vulkan 1.4) — Compute + Gráfica: aposentadoria dual de slots (B1)
        │ geração de dados                │ desenho do frame
        ▼                                 ▼
Compute Shaders (async) ──ocupação+paleta──▶ Task / Mesh Shaders
Generate → Scratch → Pack: paleta,          Culling hierárquico + geometria
ocupação, coarse e subdivisão;              on-the-fly via templates (Caminho B)
export denso u16 (C2)                               ▲
        │ readback (pós-timeline)                   │
        ▼                                           │
Ring de staging → Mirror RAM (C2)          apply_voxel_edits (E1)
ring host-visible → ChunkPages             flush do journal a 100 ms, no command
(bolha de simulação)                       buffer do frame, antes do render pass
```

*Figura 1 — Pipeline macro v3.0: CPU orquestra, GPU fabrica; o journal de edições (E1) alimenta o frame, e o mirror CPU (C2) recebe o grid denso por readback.*

**O que mudou na v3.0:** dois novos fluxos cruzam o pipeline. O journal de edições da thread principal é flushado em lotes e aplicado por um compute shader no command buffer do frame, antes do render pass (E1) — a edição aparece na malha no mesmo frame. E o compute de geração ganhou uma saída secundária: o grid denso de IDs que alimenta, por readback assíncrono, o mirror do mundo em RAM (C2). Permanecem da v2.0: a worker thread submete lotes reais de até 16 chunks por `vkQueueSubmit2` (B4) e o ciclo de vida dos slots é blindado contra corridas (B1, detalhado na Etapa 2).

## 2. Etapa 1: Chunk streaming (histerese)

O jogador movimenta a câmera e o mundo precisa carregar. Para evitar que blocos apareçam e desapareçam na borda da visão (efeito sanfona), aplicamos histerese com três zonas de raio: **Visão (8)** — o que é desenhado; **Geração (12)** — o que existe em memória; **Descarga (16)** — o que é devolvido ao pool.

**O pulo do gato (fila de prioridade):** todos os chunks na zona de geração entram numa fila. A worker thread sempre puxa os lotes mais próximos da câmera — o chão sob os pés do jogador é gerado imediatamente; o horizonte, aos poucos. Cada lote carrega até 16 chunks ordenados por distância.

**Novo na v3.0 — duas bolhas independentes:** à bolha de render acima soma-se a bolha de simulação do mirror CPU (Etapa 7), centrada nos agentes ativos e com raio próprio. Um chunk pode existir na VRAM sem existir na RAM (horizonte distante) e vice-versa (uma sala atrás da câmera onde um NPC está).

**Limitação conhecida (B5):** o raio de geração 12 descreve ~7.238 chunks, acima dos 4.096 slots físicos. A correção recomendada é reduzir o raio para ~9 ou ampliar o pool para ~8 mil slots.

## 3. Etapa 2: A ponte (Vulkan 1.4 Sync)

A submissão de trabalho usa **timeline semaphores** e o `vkQueueSubmit2`. Em vez de bloquear a CPU esperando a placa, usamos frames em voo num sistema de anel: lotes de compute são despachados e incrementam um valor na linha do tempo; a thread principal lê esse valor para saber quando um chunk pode sair de GENERATING para CACHED. Na fila gráfica, a GPU só lê blocos cuja fabricação já foi sinalizada — zero defeitos visuais por corrida de dados.

### 3.1 Correção B1 — ciclo de vida dos slots

**O defeito original:** ao descarregar um chunk ainda em geração, seu slot voltava de imediato ao pool livre enquanto a GPU podia ter um lote de compute em voo escrevendo nele — e, pior, um chunk recriado na mesma coordenada herdava o slot e era promovido indevidamente (problema ABA). A solução combina três mecanismos:

- **Geração por slot (anti-ABA):** cada alocação incrementa um contador de geração; conclusões só são aceitas se coordenada, slot e geração baterem.
- **Claim atômico:** a worker publica o lote submetido no mesmo trecho crítico em que retira a tarefa da fila — toda tarefa está em exatamente um dos dois conjuntos, nunca em ambos.
- **Aposentadoria dual:** slots de chunks em GENERATING são liberados contra a timeline de compute do lote que os referencia; slots CACHED/RENDERABLE aposentam pela timeline gráfica (Figura 2).

```
UNLOADED → GENERATING → CACHED ⇄ RENDERABLE
              │            (entra no raio de visão → RENDERABLE;
              │             sai do raio/histerese → CACHED)
              ├─ descarregar em GENERATING: aposentadoria pela timeline de COMPUTE
              └─ descarregar em CACHED/RENDERABLE: aposentadoria pela timeline GRÁFICA
```

*Figura 2 — Máquina de estados com aposentadoria dual (B1).*

## 4. Etapa 3: Geração e compactação (GPU Compute)

Quando a GPU recebe o lote, ela opera em duas fases via Compute Shaders, transformando matemática procedural num formato binário compacto. A primeira fase (**generate**) materializa um scratch denso temporário de 131 KB por chunk (1 uint por voxel); a segunda (**pack**) comprime tudo nas estruturas definitivas do slot. Na v3.0 o generate ganha uma terceira saída, condicionada à bolha de simulação: o **export denso u16** que alimenta o mirror CPU (Figura 3).

```
1. Generate (ruído procedural) → Scratch denso (131 KB — 1 uint/voxel) → 2. Pack (128 threads/chunk)
                                              │                             │
                                              └──▶ Export u16: grid denso y-major (C2, só bolha de simulação)
                                                   Fases do pack:
                                                   A  ocupação do brick + presença de blocos + custo geométrico pior-caso (Caminho B)
                                                   B1/B2  coarse cells + scan de prefixo (popcount) → ranking da paleta sem busca linear
                                                   B3  paleta no header — INVARIANTE: slot 0 = AR; overflow → SpecialVoxelRecord
                                                   C  planos de material (índice = rank + 1) + bits de subdivisão por brick
```

*Figura 3 — Fluxo generate → scratch → pack, com as fases do pack completo (B3) e a ramificação de export denso (C2).*

**Correção B3 — pack completo:** o pack shader era um esboço; agora implementa quatro fases reais. A paleta é montada por ranking de prefixo popcount — cada voxel descobre seu índice em O(1), sem busca linear. Duas invariantes:

- **O slot 0 da paleta é sempre AR.** Sem isso, voxels de ar decodificariam como o primeiro bloco sólido e o mesh shader desenharia geometria no céu. Capacidade efetiva: 255 tipos + AR.
- **Overflow vira dado, não corrupção:** chunks com mais de 255 tipos recebem a flag `CHUNK_FLAG_PALETTE_OVERFLOW` e preservam os excedentes como SpecialVoxelRecords (degradam para ar na renderização — seguro por construção).

**Caminho B — custo geométrico por brick:** como cada voxel pode ter uma malha customizada, o pack também soma o custo pior-caso de geometria de cada brick e grava 2 bits de subdivisão por brick na região de ocupação (Etapa 4).

## 5. Etapa 4: Culling e geometria on-the-fly (mesh shading)

No loop gráfico, enviamos um único comando: `vkCmdDrawMeshTasksEXT`. Daqui em diante não há CPU, vertex buffers ou index buffers.

### 5.1 O task shader (o filtro)

Cada workgroup de 128 threads avalia um chunk visível: células grossas vazias descartam 512 voxels de uma vez; bricks vazios morrem na word de ocupação. O task shader lê os bits de subdivisão gravados pelo pack e despacha 1, 2 ou 4 mesh groups por brick, conforme o custo geométrico — bricks leves (cubos) seguem em grupos de 32 voxels; bricks com malhas complexas (escadas, móveis) usam grupos de 16 ou 8, garantindo o orçamento de hardware de **256 vértices / 192 triângulos por grupo por construção**, e não por sorte.

### 5.2 O mesh shader (a usina) e o Caminho B

**Correção B2 — fronteiras:** leituras que cruzam a borda do chunk são redirecionadas à ocupação real dos 6 vizinhos (publicada por frame pela CPU). Faces internas entre chunks sólidos não são mais emitidas em dobro. Como a geometria é refeita a cada frame, um vizinho ainda em geração é tratado como ar e a face some sozinha no frame em que ele concluir — sem dirty flags.

**Culling de frustum (VS-06, ADR-B11):** o builder da fila de trabalho deriva os 6 planos do frustum (Gribb-Hartmann) da `view_projection_matrix` já presente nos push constants — a mesma matriz que leva `clip_position` no mesh shader. Em dois níveis: early-out do chunk (AABB 32³ fora → o workgroup inteiro retorna sem ler ocupação) e por brick (AABB 4×2×4 fora → nenhum item), com teste conservador de p-vertex na ordem vazio → frustum → oclusão. Sem push constants novos e sem nenhum pixel alterado para geometria visível.

**Caminho B — templates de malha:** a geometria deixou de ser um switch hardcoded (CUBO/PLANTA) e virou dado. Uma tabela global de templates em SSBO descreve, para cada tipo de bloco, vértices e triângulos. Cada triângulo carrega uma tag de culling: colado numa face do voxel (some quando o vizinho é sólido ou a câmera está atrás) ou interior (nunca culpado). O cubo e a planta são apenas os templates 1 e 2; mods registram novos sem tocar nos shaders.

**Regra do voxel unitário:** todo voxel ocupa exatamente 1 unidade³; os vértices de um template vivem em [0,1]³ — validado no carregamento. Se um objeto precisa de mais espaço (porta, cama, mesa), ele é dividido em múltiplos voxels, cada um com seu template-parte. Orientações (0°/90°/180°/270°) são um campo de rotação do bloco, não IDs novos.

## 6. Etapa 5: Orientação a dados e PBR (fragment)

Para o jogo não ser engessado, o motor é data-driven: durante o loading, a CPU lê os mods e envia à GPU um SSBO (Dicionário Global) com textura, rugosidade, template de malha e propriedades de luz de cada bloco — ao lado da tabela de templates, que segue o mesmo princípio: geometria também é dado.

No fragment shader não há UVs pré-calculadas: aplicamos **mapeamento triplanar** (a textura é projetada no espaço 3D conforme a orientação do pixel) e a normal é extraída por derivadas de tela (`dFdx`/`dFdy`) — o que funciona para qualquer malha, de cubos a escadas e cruzes de planta. **Limitação conhecida (B7):** o sombreamento atual é Lambert + emissão; as texturas PBR (roughness/metallic) já chegam à GPU mas ainda não são amostradas.

## 7. Etapa 6: Edição de voxels (E1) — novo na v3.0

Quebrar um bloco, construir uma parede, abrir um túnel: toda alteração do mundo, de qualquer origem (input do jogador, IA, física, script), vira uma única chamada — `request_voxel_edit(world_voxel, block_id)`. Daí nasce o **journal de edições**: um stream append-only com dedup «última escrita vence» por voxel, flushado em lotes a cada 100 ms (configurável; 0 = todo frame, e um flag força o flush imediato para ações de latência mínima).

**Aplicação no mesmo frame:** o flush agrupa as edições por chunk (lotes de 16B por chunk; edições packed em u32) e despacha o compute `apply_voxel_edits` no próprio command buffer do frame, antes do render pass, com barreira COMPUTE → TASK|MESH. Como a malha é refeita on-the-fly a cada frame, a geometria já nasce refletindo a edição — não existe dirty flag nem re-mesh assíncrono, e o culling de fronteira (B2) se ajusta sozinho porque o vizinho lê a ocupação ao vivo.

- **Paleta dinâmica com refcount:** o header do chunk ganhou um contador de referência por entrada de paleta (256 × u8). Uma edição que introduz um bloco novo aloca um slot livre por CAS; a que remove o último voxel de um tipo libera o slot (reciclagem preguiçosa com tombstones). A invariante do B3 é preservada: o slot 0 (AR) nunca é reciclado.
- **Tetos de segurança:** 4.096 edições por flush, 256 chunks por flush, 1.024 edições por chunk por flush — o excedente espera o próximo ciclo. Chunks em geração não participam do lote (preserva o B1); suas edições ficam pendentes e reintegram quando o chunk conclui.
- **Feedback:** um ring de resultados (lido 2 frames depois) reporta edições aplicadas, no-ops e rejeições — chunks em overflow de paleta são somente-leitura e rejeitam com código próprio. É esse canal que o mirror (Etapa 7) usa para reconciliar.

## 8. Etapa 8: Input intermediado por eventos, gravação e replay (VS-07) — novo na v3.0

Toda interação usuário↔aplicação é intermediada por um **bus de eventos** (`src/engine/events.odin`): os callbacks GLFW (teclado, mouse, botões, fechamento da janela) são produtores puros — sem contexto de runtime, sem alocação, sem efeitos — que apenas empurram eventos tipados numa fila anel de 4.096 entradas. Uma vez por frame, após `glfw.PollEvents()`, o loop principal **drena** a fila: grava cada evento em **JSONL** (`bin/events/events_<timestamp>.jsonl`, flush por linha — crash não corrompe o arquivo) e despacha aos handlers registrados por tipo.

- **Tempo de emissão relativo:** todo evento carrega `t = glfw.GetTime() − t0` (t0 fixado no fim da inicialização); eventos de um mesmo dreno compartilham o `t` do dreno.
- **Polling eliminado:** o conjunto de teclas pressionadas é estado derivado de `KeyPress`/`KeyRelease`; o movimento WASD (SHIFT ×8, diagonal normalizada, `speed × deltaTime`) consome esse estado. Rotação de câmera sai do handler de `MouseMove` (delta, sensibilidade 0.07).
- **Comandos no mesmo pipeline:** `TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock` (journal E1), `ToggleTelemetry`, `TelemetrySnapshot` e `Wait` são eventos como quaisquer outros — gravam e replayam igual.
- **Replay best-effort 1×:** `--replay <arquivo.jsonl>` carrega e valida o arquivo antes de criar a janela (ausente/ilegível ou JSON inválido na linha 1 = fatal, exit ≠ 0); um cursor ordenado por `t` despacha os devidos a cada frame. `KeyPress{duration}` agenda o `KeyRelease` em `t + duration`; `Wait{seconds}` segura o cursor. Linha inválida ou tipo desconhecido é pulada com warning e contagem no sumário — nunca fatal. `--exit-after-replay` fecha a aplicação ao fim do stream; `--record`/`--no-record` controlam a gravação (default ligada, inclusive durante replay, sempre com o tempo da sessão corrente). O validador `tools/sim/events_check.py` verifica qualquer arquivo (schema por tipo, `t` monotônico).

## 9. Etapa 7: Mirror CPU-side (C2) — novo na v3.0

**Motivação:** pathfinding de NPCs, física, colisão de câmera, ferramentas de debug e serialização de save precisam responder «que bloco há em (x,y,z)?» na CPU — sem stall de readback e sem entender o formato packed da GPU (bitmask + paleta + planos, ótimo para culling, péssimo para consulta pontual). O C2 mantém uma segunda materialização do mundo em RAM, otimizada para leitura, atualizada pelo mesmo journal que alimenta a GPU.

**O princípio que evita a dupla autoridade:** nem a VRAM nem a RAM são «a verdade». A verdade é o worldgen (semente/função) mais o journal de edições, append-only. GPU e CPU são views materializadas dessa fonte — a primeira no formato packed de render, a segunda num grid denso de consulta (Figura 4). Como ambas aplicam exatamente a mesma sequência de edições (mesma ordenação, mesmo dedup), elas convergem por construção; um contador de versão por chunk (`edit_seq`) permite verificar isso em build de debug.

```
              A VERDADE: worldgen (semente/função) + JOURNAL de edições
              append-only · dedup última-escrita-vence · ordenado por chunk
                │ edições: flush E1 (100 ms)        │ edições: aplicação imediata
                ▼                                    ▼
   View de RENDER — VRAM (GPU)          View de GAMEPLAY — RAM (CPU)
   slot packed: ocupação+planos+        ChunkPage: grid denso u16 + bitmask solid
   paleta+coarse · 4096 slots fixos ·   ~500 chunks ≈ 34 MiB · bolha de simulação ·
   bolha de render · formato otimizado  formato otimizado p/ consulta voxel(x,y,z)
   p/ culling e mesh                             ▲
                ▲                                │ readback: export u16 → ring host-visible
                └──────── Compute generate (GPU) ┘ → memcpy + replay do journal pendente
                    produz o grid denso + o formato packed
   mesma sequência de edições nos dois lados → convergência por construção (edit_seq paritário)
```

*Figura 4 — Dupla materialização: a verdade é worldgen + journal; GPU e RAM derivam views independentes, em formatos e bolhas próprios.*

**Formato da página:** cada chunk espelhado ocupa uma ChunkPage de ~68,1 KiB (Figura 5): grid denso de 32³ u16 (ID de bloco direto — sem paleta na RAM, o que elimina toda divergência de paleta e faz a query de ponto custar um único load), mais um bitmask de sólidos de 4 KiB derivado do dicionário de blocos, que responde a consulta mais frequente de todas («ocupa espaço?») testando 32 voxels por load. A indexação é **y-major**, de modo que uma coluna vertical inteira são 64 bytes contíguos — uma linha de cache — e o scan de chão, operação mais comum do gameplay, é uma leitura sequencial.

```
ChunkPage — 32³ voxels · total ≈ 68,1 KiB · alinhada a 64 B · alocada em pool de tamanho fixo
┌ Header — 64 B: coord[3], edit_seq, state, pending
├ Bitmask solid — 4 KiB ([1024] u32, 1 bit/voxel, derivado do BlockDefinition)
└ ids — 64 KiB ([32768] u16, grid denso, block ID direto, sem paleta)
Índice y-major: idx = (x·32 + z)·32 + y → coluna vertical = 64 B contíguos (1 linha de cache)

Estados: PENDING_READBACK → (fence + memcpy + replay pending) → MATERIALIZED → (saiu da bolha) → EVICTED
```

*Figura 5 — Layout da ChunkPage e sua máquina de estados.*

**Como a página nasce:** o compute de geração escreve o grid denso como saída secundária; após o signal da timeline do lote, uma cópia assíncrona o traz para um ring de staging host-visible; na confirmação, um memcpy o instala numa página do pool e as edições que chegaram enquanto isso são reaplicadas do journal — a página só então abre para leitura. Latência típica de 1–3 frames; o export é condicionado à bolha de simulação, então chunks do horizonte nunca pagam o custo.

> **Nota de implementação (2026-11-03):** a versão final no código simplificou esse fluxo — o generate escreve **direto num ring host-visible de 64 slots × 64 KiB (4 MiB), binding 16** (a escrita do shader É o readback), sem `export_pool` device-local nem `vkCmdCopyBuffer`. Requer `storageBuffer16BitAccess`.

**Bolhas independentes:** a bolha de render (4.096 slots de VRAM, raio ~12) e a bolha de simulação (~500 chunks, ~34 MiB de RAM) têm centros e raios próprios e nunca disputam recursos. A consulta é **tri-state**: `voxel_get` retorna o dado, ou «desconhecido» (página ausente ou em readback) — a política sobre o desconhecido (esperar, replanar, assumir ar ou sólido) é de cada consumidor, não do mirror, que apenas expõe o gancho `mirror_request` para puxar páginas sob demanda.

**Reconciliação:** a única divergência possível é a rejeição de edição pela GPU (chunk em overflow de paleta, somente-leitura). O mirror aplica otimisticamente; quando o ring de feedback do E1 reporta a rejeição (2 frames depois), a página é revertida por replay do journal sem aquela edição. Caminho raro, código simples.

**Decisões descartadas:** ler o device-local direto via Resizable BAR (latência de PCIe em queries de gameplay — inviável) e regenerar o mundo na CPU a partir da semente (exigiria determinismo bit-exato de ponto flutuante entre CPU e GPU — não existe).

## 10. Registro de correções e recursos desta versão

| ID | Tipo | Descrição | Status |
|---|---|---|---|
| B1 | bug crítico | Ciclo de vida de slots: geração por slot anti-ABA, claim atômico, aposentadoria dual | Corrigido |
| B2 | bug alto | Faces entre chunks em dobro: neighbor_slots no VisibleChunk | Corrigido |
| B3 | bug alto | pack_chunk era stub: 4 fases + ranking popcount + paleta slot 0 = AR | Corrigido |
| B4 | bug médio | Worker submetia 1 chunk/submit: lotes de até 16 por vkQueueSubmit2 | Corrigido |
| B9 | bug alto | generate_voxels cobria só 8192/32768 voxels: numthreads(8,8,8), job = thread_id.z/32 | Corrigido |
| Caminho B | recurso | Templates de malha data-driven em SSBO + subdivisão de brick | Implementado |
| Culling de frustum | recurso | Planos Gribb-Hartmann na GPU no builder: early-out de chunk + por brick (VS-06/ADR-B11) | Implementado |
| E1 | recurso | Edição de voxels bufferizada com flush no command buffer do frame | Implementado |
| C2 | recurso | Mirror CPU-side: ChunkPage denso u16 y-major + ring host-visible | Implementado |
| Eventos | recurso | Bus de eventos de input/comando com gravação JSONL e replay 1× (VS-07) | Implementado |
| E1 | correção | Flush do journal não era mais chamado (removido com os testes em 6897431) e `last_flush`/`force_next_flush` eram consumidos pelo ring write todo frame, matando o gating de 100 ms; restaurado via `edit_update` no loop | Corrigido |
| B5 | backlog | Raio de geração 12 > 4096 slots | Pendente |
| B6 | backlog | Plantas sem alpha-test; CULL_MODE_NONE | Pendente |
| B7 | backlog | PBR não amostrado (só Lambert + emissão) | Pendente |
| B8 | backlog | Overflow int32 em calculate_squared_distance | Pendente |

Detalhes de implementação, estruturas de memória e contratos de carga estão no documento companheiro: **Manual Técnico do Motor de Voxels**.
