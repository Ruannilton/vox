---
id: ADR-F1
titulo: Física de gameplay — solver CPU sobre o mirror
tipo: decisao
status: aceita
specs_afetadas: [VS-00, VS-13, VS-19]
ultima_atualizacao: 2026-11-08
---

# ADR-F1 — Física de gameplay: solver CPU sobre o mirror

## Contexto

O motor precisa de colisão estática, movimento de corpos dinâmicos e raycast sem duplicar o mundo nem acoplar gameplay ao packed da VRAM. O mirror C2 já contém `ids`, bitmask `solid`, heightmap e consultas tri-state; desde a VS-18 a worker é dona da mutação do mundo e a main usa APIs de leitura protegidas por mutex. A análise [[analise-fisica-arquitetura]] separa ocupação, bloqueio e possibilidade de ser atingido, e compara cinco eixos arquiteturais.

## Requisitos relacionados

- REQ-PHY-01..10 da [[VS-19-fisica-solver-mirror|VS-19]].
- Contratos revisados: REQ-MIR-01/02 da [[VS-13-heightmap-geracao-mirror|VS-13]] e binding 20 da [[VS-00-fundacao-vulkan|VS-00]].
- Fundação: ADR-C2, ADR-G1, ADR-P1 e ADR-W1.

## Opções

### Eixo 1 — Dado estático: Opção A, bitmask `solid` do mirror C2

Reutiliza a broadphase binária já derivada do registry e mantida pelo journal. Não cria memória, readback ou sincronização novos, e preserva o tri-state fora da bolha. Alternativas rejeitadas: bitmask físico exportado da GPU, redundante com o mirror, e lookup `ids`→definição em toda consulta, com acessos dependentes mais caros.

### Eixo 2 — Semântica: Opção A, `PhysicsDefinition` CPU-side

Tabela separada por tipo de bloco, carregada do `blocks.json`, com `BLOCKING`, `HITTABLE`, `CLIMBABLE` e `LIQUID` (os dois últimos reservados), fricção e restituição. O bitmask filtra; `ids` e a tabela resolvem a semântica. Não amplia o `BlockDefinition` de 48 B/std430, pois shaders não consomem propriedades físicas. O bitmask `hittable` dedicado é adiado até haver medição que justifique memória e manutenção adicionais.

### Eixo 3 — Narrowphase: Opção A, sweep de AABB na grade

AABB dinâmica varre somente os voxels da caixa do movimento, resolvendo X, Y e Z separadamente para sliding, step-up e grounded. A grade é a estrutura de aceleração; BVH/octree seriam redundantes. O heightmap é um fast-path para apoio no chão, sempre com fallback ao sweep em cavernas, interiores, sobreposição ou ausência de altura útil. A subdivisão do deslocamento evita tunneling.

### Eixo 4 — Execução: Opção A, CPU sobre o mirror

O tick fixo roda na thread de gameplay/main, dentro do acumulador, usando somente as APIs de leitura do mirror protegidas pelo mutex da VS-18. A worker continua única dona da mutação e executa `mirror_request`. Não há readback nem dependência da bolha de render. GPU fica fora da física autoritativa.

### Eixo 5 — Raycast: Opção A, DDA na grade

Amanatides & Woo percorre apenas os voxels atravessados, com distância máxima e tabela `HITTABLE`; plantas podem ser atingidas sem bloquear movimento. O resultado é tri-state: hit, miss ou desconhecido ao encontrar página não materializada antes do limite.

## Decisão

**Pendente de ratificação.** As escolhas do mantenedor estão registradas como Opção A nos cinco eixos: mirror C2, tabela física separada na CPU, sweep de AABB com fast-path de heightmap, execução na main e DDA tri-state. Corpos são AABBs e o tempo usa passo fixo com acumulador; replay é best-effort, no modelo da VS-07. Dinâmica-dinâmica não integra a primeira fatia.

## Consequências

- A VS-19 implementa o solver e os consumidores sobre o mirror, sem alterar o ownership da VS-18 nem criar uma segunda representação estática.
- `PhysicsDefinition` permanece fora dos layouts Odin↔Slang; o contrato GPU de blocos continua com 48 B.
- O heightmap deixa de ser uma estimativa analítica: na materialização da página, cada uma das 1.024 colunas é derivada do bitmask `solid` já preenchido. Assim árvores, arcos e outras topologias não dessincronizam o topo.
- O ring `mirror_heightmap_ring` (binding 20), seu write no `generate_voxels` e seu provisionamento tornam-se redundantes e são removidos pela VS-19. VS-13 e VS-00 recebem emendas; `heightmap_sim` e `mirror_sim` são atualizados antes do shader.
- Mundo desconhecido não é tratado como ar: a entidade congela e solicita a página; raycast retorna desconhecido. A ausência de páginas nunca produz queda através do mundo.
- O passo fixo dá reprodutibilidade dado o mesmo estado inicial e a mesma sequência de inputs, mas não promete determinismo bit-exato entre máquinas.
- Instrumentação Tracy cobre tick, sweep, fast-path, espera/congelamento e DDA. Fechamento exige captura versionada `VS-19` e comparação de performance com a versão anterior.

## Histórico

- 2026-11-08 — Decisão registrada como pendente a partir da análise e das escolhas do mantenedor; bloqueia a aprovação da VS-19.
