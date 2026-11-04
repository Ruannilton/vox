# Hierarquia de dependências

As dependências abaixo governam a ordem de aprovação e implementação. Rascunhos posteriores podem ser escritos antecipadamente, mas nenhuma fatia deve começar a ser implementada antes de suas predecessoras estarem concluídas e verificadas.

## Grafo

```mermaid
graph TD
    VS00[VS-00 — Fundação Vulkan]
    B5[ADR-B5 — Capacidade do streaming]
    VS01[VS-01 — Streaming, generate e pack]
    B6[ADR-B6 — Culling e alpha-test]
    B7[ADR-B7 — Escopo PBR]
    VS02[VS-02 — Task/mesh e templates]
    VS03[VS-03 — Edição E1]
    VS04[VS-04 — Mirror C2]

    VS00 --> VS01
    B5 -->|bloqueia aprovação| VS01
    VS01 --> VS02
    B6 -->|bloqueia aprovação| VS02
    B7 -->|bloqueia aprovação| VS02
    VS02 --> VS03
    VS03 --> VS04
```

## Registro normativo

| Item | Depende de | Bloqueada por | Libera |
| --- | --- | --- | --- |
| [[VS-00-fundacao-vulkan|VS-00]] | — | — | VS-01 |
| [[VS-01-streaming-generate-pack|VS-01]] | VS-00 | ADR-B5 para aprovação | VS-02 |
| [[VS-02-task-mesh-templates|VS-02]] | VS-01 | ADR-B6 e ADR-B7 para aprovação | VS-03 |
| [[VS-03-edicao-e1|VS-03]] | VS-02 | — | VS-04 |
| [[VS-04-mirror-c2|VS-04]] | VS-03 | — | Consumidores futuros do mirror |
| [[ADR-B5-capacidade-streaming|ADR-B5]] | — | Decisão pendente | Aprovação de VS-01 |
| [[ADR-B6-culling-alpha-test|ADR-B6]] | — | Decisão pendente | Aprovação de VS-02 |
| [[ADR-B7-pbr|ADR-B7]] | — | Decisão pendente | Aprovação de VS-02 |

## Dependências transversais a registrar nas specs

Estas relações não alteram a cadeia principal, mas precisam virar contratos explícitos:

- VS-00 deve fornecer as capabilities e a sincronização exigidas por todas as demais.
- VS-01 produz os formatos packed consumidos por VS-02, VS-03 e VS-04.
- VS-02 fornece o ponto de renderização no qual VS-03 aplica a barreira COMPUTE → TASK|MESH.
- VS-03 fornece o journal e o feedback usados por VS-04.
- `common.slang` e os layouts Odin↔Slang são contratos compartilhados; mudanças neles exigem revisão de todas as specs afetadas.

## Regras

1. Referenciar dependências por ID no frontmatter e neste registro.
2. Não criar ciclos; uma dependência circular indica fronteira de módulo ou fatia mal definida.
3. `depende_de` representa dependência de implementação.
4. `bloqueada_por` representa decisão ou questão que impede a aprovação da spec.
5. Ao alterar o grafo, atualizar também as specs afetadas e o [[status|painel de status]].
6. Novas dependências transversais devem indicar o contrato necessário, não apenas o nome do módulo.
