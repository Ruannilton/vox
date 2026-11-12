---
id: ADR-B12
titulo: Biomas procedurais data-driven no kernel de geração
tipo: decisao
status: pendente
specs_afetadas: [VS-22]
ultima_atualizacao: 2026-11-12
---

# ADR-B12 — Biomas procedurais data-driven no kernel de geração

## Contexto

A composição do terreno é hardcoded no `generate_voxels` (dois ruídos fixos, altura `32 + n1*10 + n2*5`, ids de bloco fixos grama/terra/pedra). O mantenedor propôs evoluir para biomas procedurais configuráveis em JSON (mesmo padrão dos blocos), com a adição de configurar por bioma qual bloco compõe a superfície e qual compõe o subsolo/fundo. O ponto de decisão é **onde e como** a morfologia do terreno passa a ser definida: continuando hardcoded com parâmetros soltos, virando dados injetados na GPU, ou indo para a CPU.

## Requisitos relacionados

- REQ-BIO-01 (config JSON), REQ-BIO-02 (classificação/ecótono), REQ-BIO-03 (composição da coluna), REQ-BIO-04 (determinismo/integração), REQ-BIO-05 (interfaces GPU) — spec [[VS-22-biomas-procedurais|VS-22]].

## Opções

### Opção A — Data-driven no kernel de geração (classificação climática contínua)

- Biomas e camadas de ruído em StructuredBuffers carregados do `assets/biomes.json`; o kernel amostra eixos climáticos (T, H) de baixíssima frequência com domain warping, classifica primário/secundário por distância euclidiana, faz blending no ecótono (`lerp` + `smoothstep`, peso ≤ 0,5) com early-out de ALU no interior dos biomas.
- Vantagens: sem paredões entre biomas (modelo climático contínuo); flexibilidade total sem reescrever shader; aproveita o FastNoiseLite já vendorado e o heightmap por coluna da VS-13; determinístico e bit a bit; custo extra só nas zonas de transição.
- Desvantagens: classificação é sequencial por coluna (até 16 distâncias) e o blending dobra o somatório de ruído no ecótono; buffers/bindings novos no descriptor set global.

### Opção B — Biomas por região (voronoi/células) com comutação direta

- Cada coluna sorteia o bioma pela célula voronoi mais próxima e usa sua pilha de ruído isoladamente.
- Vantagens: classificação O(1) sem busca; sem somatório dobrado.
- Desvantagens: fronteiras secas — exatamente os paredões verticais e sulcos que o documento do mantenedor descreve como inaceitáveis; exigiria pós-suavização de borda (complexidade extra no pack/mirror).

### Opção C — Manter hardcoded, apenas parametrizar constantes

- Trocar os números mágicos atuais por poucos parâmetros no JSON, sem classificação de biomas.
- Vantagens: menor diferença de código; zero bindings novos.
- Desvantagens: não entrega biomas nem a escolha de blocos por região — não atende o pedido do mantenedor.

## Decisão

Pendente. Recomendação registrada: **Opção A** — é a única que elimina os paredões por construção (continuidade climática + blending limitado a 0,5), mantém a geração 100% na GPU (onde o pipeline já vive) e preserva o determinismo exigido pelo streaming/mirror.

## Consequências

- Três bindings novos (22–24) e `DESCRIPTOR_SET_BINDING_COUNT = 25`; push constants e demais contratos intactos.
- A simulação `tools/sim/biomes_sim.py` passa a espelhar a lógica de composição (REQ-SIM-11) antes da integração — regra do projeto para mudança de shader.
- Configuração nova no boot (`assets/biomes.json`); troca de config só afeta chunks novos (mundo misto documentado, sem migração).
- Risco principal: custo de ALU no ecótono (somatório dobrado) — mitigado pelo early-out e medido na validação (telemetria VS-05/16).

## Histórico

- 2026-11-12 — Decisão registrada como pendente; bloqueia a aprovação da [[VS-22-biomas-procedurais|VS-22]] até a ratificação do mantenedor.
