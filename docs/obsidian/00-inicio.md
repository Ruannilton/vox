# Motor de Voxels — Especificações

Este vault organiza a evolução orientada por especificações. Não exige plugins do Obsidian.

## Comece aqui

- **[Documentação do motor](docs/00-indice-docs.md)** — documentação de aprendizado em 3 visões (alto nível, sistemas, referência), para quem nunca teve contato com o projeto. Leia antes das specs.

## Fontes e seus papéis

- [Arquitetura v3.0](../arquitetura.md): GOAL arquitetural.
- [Manual Técnico](../manual-tecnico.md): contratos, layouts e comportamento.
- [Referência Odin](../examples/voxel.odin) e [referência Slang](../examples/voxel.slang): algoritmos de consulta originais.
- `docs/reference/`: referência bruta gerada a cada commit pelo hook (`odin doc`).

## Navegação

- [[status|Painel de status]]: estado das especificações (VS-00 a VS-21), implementações e validações.
- [[backlog|Backlog consolidado]]: itens futuros (BLK-01+).
- [[dependencias|Hierarquia de dependências]]: grafo e regras das fatias.
- [[00-indice|Índice de ADRs]]: decisões registradas e aceitas.
- [[modelo-especificacao|Modelo de especificação]] / [[modelo-decisao|Modelo de decisão]]: estruturas obrigatórias para novas specs/ADRs.

## Espaços

- `especificacoes/` — specs (VS-XX) + arquivo de TASKS por spec (`VS-XX-*-tasks.md`).
- `decisoes/` — ADRs e índice.
- `tracking/` — status, dependências, backlog.
- `docs/` — documentação de aprendizado (3 visões).

## Fluxo de trabalho

1. Criar ou atualizar a spec a partir do modelo e vincular seus requisitos (criação por subagente K3.1, com arquivo de TASKS — ver AGENTS.md).
2. Registrar dependências por ID, sem ciclos, e atualizar o grafo quando necessário.
3. Atualizar no mesmo trabalho o frontmatter da spec, o [[status|painel central]] e o [[backlog|backlog]].
4. `em-revisao` somente com critérios de aceitação e validação definidos; `aprovada` após revisão do mantenedor (salvo dispensa explícita).
5. Implementar apenas spec aprovada e dependências concluídas (K2.8 executando o TASKS; debug em K2.8; escalar para K3.1 quando travado).
6. Fechamento: instrumentação Tracy, captura versionada `bin/debug/<version>/tracy/VS-XX_*.tracy`, comparação de performance com a versão anterior e commit com o nome da spec.

As dependências controlam a prontidão para implementação. Rascunhos de fatias posteriores podem ser elaborados antecipadamente.
