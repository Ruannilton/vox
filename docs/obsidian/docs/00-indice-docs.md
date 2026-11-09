---
id: DOCS-INDEX
titulo: Índice da documentação do motor
tipo: docs
ultima_atualizacao: 2026-11-09
---

# Documentação do Motor de Voxels — Índice

Documentação de aprendizado: para quem nunca teve contato com o projeto. Três visões, do macro ao detalhe:

| Visão | O que responde | Onde |
| --- | --- | --- |
| **Alto nível** | Como as coisas funcionam de forma macro — o que o motor faz, o pipeline de um frame, os fluxos de dados | `10-alto-nivel/` |
| **Sistema** | Como cada subsistema funciona, **por que** existe, e como se coordena com os demais | `20-sistemas/` |
| **Referência** | Cada struct e procedure: o que é, o papel no sistema, contratos e invariantes | `30-referencia/` |

## Guia de estilo (vale para todos os documentos)

- Formato Obsidian (wiki-links `[[...]]`); PT-BR; frontmatter mínimo (`id`, `titulo`, `tipo`, `ultima_atualizacao`).
- **Referência cruza-se com Sistema, Sistema cruza-se com Alto nível** — todo documento linka para cima (contexto) e para os vizinhos.
- Decisões de desenho apontam para a **ADR** e a **spec** correspondentes (`decisoes/`, `especificacoes/`) — a documentação explica o estado atual; specs/ADRs explicam a história.
- Código: nome de proced/struct em `` `code` `` com arquivo e, quando útil, linha aproximada. Shaders: binding e layout explícitos.
- Invariantes do AGENTS.md (regras 1–7) são citados onde pertinentes — não repetidos.
- Nada de markdown gerado por reflexo: cada documento parte da leitura do código atual (não da memória).

## Mapa

### 10 — Alto nível
- [[visao-geral|Visão geral]] — o que é o motor, pipeline de um frame, os dois mundos (CPU/GPU) e as três threads.

### 20 — Sistemas
- [[sistema-engine-fundacao|Engine e fundação Vulkan]] — init, janela, swapchain, sincronização de frames.
- [[sistema-streaming-mundo|Streaming e mundo]] — chunks, worker dona do mundo, cursor incremental, ciclo de vida dos slots.
- [[sistema-renderizacao|Renderização]] — fila de trabalho, mesh shader, fragment, culling, texturas.
- [[sistema-mirror-fisica|Mirror e física]] — o mundo na RAM, edições convergentes, solver de corpos.
- [[sistema-edicao-eventos|Edição e eventos]] — journal E1, bus de input/comandos, gravação e replay.
- [[sistema-suporte|Suporte]] — config INI, assets JSON, telemetria, Tracy, versionamento.

### 30 — Referência (um documento por módulo)
- [[ref-main|main, camera, utils]] (package main) · [[ref-engine|engine, engine_vulkan]] · [[ref-voxel-types|voxel_types]] (structs/contratos) · [[ref-voxel-gpu|voxel_gpu]] (recursos e init — inclui gpu_buffer) · [[ref-voxel-engine-worker|voxel_engine + voxel_worker]] · [[ref-voxel-render|voxel_render]] · [[ref-gameplay|gameplay]] (mira/construção/pulo) · [[ref-edit-mirror|voxel_edit + voxel_mirror]] · [[ref-assets-config-events|voxel_assets + config + events]] · [[ref-physics-tracing|physics + tracing(+gpu) + telemetry]] · [[ref-shaders|shaders]] (Slang: bindings, structs, entry points)

## Como ler na primeira vez

1. [[visao-geral|Visão geral]] (15 min).
2. Os seis documentos de **Sistema** (por interesse ou na ordem acima).
3. **Referência** como consulta — um por módulo, no ritmo do trabalho.
4. `docs/arquitetura.md` e `docs/manual-tecnico.md` continuam existindo (visão histórica e contratos); specs e ADRs são a genealogia das decisões.
