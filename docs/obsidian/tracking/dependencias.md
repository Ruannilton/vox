# Hierarquia de dependências

As dependências abaixo governam a ordem de aprovação e implementação. Rascunhos posteriores podem ser escritos antecipadamente, mas nenhuma fatia deve começar a ser implementada antes de suas predecessoras estarem concluídas e verificadas.

## Grafo

```mermaid
graph TD
    VS00[VS-00 — Fundação Vulkan]
    VS01[VS-01 — Streaming, generate e pack]
    VS02[VS-02 — Task/mesh e templates]
    VS03[VS-03 — Edição E1]
    VS04[VS-04 — Mirror C2]
    VS05[VS-05 — Telemetria e profiling GPU]
    VS06[VS-06 — Culling de frustum]
    VS07[VS-07 — Eventos de input e replay]
    VS08[VS-08 — Configuração INI e provisionamento]
    VS09[VS-09 — Visible index 16 bits]
    VS10[VS-10 — Chunks vazios virtuais]
    VS11[VS-11 — UVs nos templates]
    VS12[VS-12 — Assets JSON]
    VS13[VS-13 — Heightmap geração/mirror]
    VS14[VS-14 — Plantas alpha-test/spawn]

    VS00 --> VS01
    VS01 --> VS02
    VS02 --> VS03
    VS03 --> VS04
    VS04 --> VS05
    VS02 --> VS06
    VS06 --> VS07
    VS07 --> VS08
    VS08 --> VS09
    VS09 --> VS10
    VS10 --> VS11
    VS11 --> VS12
    VS12 --> VS13
    VS13 --> VS14
```

## Registro normativo

| Item | Depende de | Bloqueada por | Libera |
| --- | --- | --- | --- |
| [[VS-00-fundacao-vulkan|VS-00]] | — | — | VS-01 |
| [[VS-01-streaming-generate-pack|VS-01]] | VS-00 | — | VS-02 |
| [[VS-02-task-mesh-templates|VS-02]] | VS-01 | — | VS-03 |
| [[VS-03-edicao-e1|VS-03]] | VS-02 | — | VS-04 |
| [[VS-04-mirror-c2|VS-04]] | VS-03 | — | Consumidores futuros do mirror |
| [[VS-05-telemetria-profiling|VS-05]] | VS-04 | — | — |
| [[VS-06-culling-frustum|VS-06]] | VS-02 | — | — |
| [[VS-07-eventos-input-replay|VS-07]] | VS-03 | — | — |
| [[VS-08-config-ini-provisionamento|VS-08]] | VS-05 | — | — |
| [[VS-09-visible-index-16-bits|VS-09]] | VS-08 | — | — |
| [[VS-10-chunks-vazios-virtuais|VS-10]] | VS-04 | — | — |
| [[VS-11-uvs-templates|VS-11]] | VS-02 | — | — |
| [[VS-12-assets-json|VS-12]] | VS-11 | — | — |
| [[VS-13-heightmap-geracao-mirror|VS-13]] | VS-04 | — | — |
| [[VS-14-plantas-alpha-test-spawn|VS-14]] | VS-12 | — | — |

## Decisões incorporadas

- ADR-B5: VS-01 usa visão `8`, geração `8`, descarga `16` e 4.096 slots.
- ADR-B6: a correção visual de plantas é trabalho posterior e não integra o aceite de VS-02.
- ADR-B7: VS-02 usa Lambert + emissão; PBR é melhoria futura.
- ADR-B10: VS-02 renderiza sem estágio task — builder compute na fila gráfica anexa itens numa fila de trabalho global e o draw é mesh-only indireto (o payload task→mesh não era entregue pelo driver do ambiente).
- ADR-B11: VS-06 deriva os 6 planos do frustum na GPU no builder (Gribb-Hartmann) a partir da `view_projection_matrix` já presente nos push constants — nenhum contrato novo de memória; culling conservador em dois níveis (early-out de chunk + por brick).
- ADR-I1: VS-07 usa bus central de eventos (callbacks produzem, loop drena por frame) com gravação JSONL e replay best-effort em tempo de parede relativo ao início da aplicação — sem polling de teclas; determinismo bit-exato fica em backlog.
- ADR-C1: VS-08 carrega os parâmetros de streaming/compute de um INI e provisiona os recursos em runtime — capacidades derivadas das esferas (visíveis/slots/páginas), validação de coerência + limites de formato (12 bits do visible_index) e de máquina (memory budget da VS-05); push constant estendido para 92 B.
- ADR-B12: VS-09 amplia o visible_index do item da fila para 16 bits (cap de formato vision ≤ 9 → ≤ 25), resolvendo o backlog da ADR-C1; contrato do item da VS-02 emendado nos três pontos de encode/decode (Slang pack, decode do mesh, sim).
- ADR-V1: VS-10 introduz chunks vazios virtuais — chunk só-ar concluído vira estado EMPTY sem slot (feedback das flags do pack por binding 18, liberação imediata na conclusão B1), nunca publicado/despachado; edição materializa via geração + pending do E1; vizinhos o veem como ar (NEIGHBOR_SLOT_INVALID, B2) sem mudança de shader de render.
- ADR-U1: VS-11 migra o albedo de triplanar para UVs por vértice dos templates (binding 19 template_uvs, MeshVertex +TEXCOORD0, sentinela (-1,-1) → fallback triplanar); orçamento mesh shader inalterado; REQ-SHADE-03 da VS-02 emendada.
- ADR-A1: VS-12 carrega blocos/malhas/texturas de um JSON único no startup — malhas reaproveitáveis por nome, PNG única por bloco em camadas de um Texture2DArray (mesma dimensão exigida), saída formatada nos contratos atuais do pipeline (zero mudança de shader); ausente → fallback built-ins + paleta.
- ADR-G1: VS-13 calcula o heightmap 32×32 uma única vez por chunk (groupshared, threads y-local 0) com estados de ruído 1×/thread-de-coluna (8× menos avaliações — medido; saída bit a bit idêntica) e o exporta ao mirror (binding 20 + campo na ChunkPage, journal do E1 mantém; chão O(1)).
- ADR-P1: VS-14 fecha o backlog B6 com alpha-test cutout (discard condicional à flag `transparente`, pipeline inalterada, CULL_MODE_NONE permanece) e introduz o bloco planta (id 4, malha em X via assets) com spawn por hash determinístico da coluna (x,z), 10% de probabilidade. Emenda 2026-11-07 (pós-validação): a planta é não-sólida — `NON_SOLID` bit 1 de `BlockDefinition.flags` (JSON `"solid": false`); o heightmap exporta o topo sólido (`altura`) e o bitmask `solid` do mirror exclui plantas.

## Dependências transversais a registrar nas specs

Estas relações não alteram a cadeia principal, mas precisam virar contratos explícitos:

- VS-00 deve fornecer as capabilities e a sincronização exigidas por todas as demais.
- VS-01 produz os formatos packed consumidos por VS-02, VS-03 e VS-04.
- VS-02 fornece o ponto de renderização no qual VS-03 aplica a barreira COMPUTE → COMPUTE(builder) | MESH (a fila de trabalho da ADR-B10 eliminou o estágio task).
- VS-03 fornece o journal e o feedback usados por VS-04.
- `common.slang` e os layouts Odin↔Slang são contratos compartilhados; mudanças neles exigem revisão de todas as specs afetadas.

## Regras

1. Referenciar dependências por ID no frontmatter e neste registro.
2. Não criar ciclos; uma dependência circular indica fronteira de módulo ou fatia mal definida.
3. `depende_de` representa dependência de implementação.
4. `bloqueada_por` representa decisão ou questão que impede a aprovação da spec.
5. Ao alterar o grafo, atualizar também as specs afetadas e o [[status|painel de status]].
6. Novas dependências transversais devem indicar o contrato necessário, não apenas o nome do módulo.
