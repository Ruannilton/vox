# Motor de Voxels — Especificações

Este vault organiza a reescrita orientada por especificações. Não exige plugins do Obsidian.

## Fontes e seus papéis

- [Arquitetura v3.0](../arquitetura.md): GOAL arquitetural.
- [Manual Técnico v3.0](../manual-tecnico.md): GOAL de contratos, layouts e comportamento.
- [Referência Odin](../examples/voxel.odin) e [referência Slang](../examples/voxel.slang): algoritmos disponíveis para consulta, ainda não integrados.
- `src/`: provas de conceito atuais, substituíveis durante a reescrita.

## Navegação

- [[status|Painel de status]]: estado das especificações, implementações e validações.
- [[dependencias|Hierarquia de dependências]]: sequência das fatias e bloqueios.
- [[modelo-especificacao|Modelo de especificação]]: estrutura obrigatória para novas specs.
- [[00-indice|Índice de ADRs]]: 12 decisões registradas, incluindo B1–B9, Caminho B, E1 e C2.
- [[modelo-decisao|Modelo de decisão]]: estrutura para novas ADRs.
- [[ADR-B5-capacidade-streaming|ADR-B5]]: bloqueia VS-01; [[ADR-B6-culling-alpha-test|ADR-B6]] e [[ADR-B7-pbr|ADR-B7]] bloqueiam VS-02.

## Fatias planejadas

1. [[VS-00-fundacao-vulkan|VS-00 — Fundação Vulkan]]
2. [[VS-01-streaming-generate-pack|VS-01 — Streaming, generate e pack]]
3. [[VS-02-task-mesh-templates|VS-02 — Task/mesh e templates]]
4. [[VS-03-edicao-e1|VS-03 — Edição E1]]
5. [[VS-04-mirror-c2|VS-04 — Mirror C2]]

## Fluxo de trabalho

1. Criar ou atualizar a spec a partir do modelo e vincular seus requisitos.
2. Registrar dependências por ID, sem ciclos, e atualizar o grafo quando necessário.
3. Atualizar no mesmo trabalho o frontmatter da spec e o [[status|painel central]].
4. Mover a spec para `em-revisao` somente com critérios de aceitação e validação definidos.
5. Mover para `aprovada` somente após revisão e sem questões críticas abertas.
6. Iniciar implementação apenas de spec aprovada e com dependências concluídas.
7. Marcar implementação como `concluida` somente com os critérios atendidos; marcar validação como `verificada` somente com evidência reproduzível.

As dependências controlam a prontidão para implementação. Rascunhos de fatias posteriores podem ser elaborados antecipadamente.
