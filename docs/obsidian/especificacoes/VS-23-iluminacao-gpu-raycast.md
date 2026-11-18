---
id: VS-23
titulo: Iluminação híbrida por ray casting na GPU
tipo: especificacao
status_spec: aprovada
status_implementacao: em-andamento
status_validacao: nao-iniciada
depende_de: [VS-02, VS-03, VS-04]
bloqueada_por: []
requisitos: []
ultima_atualizacao: 2026-11-14
---

# VS-23 — Iluminação híbrida por ray casting na GPU

## Objetivo

Substituir o Lambert fixo por iluminação híbrida que combine visibilidade primária por mesh shader, shadow rays e AO determinístico no fragment e block light RGB propagada por compute. O resultado deve incluir sombras do sol, oclusão nos contornos, milhares de emissores com relight local após edições e até duas luzes dinâmicas, sem depender da malha para atravessar o mundo.

## Rastreabilidade

- Decisão principal: [[ADR-L1-iluminacao-gpu-raycast|ADR-L1]], aceita pelo mantenedor em 2026-11-14.
- Ciclo de vida e sincronização: [[ADR-B1-ciclo-vida-slots|ADR-B1]].
- Shading inicial e evolução futura: [[ADR-B7-pbr|ADR-B7]].
- Templates com vértices arbitrários: [[ADR-U1-uvs-templates-malha|ADR-U1]].
- Fundação de render e edição: [[VS-02-task-mesh-templates|VS-02]], [[VS-03-edicao-e1|VS-03]] e [[VS-04-mirror-c2|VS-04]].
- Referência de design: discussão técnica `C:\Users\ruann\.kimi-code\sessions\wd_vox_b757afedde18\session_c47e1ee9-17d6-4c87-9b48-b8549b3e3eca\attachments\f_f6e497a3-0814-429a-b2d6-3a377f5dbca6-ray-cast-light.md`, especialmente as tasks T0.1–T3.6, com código Slang e comportamento esperado da CPU.
- Requisitos: nenhum ID adicional vinculado; os critérios abaixo operacionalizam a ADR-L1.

## Escopo

- **Fase 0 — fundação:** máscara de opacidade por brick, `chunk_grid` global, UBO `LightGlobals`, visibilidade dos descriptors ao fragment/compute, feature `fragmentStoresAndAtomics` e barreiras necessárias.
- **Fase 1 — sol:** `lighting.slang`, travessia hierárquica stateless any-hit, `shade_surface`, sombra dura no fragment, depth pre-pass e modos de debug.
- **Fase 2 — AO e ambiente:** AO por fragmento com oito leituras de opacidade e interpolação bilinear; gradiente de céu pela normal, modulado pelo AO.
- **Fase 3 — emissores e dinâmicas:** `light.slang`, pool RGB de block light, seed e até 15 passes de propagação por compute, relight de chunks afetados e vizinhos, amostragem trilinear simples no shading e no máximo duas luzes dinâmicas com shadow ray direto.
- Simulações Python anteriores às mudanças de shader, builds e validação Vulkan, cenários manuais de iluminação/edição, instrumentação Tracy e comparação de performance com a versão anterior.

## Não escopo

- Skylight propagada entre chunks, que exige varredura vertical própria e será tratada em task futura.
- Fase 4 da ADR-L1: G-buffer deferred, acúmulo temporal, denoise SVGF, AO estocástico, sombras macias e path tracing com throughput, NEE, Fresnel/Schlick, Beer-Lambert e Russian roulette. Esses itens permanecem apenas como contrato futuro.
- Shadow maps cascadedados, grade clustered/froxel, RIS/ReSTIR ou outras estruturas de seleção de muitas luzes por pixel.
- SVDAG/LOD distante. Os raios enxergam somente chunks carregados; ausência no grid é tratada como espaço aberto.
- Translucidez colorida, reflexos e vidro fisicamente refrativo.

## Dependências

- VS-02, VS-03 e VS-04 concluídas e verificadas: fornecem renderização por templates, edição bufferizada e ciclo de conclusão/materialização do mundo.
- ADR-L1 aceita; nenhum bloqueio pendente.
- Toda alteração de shader deve ser precedida pela simulação Python correspondente em `tools/sim/`, com os mesmos casos de borda usados depois na validação integrada.

## Interfaces e recursos

| Contrato | Conteúdo | Invariante / orçamento |
| --- | --- | --- |
| Máscara de opacidade | Uma word por brick em `occupancy_pool` | `opaco = id != 0 && !NON_SOLID && !TRANSPARENT`; `OCCUPANCY_WORDS_PER_CHUNK = 3138`; +4 KiB/chunk |
| `light_globals` | UBO com sol, céu, limites do grid, parâmetros e até duas dinâmicas | Set 0, binding 25; atualizado por frame |
| `chunk_grid` | Coordenada de chunk → slot ou `0xFFFFFFFF` | Set 0, binding 26; grade típica 64×16×64 ≈ 256 KB |
| `light_pool` | `uint16` por voxel: RGB com 4 bits por canal | Set 0, binding 27; 64 KiB/chunk; bits 12–15 reservados |
| `light_jobs` | Origem de mundo e slot dos chunks no relight | Set 0, binding 28; jobs sem duplicatas por flush |
| `lighting.slang` | Travessia, AO e `shade_surface` | Compartilhado por `render.slang` e `light.slang` |
| `light.slang` | `light_seed`, `light_propagate` e helpers de luz | Compute; no máximo 15 passes de propagação por relight |
| Depth pre-pass | Mesmo mesh shader, sem color attachment | Pass principal com depth write desligado e compare `LESS_OR_EQUAL` |
| Modos de debug | 0 normal, 1 sombra, 2 AO, 3 block light | Selecionáveis sem alterar os contratos de dados |

### Publicação e sincronização

- O slot entra no `chunk_grid` somente após a conclusão de `pack_chunk`; a célula é limpa antes da reutilização ou descarregamento do slot, conforme ADR-B1.
- Recentralização reescreve as células afetadas e atualiza a origem/dimensões no UBO. Chunks ausentes ou vazios são atravessados como abertos.
- Os buffers RW lidos no fragment exigem `fragmentStoresAndAtomics`; escritas de `pack_chunk`, edições e luz devem ter barreiras para as leituras subsequentes.
- O pool de luz acompanha o ciclo de vida do slot de occupancy; nenhum trabalho pode consultar slot em construção ou já reciclado.

### Ordem do frame

1. Gerar chunks e aplicar edições (`pack_chunk`, `apply_voxel_edits`).
2. Publicar slots no `chunk_grid` e montar `light_jobs` com chunks afetados e vizinhos.
3. Executar `light_seed` e até 15× `light_propagate`, com barreira compute→compute entre passes.
4. Construir e finalizar a work queue.
5. Executar depth pre-pass.
6. Executar o pass principal com `shade_voxel`/`shade_surface`.

## Cenários

### Cenário de sucesso — sol e AO

- **Dado** uma cena com superfície iluminada, obstrutor opaco, vidro e contornos de voxel.
- **Quando** os modos normal, 1 e 2 são inspecionados após o pre-pass.
- **Então** o obstrutor projeta sombra dura coerente com a direção do sol, vidro não bloqueia o raio, o AO escurece os contornos sem ruído e o ambiente varia suavemente entre horizonte e zênite.

### Cenário de sucesso — emissores e edição

- **Dado** uma caverna fechada sem emissores e chunks vizinhos carregados.
- **Quando** uma tocha é adicionada e depois removida por `apply_voxel_edits`.
- **Então** a luz RGB se propaga por até 15 níveis, perdendo um nível por voxel, alcança vizinhos quando cabe no alcance e desaparece após o relight da remoção, sem luz residual.

### Falhas e concorrência

- Coordenada fora do grid ou chunk ausente: a travessia salta a região como aberta, sem índice inválido nem falsa oclusão.
- Chunk vazio: salto no nível de chunk; nenhum acesso a slot inexistente.
- Slot em construção: nunca publicado; descarregamento/recentalização não deixa slot obsoleto no grid.
- Template parcial, como slab: `ignore_voxel` impede auto-oclusão quando a origem deslocada ainda pertence ao próprio voxel opaco.
- Edição no mesmo frame do relight: `apply_voxel_edits` e a atualização de opacidade precedem seed/propagate, de modo que nenhum passe usa a versão anterior do voxel editado.
- Edição na fronteira: o chunk editado e seus 26 vizinhos carregados entram no conjunto de relight, com remoção de duplicatas; descarregar um chunk também invalida a luz dos vizinhos.

## Critérios de aceitação

| ID | Critério verificável | Validação planejada | Evidência |
| --- | --- | --- | --- |
| VS-23-AC-01 | Opacidade coincide com paleta/flags em pack e edição; ar, não-sólidos e vidro não bloqueiam; layout usa 3138 words/chunk | Sim de opacidade antes do shader; Slang + `spirv-val`; readback de bricks e edições; build default/Tracy | Pendente |
| VS-23-AC-02 | Sombra do sol aparece apenas sob obstrutores e respeita direção/alcance; ausente/vazio é aberto; overdraw não dispara raios redundantes no pass principal | Sim de `trace_occluded` antes do shader; modo debug 1 em cena controlada; validation e inspeção do pre-pass | Pendente |
| VS-23-AC-03 | Slabs e demais templates parciais não apresentam auto-oclusão quando a origem está no próprio voxel | Casos `ignore_voxel` na sim; cena manual com faces e orientações distintas no modo debug 1 | Pendente |
| VS-23-AC-04 | AO por fragmento usa os oito vizinhos e bilinear, ficando dentro da tolerância definida pela sim Python; vidro não contribui para oclusão | Sim de AO antes do shader com gabarito numérico; modo debug 2 em cantos, arestas, fronteiras e face diagonal | Pendente |
| VS-23-AC-05 | Block light RGB alcança no máximo 15 níveis, cai 1 por voxel, preserva canais independentes e não atravessa opacos | Sim de seed/relaxação antes do shader; modo debug 3 e readback do volume após 15 passes | Pendente |
| VS-23-AC-06 | Adicionar uma fonte ilumina vizinhos; removê-la apaga toda luz derivada após seed/relight, sem fonte fantasma | Roteiro manual/replay de adicionar e remover tocha em caverna; comparação do volume antes/depois e debug 3 | Pendente |
| VS-23-AC-07 | Edição em qualquer fronteira agenda chunk + 26 vizinhos carregados sem duplicatas e propaga/atualiza luz entre chunks | Sim de seleção de jobs; roteiro em faces, arestas e cantos; contadores e readback dos jobs/volumes | Pendente |
| VS-23-AC-08 | Não há regressão injustificada de performance em relação ao binário anterior; custos de pre-pass, fragment e relight ficam identificados | Captura `run_tracy.bat` + `tracy-capture`; comparação por subagente coder K2.8 thinking low, com cenário e limitações registrados | Pendente |
| VS-23-AC-09 | Zones Tracy de CPU e GPU cobrem grid/jobs, seed, cada etapa de propagação, pre-pass e shading alterado, com nomes do domínio de iluminação | Inspeção da captura `bin/debug/<version>/tracy/VS-23_*.tracy`; zones e contadores correlacionados aos passes | Pendente |

## Tarefas da especificação

- [x] Vincular ADR, dependências e referência de design.
- [x] Definir escopo, não escopo, recursos e ordem do frame.
- [x] Cobrir sucesso, falhas, concorrência e edições em fronteiras.
- [x] Definir validação para cada critério de aceitação.
- [x] Resolver questões críticas abertas.
- [x] Registrar aprovação da direção pelo mantenedor via ADR-L1.

## Tarefas de implementação

Ver [[VS-23-iluminacao-gpu-raycast-tasks]]. As tasks seguem as Fases 0–3 e tornam obrigatórias as simulações antes da integração dos shaders. Fases 0–3 implementadas em 2026-11-14 (sims verdes, builds limpos, smoke sem VUIDs); fechamento (Tracy, ACs visuais, commit) pendente do mantenedor.

## Questões abertas

- Nenhuma questão crítica. Parâmetros concretos de intensidade, alcance do sol e tolerância numérica do AO serão fixados nas simulações e documentados na implementação, sem alterar a ADR-L1.

## Histórico

- 2026-11-14 — Spec criada e aprovada após a ratificação da ADR-L1 pelo mantenedor; arquivo de tasks derivado. Nenhuma implementação ou evidência de validação produzida.
- 2026-11-14 — Fases 0–3 implementadas (ver progresso no [[VS-23-iluminacao-gpu-raycast-tasks|arquivo de tasks]]): sims opacity/trace/AO/light verdes, shaders com Slang + `spirv-val` limpos, builds default/Tracy sem erros, smoke com validation layers sem VUIDs. ACs de validação visual (AC-02..AC-07) e captura Tracy (AC-08/AC-09) pendentes do mantenedor.
