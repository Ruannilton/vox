---
id: ADR-L1
titulo: Iluminação híbrida por ray casting na GPU
tipo: decisao
status: aceita
specs_afetadas: [VS-23]
ultima_atualizacao: 2026-11-14
---

# ADR-L1 — Iluminação híbrida por ray casting na GPU

## Contexto

O motor possui shading Lambert simples, com luz direcional fixa e ambiente constante. Embora `emission_color` já exista em `BlockDefinition`, blocos emissivos ainda não iluminam o mundo. O sistema pretendido precisa oferecer sombras, ambient occlusion e muitas luzes — tochas e lava podem representar milhares de fontes — sobre chunks editáveis dinamicamente.

O pipeline já é híbrido por natureza: mesh shaders resolvem a visibilidade primária, enquanto compute e fragment shaders podem executar os raios secundários. Esses raios precisam atravessar geometria fora da tela e atrás da câmera, portanto o mundo deve ser consultável na GPU independentemente da malha. A hierarquia de ocupação existente, com células grossas de 8³, bricks 4×2×4 e bits por voxel, fornece a base para essa travessia.

## Requisitos relacionados

- [[VS-23-iluminacao-gpu-raycast|VS-23]] — especificação do sistema de iluminação.
- VS-02 — renderização e shading, hoje limitados a Lambert e emissão.
- VS-03 e VS-04 — edição de voxels e mirror, cujas invalidações alimentam o relight local.
- [[ADR-B1-ciclo-vida-slots|ADR-B1]] — publicação, conclusão e reutilização dos slots.
- [[ADR-B7-pbr|ADR-B7]] — escopo inicial de shading e evolução posterior do modelo de materiais.
- [[ADR-U1-uvs-templates-malha|ADR-U1]] e [[ADR-CAMINHO-B-templates-malha|ADR-CAMINHO-B]] — templates data-driven com vértices arbitrários, que motivam o AO por fragmento.

## Opções

### Opção A — Shadow maps cascadedados rasterizados para o sol

- Reutiliza rasterização e mesh shaders para produzir cascatas de profundidade do sol.
- Vantagens: custo conhecido e relativamente baixo; técnica consolidada para sombras direcionais.
- Desvantagens: menor precisão, aliasing e ajuste de cascatas; introduz um mecanismo de visibilidade distinto dos demais efeitos e não reaproveita diretamente a hierarquia de ocupação já existente.

### Opção B — AO por vértice

- Calcula a oclusão clássica de voxel nos vértices das faces, a partir dos vizinhos laterais e diagonais.
- Vantagens: custo quase nulo no shading e visual de voxel consolidado.
- Desvantagens: inaplicável como solução geral, pois os templates data-driven possuem vértices arbitrários e não apenas quads alinhados ao voxel; exigiria restringir ou especializar o formato de malha.

### Opção C — Grade clustered/froxel ou importance sampling/RIS/ReSTIR com shadow ray por luz

- Seleciona poucas luzes relevantes por célula ou por pixel e traça shadow rays para avaliar sua visibilidade.
- Vantagens: escala melhor que iterar todas as luzes por pixel; aproxima-se de iluminação direta de alta qualidade e admite muitas fontes.
- Desvantagens: custo por pixel elevado, complexidade de estruturas de seleção e necessidade de acúmulo temporal e denoiser nas abordagens estocásticas; combina pior com edições locais imprevisíveis que um volume propagado, que também ilumina interiores e cavernas quase de graça no consumo do fragment.

### Opção D — Path tracing completo desde o início

- Adota transporte de luz com múltiplos rebatimentos como base inicial do renderer.
- Vantagens: maior qualidade e caminho direto para GI, reflexos, espelhos e vidro fisicamente consistentes.
- Desvantagens: exige G-buffer, acúmulo temporal, reprojeção e denoiser antes de produzir ganhos utilizáveis; amplia demais o risco e o escopo da primeira entrega.

### Opção E — Pipeline híbrido com ray casting, AO determinístico e volume de luz propagada

- Mantém mesh shaders para visibilidade primária e usa fragment/compute para raios secundários e propagação de luz.
- Reutiliza a hierarquia de ocupação para travessia hierárquica stateless e acrescenta opacidade, lookup global de chunks e volume RGB de block light.
- Vantagens: entrega sombra e AO sem ruído nem denoiser, acomoda milhares de emissores e atualizações locais, e estabelece a travessia necessária para path tracing futuro.
- Desvantagens: aumenta memória por chunk e o número de bindings e passes; exige sincronização adicional e limita inicialmente os raios aos chunks carregados.

## Decisão

Adotar a **Opção E — pipeline híbrido com ray casting na GPU**, dividida nas seguintes frentes:

- **Mundo atravessável:** publicar na GPU um buffer global `chunk_grid`, indexado por coordenada de chunk e contendo o slot correspondente. A CPU só publica um slot depois da conclusão de `pack_chunk` e limpa sua célula antes da reutilização do slot, preservando o ciclo de vida definido pela ADR-B1.
- **Travessia e opacidade:** reutilizar as células grossas de 8³, os bricks e os bits de voxel para uma travessia hierárquica stateless. Acrescentar uma máscara de opacidade separada da solidez, com `opaco = !NON_SOLID && !TRANSPARENT`, para que vidro não bloqueie sombra nem AO. A máscara adiciona 4 KiB por chunk.
- **Sol e sombras:** disparar inicialmente no fragment um shadow ray hierárquico any-hit, encerrado na primeira oclusão. Usar depth pre-pass para evitar raios em overdraw e bias por deslocamento ao longo da normal axial. Fornecer `ignore_voxel` para templates parciais, como slabs, cuja origem pode permanecer dentro do próprio voxel opaco.
- **AO e ambiente:** calcular AO por fragmento, não por vértice. Para o voxel à frente da face, realizar oito leituras da máscara de opacidade nos vizinhos necessários aos quatro cantos e interpolar bilinearmente o resultado pela posição do fragmento na face. O resultado é determinístico, sem ruído e sem denoiser. A luz ambiente usa um gradiente de céu pela normal, do horizonte ao zênite, modulado pelo AO.
- **Blocos emissivos:** manter um volume de luz propagada por voxel, usando 4 bits por canal RGB em um `uint16`, totalizando 64 KiB por chunk. O pool acompanha o ciclo de vida dos slots. O flood-fill é resolvido por relaxação em passes de compute, in-place e monotônica; uma edição marca o chunk e seus 26 vizinhos por meio do fluxo associado a `shared_edit_dirty_bricks`, o seed reescreve o volume do conjunto afetado e até 15 passes propagam a luz.
- **Skylight propagada:** permanece fora do escopo inicial, pois exige varredura de cima para baixo entre chunks e merece uma task própria posterior.
- **Luzes dinâmicas:** admitir no máximo uma ou duas por frame, como a tocha do jogador, cada uma com shadow ray direto e atenuação `saturate(1-(d/R)^4)^2 / d²`.
- **Fase futura:** registrar como contrato, sem incluir no escopo inicial, G-buffer deferred com MRT de albedo, normal octaédrica e `block_id`, acúmulo temporal com denoise SVGF e path tracing com loop de throughput, NEE, Fresnel/Schlick, Beer-Lambert e Russian roulette para espelhos e vidro de verdade.

A implementação será planejada nesta ordem: **Fase 0** — máscara de opacidade, `chunk_grid` e `LightGlobals`; **Fase 1** — sol, sombra e depth pre-pass; **Fase 2** — AO por fragmento; **Fase 3** — volume de block light e relight; **Fase 4** — deferred, temporal e path tracing.

Esta decisão foi **aceita pelo mantenedor em 2026-11-14** e orienta a implementação das Fases 0 a 3 na VS-23; a Fase 4 permanece como contrato futuro.

## Consequências

- Cada chunk ocupará mais 4 KiB no pool de opacidade e 64 KiB no pool de luz; o consumo total acompanha a quantidade de slots alocados.
- Serão reservados os bindings 25–28 do set 0 para `LightGlobals`, `chunk_grid`, `light_pool` e `light_jobs`; o G-buffer futuro usará um set 1 próprio para recursos dependentes do tamanho da tela.
- O device deverá habilitar `fragmentStoresAndAtomics`, pois buffers declarados como RW serão lidos no fragment, e as barreiras entre escritas de compute e leituras posteriores deverão ser explícitas.
- O `chunk_grid` típico de 64×16×64 ocupará aproximadamente 256 KB e será reescrito nas operações de carregamento, descarregamento e recentralização.
- A ordem do frame passará a incluir o relight depois da geração/edição e antes do depth pre-pass e da renderização; a publicação dos slots no grid deverá respeitar essa sincronização.
- Sombras e demais raios só enxergarão chunks carregados até que exista uma representação distante, como SVDAG/LOD, com travessia própria.
- A VS-23 e seu arquivo de tasks detalham a implementação das Fases 0 a 3 e suas validações.
- Os caminhos novos ou alterados deverão receber zones Tracy de CPU e, quando aplicável, de GPU durante a implementação, com evidências de desempenho anexadas à especificação.

## Histórico

- 2026-11-14 — Decisão registrada como pendente.
- 2026-11-14 — Decisão aceita pelo mantenedor.
