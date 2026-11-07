---
id: ADR-P1
titulo: Plantas — alpha-test e spawn determinístico
tipo: decisao
status: aceita
specs_afetadas: [VS-14]
ultima_atualizacao: 2026-11-07
---

# ADR-P1 — Plantas: alpha-test e spawn determinístico

## Contexto

Backlog B6: plantas renderizam opacas (sem alpha-test) e a pipeline usa `CULL_MODE_NONE`. O mantenedor quer fechar B6 e, junto, introduzir o **bloco planta** no registro (malha em X reaproveitando o formato da planta built-in), com spawn no worldgen decidido por **hash determinístico da coluna (x,z)** e probabilidade de 10%.

Decisões necessárias: técnica de transparência (cutout vs blending), onde a planta nasce (no voxel acima da grama), e como o alpha-test entra no fragment sem quebrar o caminho UV/triplanar da VS-11.

## Requisitos relacionados

- REQ-PLT-01..05 e REQ-SIM-11 da [[VS-14-plantas-alpha-test-spawn|VS-14]].

## Opções

### Opção A — Alpha-test cutout (discard) + planta no voxel acima da grama + hash por coluna

- **Transparência:** blocos com flag `transparente` (`BlockDefinition.flags` bit 0, que já existe) descartam fragmentos com `albedo.a < 0.5` no fragment, após a amostragem (caminho UV da VS-11 e fallback triplanar). Cutout opaco: sem blending, sem ordenação, pipeline inalterada — `CULL_MODE_NONE` **permanece** (as duas faces das cruzes em X são necessárias). O JSON de assets ganha `"transparent": true` por bloco.
- **Spawn:** o worldgen decide por coluna: hash u32 determinístico de (x_mundo, z_mundo) (wang hash, documentado) < 10% → o voxel `y = altura+1` (acima da grama) recebe o id da planta (4). Puro função de (x,z) → consistente entre chunks vizinhos (a planta na fronteira nasce nos dois chunks que a contêm). Heightmap da VS-13 exporta `altura+1` nessas colunas (topo sólido real).
- Vantagens: fecha B6 com o caminho de menor risco (descarte é compatível com depth-first opaco); planta é dado (mesh/UV/tags 7 no JSON, textura RGBA com alpha); contrato worldgen vira ids 1–4 (validado no loader, fallback built-in cobre).
- Desvantagens: sem translucidez (vidro fica para blending posterior); borda dura no recorte (sem AA de alpha — aceitável em voxel).

### Opção B — Blending com ordenação por profundidade

- Transparência real. Exige ordenação de fragmentos (OIT ou ordenação por chunk), mudança de pipeline e contratos de render — desproporcional para folhagem e fora do "simples" do pedido.

### Opção C — Geometria recortada (sem textura alpha)

- Modelar as lâminas da planta como geometria sólida (sem alpha). Multiplica triângulos e perde o benefício do cutout; contraria o Caminho B (a textura é dado).

## Decisão

**Opção A** — alpha-test cutout (discard condicional à flag `transparente`, pipeline inalterada, `CULL_MODE_NONE` permanece), planta no voxel acima da grama decidido por hash determinístico da coluna (x,z) com 10%, heightmap exportando altura+1, contrato de ids 1–4. Ratificada pelo mantenedor em 2026-11-07, junto à aprovação da VS-14.

## Consequências

- Shaders: `generate_voxels` (hash + planta + heightmap com planta) e `shade_voxel` (discard condicional à flag) — sim antes da integração (REQ-SIM-11).
- Contrato do worldgen: ids 1–4 exigidos no JSON (planta = 4); fallback sem assets ganha id 4 (template cruz built-in 2 + camada de paleta).
- B6 sai do backlog quando a VS-14 fechar; blending/translucidez e AA de alpha ficam como item novo no backlog.

## Histórico

- 2026-11-07 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-14 até a ratificação do mantenedor.
- 2026-11-07 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-14.
