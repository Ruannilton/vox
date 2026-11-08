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
8. Comentários no código devem ser curtos, descritiveis e apenas quando necessário
9. Ordem de organização do código: imports primeiros, depois constantes, depois structs, depois funções públicas e por ultimo funções privadas
10. Funções que não são utilizada em outros móudos devem ser privdas, funções que não serão utilizadas em outro arquivo devem ser privadas ao nível de arquivo
12. Nomes de variáveis sempre legíveis, nada de abreviações

## Workflow
- Criação de ADR e spec: subagente com **K3.1 (thinking low)**; a partir da spec criada, gerar também um **arquivo de TASKS** (`docs/obsidian/especificacoes/VS-XX-<slug>-tasks.md`) com todas as etapas de alteração necessárias para implementar a spec e as validações de cada etapa. O agente principal mantém a orquestração, a aprovação pelo mantenedor e o tracking.
- Desenvolvimento (implementação): subagente coder **K2.8 (thinking low)**, executando as etapas do arquivo de TASKS da spec.
- Debug: subagente coder **K2.8 (thinking low)**.
- Escalar para K3.1 (parâmetro `model` do Agent) quando o subagente estiver travado.
- Mudança de shader → escrever/estender simulação Python em tools/sim/ antes de integrar.
- Marcar integrações pendentes com TODO(E1)/TODO(B)/TODO(C2) (convenção existente).
- Manter documentação do projeto atualizada no formato obsidian dentro do diretorio docs/obsidian/*
- Especificações e planejamento precedem o código; documentação de comportamento integrado deve mudar junto com o código correspondente.
- Registrar especificações em docs/obsidian/especificacoes/ usando modelos/modelo-especificacao.md.
- Registrar decisões arquiteturais em docs/obsidian/decisoes/ usando modelos/modelo-decisao.md e indexá-las em decisoes/00-indice.md.
- Manter o frontmatter da spec, docs/obsidian/tracking/status.md e docs/obsidian/tracking/dependencias.md sincronizados a cada mudança.
- Só iniciar implementação com spec aprovada e dependências concluídas; só marcar validação verificada com evidência reproduzível.
- Ao fim de uma specificação realizar o commit passando o nome da especificação na mensagem
- Toda especificação implementada deve ser instrumentada: zones Tracy (CPU e, quando aplicável, GPU) nos caminhos novos ou alterados, com nomes ligados ao domínio da spec.
- Todos os arquivos de debug, telemetria, gravações e capturas ficam em `./bin/debug/<version>/` (version = VERSION_STRING); captures Tracy usam a subpasta `tracy/`.
- Ao finalizar cada implementação: executar o projeto com Tracy ativado (`run_tracy.bat`, captura via `tracy-capture`), salvar os dados com o código da especificação no nome do arquivo (ex.: `bin/debug/<version>/tracy/VS-XX_<descricao>.tracy`) e despachar um subagente coder (K2.8, thinking low) para comparar a performance com a versão anterior; o relatório da comparação entra nas evidências dos ACs da spec.

## Odin
- Documentação em docs/Odin-Documentation
- NUNCA tente ler a documentação completa, procure pelo item em especifico

## Comandos
- Build: `run.bat` (compila shaders Slang → `bin/`, `odin build ./src -out:./bin/vox.exe` e executa)
- Simulações: python3 tools/sim/<arquivo>.py