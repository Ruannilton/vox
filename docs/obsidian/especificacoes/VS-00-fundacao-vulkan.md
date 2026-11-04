---
id: VS-00
titulo: Fundação Vulkan
tipo: especificacao
status_spec: rascunho
status_implementacao: nao-iniciada
status_validacao: nao-iniciada
depende_de: []
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-03
---

# VS-00 — Fundação Vulkan

## Objetivo

Estabelecer a base executável da nova implementação: janela, dispositivo, capabilities, filas, sincronização, recursos por frame e apresentação de um frame vazio.

## Rastreabilidade

- GOAL: [Arquitetura — Etapa 2](../../arquitetura.md) e [Manual Técnico — Sincronização Vulkan](../../manual-tecnico.md).
- Referência: `VulkanContext` em `docs/examples/voxel.odin`; a inicialização atual em `src/` é somente prova de conceito.
- Requisitos: vincular os IDs de plataforma, dispositivo, frames e sincronização durante o catálogo de requisitos.

## Escopo

- Inicialização e encerramento de janela e Vulkan.
- Seleção de dispositivo e verificação explícita de extensões e features.
- Filas gráfica e de compute, command buffers e timelines.
- Swapchain, dynamic rendering e recursos por frames em voo.
- Estrutura de descriptors e pipelines necessária às fatias seguintes.
- Build reproduzível e smoke test com validation layers.

## Não escopo

- Streaming, worldgen, chunks, geometria, edição e mirror.
- Fallback para GPUs sem `VK_EXT_mesh_shader`.

## Dependências

Nenhuma spec predecessor. As decisões de capabilities devem considerar as necessidades de VS-01 a VS-04, incluindo mesh shaders e `storageBuffer16BitAccess`.

## Interfaces e recursos

A especificar: propriedade do contexto Vulkan, ciclo de vida dos recursos, contratos de aquisição/apresentação, valores iniciais das timelines e comportamento de erro e shutdown.

## Cenários mínimos a detalhar

- Inicialização em dispositivo compatível e apresentação de frames vazios.
- Rejeição clara de dispositivo sem features obrigatórias.
- Resize e recriação de swapchain.
- Encerramento sem destruir recursos ainda em uso pela GPU.
- Execução com validation layers sem erros introduzidos pela fatia.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-00-AC-01 | O comando documentado compila e executa a fundação sem intervenção manual adicional | Build e smoke test | Pendente |
| VS-00-AC-02 | Features e extensões obrigatórias são consultadas e falhas produzem diagnóstico explícito | Teste de capabilities | Pendente |
| VS-00-AC-03 | Frames e shutdown respeitam as timelines e a vida útil dos recursos | Smoke test com validation layers | Pendente |

## Tarefas da especificação

- [ ] Vincular todos os requisitos do GOAL.
- [ ] Definir interfaces, proprietários e ciclo de vida dos recursos.
- [ ] Detalhar cenários de falha, resize e shutdown.
- [ ] Definir comandos e evidências de validação.
- [ ] Submeter à revisão e obter aprovação.

## Tarefas de implementação

Não gerar antes da aprovação desta spec.

## Questões abertas

- Definir versões mínimas suportadas do toolchain e política para validation layers ausentes.

## Histórico

- 2026-11-03 — Rascunho estrutural criado; conteúdo ainda não aprovado.
