---
id: VS-23-TASKS
titulo: Tarefas — iluminação híbrida por ray casting na GPU
tipo: tarefas
spec: VS-23
status: em-andamento
ultima_atualizacao: 2026-11-14
---

# VS-23 — Tarefas de implementação

Spec aprovada com a ADR-L1. Executar as fases em ordem, sem integrar mudança de shader antes da simulação Python correspondente. A referência de design contém os pontos de inserção e o código inicial de T0.1–T3.6; cada etapa deve adaptar esse desenho ao código vigente, sem copiar contratos que já tenham mudado.

## Progresso (2026-11-14)

- [x] T0.1 — Máscara de opacidade (sim `tools/sim/opacity_sim.py` verde; `pack_chunk`/`apply_voxel_edits` atualizados; pool realocado para 3138 words; Slang + `spirv-val` limpos).
- [x] T0.2 — `chunk_grid` e `LightGlobals` (bindings 25/26; publicação no handler de conclusão B1; limpeza no unload; recentralização 64×16×64 no worker; UBO dinâmico por frame).
- [x] T0.3 — Descriptors, feature e sincronização (`fragmentStoresAndAtomics` habilitado e checado; barreiras compute→compute e compute→fragment; smoke com validation sem VUIDs e `--full-teardown` limpo).
- [x] T1.0 — Simulação `tools/sim/trace_sim.py` verde (300 raios + casos de ignore/ausente/vidro/negativos/t_max).
- [x] T1.1 — `lighting.slang` + `trace_occluded` (travessia hierárquica stateless any-hit).
- [x] T1.2 — `shade_surface` e fragment principal (sol com shadow ray, ambiente de céu, emissão; helpers extraídos; alpha-test antes do raio).
- [x] T1.3 — Depth pre-pass (pipeline sem color attachment, depth write ligado; principal com `LESS_OR_EQUAL` e sem escrita; mesmo mesh shader e work queue).
- [x] T1.4 — Modos de debug (tecla F5 cicla 0 normal/1 sombra/2 AO/3 block light; smoke alternou os modos em runtime).
- [x] T2.0 — Simulação `tools/sim/ao_sim.py` verde (1600 posições vs gabarito independente; vidro não oclui; face diagonal sem AO).
- [x] T2.1 — `voxel_ao` e ambiente (oito leituras, bilinear por u/w, `ao_strength`, gradiente horizonte→zênite; divergência da referência nos tangentes de faces ±Z corrigida e documentada).
- [x] T3.0 — Simulação `tools/sim/light_sim.py` verde (seed/propagate/relaxação == BFS por canal; remoção zera volume; opaco bloqueia; 15 níveis; seleção de jobs deduplicada).
- [x] T3.1 — `light_pool`, `light_jobs` e helpers (bindings 27/28; 64 KiB/slot; `read_block_identifier_fast`; ring por frame).
- [x] T3.2 — `light_seed` (kernel 8×8×8, RGB 4 bits, sempre reescreve o volume).
- [x] T3.3 — `light_propagate` (6 vizinhos, `max-1` por canal, seed + 15 passes com barreiras compute→compute).
- [x] T3.4 — Gatilhos de relight na CPU (conclusão de geração, flush de edições e descarregamento marcam chunk + 26 vizinhos; dedup no build; relight após edições e antes da work queue).
- [x] T3.5 — Amostragem trilinear de block light no `shade_surface` (modo debug 3 ligado).
- [x] T3.6 — Luzes dinâmicas (tocha do jogador, F6 liga/desliga; `counts.x ≤ 2`, janela suave `saturate(1-(d/R)^4)^2/d²`, shadow ray com `ignore_voxel`).
- [x] T3.7 — Correção de regressão: flicker de geometria inteira por push constant parcial (detalhes e evidências na seção "Regressão corrigida" abaixo).
- [x] T3.8 — Correção de regressão: assert `s_profilerData` no binário Tracy (`ZoneN("biomes_load")` da VS-22 executa antes de `TracingStartup` — BLK-37/TRACY_DELAYED_INIT proíbe API Tracy fora do intervalo). Guarda `tracy.ProfilerStarted()` nas zones CPU e lock tracking do wrapper do projeto (`src/engine/tracing.odin`); smoke Tracy com `--full-teardown` sem assert e captura `tracy-capture` íntegra (28.986 zones, `bin/debug/0.1.35/tracy/VS-23_tracy_fix_validation.tracy`).
- [x] T3.8 — Correção de regressão: assert `s_profilerData` do Tracy ao rodar `run_tracy.bat` (detalhes na seção "Regressão corrigida" abaixo).
- [x] T5.1 (parcial) — Regressão da thread GPU na UI Tracy corrigida (resets do query pool em frames sem edição/relight) + captura baseline `bin/debug/0.1.35/tracy/VS-23_baseline.tracy` com breakdown por pass (detalhes na seção "Regressão corrigida").
- [ ] T5.1–T5.3 — Fechamento: instrumentação Tracy final, validação integrada dos ACs com evidências visuais, captura de performance, comparação, documentação final e commit (etapa do mantenedor).

Evidências do smoke automatizado (2026-11-14): `vox.exe --replay docs/examples/vs23_smoke.jsonl --exit-after-replay --full-teardown` — 9 edições aplicadas, modos F5/F6 exercitados, validation layers ativas sem VUIDs, teardown limpo. Validação visual (sombras/AO/block light em cena controlada) e captura Tracy pendentes do mantenedor.

**Regressão corrigida (2026-11-14, reporte do mantenedor):** a geometria inteira piscava — frames alternados totalmente vazios. Causa-raiz: o bloco de relight em `voxel_render_prepare` fazia um `CmdPushConstants` PARCIAL (`batch_job_offset` + `visible_chunk_capacity`, demais campos zero) para o seed/propagate e não restaurava o conjunto completo. Como push constants são estado do command buffer, `build_work_queue`/`finalize_work_queue` executavam em seguida com `visible_chunk_offset = 0` e VP zerada: a fila era escrita no slot 0 do ring enquanto o `CmdFillBuffer` do frame zerava o slot correto — o draw lia `INDIRECT_X = 0` e despachava 0 mesh tasks (frame vazio; com `NUM_FRAMES_IN_FLIGHT = 2` o frame vazio alternava). Correção mínima: re-push do `VoxelPushConstants` completo após os passes de luz (+ `tracing_gpu_record_context` antes das zones GPU do relight). Evidência: captura GDI frame a frame (`bin/debug/0.1.35/capture_loop.ps1`) com replay `docs/examples/vs23_flicker.jsonl` — binário com regressão: 28/91 frames vazios esparsos; binário corrigido: 0/88. Smoke pós-correção sem VUIDs com `--full-teardown`.

**Regressão corrigida (2026-11-14, reporte do mantenedor) — assert Tracy `s_profilerData`:** ao rodar o binário Tracy (`-define:TRACY_ENABLE=true`), o engine assertava no client Tracy logo após `assets_load`, antes de `create_vulkan_instance`. Causa-raiz: `biomes_load()` (main.odin) emite `ZoneN("biomes_load")` mas roda antes de `TracingStartup()` (decisão VS-15/BLK-37: profiler só sobe após init Vulkan/GLFW); com a lib em `TRACY_MANUAL_LIFETIME` + `TRACY_DELAYED_INIT`, qualquer call Tracy antes do startup é inválida (`s_profilerData == nullptr`). Correção: guarda centralizada no wrapper (`src/engine/tracing.odin`) — `ZoneN`/`Zone`/`zone_end` viram no-op quando `tracy.ProfilerStarted()` é falso, cobrindo qualquer zone fora do intervalo [startup, shutdown], não só a do biomas. Evidência: build Tracy verde + smoke completo (`--exit-after-replay --full-teardown`) sem assert, exit 0, teardown limpo.

**Regressão corrigida (2026-11-14, reporte do mantenedor) — thread GPU sumida da UI Tracy:** as zonas GPU (VS-16) pararam de aparecer. Causa-raiz: a VS-23 removeu o guarda `if edit_job_count == 0 { tracing_gpu_record_context(...) }` de `voxel_render_prepare` ao reestruturar o bloco de barreiras — em frames sem edição nem relight, os resets pendentes do query pool de timestamps nunca eram aplicados, e quando o ring dava a volta os `CmdWriteTimestamp2` caíam em slots nunca resetados (resultado indisponível/inválido, coleta estagnava e a thread GPU ficava vazia). Correção: guarda restaurada em `voxel_render_prepare` (`edit_job_count == 0 && light_job_count == 0`) **antes** das zones de build/finalize — o fix inicial no `voxel_render_record` ficava tarde demais para essas timestamps, pois ambas rodam no mesmo command buffer. Evidência: captura `bin/debug/0.1.35/tracy/VS-23_baseline.tracy` (tracy-capture, replay `vs23_flicker.jsonl`, 479 frames) com todas as zonas GPU presentes; smoke Tracy sem assert, exit 0.

**Investigação (2026-11-14, reporte do mantenedor) — engasgos na geração (`frame_wait`):** sub-zones adicionados em `main.odin` (`wait_timeline`, `acquire_image`) + replay reprodutor `docs/examples/vs23_genstutter.jsonl` + captura `bin/debug/0.1.35/tracy/VS-23_genstutter.tracy`. Resultados: (1) 98% do `frame_wait` é `WaitTimelineSemaphore` (slot de frame, `NUM_FRAMES_IN_FLIGHT=2`) — `acquire_image` e `publish_visible` são irrelevantes; (2) o dispatch `generate` é fortemente bimodal — mediana ~0,1–0,5 ms, mas com monstros de 20–260 ms (captura manual) até 1223 ms (captura em sessão sem janela visível); (3) os monstros se agrupam em rajadas e o custo do kernel é quase independente de conteúdo (laços fixos por registro), apontando para agendador/clock da GPU (WDDM, prioridade de processo em background, D3 wake) e não para biome específico; (4) achado operacional: builds não-Tracy também escutam na porta 8086 (lib vendora sempre sobe o listener) — um processo zumbi `vox.exe` segurou a porta e travou capturas subsequentes; capturar com o app já em execução (`tracy-capture` sem child) contorna. Mitigações registradas para follow-up: aumentar `NUM_FRAMES_IN_FLIGHT`, reduzir `chunks_per_batch` para granularidade de pico, e reavaliar a espera global por compute (`published_compute_value`) que amarra o frame gráfico a lotes de geração distantes.

**Mitigações implementadas (2026-11-14) — knobs via INI sem recompilar:** `chunks_per_batch` já era configurável (`[compute] chunks_per_batch=16`); `NUM_FRAMES_IN_FLIGHT` (antes constante de compilação) virou `sync.frames_in_flight` (INI, 2..4, default 2; `MAX_FRAMES_IN_FLIGHT=4` é o teto dos arrays). Ambos os valores **não são baked nos shaders** — a GPU os recebe por push constants/buffers dimensionados host-side, então a ferramenta de patch de shader source/SPIR-V pedida pelo mantenedor não se faz necessária para estes knobs (fica como opção futura se alguma constante de shader precisar ser tunável). Validação: smoke completo com `[sync] frames_in_flight=3` + `chunks_per_batch=8` (exit 0, zero VUIDs) e rejeição fatal de `frames_in_flight=5` (exit 1).

**A/B de engasgos (2026-11-14, critérios: >30 FPS estável inegociável, >60 desejado):** matriz `frames_in_flight` {2,3} × `chunks_per_batch` {16,8}, 4 repetições por config (12 capturas `bin/debug/0.1.35/tracy/AB_*.tracy`, ferramentas `tools/ab_test.sh` + `tools/ab_analyze.py`). Resultado: **nenhuma config passa o limiar em headless** e a baseline INTERATIVA do mantenedor (`teste_manual.tracy`) também falha (11,9% dos frames < 30 FPS, p95 47,6 ms, pior 268 ms — os engasgos relatados). Ranking headless: **f2_b16 (default) é a melhor** (%<30 = 11,1%), `frames_in_flight=3` piora (16,6–17,7% — mais frames em voo expõem mais ao monstro de `generate`), `chunks_per_batch=8` não ajuda (11,7%). Conclusão: tuning de INI sozinho não atinge o limiar — é preciso atacar a raiz (monstros de `generate` ambientais, ver investigação acima) ou desacoplar a espera global por compute.

**Análise — desacoplar a espera global por compute (2026-11-14, pedido do mantenedor):** a espera do semáforo (`compute_wait_value = published_compute_value`) já é teoricamente um no-op — o valor publicado é o `highest_completed_compute_value` processado via fence no handler, logo sempre ≤ valor alcançado pelo semáforo no momento da submissão gráfica. O engasgo nesta máquina (RTX 3050 Laptop, fila compute **dedicada** família 2 — confirmado no log) não é serialização de fila nem espera de semáforo: é **contenção de execução** — o monstro de `generate` satura SM/memória e o frame gráfico N-2 compete, atrasando a conclusão que o `wait_timeline` observa. Redundâncias já existentes: edições deferem chunks GENERATING (voxel_edit.odin:361), chunks só são endereçáveis pela GPU após publicação pós-pack (chunk_grid B1, visible/neighbor só CACHED/RENDERABLE), relight re-marca sujeira na conclusão. Remover a espera ganharia ~nada e quebraria o ordering de visibilidade GPU entre filas (o semáforo é a única cadeia happens-before pack→leitura gráfica). Alavancas reais, em ordem de custo: (1) **prioridade de fila** — criar a fila compute com `queuePriority < 1.0` (hoje ambas 1.0), dando preferência de scheduling ao graphics sob contenção; (2) atacar o monstro (experimento de dispatch sintético para separar conteúdo×ambiente); (3) gate fino da espera (esperar só quando o publish trouxe chunks novos — ganho pequeno esperado, complexidade média).

**Breakdown GPU baseline (VS-23_baseline.tracy, média por zona):** `draw_mesh` ≈ 1,20 ms (pass principal: mesh + fragment com shadow ray/AO) — maior custo; `depth_prepass` ≈ 0,89 ms (≈42% extra sobre a pass principal — candidato a otimização); `light.propagate` ≈ 0,07 ms mediana (≈1 ms/soma nos frames com relight, 15 passes); `light.seed` ≈ 0,07 ms mediana; `generate` ≈ 0,20 ms mediana (picos de chunk novo até 11 ms); `pack` ≈ 0,29 ms mediana; `build_work_queue` ≈ 38 µs; `finalize_work_queue` ≈ 1 µs; `apply_edits` ≈ 17 µs. Limitação: fragment e mesh shader do pass principal não são separáveis por zone Tracy (a granularidade disponível é por pass/dispatch — pre-pass vs pass principal vs computes).

**Regressão corrigida (2026-11-14, Tracy — assert `s_profilerData`):** o binário `-define:TRACY_ENABLE=true` assertava logo após `assets_load`, antes de qualquer frame. Causa: `ZoneN("biomes_load")` (VS-22) roda em `main` antes de `TracingStartup` — com `TRACY_MANUAL_LIFETIME`/`TRACY_DELAYED_INIT` (BLK-37), qualquer API Tracy fora de [startup, shutdown] asserta em `GetProfilerData`. Não foi introduzido pela VS-23; o binário Tracy simplesmente não era executado desde a VS-22 (validação manual pendente). Correção: guarda `tracy.ProfilerStarted()` (binding já vendido, não usado) nas procs `ZoneN`/`Zone`/`zone_end` e no lock tracking do wrapper do projeto — zones fora do intervalo viram no-op, consistente com o contrato VS-15. Validado: smoke Tracy `--full-teardown` exit 0 sem asserts/VUIDs e captura real com `tracy-capture` (28.986 zones, 5,1 MB).

**Divergências da referência (`docs/examples/ray-cast-light.md`) registradas:**

1. Tangentes do AO para faces ±Z: a referência usava `(0,1,0)` para t1 e t2, colapsando o eixo; o código usa `(1,0,0)` para t2 em faces ±Z (corrigido na sim `ao_sim.py` antes da integração).
2. `LightGlobals` sem `inverse_view_projection` (campo da Fase 4/deferred, fora de escopo da VS-23).
3. Blocos emissivos: `assets/blocks.json` atual não possui bloco com `emission_color` — o seed/rota de block light está implementado e validado pela sim, mas a evidência visual de tocha/lava depende de um bloco emissor no registry (ou edição de `blocks.json`).
4. `lighting.slang` é biblioteca sem entry points — excluído dos loops de compilação de `run.bat`/`run_tracy.bat` (padrão `common.slang`).

## Fase 0 — Fundação

### T0.1 — Máscara de opacidade

- **Descrição:** adicionar uma word de opacidade por brick e mantê-la tanto no pack quanto na edição.
- **Arquivos afetados:** `tools/sim/` (sim de opacidade/pack); `src/assets/shaders/common.slang`, `voxel.slang`, `edit.slang`; constantes e provisionamento de `occupancy_pool` no Odin; cache de occupancy em disco, se existir.
- **Passos:**
  1. Criar/estender sim com ar, sólido, `NON_SOLID`, `TRANSPARENT` e vidro, cobrindo pack e atualização atômica por edição.
  2. Definir `OPAQUE_WORD_BASE = 2114` e `OCCUPANCY_WORDS_PER_CHUNK = 3138`, espelhando o valor no Odin.
  3. Acumular `opacity` em `pack_chunk` e atualizar o bit com `InterlockedOr`/`InterlockedAnd` em `apply_voxel_edits`.
  4. Realocar o pool com +4 KiB por slot e invalidar caches incompatíveis.
- **Validação da etapa:** sim verde antes do shader; `run.bat`, Slang e `spirv-val` limpos; readback confirma os bits após pack e edições, inclusive vidro não opaco; zero VUIDs.

### T0.2 — `chunk_grid` e `LightGlobals`

- **Descrição:** tornar coordenadas globais de chunks consultáveis na GPU e centralizar parâmetros de iluminação.
- **Arquivos afetados:** `src/assets/shaders/common.slang`; módulos Odin de mundo/streaming, conclusão B1, GPU e provisionamento Vulkan; `bin/vox.ini` somente se houver parâmetro runtime novo.
- **Passos:**
  1. Declarar `LightGlobals` e os bindings 25/26, incluindo sol, céu, origem/dimensões do grid, parâmetros e slots para duas dinâmicas.
  2. Criar o buffer `chunk_grid` com sentinela `0xFFFFFFFF`, indexação `x + dim.x*(z + dim.z*y)` e helpers `chunk_slot_at`/`opaque_at_world`.
  3. Publicar slot somente no handler de conclusão de `pack_chunk`; limpar antes de descarregar/reutilizar e reescrever células na recentralização.
  4. Atualizar o UBO por frame e provisionar seus recursos sem corrida entre frames em voo.
- **Validação da etapa:** build e validation limpos; readback/log do grid confirma células após carregar, descarregar e recentralizar; slot pendente nunca aparece; coordenada fora da grade retorna a sentinela.

### T0.3 — Descriptors, feature e sincronização

- **Descrição:** habilitar os novos estágios e ordenar os acessos entre compute e fragment.
- **Arquivos afetados:** criação de device, descriptor layouts/pools/sets, pipelines e gravação de comandos no Odin.
- **Passos:**
  1. Habilitar `fragmentStoresAndAtomics` com checagem de suporte do device.
  2. Tornar `occupancy_pool`, `chunk_headers` e recursos de luz necessários visíveis ao fragment e compute.
  3. Inserir barreiras de pack/edição/luz para consumidores e estabelecer a ordem gerar/editar → grid/jobs → luz → work queue → pre-pass → principal.
  4. Garantir teardown e recriação seguros dos novos recursos.
- **Validação da etapa:** builds default/Tracy com validation sem VUIDs de estágio, `NonWritable` ou sincronização; smoke com carregamento/edição e `--full-teardown` limpo.

## Fase 1 — Sol com sombra

### T1.0 — Simulação da travessia `trace_occluded`

- **Descrição:** validar a travessia hierárquica antes de escrever `lighting.slang`.
- **Arquivos afetados:** novo sim em `tools/sim/`.
- **Passos:**
  1. Modelar grid, células 8³, bricks 4×2×4 e bits de opacidade com o mesmo layout do shader.
  2. Cobrir raios axiais/diagonais, coordenadas negativas, distância máxima, chunk ausente/vazio, célula e brick vazios, vidro e primeiro opaco.
  3. Cobrir `ignore_voxel`, origem em slab/template parcial e limites de iteração.
- **Validação da etapa:** todos os casos concordam com uma referência voxel a voxel; nenhum falso hit em ar/vidro/ausente; nenhum acesso fora do grid ou slot inválido.

### T1.1 — `lighting.slang` e `trace_occluded`

- **Descrição:** implementar a travessia stateless any-hit na GPU.
- **Arquivos afetados:** novo `src/assets/shaders/lighting.slang`; `common.slang` e build de shaders conforme necessário.
- **Passos:**
  1. Implementar `exit_t` e o salto hierárquico por chunk, célula grossa, brick e voxel.
  2. Encerrar no primeiro opaco, respeitando `t_max` e `ignore_voxel`.
  3. Importar o módulo no build sem alterar generate, work queue ou mesh builder.
- **Validação da etapa:** sim T1.0 verde antes da integração; Slang/`spirv-val` e build limpos; testes integrados reproduzem os mesmos hits da referência.

### T1.2 — `shade_surface` e fragment principal

- **Descrição:** substituir o Lambert fixo por sol, ambiente inicial e emissão no novo ponto de shading.
- **Arquivos afetados:** `src/assets/shaders/lighting.slang`, `render.slang`; UBO/parâmetros no Odin.
- **Passos:**
  1. Extrair `face_normal_from_derivatives` e `fetch_albedo`, preservando UV, triplanar e alpha-test.
  2. Implementar `shade_surface` com origem deslocada pela normal, `own_voxel`, shadow ray e emissão.
  3. Manter amostras de textura antes de ramos divergentes e o `discard` antes do raio; preservar highlight.
- **Validação da etapa:** build e validation limpos; cena com obstrutor mostra sombra dura na direção correta; ausência de obstrutor deixa superfície iluminada; vidro não projeta sombra e não há regressão de textura/highlight.

### T1.3 — Depth pre-pass

- **Descrição:** evitar shadow rays em fragmentos descartados por profundidade.
- **Arquivos afetados:** `render.slang`; pipelines e passes gráficos no Odin.
- **Passos:**
  1. Adicionar fragment de profundidade com o mesmo alpha-test e reutilizar o mesh shader atual.
  2. Criar pipeline sem color attachment, depth write ligado e a mesma work queue.
  3. Configurar o principal com depth write desligado e compare `LESS_OR_EQUAL`.
- **Validação da etapa:** imagem equivalente à versão sem pre-pass, salvo iluminação pretendida; modos de profundidade e validation limpos; Tracy confirma ordem e execução do passe.

### T1.4 — Modos de debug

- **Descrição:** expor visualizações isoladas de sombra, AO e block light.
- **Arquivos afetados:** `lighting.slang`, `render.slang`; input/config e UBO no Odin.
- **Passos:**
  1. Implementar `debug_mode`: 0 normal, 1 sombra, 2 AO e 3 block light.
  2. Adicionar controle de debug sem alterar push constants nem os recursos da work queue.
- **Validação da etapa:** alternância em runtime mostra somente o termo selecionado; retorno ao modo 0 restaura o shading composto; modo 1 confirma a cena de AC-02/03.

## Fase 2 — AO por fragmento

### T2.0 — Simulação do AO

- **Descrição:** gerar gabarito numérico do AO antes da integração.
- **Arquivos afetados:** sim de iluminação/AO em `tools/sim/`.
- **Passos:**
  1. Modelar voxel à frente da face, eixos tangentes, quatro cantos e oito leituras compartilhadas.
  2. Cobrir canto livre, lados, diagonal, ambos os lados, interpolação em centro/bordas, coordenadas negativas e fronteiras.
  3. Cobrir vidro transparente, face não axial sem AO e fixar a tolerância numérica usada no AC-04.
- **Validação da etapa:** resultados e interpolação conferem com cálculo independente; todos os casos ficam dentro da tolerância documentada.

### T2.1 — `voxel_ao` e ambiente

- **Descrição:** integrar AO determinístico e gradiente de céu ao `shade_surface`.
- **Arquivos afetados:** `src/assets/shaders/lighting.slang`; parâmetros do UBO no Odin.
- **Passos:**
  1. Implementar `corner_ao`, `voxel_ao` e as oito consultas de opacidade.
  2. Aplicar bilinear por `u/w`, `ao_strength` e gradiente horizonte→zênite pela normal.
  3. Ligar o modo debug 2 e manter faces diagonais sem AO.
- **Validação da etapa:** sim T2.0 verde antes do shader; build/`spirv-val`; modo 2 compara valores visuais/readback ao gabarito em arestas, cantos e fronteiras, sem ruído temporal.

## Fase 3 — Block light e luzes dinâmicas

### T3.0 — Simulação de seed, propagação e relight

- **Descrição:** validar volume RGB e seleção de trabalho antes dos novos shaders de compute.
- **Arquivos afetados:** sim de block light em `tools/sim/`.
- **Passos:**
  1. Modelar emissão RGB quantizada em 4 bits, opacidade, perda de um nível e relaxação in-place monotônica.
  2. Cobrir fontes adicionadas/removidas, 15 níveis, canais independentes, barreiras opacas e convergência em até 15 passes.
  3. Modelar chunk + 26 vizinhos, deduplicação, fronteiras, chunks ausentes e descarregamento.
- **Validação da etapa:** gabarito BFS/referência confirma volumes; remoção limpa luz antiga; seleção de jobs cobre faces/arestas/cantos sem duplicatas.

### T3.1 — `light_pool`, `light_jobs` e helpers

- **Descrição:** provisionar o volume e seus trabalhos com o ciclo de vida dos slots.
- **Arquivos afetados:** `common.slang`; provisionamento GPU, descriptors e mundo no Odin.
- **Passos:**
  1. Declarar bindings 27/28, `LightJob`, índices e pack/unpack RGB.
  2. Alocar `slots × 32768 × 2 B` e buffer de jobs reescrito por frame.
  3. Implementar leitura de luz por mundo e `read_block_identifier_fast`, sem copiar `ChunkHeader` inteiro.
- **Validação da etapa:** sim de layout verde; build e validation limpos; tamanhos/offsets conferem 64 KiB por chunk; slot reciclado não conserva job ou publicação inválida.

### T3.2 — `light_seed`

- **Descrição:** limpar e semear o volume dos chunks selecionados.
- **Arquivos afetados:** novo `src/assets/shaders/light.slang`; pipeline/dispatch compute no Odin.
- **Passos:**
  1. Criar kernel 8×8×8 com seleção de job e coordenada local.
  2. Quantizar `emission_color` para RGB de 4 bits e escrever zero nos demais voxels.
  3. Configurar dispatch em lotes com offset de jobs.
- **Validação da etapa:** sim T3.0 verde antes do shader; readback após seed contém apenas as fontes e zera volumes reprocessados; build/`spirv-val` limpos.

### T3.3 — `light_propagate`

- **Descrição:** propagar a luz por relaxação in-place com no máximo 15 passes.
- **Arquivos afetados:** `light.slang`; gravação de comandos e barreiras no Odin.
- **Passos:**
  1. Consultar os seis vizinhos, bloquear opacos e aplicar `max(vizinhos)-1` por canal.
  2. Preservar emissão e monotonicidade durante a propagação.
  3. Executar seed + 15 dispatches com barreiras compute→compute.
- **Validação da etapa:** modo 3/readback coincide com o gabarito até o nível 15; fonte apagada não reaparece; nenhuma propagação atravessa opaco; validation limpa.

### T3.4 — Gatilhos de relight na CPU

- **Descrição:** transformar geração, edição e descarregamento em jobs locais.
- **Arquivos afetados:** fluxo de edição/conclusão/streaming e fila de luz no Odin.
- **Passos:**
  1. Usar os chunks de `EditChunkJob` e o fluxo de `shared_edit_dirty_bricks` para identificar edições concluídas.
  2. Agendar o chunk e os 26 vizinhos carregados, deduplicar no flush e tratar chunks recém-gerados/descarregados.
  3. Garantir relight depois de `apply_voxel_edits` e antes do pre-pass.
- **Validação da etapa:** jobs observados cobrem face, aresta e canto sem duplicatas; adicionar/remover tocha atualiza no mesmo ciclo; descarregamento invalida vizinhos sem usar slot reciclado.

### T3.5 — Amostragem de block light no shading

- **Descrição:** combinar o volume RGB ao resultado de `shade_surface`.
- **Arquivos afetados:** `lighting.slang`; intensidade no UBO/Odin.
- **Passos:**
  1. Amostrar oito voxels em torno de `world_pos + normal*0.5` e interpolar trilinearmente de forma simples.
  2. Normalizar por 15, aplicar intensidade e somar ao sol/ambiente antes da emissão.
  3. Ligar o modo debug 3.
- **Validação da etapa:** tocha ilumina caverna com degradê contínuo e queda de um nível por voxel no volume; ausência de fonte resulta em zero; modo 3 e build limpos.

### T3.6 — Luzes dinâmicas

- **Descrição:** suportar uma ou duas luzes fortes por frame, como a tocha do jogador.
- **Arquivos afetados:** `lighting.slang`; preenchimento de `LightGlobals` e gameplay/câmera no Odin.
- **Passos:**
  1. Iterar somente `dynamic_light_count ≤ 2`, testar alcance e `N·L` e disparar shadow ray direto.
  2. Aplicar `saturate(1-(d/R)^4)^2 / d²` com proteção numérica documentada.
  3. Atualizar posição, raio e cor por frame sem usar o volume de emissores estáticos.
- **Validação da etapa:** luz acompanha o jogador, apaga fora do raio e é bloqueada por opaco; vidro não bloqueia; zero, uma e duas luzes funcionam sem acessos fora do array.

## Fechamento

### T5.1 — Instrumentação Tracy

- **Descrição:** instrumentar todos os caminhos novos com nomes ligados ao domínio.
- **Arquivos afetados:** módulos Odin de grid/jobs/passes e shaders/pipelines conforme o suporte de GPU zones.
- **Passos:** adicionar zones CPU para publicação do grid, montagem/deduplicação de jobs e relight; GPU zones para seed, propagação, pre-pass e pass principal; contadores de jobs, chunks e passes.
- **Validação da etapa:** captura mostra todas as zones e permite separar custo de seed, 15 propagates, pre-pass e shading; contadores correspondem ao roteiro executado.

**Fechamento T5.1 (regressão da thread GPU gráfica — 2026-11-14):**

- **Causa-raiz:** `voxel_render_prepare` era o único ponto que gravava `tracing_gpu_record_context` (resets do query pool + re-sync) no command buffer do frame. A VS-23 moveu a chamada para dentro dos blocos `edit_job_count > 0` / `light_job_count > 0` (e removeu o antigo `if edit_job_count == 0 { record_context }`). No estado estacionário (sem edições nem relight) nenhum reset era gravado, os `CmdWriteTimestamp2` de `build_work_queue`/`finalize_work_queue`/`depth_prepass`/`draw_mesh` caíam em slots nunca resetados (violação da spec — resultado indisponível/indefinido), a coleta travava no primeiro par não disponível e o contexto gráfico parava de emitir `GpuTime`: a thread GPU "graphics" sumia da UI Tracy. Evidência: `git diff HEAD -- src/engine/voxel_render.odin` (remoção do bloco `edit_job_count == 0`); audit de chamadas de `tracing_gpu_record_context` (nenhuma em `voxel_render_record`).
- **Correção (mínima):** `tracing_gpu_record_context(cmd, TRACING_GPU_CONTEXT_GRAPHICS)` no topo de `voxel_render_record` (`src/engine/voxel_render.odin`), restaurando o invariante pré-VS-23 de um reset por command buffer por frame, em todos os caminhos. A chamada é idempotente dentro do mesmo command buffer (faixa `[reset_pos, collect_pos)` já vazia nas chamadas subsequentes).
- **Cobertura de zones GPU:** `generate`/`pack` (compute), `apply_edits`, `light.seed`, `light.propagate` (1 zone por pass, 15 passes), `build_work_queue`, `finalize_work_queue`, `depth_prepass` e `draw_mesh` (ao redor de `CmdDrawMeshTasksIndirectEXT`). Limite: a zone do pass principal mede mesh+fragment juntos; fragment isolado não é separável por zone Tracy — a granularidade disponível é por pass/dispatch.
- **Evidência:** `bin/debug/0.1.35/tracy/VS-23_gpu_breakdown.tracy` (smoke `vs23_smoke.jsonl`, exit 0, teardown completo). Breakdown (mean/median, µs): draw_mesh 1286/1313, depth_prepass 953/1026, build_work_queue 41/40, finalize_work_queue ~1, light.seed 704/196, light.propagate 143/100 (×15 por flush), apply_edits 19, generate 462/212, pack 449/296. Comparação com `VS-23_baseline.tracy`: draw 1198→1286, prepass 889→953 (ruído de cena; relight ~2,1ms só nos frames com flush).
- **Instruções de reprodução:** build `odin build ./src/ -out:./bin/vox.exe -define:TRACY_ENABLE=true -define:TRACY_CALLSTACK=10` (shaders via loop de `run_tracy.bat`), subir `tools/tracy/tracy-capture.exe -o <arquivo>.tracy` e, de `bin/`, `vox.exe --replay ../docs/examples/vs23_smoke.jsonl --exit-after-replay --full-teardown`; abrir o `.tracy` em `tools/tracy/tracy-profiler.exe` (abas GPU "graphics"/"compute").

### T5.2 — Validação integrada dos ACs

- **Descrição:** executar cenários funcionais e registrar evidências reproduzíveis.
- **Arquivos afetados:** VS-23, roteiros/sims e logs de debug existentes em `bin/debug/<version>/`.
- **Passos:** executar cena de sombra/slab/AO, adicionar/remover tocha, editar faces/arestas/cantos, testar ausente/vazio e dinâmicas; rodar builds default/Tracy com validation e teardown.
- **Validação da etapa:** AC-01..07 e AC-09 preenchidos com comandos, resultados e caminhos de evidência; nenhum AC marcado verificado sem reprodução.

### T5.3 — Captura, performance, documentação e commit

- **Descrição:** fechar a especificação com comparação de performance e documentação integrada.
- **Arquivos afetados:** `bin/debug/<version>/tracy/VS-23_*.tracy`; VS-23, tracking, `docs/arquitetura.md` e `docs/manual-tecnico.md` quando aplicável.
- **Passos:**
  1. Executar `run_tracy.bat` e `tracy-capture`, salvando captura íntegra com prefixo VS-23.
  2. Despachar subagente coder K2.8 thinking low para comparar com a captura anterior e registrar o relatório no AC-08/histórico.
  3. Atualizar documentação, ACs, frontmatter e tracking conforme os resultados.
  4. Commitar com o nome da especificação na mensagem.
- **Validação da etapa:** AC-08 concluído com baseline e limitações explícitas; captura e documentos presentes; `git diff --check` limpo; commit contém somente os artefatos pretendidos.

## Checklist tasks → critérios de aceitação

| Tasks | ACs cobertos | Verificação de fechamento |
| --- | --- | --- |
| T0.1, T0.2, T0.3 | AC-01, AC-02, AC-07 | Layout/opacidade, publicação B1 e sincronização validados por sim, readback e Vulkan |
| T1.0, T1.1, T1.2, T1.3, T1.4 | AC-02, AC-03 | Sim de travessia, debug 1, obstrutor/vidro/ausente e slabs sem auto-oclusão |
| T2.0, T2.1 | AC-04 | Gabarito Python e debug 2 dentro da tolerância |
| T3.0, T3.1, T3.2, T3.3 | AC-05 | Volume RGB e queda por nível conferidos após seed + 15 propagates |
| T3.4, T3.5 | AC-05, AC-06, AC-07 | Adicionar/remover fonte e editar fronteiras atualizam todos os vizinhos corretos |
| T3.6 | AC-02, AC-03 | Shadow rays dinâmicos respeitam opacidade e `ignore_voxel` |
| T5.1, T5.2 | AC-09, reforço de AC-01..07 | Zones/contadores observáveis e evidências reproduzíveis anexadas |
| T5.3 | AC-08 e fechamento de todos | Captura versionada, comparação registrada, docs/tracking atualizados e commit da VS-23 |
