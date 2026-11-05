# AGENTS.md — Motor de Voxels (Vulkan 1.4 / Odin / Slang)

## Contexto
Motor GPU-driven/data-driven. Leia docs/arquitetura.md antes de alterar pipeline.
Constantes e layouts: src/assets/shaders/common.slang é a fonte única de verdade.

## Regras inegociáveis
1. Voxel = 1 unidade³ sempre. Objetos maiores = múltiplos voxels-parte.
2. Slot 0 da paleta é AR. Nunca reciclar.
3. 1 claim = 1 lote = 1 valor de timeline (B1). Anti-ABA por coord+geração.
4. Nunca liberar slot de ring em voo; só o handler de conclusão libera (C2).
5. Orçamento mesh shader 256v/192t garantido por subdivisão — não assumir culling direcional.
6. Chunk com CHUNK_FLAG_PALETTE_OVERFLOW é somente-leitura.
7. Layout do mirror é y-contíguo (y|z<<5|x<<10); o scratch GPU é x-contíguo. Não misturar.

## Workflow
- Decisões de arquitetura e criação de requisitos/specs: executadas pelo agente principal (K3.1, thinking high).
- Desenvolvimento e depuração: despachar para subagentes `coder` (K2.8, thinking low, via `[secondary_model]`); escalar para K3.1 (parâmetro `model` do Agent) só quando o subagente estiver travado.
- Mudança de shader → escrever/estender simulação Python em tools/sim/ antes de integrar.
- Marcar integrações pendentes com TODO(E1)/TODO(B)/TODO(C2) (convenção existente).
- Manter documentação do projeto atualizada no formato obsidian dentro do diretorio docs/obsidian/*
- Especificações e planejamento precedem o código; documentação de comportamento integrado deve mudar junto com o código correspondente.
- Registrar especificações em docs/obsidian/especificacoes/ usando modelos/modelo-especificacao.md.
- Registrar decisões arquiteturais em docs/obsidian/decisoes/ usando modelos/modelo-decisao.md e indexá-las em decisoes/00-indice.md.
- Manter o frontmatter da spec, docs/obsidian/tracking/status.md e docs/obsidian/tracking/dependencias.md sincronizados a cada mudança.
- Só iniciar implementação com spec aprovada e dependências concluídas; só marcar validação verificada com evidência reproduzível.
- Ao fim de uma specificação realizar o commit passando o nome da especificação na mensagem

## Odin
- Documentação em docs/Odin-Documentation
- NUNCA tente ler a documentação completa, procure pelo item em especifico

## Comandos
- Build: `run.bat` (compila shaders Slang → `bin/`, `odin build ./src -out:./bin/vox.exe` e executa)
- Simulações: python3 tools/sim/<arquivo>.py