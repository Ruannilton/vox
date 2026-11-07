---
id: backlog
titulo: Backlog consolidado
tipo: tracking
ultima_atualizacao: 2026-11-06
---

# Backlog consolidado

Índice único dos itens futuros do motor. Itens entram aqui a partir dos **não-escopos das specs**, **consequências de ADRs** e **bugs deixados para depois**; saem quando viram spec aprovada (ou são explicitamente descartados pelo mantenedor). Bugs ativos da tabela de registros da arquitetura (B6–B8) permanecem lá e são espelhados aqui.

Legenda de origem: `VS-xx não-escopo` · `ADR-xx consequência` · `arquitetura §9` · `ressalva de validação`.

## Bugs e débitos técnicos

| ID | Item | Origem | Notas |
| --- | --- | --- | --- |
| BLK-01 | **B6 — Plantas sem alpha-test** (`CULL_MODE_NONE` na pipeline; folhagem renderiza opaca) | arquitetura §9 | Corrigir junto com transparência via assets (BLK-13) |
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
| BLK-13 | Transparência/emissão/PBR via JSON (flags já existem no `BlockDefinition`) | VS-12 não-escopo + BLK-01 | Fecha o alpha-test de plantas |
| BLK-14 | Mipmaps e filtragem trilinear nas texturas de blocos | VS-12 não-escopo | Alias em minificação em visões longas |
| BLK-15 | Atlas interno por face / texturas por face | VS-12 não-escopo | Depende de BLK-08 (rotação) |
| BLK-16 | **Worldgen data-driven** — desacoplar o contrato ids 1–3 do `generate` | VS-12 não-escopo | Hoje o JSON deve definir grama/terra/pedra nos ids fixos |
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
| BLK-25 | SDK externo (Tracy etc.) sobre os pontos de instrumentação; HUD/GUI de telemetria | ADR-T1 / VS-05 não-escopo | Arquivo continua sendo o destino base |
| BLK-26 | Contadores da VS-10 (empties ativos, slots economizados) no CSV de telemetria | VS-10 questão aberta | — |
| BLK-27 | Guard permanente "replay ativo ignora input live" (capturas/smokes automatizados movem a câmera ao focar a janela) | ressalva VS-13 | Hoje é contorno manual por roteiro; afeta qualquer smoke com captura |
| BLK-28 | Corrida de desligamento intermitente (worker × thread principal no teardown) | ressalva VS-13 | Vista 1× em smokes; intermitente |

## Regras

1. Item novo só entra aqui (não fica espalhado em specs fechadas) — mas a origem deve ser citada.
2. Item sai do backlog quando uma spec que o cobre é aprovada; referenciar a spec no histórico.
3. B6–B8 permanecem na tabela de registros da arquitetura até serem corrigidos; este arquivo é o índice consolidado.
4. Ordem dentro de cada seção é livre; prioridade é decisão do mantenedor na escolha da próxima spec.
