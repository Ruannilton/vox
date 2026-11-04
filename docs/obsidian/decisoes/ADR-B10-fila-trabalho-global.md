---
id: ADR-B10
titulo: Fila de trabalho global no lugar do payload task→mesh
tipo: decisao
status: aceita
specs_afetadas: [VS-02]
ultima_atualizacao: 2026-11-04
---

# ADR-B10 — Fila de trabalho global no lugar do payload task→mesh

## Contexto

A VS-02 transportava os grupos selecionados (brick | parte | subdivisão) do task shader ao mesh shader pelo payload de `DispatchMesh`. Na validação visual (2026-11-04), toda a geometria saía empilhada na origem do mundo com z-fighting intermitente ("voxels piscando", "renderizados apenas em um único local"). A depuração por experimentos isolados — screenshots com a câmera travada, inspeção de `spirv-dis` e `spirv-val` — demonstrou que **o payload chega sempre zerado ao mesh shader neste ambiente** (NVIDIA RTX 3050 Laptop, driver Vulkan 1.4.351, slangc 2026.17), mesmo com o task shader gravando valores constantes, com payloads de 8 e de 2.048 words, e com `[shader("task")]` ou `[shader("amplification")]`. O SPIR-V gerado está correto e valida limpo — o defeito está na entrega do payload pelo driver, não no código.

Um pipeline mesh-only de diagnóstico (sem estágio task, mesh lendo `visible_chunks` diretamente por `SV_GroupID`) renderizou milhares de triângulos corretamente posicionados, provando que todo o restante do caminho (bindings, push constants, VP, ocupação, texturas, fragment) estava íntegro.

## Requisitos relacionados

- VS-02: REQ-VIS-03, REQ-VIS-04, REQ-MESH-01, REQ-PIPE-01, REQ-PIPE-03.

## Opções

### Opção A — manter task/mesh com payload

- Persistir na arquitetura canônica de mesh shaders e investigar workarounds de driver (versões, repacking do payload, tamanhos alternativos). Vantagem: zero mudança arquitetural. Desvantagens: o defeito é externo ao código e não foi contornado por nenhuma variação testada; sem previsão de correção; o transporte por payload já consumiu ciclos de depuração sem nenhum sinal de vida.

### Opção B — fila de trabalho global em storage buffer + draw mesh-only indireto

- Um builder compute na fila gráfica (1 workgroup de 128 threads por chunk visível) executa a mesma seleção do antigo task shader (ocupação + culling de oclusão B2 + subdivisão gravada pelo pack) e anexa **itens de 32 bits** (`visible_index 12b | brick 10b | parte 2b | subdivisão 2b`) num buffer global com um `InterlockedAdd` por chunk (scan exclusivo local em groupshared para os offsets por brick; rederivação determinística na fase de escrita). Um segundo compute de 1 thread (`finalize_work_queue`) fecha o `x` do `VkDrawMeshTasksIndirectCommandEXT` com clamp na capacidade. O draw é `vkCmdDrawMeshTasksIndirectEXT` com **um único** comando e cada workgroup de mesh lê o seu item por `SV_GroupID`, resolvendo o chunk via `visible_chunks`. Vantagens: elimina o payload e o estágio task (o defeito desaparece junto), reaproveita integralmente a lógica de seleção já simulada, torna o overflow explícito (word de estado) e custa três barreiras de buffer no command buffer gráfico. Desvantagens: ≈ 32 MiB de buffer device-local (2 slots × 16 MiB — capacidade global de 4.096 visíveis × 1.024 bricks); a ordem dos itens entre chunks é corrida (irrelevante: itens são independentes e o depth resolve).

## Decisão

Aceita a Opção B. Implementada na correção pós-validação 3 da VS-02 (2026-11-04).

## Consequências

- `TaskPayload`, o task shader `select_bricks` e `CmdDrawMeshTasksEXT` saem; entram `build_work_queue` + `finalize_work_queue` (compute na fila gráfica, gravados antes do render pass), o buffer `work_queue` (binding 17, ring de 2 slots: 8 words de estado + itens) e o draw indireto de comando único.
- O estágio `TASK_EXT` some dos layouts e stage flags; a espera da timeline de compute no submit gráfico passa a `COMPUTE_SHADER | MESH_SHADER_EXT` (quem lê a ocupação primeiro é o builder).
- Cuidado registrado: `vkCmdDrawMeshTasksIndirectCountEXT` tem semântica de **N comandos indiretos**, não de "um comando com x = count" — o uso incorreto (count = contagem de itens) fez a GPU ler itens como se fossem comandos `(x,y,z)` e derrubou o dispositivo (TDR/`ERROR_DEVICE_LOST`) na primeira integração. Como o finalize já grava `x` com clamp e fila vazia vira `x = 0` (no-op), um único comando indireto basta.
- A simulação `tools/sim/render_sim.py` foi reescrita para o modelo de fila (210 checks): empacotamento do item, layout do slot do ring, clamp do finalize, orçamento 256 v/192 t, oclusão conservadora e fronteiras B2 preservados.
- Futuras specs que consumam o ponto de renderização (VS-03 em diante) não podem assumir a existência de estágio task: a barreira correta é COMPUTE → COMPUTE(builder) | MESH.

## Histórico

- 2026-11-04 — Decisão registrada como aceita (correção pós-validação 3 da VS-02).
