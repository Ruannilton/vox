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

    VS00 --> VS01
    VS01 --> VS02
    VS02 --> VS03
    VS03 --> VS04
    VS04 --> VS05
    VS02 --> VS06
    VS06 --> VS07
    VS07 --> VS08
    VS08 --> VS09
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

## Decisões incorporadas

- ADR-B5: VS-01 usa visão `8`, geração `8`, descarga `16` e 4.096 slots.
- ADR-B6: a correção visual de plantas é trabalho posterior e não integra o aceite de VS-02.
- ADR-B7: VS-02 usa Lambert + emissão; PBR é melhoria futura.
- ADR-B10: VS-02 renderiza sem estágio task — builder compute na fila gráfica anexa itens numa fila de trabalho global e o draw é mesh-only indireto (o payload task→mesh não era entregue pelo driver do ambiente).
- ADR-B11: VS-06 deriva os 6 planos do frustum na GPU no builder (Gribb-Hartmann) a partir da `view_projection_matrix` já presente nos push constants — nenhum contrato novo de memória; culling conservador em dois níveis (early-out de chunk + por brick).
- ADR-I1: VS-07 usa bus central de eventos (callbacks produzem, loop drena por frame) com gravação JSONL e replay best-effort em tempo de parede relativo ao início da aplicação — sem polling de teclas; determinismo bit-exato fica em backlog.
- ADR-C1: VS-08 carrega os parâmetros de streaming/compute de um INI e provisiona os recursos em runtime — capacidades derivadas das esferas (visíveis/slots/páginas), validação de coerência + limites de formato (12 bits do visible_index) e de máquina (memory budget da VS-05); push constant estendido para 92 B.
- ADR-B12: VS-09 amplia o visible_index do item da fila para 16 bits (cap de formato vision ≤ 9 → ≤ 25), resolvendo o backlog da ADR-C1; contrato do item da VS-02 emendado nos três pontos de encode/decode (Slang pack, decode do mesh, sim).

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
