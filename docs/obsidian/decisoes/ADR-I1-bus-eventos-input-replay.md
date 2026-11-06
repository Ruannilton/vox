---
id: ADR-I1
titulo: Bus de eventos de input com gravação e replay
tipo: decisao
status: aceita
specs_afetadas: [VS-07]
ultima_atualizacao: 2026-11-06
---

# ADR-I1 — Bus de eventos de input com gravação e replay

## Contexto

Toda interação usuário↔aplicação hoje é direta: callbacks GLFW no `main.odin` mutam estado (câmera, telemetria, fechamento) e o movimento WASD é lido por *polling* (`glfw.GetKey`) por frame. Não existe registro nem reprodução: debugar "o que foi feito" exige reexecução manual. O mantenedor quer: (1) toda interação intermediada por eventos internos (PressKey, MouseMove, …); (2) eventos de comando estilo shell (TeleportTo, LookAt, AddBlock, RemoveBlock, …); (3) parâmetro de tempo em alguns eventos (tecla pressionada por X segundos, espera obrigatória); (4) timestamp de emissão em todo evento (referência: início da aplicação); (5) log JSON de todos os eventos; (6) replay a partir de arquivo JSON passado por parâmetro de inicialização.

A escolha que mais importa é o **modelo temporal do replay**: o que significa "reproduzir" quando o custo por frame varia (streaming, geração de chunks) e o `deltaTime` de cada frame depende da máquina.

## Requisitos relacionados

- REQ-EVT-01..09 da [[VS-07-eventos-input-replay|VS-07]].

## Opções

### Opção A — Bus central + tempo de parede relativo + JSONL

- Uma fila central de eventos: os callbacks GLFW (e o carregador de replay) só **produzem** eventos com timestamp; o loop principal **drena** a fila uma vez por frame e despacha aos handlers. O estado de teclas pressionadas é derivado dos eventos KeyPress/KeyRelease (o polling `glfw.GetKey` é eliminado); a rotação da câmera passa a ser aplicada pelo handler de MouseMove no dreno.
- Gravação em **JSONL** (um evento JSON por linha, arquivo com timestamp da sessão), escrita no lado do dreno (thread única, sem contenção). Replay em velocidade 1×: um cursor percorre o arquivo ordenado por `t` e despacha os eventos devidos a cada frame; `KeyPress{duration}` sintetiza o release em `t+duration`; `Wait` segura o cursor.
- Tempo de referência: segundos desde o início da aplicação (`glfw.GetTime() − t0`), portanto o replay é **best-effort**: eventos disparam nos mesmos tempos da sessão original, mas a integração por `deltaTime` faz a trajetória resultante depender do frame rate da máquina — bit-exato não é garantido nem pretendido.
- Vantagens: refatoração contida (callbacks viram produtores puros, sem `context` de runtime), gravação crash-safe (JSONL não precisa de trailer), replay sem engenharia de determinismo, funciona no loop atual sem tocar em sincronização GPU.
- Desvantagens: replay não é bit-exato; reproduzir trajetórias de câmera longas exige máquina similar; arquivo de eventos pode crescer rápido (MouseMove contínuo) — aceitável para debug.

### Opção B — Callbacks diretos + interceptação apenas para registro

- Mantém a arquitetura atual e apenas grava/reproduz por interceptação. O polling `glfw.GetKey` não gera eventos (só um snapshot por frame), então a gravação é incompleta e o replay de movimento WASD é uma aproximação grosseira (síntese de holds por frame).
- Vantagens: quase zero refatoração.
- Desvantagens: não cumpre o requisito do mantenedor ("toda e qualquer interação intermediada por eventos"); replay de qualidade inferior; dois caminhos de input (evento vs polling) para sempre.

### Opção C — Replay determinístico com timestep fixo

- Define um passo fixo de simulação (ex. 60 Hz lógico): eventos indexados por *tick* lógico, `deltaTime` constante, loop desacoplado do vsync.
- Vantagens: replay bit-exato mesmo em máquinas diferentes; habilita testes de regressão visual.
- Desvantagens: reestrutura o loop principal e a relação com o streaming/timeline Vulkan (o mundo é assíncrono por natureza — a GPU conclui chunks em tempos de máquina); alto custo agora; fere a simplicidade do pipeline atual sem ganho imediato.

## Decisão

**Opção A** — bus central de eventos (callbacks produzem, loop drena por frame), tempo de parede relativo ao início da aplicação, gravação JSONL e replay best-effort 1×. Determinismo bit-exato fica explicitamente como backlog (a Opção C é o caminho se um dia for necessário). Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-07.

## Consequências

- Os callbacks GLFW no `main.odin` deixam de aplicar efeitos: viram produtores puros de eventos (sem `context` de runtime, sem alocação). O movimento WASD passa de polling para estado derivado de KeyPress/KeyRelease — comportamento interativo deve permanecer idêntico (requisito e AC da VS-07).
- Toda funcionalidade nova de input (gamepad, console) tem um ponto único de entrada natural: produzir eventos.
- A validação do replay compara **sequência e tempos de eventos**, não pixels; cenários com comandos (TeleportTo/LookAt/AddBlock) têm asserções exatas de estado (pose da câmera, presença do bloco).
- O formato JSONL e o schema dos eventos viram contrato (documentados na spec); o validador Python faz parte da fatia.

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-07 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-07.
