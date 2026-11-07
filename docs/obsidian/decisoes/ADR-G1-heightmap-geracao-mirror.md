---
id: ADR-G1
titulo: Heightmap na geração e no mirror
tipo: decisao
status: aceita
specs_afetadas: [VS-13, VS-04]
ultima_atualizacao: 2026-11-06
---

# ADR-G1 — Heightmap na geração e no mirror

## Contexto

O `generate_voxels` hoje cria os dois estados `fnl_state` (struct grande, `fnlCreateState` + ajustes) **por voxel** e avalia o ruído 2× por voxel — 65.536 avaliações por chunk — quando o heightmap só depende de (x,z): 1.024 colunas bastariam (estimativa original: redução de 32×; **medido na implementação: 8×** — 8.192 avaliações/chunk, pois as 4 fatias-y de um mesmo (x,z) recalculam a mesma coluna, uma vez que o groupshared é por workgroup e o dispatch/thread mapping ficaram inalterados). O mantenedor quer: (1) manter/reusar o state do ruído em vez de instanciá-lo por voxel; (2) uma matriz 2D de heightmap por chunk, **também enviada ao mirror**. No mirror, o heightmap torna O(1) a operação mais comum de gameplay (scan de chão, hoje um walk da coluna vertical).

## Requisitos relacionados

- REQ-GEN-01/02, REQ-MIR-01..04 e REQ-SIM-10 da [[VS-13-heightmap-geracao-mirror|VS-13]]; emenda a [[VS-04-mirror-c2|VS-04]] (formato da ChunkPage e do ring).

## Opções

### Opção A — Heightmap em groupshared por workgroup + binding 20 separado + ChunkPage com heights

- **Geração:** cada workgroup (8×8×8) calcula as alturas das suas 64 colunas (x,z) uma única vez — threads com y-local 0 avaliam o ruído (2 evals/coluna), guardam num `groupshared uint16[8][8]`, barrier, e os 512 threads do workgroup leem. Estados `fnl_state` criados uma vez por workgroup (não por voxel). Mesmos inputs na mesma função → saída **bit a bit idêntica** (equivalência pura, sem mudança de worldgen).
- **Mirror:** novo binding 20 (`mirror_heightmap_ring`, 64 slots × 1.024 u16 = 2 KiB, host-visible — ring paralelo ao denso, mesmo slot). `ChunkPage` ganha `heights[1024]u16` (semântica: y do sólido mais alto da coluna; `0xFFFF` = coluna vazia), preenchido no materialize; o journal do E1 mantém o campo em `mirror_page_apply` (colocar acima → sobe; remover no topo → rescan de 32; caso contrário inalterado).
- Vantagens: cumpre os dois pedidos com equivalência garantida; groupshared é trivial (128 B/workgroup); ring separado não toca o layout do denso; consumo O(1) no mirror.
- Desvantagens: ChunkPage cresce ~2 KiB (68,1 → 70,2 KiB; +1,5 MiB no pool de 768 páginas — residual); journal do mirror ganha um caso de manutenção.

### Opção B — Kernel separado de heightmap (dispatch extra gravando scratch global)

- Um passo compute prévio calcula 32×32 alturas por chunk num buffer global; o generate lê. Mais regular, mas exige dispatch extra, sincronização e scratch novo — complexidade desproporcional para 64 colunas por workgroup.

### Opção C — Só reusar o state (groupshared), sem heightmap

- Mata a instanciação por voxel mas mantém as 65.536 avaliações; não envia matriz ao mirror — não cumpre o pedido.

## Decisão

**Opção A** — heightmap em groupshared por workgroup (colunas calculadas 1×, estados de ruído 1×/workgroup) + binding 20 + ChunkPage com heights mantido pelo journal. States em buffer foram avaliados e descartados (custo de leitura global por avaliação, sem ganho). Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-13.

## Consequências

- `voxel.slang` (generate) reestruturado; binding 20 novo (revisão da VS-00); ChunkPage e ring do mirror emendados na VS-04; `DESCRIPTOR_SET_BINDING_COUNT` 20 → 21.
- O `apply_voxel_edits` (GPU) **não** mantém heightmap: pelo princípio C2, o ring alimenta só o materialize, e o journal é a verdade — o mirror mantém o próprio heightmap. Correto por construção.
- Sim antes da integração (REQ-SIM-10): indexação do heightmap no mapeamento de threads (com mock noise) e manutenção do heights pelo journal (mirror_sim).
- Ganho medido pela telemetria VS-05 (tempo do generate no CSV, antes/depois na mesma pose).

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-13 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor** (states em groupshared; alternativa de buffer avaliada e descartada — ver nota no REQ-GEN-02 da spec); status `aceita`; desbloqueia a VS-13.
