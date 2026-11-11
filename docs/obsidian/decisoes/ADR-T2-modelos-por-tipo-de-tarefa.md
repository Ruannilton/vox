---
id: ADR-T2
titulo: Modelo e thinking por tipo de tarefa
tipo: decisao
status: aceita
specs_afetadas: []
ultima_atualizacao: 2026-11-05
---

# ADR-T2 — Modelo e thinking por tipo de tarefa

## Contexto

Custo e latência das sessões crescem quando todo o trabalho roda no mesmo modelo com thinking alto. O projeto distingue naturalmente dois tipos de tarefa: decisões de arquitetura e criação de requisitos/specs (raras, exigem raciocínio profundo) e desenvolvimento/depuração (frequentes, mecânicas após o desenho estar fixado). O Kimi Code não permite definir modelo por arquivo de agente (o frontmatter `model` é ignorado), mas permite um modelo principal e um pool de modelos para subagentes (`[secondary_model]` no `config.toml`).

## Requisitos relacionados

- Nenhuma spec afetada diretamente; decisão de processo de desenvolvimento.

## Opções

### Opção A — Tudo no modelo principal (K3.1, thinking high)

- Simples, sem configuração extra; mas todo despacho de subagente herda o modelo caro e o thinking alto, desperdiçando quota em tarefas mecânicas.

### Opção B — Divisão principal/subagentes via `[secondary_model]` (escolhida)

- Agente principal em `kimi-code/k3.1-pro` (`default_model`, thinking `high`) para decisões de arquitetura e specs; subagentes fixos em `kimi-code/kimi-for-coding` (K2.8) com `default_effort = "low"`, com `kimi-code/k3.1-pro` no pool como escalonamento para subtarefas difíceis.

### Opção C — Configuração por projeto

- Rejeitada por inviabilidade: o Kimi Code não lê modelo/thinking de configuração local do projeto (só `local.toml` legado de diretórios e `mcp.json`); modelo só existe no `config.toml` user-level.

## Decisão

Opção B, registrada também em `AGENTS.md` (workflow): decisões de arquitetura e requisitos no agente principal (K3.1, thinking high); desenvolvimento e depuração despachados a subagentes `coder` (K2.8, thinking low), escalando para K3.1 via parâmetro `model` do Agent apenas quando travados.

## Consequências

- `default_model` global passa de K2.8 para K3.1 Pro em todas as sessões do usuário (config é user-level; afeta outros projetos).
- Subagentes passam a custar K2.8 com thinking low por padrão; o agente principal pode escolher o alias K3.1 do pool por spawn.
- O refresh gerenciado do provider pode reescrever `default_effort`/`support_efforts` das entradas de modelo; se isso ocorrer, fixar via `[models."<alias>".overrides]`.

## Histórico

- 2026-11-05 — Decisão registrada como aceita e configurada em `~/.kimi-code/config.toml` e `AGENTS.md`.
