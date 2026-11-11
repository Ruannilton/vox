---
id: VS-20-TASKS
titulo: Tarefas — seleção, construção e pulo
tipo: tarefas
spec: VS-20
status: concluida
ultima_atualizacao: 2026-11-08
---

# VS-20 — Tarefas de implementação

Spec aprovada de nascença por dispensa do mantenedor. Etapas VS-20-IMPL-01..06 **concluídas em 2026-11-08** (sim verde antes do shader; validações da coluna obrigatória executadas; ver ACs e histórico da spec).

| ID | Etapa e alterações | Requisitos / ACs | Validação obrigatória |
| --- | --- | --- | --- |
| VS-20-IMPL-01 | **Sim, UBO e realce.** Estender sim de render com floor, negativos, flag e fator; depois declarar `TargetHighlight` 16 B/binding 21, provisionamento por frame, descriptor e tint no fragment. Emendar VS-00. | REQ-GPL-02/03; AC-01 | Sim verde antes do shader; assert 16 B; Slang + `spirv-val`; builds default/Tracy, zero VUIDs; sem hit visualmente equivalente e push constants 92 B. |
| VS-20-IMPL-02 | **Mira central por frame.** Após física/câmera, DDA origem câmera/direção view/12 u, snapshot único e upload do UBO; limpar em miss/unknown e teleporte. | REQ-GPL-01/07; AC-02 | Roteiro com LookAt e movimento; alvo/coordenada conferem DDA; flag limpa em miss/unknown; highlight e snapshot iguais no clique. |
| VS-20-IMPL-03 | **Cliques de construção/remoção.** Handlers press esquerdo→pedra id 3 em hit+normal e direito→ar no hit, usando snapshot e `ve_request_voxel_edit`; guardas de destino/AABB e no-op tri-state. | REQ-GPL-04/05/07; AC-03 | Replay com seis faces, planta, origem interna, miss/unknown, destino ocupado/desconhecido e interseção do jogador; feedback E1 e mirror/readback confirmam células/ids. |
| VS-20-IMPL-04 | **Pulo.** SPACE press com grounded/não congelado aplica `sqrt(2·24·1,5)`; sem pulo por release/hold/no ar; solver permanece responsável por gravidade/teto. | REQ-GPL-06/07; AC-04 | Sim/roteiro mede ápice 1,5 ± tolerância de um passo; teto, auto-repeat, congelado e novo pouso; velocidade inicial documentada. |
| VS-20-IMPL-05 | **Instrumentação e validação integrada.** Zones/contadores de mira, ações e pulo; docs arquitetura/manual/tracking; sessão completa de gameplay em builds default/Tracy. | REQ-GPL-08; AC-02..06 | Todas as zones/contadores observáveis; replay completo sem falhas funcionais, validation limpa e sem regressão de ownership/E1. |
| VS-20-IMPL-06 | **Stress, captura e fechamento.** 5× por build com `--full-teardown`; captura `VS-20_gameplay_selecao_construcao_pulo.tracy`; subagente K2.8 thinking low compara com VS-19; anexar evidências e commitar com nome da spec. | AC-01..06 | 10/10 sem VUIDs/threading/deadlock; captura íntegra no diretório versionado; comparação registrada; ACs com evidências reproduzíveis e working tree limpo. |
