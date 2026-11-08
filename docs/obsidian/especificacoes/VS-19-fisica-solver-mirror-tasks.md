---
id: VS-19-TASKS
titulo: Tarefas — física de gameplay sobre o mirror
tipo: tarefas
spec: VS-19
status: bloqueada
ultima_atualizacao: 2026-11-08
---

# VS-19 — Tarefas de implementação

Pré-condição: ADR-F1 aceita, VS-19 aprovada e dependências concluídas. Executar em ordem; mudança de shader somente depois das sims da etapa 2. Nenhuma tarefa está iniciada.

| ID | Etapa e alterações | Requisitos / ACs | Validação obrigatória |
| --- | --- | --- | --- |
| VS-19-IMPL-01 | **Tabela e loader físico.** Adicionar `PhysicsDefinition` CPU-side, flags/materiais e defaults; estender `blocks.json`, loader, fallback built-in, `assets_check`/bateria. Não alterar `BlockDefinition`/std430. | REQ-PHY-01; AC-01 | `assets_check` no JSON real e bateria com campos válidos/inválidos; build Odin; assert/verificação dos 48 B e paridade da planta/fallback. |
| VS-19-IMPL-02 | **Sims do heightmap medido (ring mantido como reserva — decisão do mantenedor).** Atualizar `heightmap_sim` e `mirror_sim` para topo derivado do `solid`, inclusive arcos/flutuantes e E1, PRESERVANDO os cenários de write do ring (ele continua sendo escrito pelo generate). Manter write no shader, binding 20, ring, descriptor e provisionamento intactos; derivar as 1.024 colunas no materialize a partir do bitmask (ignorando o ring); paridade ring×medido opcional em debug. Emendar docs VS-13/VS-00 (corrigir a emenda de remoção — já registrada pelo principal). | REQ-PHY-07; AC-04 | Sims novas e antigas verdes antes do shader; `run.bat`/compilação Slang, `spirv-val`, build; readback/paridade e varredura `heights`×bitmask; binding 20 presente e provisionado |
| VS-19-IMPL-03 | **Núcleo temporal e solver.** Criar acumulador de passo fixo com teto, corpos AABB, sweep X→Y→Z, subdivisão anti-tunneling, sliding, grounded, step-up seguro e materiais. Adicionar sim de física para os casos normais e patológicos. | REQ-PHY-02..04; AC-02 | Sim de acumulador/repetição e de contatos; testes de canto, fronteira negativa, teto, degrau sem espaço e deslocamento >1 voxel; build e sessão controlada sem penetração. |
| VS-19-IMPL-04 | **Fast-path e desconhecido.** Integrar apoio via `heights` com prova de equivalência e fallback; congelamento sem movimento parcial, pedido coalescido à worker e retomada após materialização, usando apenas APIs mutex-protegidas. | REQ-PHY-05/06; AC-02/05 | Comparar fast-path×sweep em superfície, caverna, interior, `0xFFFF` e cruzamento de chunk; concorrência com edições/readback e ausência de páginas; zero deadlock/warnings. |
| VS-19-IMPL-05 | **Raycast DDA.** Implementar percurso Amanatides & Woo, limites, normal/distância, `HITTABLE` e hit/miss/unknown. Não criar bitmask adicional. | REQ-PHY-08/09; AC-03 | Sim com eixos, diagonais, fronteiras, origem interna, direção nula e distância inválida; planta atingível/não-bloqueante; unknown antes de miss; consultas integradas. |
| VS-19-IMPL-06 | **Hooks, jogador e instrumentação.** Expor ciclo de vida/consulta de corpos e raycast; integrar jogador no tick da main sem alterar ownership; adicionar zones/contadores Tracy de física. Atualizar arquitetura/manual/tracking. | REQ-PHY-10; AC-05/07 | Build default/Tracy; replay com caminhada, colisão, step-up e seleção; inspeção das zones e contadores no trace; validation layers limpas. |
| VS-19-IMPL-07 | **Stress, evidências e fechamento.** Executar 5× cenários completos nos dois builds com `--full-teardown`; capturar Tracy em `bin/debug/<version>/tracy/VS-19_fisica_solver_mirror.tracy`; despachar subagente coder K2.8 thinking low para comparar performance com a versão anterior; anexar relatório e hashes/logs aos ACs; commit com o nome da spec. | AC-01..07 | Todos os ACs com evidência reproduzível; 5/5×2 sem VUIDs/threading/deadlock; captura íntegra e comparação registrada; `git status` limpo após o commit. |

## Ordem e entregáveis

1. Dados físicos validados sem contrato GPU novo.
2. Heightmap CPU e sims verdes antes da remoção do shader/ring.
3. Solver determinístico por sequência de passos.
4. Otimização de chão e política da bolha.
5. DDA e semântica `HITTABLE`.
6. Integração observável do jogador.
7. Evidências, comparação e fechamento.
