---
id: ADR-G1
titulo: Gameplay — seleção, construção e pulo
tipo: decisao
status: aceita
specs_afetadas: [VS-00, VS-20]
ultima_atualizacao: 2026-11-08
---

# ADR-G1 — Gameplay: seleção, construção e pulo

> **Nota de identificador:** o ID ADR-G1 já foi usado historicamente por [[ADR-G1-heightmap-geracao-mirror]]. Este arquivo registra a decisão de gameplay no caminho solicitado pelo mantenedor; os links devem usar o nome completo do arquivo para evitar ambiguidade.

## Contexto

A VS-19 fornece DDA tri-state, AABB, gravidade e grounded; VS-07 fornece `MouseButton`/`KeyPress` no bus e VS-03 fornece edição E1. A nova interação precisa indicar continuamente o voxel sob o centro da tela, construir/remover pelo mouse e permitir pulo de 1,5 bloco. O fragment já recebe `world_position`; os push constants de 92 B estão cheios no desenho atual e o binding 21 está livre.

## Requisitos relacionados

- REQ-GPL-01..08 da [[VS-20-gameplay-selecao-construcao-pulo|VS-20]].
- Revisão do contrato de bindings da [[VS-00-fundacao-vulkan|VS-00]].

## Opções

### Indicação do alvo

- **Opção A — Realce no fragment por UBO (recomendada e fixada).** Binding 21, 16 B: `target_voxel` i32×3 + `target_valid` u32. O fragment deriva `floor(world_position)` e clareia/tinge somente o voxel alvo. Não exige UI, geometria, fila de trabalho ou push constants novos.
- **Opção B — Geometria extra de outline.** Rejeitada: adiciona draw/geometria e interfere na fila de trabalho e nos orçamentos de mesh para uma indicação simples.
- **Opção C — Sem realce.** Rejeitada: não atende ao pedido de indicar onde o jogador aponta.

### Modelo do pulo

- **Opção A — Impulso vertical no tick (recomendada e fixada).** Ao `KeyPress` de SPACE com grounded e corpo não congelado, `velocity.y = sqrt(2 · |g| · 1.5)`. Com `g = 24 u/s²`, `v₀ = sqrt(72) ≈ 8,485 u/s`; altura balística ideal 1,5 voxel, limitada por colisão. A gravidade e o sweep existentes fazem o restante.
- **Opção B — Deslocamento/teleporte vertical.** Rejeitada: ignora integração temporal e produz colisão/grounded inconsistentes.
- **Opção C — Força enquanto SPACE está pressionado.** Rejeitada: altura depende da duração do input e não implementa o pulo único pedido.

### Construção e remoção

- **Opção A — Snapshot do DDA central + E1 (recomendada e fixada).** Origem na câmera, direção `camera.direction`, alcance 12 voxels, atualizado uma vez por frame após sincronizar câmera e física. Clique esquerdo coloca pedra id 3 em `hit.voxel + hit.normal`; direito substitui o voxel atingido por ar. Ambos usam `ve_request_voxel_edit` no intake da main. Atualização por frame evita defasagem perceptível entre mira e clique; uma atualização periódica em N ms foi rejeitada por introduzir staleness sem economia relevante para um único DDA.
- **Opção B — Novo DDA independente em cada clique.** Rejeitada: pode selecionar célula diferente da exibida e duplica o traçado.
- **Opção C — Comandos de coordenada manual.** Rejeitada: já existem para replay/debug, mas não realizam a interação pedida.

## Decisão

**Aceita: Opções A em todos os desenhos.** O mantenedor dispensou expressamente a aprovação da spec em 2026-11-08: “não espere minha aprovação, pode prosseguir”. O alvo é recalculado por frame e publicado no UBO do frame; miss/unknown limpam o realce e tornam cliques no-op. SPACE gera um impulso somente em press, com grounded e corpo válido/não congelado; auto-repeat não gera pulsos adicionais enquanto a tecla permanece pressionada.

## Consequências

- Novo binding 21 `TargetHighlight` uniform de 16 B; descriptor count 21→22 e estágio fragment. Push constants permanecem em 92 B.
- `render.slang` muda e exige sim antes da integração; o realce não altera alpha-test, UVs, templates, work queue ou orçamento de mesh.
- Posicionar pedra só é solicitado se a célula adjacente estiver conhecida e não-bloqueante, a normal for válida e a nova AABB não intersectar o jogador. Remoção mira exatamente o hit. E1 mantém dedup, feedback e ownership da worker.
- Um clique por press; release não edita. O snapshot compartilhado garante que highlight e ação se refiram ao mesmo alvo.
- Novas zones/contadores Tracy cobrem mira, ações e pulo; fechamento exige captura versionada VS-20 e comparação com a VS-19.

## Histórico

- 2026-11-08 — Decisão aceita de nascença; recomendação fixada e aprovação da spec dispensada pelo mantenedor.
