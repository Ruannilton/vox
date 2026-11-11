---
id: VS-07
titulo: Eventos de input, comandos e replay
tipo: especificacao
status_spec: aprovada
status_implementacao: concluida
status_validacao: verificada
depende_de:
  - VS-03
bloqueada_por: []
requisitos: [REQ-EVT-01, REQ-EVT-02, REQ-EVT-03, REQ-EVT-04, REQ-EVT-05, REQ-EVT-06, REQ-EVT-07, REQ-EVT-08, REQ-EVT-09]
ultima_atualizacao: 2026-11-06
---

# VS-07 — Eventos de input, comandos e replay

## Objetivo

Intermediar **toda** interação usuário↔aplicação por eventos internos tipados (input: teclado/mouse; comando: TeleportTo, LookAt, AddBlock, RemoveBlock, …), cada um carregando o tempo de emissão em relação ao início da aplicação; gravar todos os eventos em arquivo JSON (JSONL); e reproduzir uma sessão a partir de um arquivo de eventos passado por parâmetro de inicialização — com parâmetros de tempo (tecla segurada por X segundos, espera obrigatória) para roteirizar comportamentos.

## Rastreabilidade

- GOAL: nova fatia (input/eventos) — sem requisitos numerados nos documentos de arquitetura; o escopo foi definido pelo mantenedor (2026-11-06): bus de eventos, comandos shell, parâmetro de tempo, timestamp relativo, log JSON, replay por parâmetro de inicialização.
- Referência: callbacks GLFW e polling de teclas em `src/main.odin` (`SetKeyCallback`, `SetCursorPosCallback`, `update_camera_movement`), câmera em `src/camera.odin`, API de edição `ve_request_voxel_edit`/`ve_request_voxel_edits_in_box` em `src/engine/voxel_edit.odin` (VS-03), tempo de frame em `src/engine/engine.odin` (`Update`, `glfw.GetTime`).
- Decisões: [[ADR-I1-bus-eventos-input-replay|ADR-I1]] (bus central, tempo de parede relativo, JSONL, replay best-effort — **bloqueia a aprovação desta spec**).
- Fundação: VS-00 (engine, loop, janela GLFW) e [[VS-03-edicao-e1|VS-03]] (journal de edição que AddBlock/RemoveBlock alimentam); [[VS-04-mirror-c2|VS-04]] fornece o mirror para verificar efeitos de AddBlock/RemoveBlock em validação (não é dependência de implementação).

## Requisitos

### Modelo de eventos e bus

- **REQ-EVT-01** — Todo evento tem: `t` (segundos desde o início da aplicação, f64, monotônico não decrescente dentro de uma sessão), `type` (string do tipo) e `payload` tipado. Tipos: input — `KeyPress`, `KeyRelease`, `MouseMove` (delta), `MouseButton` (press/release), `CloseRequested`; comando — `TeleportTo`, `LookAt`, `AddBlock`, `RemoveBlock`, `Wait`, `ToggleTelemetry`, `TelemetrySnapshot`. Eventos de comando usam exatamente o mesmo pipeline (bus, gravação, replay) que os de input.
- **REQ-EVT-02** — Bus central em fila: produtores (callbacks GLFW, cursor de replay) **apenas produzem**; o loop principal drena a fila **uma vez por frame**, após `glfw.PollEvents()` e antes de `engine.Update()`, e despacha aos handlers registrados. Callbacks são funções puras de produção: sem `context` de runtime, sem alocação, sem log (a gravação acontece no dreno). Fila com capacidade fixa (4.096 eventos); overflow é defensivo (thread única, não deve ocorrer) — evento descartado com contador e warning no log.
- **REQ-EVT-03** — Eliminação do polling: o conjunto de teclas pressionadas passa a ser estado derivado de `KeyPress`/`KeyRelease` (mantido pelo módulo de eventos); `update_camera_movement` consome esse estado por frame, com a mesma semântica atual (WASD, SHIFT ×8, normalização de diagonal, `speed × deltaTime`). A rotação da câmera é aplicada pelo handler de `MouseMove` (mesma sensibilidade 0.07 e eixos atuais, incluído o primeiro evento de cursor que só ressincroniza). Handlers são registrados por tipo; um handler pode servir a vários tipos. `CloseRequested` fecha a janela (`glfw.SetWindowShouldClose`).

### Parâmetros de tempo

- **REQ-EVT-04** — Duração em teclas: `KeyPress` aceita `duration` (segundos, opcional). Em qualquer origem (replay ou API), o sistema agenda o correspondente `KeyRelease` em `t + duration` — pressionar "W por 2,5 s" é um evento único. Sem `duration`, `KeyPress` de tecla de ação (F8/F9/ESCAPE) é tratada como instantânea pelo seu handler; teclas de estado (WASD) permanecem pressionadas até `KeyRelease` explícito ou `duration`.
- **REQ-EVT-05** — Espera: `Wait {seconds}` segura o cursor de replay — nenhum evento subsequente com `t` anterior a `t_emitido + seconds` é despachado antes desse instante (o app continua rodando e renderizando normalmente durante a espera).

### Gravação

- **REQ-EVT-06** — Gravação default-ligada em todo evento drenado, em **JSONL** (um objeto JSON por linha), arquivo `bin/events/events_YYYYMMDD_HHMMSS.jsonl` com timestamp da sessão (mesmo padrão de nomes da telemetria). Cada linha é escrita e flushed no dreno (thread única); JSONL não exige trailer, então crash não corrompe o arquivo já escrito. Flags: `--no-record` desliga; `--record <caminho>` fixa o destino. Gravar durante replay é permitido: o arquivo da sessão recebe os eventos com o tempo de emissão **da sessão corrente** (nunca o `t` original do evento replayado) — a invariante "`t` = quando foi emitido, relativo ao início desta aplicação" vale sempre.
- **REQ-EVT-07** — Timestamp de emissão: `t = glfw.GetTime() − t0`, com `t0` fixado no fim da inicialização da engine, antes do primeiro `PollEvents`. Eventos gerados durante o mesmo dreno compartilham o `t` do dreno.

### Replay

- **REQ-EVT-08** — Parâmetro de inicialização `--replay <caminho.jsonl>`: o arquivo é validado e carregado antes do loop principal; um cursor ordenado por `t` despacha a cada frame os eventos com `t ≤ tempo_atual` (1×, best-effort — ver ADR-I1). Ao final do stream: log de sumário (total despachados, pulados, ignorados, duração) e a sessão continua interativa. Flag opcional `--exit-after-replay`: fecha a aplicação ao terminar o stream (para pipelines automatizados de captura). Erros: arquivo inexistente/ilegável ou JSON inválido na linha 1 → **erro fatal com exit code não-zero** (uso inválido); linha individual inválida ou tipo desconhecido → evento **pulado com warning contado** no sumário, nunca fatal.
- **REQ-EVT-09** — Fidelidade de schema: o leitor de replay e o gravador compartilham o mesmo schema e a mesma tabela de tipos (`src/engine/events.odin`); `tools/sim/events_check.py` valida qualquer arquivo JSONL de eventos (schema por tipo, `t` monotônico, payloads completos) e é usado como evidência nos ACs.

## Escopo

- Módulo `src/engine/events.odin`: tipos, fila, estado de teclas, registrador de handlers, gravador JSONL, carregador/cursor de replay, parsing de parâmetros de inicialização.
- Refatoração do `src/main.odin`: callbacks viram produtores; handlers de câmera/telemetria/fechamento; registro dos handlers de comando (TeleportTo/LookAt usam `camera.odin`; AddBlock/RemoveBlock usam `ve_request_voxel_edit`; ToggleTelemetry/TelemetrySnapshot reutilizam a telemetria VS-05).
- Callbacks GLFW adicionais necessários para cobertura total: `SetMouseButtonCallback` e `SetWindowCloseCallback` (CloseRequested).
- Gravação default em `bin/events/`; flags `--record`, `--no-record`, `--replay`, `--exit-after-replay`.
- Validador `tools/sim/events_check.py`.
- Docs: arquitetura (nova seção ou subseção de input), manual técnico, tracking.

## Não escopo

- Replay determinístico/bit-exato (timestep fixo — backlog, Opção C da ADR-I1).
- Console interativo na janela (digitação de comandos em runtime), gamepad, scroll de mouse, rede/multiplayer.
- Edição em lote roteirizada além de AddBlock/RemoveBlock pontuais (`ve_request_voxel_edits_in_box` como comando fica para consumidor futuro).
- Compactação/compactação de MouseMove (gravação crua; volume é aceitável para debug — backlog).
- Qualquer mudança em shaders, streaming, mirror ou sincronização GPU.
- Telemetria de input (contadores por tipo de evento): backlog natural da VS-05.

## Dependências

- [[VS-03-edicao-e1|VS-03]] concluída e verificada (journal/edição que os comandos de bloco alimentam); VS-00 (engine/loop) como fundação transversal.
- [[ADR-I1-bus-eventos-input-replay|ADR-I1]] — **pendente; bloqueia a aprovação desta spec** até a ratificação do mantenedor (recomendação registrada: Opção A).

## Interfaces e recursos

### Schema dos eventos (contrato gravador↔leitor↔validador)

```jsonc
// input
{"t": 12.345, "type": "KeyPress",   "key": 87, "key_name": "W", "duration": 2.5}
{"t": 12.360, "type": "KeyRelease", "key": 87, "key_name": "W"}
{"t": 12.400, "type": "MouseMove",  "dx": 1.5, "dy": -0.5}
{"t": 12.410, "type": "MouseButton","button": 0, "action": "press"}
{"t": 99.000, "type": "CloseRequested"}
// comando
{"t": 13.000, "type": "TeleportTo", "position": [32.0, 75.0, 60.0]}
{"t": 13.100, "type": "LookAt",     "target": [0.0, 32.0, 0.0]}
{"t": 14.000, "type": "AddBlock",   "position": [10, 40, 10], "block_id": 1}
{"t": 14.500, "type": "RemoveBlock","position": [10, 40, 10]}
{"t": 15.000, "type": "Wait",       "seconds": 3.0}
{"t": 16.000, "type": "ToggleTelemetry"}
{"t": 16.100, "type": "TelemetrySnapshot"}
```

- `key`: código GLFW (i32) — fonte da verdade no replay; `key_name`: opcional, só legibilidade.
- `MouseMove` grava apenas o **delta** aplicado (o modo `CURSOR_DISABLED` torna a posição absoluta sem significado).
- `AddBlock`/`RemoveBlock`: `position` é coordenada de **voxel mundo** `[3]i32`; `RemoveBlock` equivale a `block_id = 0`.

### Recursos e proprietários

- **`src/engine/events.odin`** (novo): fila (4.096 × struct de evento + union de payload), pressed-set de teclas, handler registry (mapa tipo→handler), gravador (arquivo + buffer de linha), replay (vetor ordenado de eventos + cursor + hold-until). Sem objetos Vulkan; destruído com o app.
- **Arquivo de sessão**: `bin/events/events_<timestamp>.jsonl` (default), flush por dreno e no shutdown.
- **`src/main.odin`**: callbacks produtores (key/cursor/mouse-button/window-close), handlers de input (câmera, telemetria, fechamento) e de comando (blocos via `ve_request_voxel_edit`).

### Sequência do frame (integração)

```
glfw.PollEvents()                 [callbacks produzem na fila]
events_drain()                    [grava JSONL + despacha handlers:
                                   MouseMove→câmera, Key*→pressed-set+ações,
                                   comandos→teleport/lookat/blocos/telemetria]
engine.Update()
update_camera_movement(dt)        [consome pressed-set; SEM glfw.GetKey]
…resto do frame inalterado (VS-01..06)…
```

### Comportamento quando limites são atingidos

- Fila cheia (defensivo): descarta o evento, incrementa contador, warning uma vez por sessão.
- Replay: arquivo ausente → erro fatal (exit ≠ 0); linha inválida/tipo desconhecido → skip + warning + contagem no sumário; `--exit-after-replay` fecha ao fim do stream (inclusive se o stream estiver vazio).
- `KeyPress` com `duration` sobre tecla já pressionada: re-marca o release para `t + duration` (última escrita vence).
- Flags conflitantes (`--no-record` + `--record`): `--record` vence, com warning.

## Cenários

### Gravação e replay de uma sessão interativa

- **Dado** uma sessão em que o usuário anda (WASD), olha (mouse), teleporta e adiciona um bloco.
- **Quando** a sessão roda com gravação default e depois `vox.exe --replay events_<ts>.jsonl --exit-after-replay` é executado.
- **Então** o arquivo da primeira sessão contém todos os eventos com `t` monotônico (validados por `events_check.py`); o replay despacha a mesma sequência nos mesmos tempos (sumário confere com a contagem do arquivo), a pose final da câmera e o bloco adicionado reproduzem o estado da sessão original, e a aplicação encerra sozinha.

### Roteirizado com tempo (HoldKey + Wait)

- **Dado** um JSONL com `KeyPress{key:W, duration:2.5}` seguido de `Wait{seconds:1}` e `AddBlock`.
- **Quando** o replay executa.
- **Então** a câmera anda por ~2,5 s, aguarda 1 s renderizando, e só então o bloco é adicionado (o `AddBlock` não ocorre antes de `t_press + 2.5 + 1.0`, tolerância de um frame).

### Comandos de câmera exatos

- **Dado** um JSONL com `TeleportTo{position:[x,y,z]}` + `LookAt{target}` + `--exit-after-replay`.
- **Quando** o replay termina.
- **Então** a câmera está exatamente em `[x,y,z]` olhando para `target` (asserção exata de estado, independente de frame rate).

### Falhas e concorrência

- Arquivo de replay inexistente: erro fatal com exit code não-zero antes de criar a janela.
- Linha com JSON quebrado no meio do arquivo: sessão continua, warning e contagem no sumário.
- Replay durante streaming pesado: eventos continuam despachando nos tempos de parede (best-effort); nenhum evento é perdido — o cursor só avança, nunca recua.
- Gravação durante replay produz arquivo novo com tempos da sessão corrente, sem reutilizar os `t` originais.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-07-AC-01 | Todo evento emitido numa sessão interativa é gravado em JSONL válido com `t` monotônico (schema por tipo) | Sessão roteirizada (handlers via API + input sintético) → `tools/sim/events_check.py` no arquivo + contagens conferem | **Verificado (2026-11-06):** sessão roteirizada gravada durante o replay do AC-03 (`--record events/ac03_gravado.jsonl`) — 7 linhas, `events_check.py` OK (exit 0, schema por tipo, `t` monotônico); contagens: 6 despachados + 1 `KeyRelease` sintetizado do `duration` = 7 linhas. Arquivo default `events/events_20261106_114251.jsonl` de sessão sem input também validado (0 eventos, intacto após kill -9) |
| VS-07-AC-02 | Comportamento interativo inalterado: WASD/SHIFT (movimento), mouse (rotação com primeiro-evento especial), F8/F9 e ESC funcionam como hoje | Smoke manual comparando com o build anterior + código revisado (polling eliminado, semântica preservada) | **Verificada (2026-11-06)** — smoke interativo manual do mantenedor com teclado/mouse reais (movimento WASD/SHIFT, rotação, F8/F9, ESC) confirmou a paridade interativa; somada à paridade record→replay automatizada (pose final exata `[10,75,20]/[0,70,0]`, edição re-aplicada `applied=1`) e à revisão de semântica (sensibilidade 0.07, eixos, SHIFT ×8, diagonal, speed 10, mesmos gatilhos ESC/F8/F9) |
| VS-07-AC-03 | Replay executa a sequência nos tempos gravados: HoldKey move por ~`duration`, Wait atrasa o restante, TeleportTo/LookAt resultam na pose exata, AddBlock/RemoveBlock refletidos no mundo (verificável pelo mirror/VS-04 ou feedback E1) | Sessão `--replay roteiro.jsonl --exit-after-replay` com asserções de estado e de tempos (tolerância 1 frame); sumário bate com o arquivo | **Verificado (2026-11-06):** roteiro `KeyPress W duration 2.5` → release sintetizado registrado em `t+2.50` (0.505→3.006); `Wait 1.0` em t=3.2 segurou o `AddBlock` (t=3.5 no arquivo) até t=4.201 (≥4.2, tolerância 1 frame ✓); pose final exata `position=[10,75,20] target=[0,70,0]`; feedback E1 `applied=1 noop=0 rejected=0`; sumário `despachados=6` = 6 linhas do roteiro; `--exit-after-replay` encerrou sozinho (EXIT=0, duração 8.000s) |
| VS-07-AC-04 | Robustez do replay: arquivo ausente → exit ≠ 0; linha inválida e tipo desconhecido → skip com warning e contagem no sumário; `--no-record`/`--record` respeitados | Execuções com cada caso de erro; inspeção do log e do exit code; `events_check.py` rejeita arquivo com schema inválido | **Verificado (2026-11-06):** `--replay nao_existe.jsonl` → exit 1 com erro fatal pré-janela; roteiro com linha quebrada (`isto nao e json`) + tipo desconhecido (`FooBar`) → 2 warnings, sumário `despachados=3, pulados(linhas)=2`, exit 0; `--no-record` não criou arquivo nem log de gravação; `--record novo_dir/sub/teste.jsonl` criou diretórios e gravou; `events_check.py` rejeita JSON com schema inválido (campos/valores por tipo) |

## Tarefas da especificação

- [x] Vincular o escopo definido pelo mantenedor (REQ-EVT-01..09) às interfaces existentes (callbacks/polling do main, edição VS-03, telemetria VS-05).
- [x] Formalizar schema dos eventos, flags de linha de comando e semântica de tempo (HoldKey/Wait).
- [x] Cobrir sucesso, dados-limite, falhas e concorrência (thread única; replay best-effort).
- [x] Definir validação para cada critério de aceitação.
- [x] Ratificar a ADR-I1 e obter aprovação da spec. — ADR-I1 (Opção A) ratificada e spec aprovada pelo mantenedor em 2026-11-06.

## Tarefas de implementação

Só entram na fila após a aprovação desta spec e a ratificação da ADR-I1. Cada tarefa referencia requisitos e critérios de aceitação.

1. ~~VS-07-IMPL-01~~ **VS-07-IMPL-01 — Módulo de eventos** (REQ-EVT-01, REQ-EVT-02, REQ-EVT-07; AC-01). ✅ 2026-11-06 — `src/engine/events.odin`: tipos/union, fila de 4.096 (anel, overflow contado com warning único), pressed-set e scheduled-release (mapas), handler registry por tipo, timestamp `t = glfw.GetTime() − t0` (t0 em `events_set_t0`, fim da init), gravação JSONL (flush por linha + shutdown) com flags `--record`/`--no-record` e default `bin/events/events_<ts>.jsonl` (diretórios do caminho criados).
2. ~~VS-07-IMPL-02~~ **VS-07-IMPL-02 — Validação de schema** (REQ-EVT-09; AC-01, AC-04). ✅ 2026-11-06 — `tools/sim/events_check.py`: 12 tipos, campos obrigatórios/opcionais/desconhecidos, `t` monotônico (tolerância 1e-9); exit 0/1.
3. ~~VS-07-IMPL-03~~ **VS-07-IMPL-03 — Refatoração do input no main** (REQ-EVT-03, REQ-EVT-04; AC-02). ✅ 2026-11-06 — callbacks `proc "c"` produtores puros (key/cursor/mouse-button/window-close; resync do primeiro cursor no callback, sem push); handlers registrados (câmera, F8/F9, ESC→`CloseRequested`, fechamento); `update_camera_movement` consome `events_is_pressed` (sem `glfw.GetKey`); `duration` agenda release sintetizado no dreno (última escrita vence).
4. ~~VS-07-IMPL-04~~ **VS-07-IMPL-04 — Comandos** (REQ-EVT-01; AC-03). ✅ 2026-11-06 — handlers TeleportTo/LookAt (camera.odin), AddBlock/RemoveBlock (`ve_request_voxel_edit`), ToggleTelemetry/TelemetrySnapshot.
5. ~~VS-07-IMPL-05~~ **VS-07-IMPL-05 — Replay** (REQ-EVT-05, REQ-EVT-08; AC-03, AC-04). ✅ 2026-11-06 — validação fatal pré-janela (ausente/ilegível/JSON inválido na linha 1 → exit 1); vetor ordenado por t (insertion sort) + cursor; `Wait` hold-until comparando o relógio da sessão; skips com warning e contagem; sumário `REPLAY SUMMARY: despachados/pulados/ignorados/duração`; `--exit-after-replay`; gravação durante replay usa `t` da sessão corrente.
6. ~~VS-07-IMPL-06~~ **VS-07-IMPL-06 — Evidências e fechamento** (AC-01..04). ✅ 2026-11-06 — sessões executadas e documentadas nos ACs; docs (arquitetura §8, tracking) e commit com o nome da spec.

## Questões abertas

- Sensibilidade do mouse (0.07) e speed de movimento (10.0 × 8 com SHIFT) permanecem hardcoded como hoje — parametrizá-los como comandos (SetMouseSensitivity etc.) é backlog; não bloqueia a aprovação.
- Prefixo das flags (`--replay` vs `-replay`): `--` adotado na spec e na implementação. Não bloqueia a aprovação.
- Formato exato do sumário de replay: **definido na implementação** — `REPLAY SUMMARY: despachados=<n>, pulados(linhas)=<n>, ignorados(aguardando)=<n>, duração=<t>s` (log INFO ao fim do stream). "pulados" = linhas inválidas/tipos desconhecidos; "ignorados" = eventos válidos nunca despachados (janela fechou antes).

## Histórico

- 2026-11-06 — Rascunho elaborado a partir do pedido do mantenedor (intermediar interações por eventos internos, comandos shell, parâmetro de tempo, timestamp relativo, log JSON, replay por parâmetro); ADR-I1 registrada como pendente com recomendação da Opção A; spec submetida à revisão bloqueada pela ADR.
- 2026-11-06 — **ADR-I1 ratificada (Opção A) e spec aprovada** pelo mantenedor; bloqueio removido; tarefas VS-07-IMPL-01..06 destravadas.
- 2026-11-06 — **Implementação concluída (IMPL-01..06).** O que mudou em relação ao previsto: (1) Odin não tem closures — `voxel_engine` virou global de pacote em `main.odin` (mesmo padrão de `camera`); (2) escape de chaves `{{}}` no fmt para as linhas JSONL; (3) gravação com `--record` cria os diretórios do caminho; (4) um `Wait` em última posição não atrasa `--exit-after-replay` (o stream terminou; o hold só bloqueia eventos subsequentes).
- 2026-11-06 — **Bugs encontrados durante a validação:** (a) *hold do Wait travava o cursor* — a comparação `e.t < hold_until → break` usava o `t` do evento em vez do relógio da sessão, impedindo para sempre o despacho de eventos com `t` entre o `Wait` e o fim da espera (corrigido comparando o relógio); (b) *regressão pré-existente do E1 (VS-03)* — o commit `6897431` ("remove tests") removeu do `main` as chamadas a `edit_flush_due`/`flush_voxel_edits`, deixando o flush do journal morto, e `edit_ring_write` sobrescrevia `last_flush`/`force_next_flush` todo frame, o que anularia o gating de 100 ms mesmo com as chamadas restauradas; corrigido com o wrapper `edit_update` no loop e a movimentação do carimbo/flag para o fim de `flush_voxel_edits` (sem esse fix, AddBlock/RemoveBlock enfileiravam mas nunca aplicavam — `fila=1, applied=0`). Registrado na tabela de correções da `docs/arquitetura.md`.
- 2026-11-06 — **Validação executada (AC-01..04, números na tabela de ACs).** Destaques: roteiro `KeyPress W duration 2.5` + `Wait 1.0` + `AddBlock` + `TeleportTo`/`LookAt` — release sintetizado em `t+2.50`, bloco despachado só após o fim da espera (4.201 ≥ 4.2), pose final exata, feedback E1 `applied=1`, exit sozinho; arquivo ausente → exit 1 pré-janela; linha quebrada + tipo desconhecido → 2 skips com warning no sumário; `--no-record`/`--record` respeitados; `events_check.py` OK no arquivo gravado. **AC-02 ficou `em-validacao`**: a paridade record→replay da mesma build foi verificada (pose e efeitos reproduzidos) e a equivalência de código revisada, mas o smoke interativo manual (teclado/mouse reais, F8/F9/ESC) depende do mantenedor.
- 2026-11-06 — **AC-02 verificado pelo mantenedor** (smoke interativo manual com input real: WASD/SHIFT, rotação do mouse, F8/F9, ESC — paridade confirmada). Com a paridade record→replay automatizada e a revisão de semântica, a spec está integralmente concluída: `status_validacao: verificada`.
