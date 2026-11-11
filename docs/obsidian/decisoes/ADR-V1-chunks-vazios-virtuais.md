---
id: ADR-V1
titulo: Chunks vazios virtuais sem slot
tipo: decisao
status: aceita
specs_afetadas: [VS-10]
ultima_atualizacao: 2026-11-06
---

# ADR-V1 — Chunks vazios virtuais sem slot

## Contexto

Chunks contendo apenas ar dentro da bolha de visão hoje custam recursos sem produzir nada: a CPU publica todo chunk `RENDERABLE` em `visible_chunks`, o builder despacha um workgroup por chunk visível que só então early-outa em `CHUNK_FLAG_EMPTY`, e o chunk permanece CACHED/RENDERABLE segurando um slot residente (≈42,7 KiB device) até sair da esfera de unload. No terreno atual (superfície em y≈32–47, câmera em altura) ~metade da bolha de visão é ar puro. O mantenedor propôs: após a geração, marcar chunks sem blocos úteis e dar preferência de reuso ao slot; edições em chunk descartado recarregam antes de aplicar.

## Requisitos relacionados

- REQ-VRT-01..06 e REQ-SIM-07 da [[VS-10-chunks-vazios-virtuais|VS-10]].

## Opções

### Opção A — Estado EMPTY virtual, sem slot (liberação imediata)

- Novo estado `ChunkState.EMPTY`: o registro permanece no map de chunks (custa só memória de índice), mas **não possui slot**. Na conclusão do lote, o pack exporta as flags por slot num buffer host-visible minúsculo (`chunk_result_flags`, binding 18); o handler de conclusão (já ordenado pela timeline, B1) marca `EMPTY` e devolve o slot ao pool imediatamente.
- Chunk `EMPTY` nunca é publicado, nunca é `RENDERABLE`, e seus vizinhos o veem como `NEIGHBOR_SLOT_INVALID` — que o shader **já trata como ar** (B2): zero mudança nos shaders de render. Unload de `EMPTY` = deletar o registro, sem aposentadoria.
- Edição em chunk `EMPTY`: aloca slot + enfileira geração + estado `GENERATING`; o mecanismo de pendências do E1 (VS-03) reaplica a edição na conclusão. Edição de ar-em-ar = no-op sem materializar. Mirror sintetiza a página (zeros) quando na bolha de simulação.
- Vantagens: elimina o custo inteiro (slot, builder dispatch, entrada visível) — não só reordena o reuso; usa hooks existentes (B1, E1-pending, B2-invalid); shaders de render intocados.
- Desvantagens: exige um binding novo (18) e feedback do pack (contrato VS-00 revisado); um fluxo novo de "materializar por edição" (com retry sob pool esgotado).

### Opção B — Flag + preferência de reuso (proposta original)

- Chunk vazio mantém o slot com uma flag; o pool o reusa preferencialmente sob pressão.
- Vantagens: nenhum feedback novo (a flag vive no header GPU que o builder já lê).
- Desvantagens: o slot continua ocupado (memória intacta), o builder dispatch por frame continua, e a "preferência" só se manifesta sob pressão — economia marginal perto da Opção A.

### Opção C — Atalho CPU "provavelmente vazio"

- A CPU marca como vazio, sem gerar, chunks acima do teto máximo do worldgen (y > 47 p/ o gerador atual).
- Vantagens: economiza também a geração.
- Desvantagens: acoplado ao gerador (mods/novos geradores quebram a garantia); duas fontes de verdade para "vazio". Melhor como complemento futuro, nunca como mecanismo único.

## Decisão

**Opção A** — estado `EMPTY` virtual sem slot: feedback das flags do pack por binding 18, liberação imediata do slot na conclusão (B1), edição via materialização com o pending do E1, vizinhos como `NEIGHBOR_SLOT_INVALID` (ar) sem mudança de shader de render. Opção C registrada como backlog complementar. Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-10.

## Consequências

- Contrato VS-00 revisado mais uma vez: binding 18 (`chunk_result_flags`, host-visible, RW) no descriptor set do motor de voxels.
- `ve_publish_visible` passa a publicar só `CACHED`/`RENDERABLE` com slot (EMPTY nunca); a condição de vizinho passa a exigir slot materializado — comportamento de render idêntico (ar lê zero de qualquer forma).
- Contadores novos (chunks EMPTY ativos, slots economizados) alimentam log/observabilidade.
- Backlog ganha: vacated-by-edit → EMPTY; atalho provably-empty; save trata EMPTY como "sem dados".

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-10 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-10.
