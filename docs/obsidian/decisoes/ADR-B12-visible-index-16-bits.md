---
id: ADR-B12
titulo: visible_index de 16 bits no item da fila de trabalho
tipo: decisao
status: aceita
specs_afetadas: [VS-09, VS-02, VS-08]
ultima_atualizacao: 2026-11-06
---

# ADR-B12 — visible_index de 16 bits no item da fila de trabalho

## Contexto

O item de trabalho da fila global (VS-02/ADR-B10) empacota em u32: `visible_index (12b) | brick (10b)<<12 | parte (2b)<<22 | subdivisão (2b)<<24` — 26 bits usados, 6 livres. Esse 12 bits é o limite de formato da VS-08: visíveis ≤ 4.096, logo `vision ≤ 9` (r=10 ⇒ ≈4,2 mil chunks na esfera). Com a configuração via INI (VS-08), o mantenedor quer liberar raios de visão maiores: usar 16 bits para o `visible_index` (30 de 32 bits, sobrando 2) e elevar o cap de formato para `vision ≤ 25` (esfera de r=25 ≈ 65 mil < 65.535; r=26 estoura).

## Requisitos relacionados

- REQ-WID-01..03 e REQ-SIM-06 da [[VS-09-visible-index-16|VS-09]]; amenda REQ-CFG-03 da [[VS-08-config-ini-provisionamento|VS-08]] e o contrato do item da [[VS-02-task-mesh-templates|VS-02]].

## Opções

### Opção A — visible_index 16 bits (cap vision ≤ 25)

- Novo layout: `visible_index (16b) | brick (10b)<<16 | parte (2b)<<26 | subdivisão (2b)<<28`. Libera vision 10–25; o limite prático passa a ser VRAM da fila de trabalho (linear em visíveis: ≈535 MiB em vision 25) e custo por frame — ambos já governados pela validação de máquina da VS-08 (budget × 0,9) e escolha do usuário.
- Vantagens: difusão mínima (3 pontos de encode/decode: `pack_work_item` no Slang, decode no mesh, espelho na simulação + regra de validação); nenhuma mudança de push constant nem de estrutura de memória; resolve o backlog registrado na ADR-C1.
- Desvantagens: contrato do item muda pela segunda vez (histórico carrega); sobram só 2 bits de reserva (hoje 6).

### Opção B — Manter 12 bits

- Vision continua limitado a 9; raios maiores exigiriam LOD/culling mais agressivo para serem úteis de qualquer forma.
- Vantagens: nenhuma mudança.
- Desvantagens: não atende o pedido do mantenedor; o cap de formato vira impedimento real para cenários de vista longa.

### Opção C — Item de 64 bits

- `visible_index` de 24+ bits, zero preocupação de layout.
- Desvantagens: dobra a largura da fila (≈1 GiB em vision 25), muda strides e offsets em três shaders — custo desproporcional ao benefício.

## Decisão

**Opção A** — `visible_index` de 16 bits (novo layout 16|10|2|2, cap de formato `vision ≤ 25`), máscaras/shifts atualizados nos três pontos de encode/decode, validação e docs revisados. Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-09.

## Consequências

- REQ-CFG-03 da VS-08 é emendada: a regra de formato vira `1 ≤ vision ≤ 25` (visíveis ≤ 65.535), com mensagem de erro correspondente; as demais regras (histerese, máximo de slots, máquina) inalteradas.
- A consequência da ADR-C1 ("alargar o empacotamento para 16 bits" como backlog) é resolvida por esta decisão.
- Aritmética do ring verificada para o pior caso: 2 × (8 + 65.535 × 1.024) words ≈ 134 M < 2³² — nenhum estouro u32.
- Brick permanece 10 bits (1.024 bricks/chunk é geometria fixa); parte/subdivisão permanecem 2 bits.

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-09 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-09.
