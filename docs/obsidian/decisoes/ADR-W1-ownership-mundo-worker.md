---
id: ADR-W1
titulo: Ownership do mundo na worker thread
tipo: decisao
status: aceita
specs_afetadas: [VS-18]
ultima_atualizacao: 2026-11-08
---

# ADR-W1 — Ownership do mundo na worker thread

## Contexto

Análise da captura `tracy_view_22.tracy` e da VS-17 mostraram que a main thread carrega ~7 ms/frame de trabalho de mundo (promote/publish ~2,4 ms, mirror service ~2,7 ms, completions ~0,5 ms, streaming ~1-6 ms) além do render (~4 ms). O mantenedor aprovou a **Opção A**: migrar o ownership do mundo para a worker thread, que hoje passa grande parte do tempo ociosa esperando lotes.

## Decisão (Opção A, aprovada pelo mantenedor em 2026-11-08)

A worker vira a dona do mundo: `active_chunks` (streaming incremental, completions/B1, promote/publish, materialização E1, mirror service). A main fica com: input/eventos, espera do slot publicado, gravação do CB e present — alvo de ~4-5 ms/frame.

Pontos de desenho fixados:

- **Handoff do frame:** a main publica pedido (atomic: `frame_index` + `camera_chunk`); a worker produz promote+publish direto no ring `visible_chunks` (host-visible, 2 slots) e sinaliza; a main espera. Reescrita de slot só após a timeline gráfica confirmar que o uso anterior completou (mesma garantia do ring desde a VS-02, lida na worker via `vkGetSemaphoreCounterValue` não-bloqueante).
- **Liberdade de deadlock:** as dependências apontam para trás — o publish do frame N só depende do slot do frame N-2 (submetido há duas frames); a main só depende do publish do frame N. Sem ciclo.
- **Edições (E1):** intake na main (fila protegida por mutex existente); pipeline completo na worker (dedup, journal do mirror, materialização VS-10, flush staging); a main consome o staging para `edit_ring_write` com o mesmo mutex.
- **Mirror:** journal/materialize/service na worker; APIs de leitura (`voxel_get`, `mirror_height_get`) continuam chamáveis da main — sincronização de páginas auditada.
- **Invariantes intocados:** regras 3 e 4 do AGENTS (B1: 1 claim = 1 lote = 1 timeline; só o handler de conclusão libera ring) — apenas a thread que executa muda; convergência C2 (mesma sequência de edições nos dois lados).

## Consequências

- Frame da main: ~11 ms → ~4-5 ms; a worker passa a ter laço por frame (acorda a cada frame; publish pipelined no pedido da main).
- Fast-exit inalterado (worker morre com o processo); `--full-teardown` mantém stop+broadcast+join da worker antes dos waits (ordem do BLK-28).
- Risco concentrado em sincronização do handoff (frame/edições) — mitigado pelos ACs de stress e validation layers.

## Histórico

- 2026-11-08 — Decisão registrada como aceita (Opção A citada e aprovada pelo mantenedor na íntegra); desbloqueia a VS-18.
