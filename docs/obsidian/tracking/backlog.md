---
id: backlog
titulo: Backlog consolidado
tipo: tracking
ultima_atualizacao: 2026-11-07
---

# Backlog consolidado

Índice único dos itens futuros do motor. Itens entram aqui a partir dos **não-escopos das specs**, **consequências de ADRs** e **bugs deixados para depois**; saem quando viram spec aprovada (ou são explicitamente descartados pelo mantenedor). Bugs ativos da tabela de registros da arquitetura (B6–B8) permanecem lá e são espelhados aqui.

Legenda de origem: `VS-xx não-escopo` · `ADR-xx consequência` · `arquitetura §9` · `ressalva de validação`.

## Bugs e débitos técnicos

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-01 | ~~**B6 — Plantas sem alpha-test**~~ **FECHADO pela VS-14** (Opção A da ADR-P1): alpha-test cutout no fragment + bloco planta id 4 com spawn determinístico | arquitetura §9 | Fechado em 2026-11-07; translucidez real/A2C viraram BLK-29/BLK-30 |
| BLK-02 | **B7 — PBR não amostrado** (roughness/metallic chegam à GPU; fragment só Lambert + emissão) | arquitetura §9 | Cook-Torrance; roughness vem do dummy até texturas PBR reais |
| BLK-03 | **B8 — Overflow int32 em `calculate_squared_distance`** | arquitetura §9 | Distâncias já usam i64 nos caminhos quentes; auditar restantes |
| BLK-04 | `debug_readback_validate` sempre valida chunk subsuperfície (100% sólido) — forçar chunk de **superfície** (com ar) | ressalva VS-04 (correção 2026-11-06) | Decode/comparação idênticos ao `debug_mirror_parity`; baixo risco |
| BLK-05 | Plateaus longos do streaming entre execuções | ressalva VS-06 | Comportamento pré-existente; investigar se incomodar |

## Render e shading

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-06 | Oclusão por Hi-Z | VS-06 não-escopo | Depende de depth-pyramid; compõe com o frustum culling |
| BLK-07 | LOD de bricks/chunks | VS-06 não-escopo | Ganha sentido com visões longas (vision ≥ 16) |
| BLK-08 | **Rotação yaw × UV** — texturas direcionais (atlas por face) exigem unwraps simétricos à rotação ou templates por rotação | VS-11 questão aberta | Nulo com a paleta atual; desbloqueia mods com grão direcional |
| BLK-09 | Normais/tangentes por atributo (hoje: derivadas de tela) | VS-11 não-escopo | Pré-requisito de normal mapping |

## Mundo e streaming

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-10 | Chunk que **vira** ar por edição transitar para `EMPTY` e liberar o slot | VS-10 não-escopo | Mesma máquina do EMPTY; feedback via refcount do header |
| BLK-11 | Atalho CPU "provavelmente vazio" por teto de worldgen (sem gerar) | ADR-V1 Opção C | Acoplado ao gerador; complemento, nunca substituto do EMPTY empírico |
| BLK-12 | Reconfigurar raios em runtime (sem reiniciar) | VS-08 não-escopo | Exige drenar/descarregar o mundo |

## Assets e mods

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-13 | Emissão/PBR via JSON e **blending** de transparência (o `transparent` de cutout já veio na VS-14; flags restantes de `BlockDefinition`) | VS-12 não-escopo + BLK-01 | Parte do item fechada pela VS-14; blending real é BLK-29 |
| BLK-14 | Mipmaps e filtragem trilinear nas texturas de blocos | VS-12 não-escopo | Alias em minificação em visões longas |
| BLK-15 | Atlas interno por face / texturas por face | VS-12 não-escopo | Depende de BLK-08 (rotação) |
| BLK-16 | **Worldgen data-driven** — desacoplar o contrato ids 1–4 do `generate` (grama/terra/pedra/planta) | VS-12 não-escopo + VS-14 (ids 1–4) | Hoje o JSON deve definir grama/terra/pedra/planta nos ids fixos |
| BLK-17 | Hot-reload de assets, pacotes/mods com dependências, formato binário | VS-12 não-escopo | Depende do sistema de mods amadurecer |

## Gameplay e input

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-18 | **Replay determinístico** (timestep fixo, bit-exato) | ADR-I1 Opção C | Reestrutura o loop; habilita regressão visual automatizada |
| BLK-19 | Console interativo na janela (comandos em runtime) | VS-07 não-escopo | O bus de eventos já é o ponto de entrada |
| BLK-20 | Gamepad e scroll de mouse; coalescência/compressão de MouseMove | VS-07 não-escopo | Volume de gravação cresce rápido com mouse livre |
| BLK-21 | Comandos de sensibilidade (`SetMouseSensitivity`, `SetMoveSpeed`) | VS-07 questão aberta | Hoje hardcoded (0.07 / 10 u/s) |
| BLK-22 | **Save/serialização** — mundo, edições; chunks `EMPTY` tratados como "sem dados" | VS-10 não-escopo | Sistema inexistente hoje; journal append-only é a base |

## Telemetria e observabilidade

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-23 | `VK_KHR_performance_query` (contadores de hardware) | ADR-T1 Opção B | — |
| BLK-24 | Nsight Aftermath (crash dumps GPU) | ADR-T1 Opção D | — |
| BLK-25 | ~~SDK externo (Tracy etc.) sobre os pontos de instrumentação~~ **FECHADO pela VS-15** (ADR-T3 Opção A): Tracy CPU zones opt-in via `-define:TRACY_ENABLE=true` (`run_tracy.bat`); HUD/GUI de telemetria segue em aberto | ADR-T1 / VS-05 não-escopo | Fechado em 2026-11-07; não-escopos da VS-15 viraram BLK-33..36 |
| BLK-26 | Contadores da VS-10 (empties ativos, slots economizados) no CSV de telemetria | VS-10 questão aberta | — |
| BLK-27 | Guard permanente "replay ativo ignora input live" (capturas/smokes automatizados movem a câmera ao focar a janela) | ressalva VS-13 | Hoje é contorno manual por roteiro; afeta qualquer smoke com captura |
| BLK-28 | Corrida de desligamento intermitente (worker × thread principal no teardown) | ressalva VS-13 | Vista 1× em smokes; intermitente |
| BLK-29 | **Blending/translucidez real** (vidro, água) com ordenação de transparência | VS-14 não-escopo + ADR-P1 Opção B | Pipeline muda (OIT ou ordenação por chunk); hoje só cutout opaco |
| BLK-30 | **Alpha-to-coverage** para suavizar o recorte da folhagem | VS-14 não-escopo | Depende de MSAA na pipeline |
| BLK-31 | **Probabilidade de spawn da planta configurável** (hoje constante 10% no shader) | VS-14 não-escopo | Via `vox.ini`/push constant; exige caminho de config até o generate |
| BLK-32 | **Heights do mirror vs denso em chunks abaixo de y=0**: o comparador `int`×`uint` do generate faz esses chunks serem ar no denso, mas o export do heightmap grava `min(altura-base, 31)` — coluna reporta topo 31 onde o denso é ar | ressalva VS-14 (achado na validação) | Artefato pré-existente da VS-13; sem impacto em plantas/ACs; alinhar semântica (export replica o comparador) quando o mirror ganhar consumidor de gameplay |
| BLK-33 | **GPU zones Tracy** (`TracyVkContext` + calibração por fila) | VS-15 não-escopo | Grande superfície: contexto por queue, timestamps de calibração |
| BLK-34 | **Memory profiling Tracy** (allocator custom do odin-tracy) | VS-15 não-escopo | Integra ao context/allocator do Odin |
| BLK-35 | **Lock tracking Tracy** (`LockCtx` nos mutexes do streaming) | VS-15 não-escopo | `queue_mutex` é o candidato principal |
| BLK-36 | **Call stacks Tracy** (`TRACY_CALLSTACK > 0` nas zones) + sampling | VS-15 não-escopo | Cliente recompilado com a flag; só Windows x64 |
| BLK-37 | ~~Build Tracy trava após `voxel_gpu_init`~~ **FECHADO (2026-11-07)** — fix: lib com `TRACY_MANUAL_LIFETIME` + `TRACY_DELAYED_INIT`, startup manual do profiler após o init Vulkan (`engine.TracingStartup`/`TracingShutdown`); ver histórico da VS-15 | ressalva do fix de sincronização 2026-11-07 | Fechado em 2026-11-07; 8/8 verdes pós-fix vs 5/5 hangs no HEAD |
| BLK-38 | **THREADING ERROR `vkQueueSubmit2` × `vkDeviceWaitIdle` em threads distintas** durante tempestade de resize/minimize (recreate de swapchain em loop) | ressalva do fix de sincronização 2026-11-07 | Vista 1× sob minimize/restore agressivo repetido; investigar se o recreate drena a fila de outra thread ou se há uso concorrente da fila gráfica |
| BLK-39 | **`vkDestroyDevice` leva ~60 s no teardown** após replay longo (125 eventos), com e sem Tracy — GPU work acumulado drenando no destroy | ressalva do fix BLK-37 (2026-11-07) | Pré-existente (reproduz no build default); não bloqueia smokes curtos; investigar drenagem explícita (wait idle por etapa) se incomodar |

## Regras

1. Item novo só entra aqui (não fica espalhado em specs fechadas) — mas a origem deve ser citada.
2. Item sai do backlog quando uma spec que o cobre é aprovada; referenciar a spec no histórico.
3. B6–B8 permanecem na tabela de registros da arquitetura até serem corrigidos; este arquivo é o índice consolidado.
4. Ordem dentro de cada seção é livre; prioridade é decisão do mantenedor na escolha da próxima spec.
