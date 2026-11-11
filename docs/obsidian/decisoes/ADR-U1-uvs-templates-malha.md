---
id: ADR-U1
titulo: UVs nos templates de malha
tipo: decisao
status: aceita
specs_afetadas: [VS-11, VS-02]
ultima_atualizacao: 2026-11-06
---

# ADR-U1 — UVs nos templates de malha

## Contexto

O shading amostra o albedo por **triplanar** sobre a posição mundo (REQ-SHADE-02/03 da VS-02, escolhido por funcionar para qualquer malha sem unwrap). O mantenedor quer migrar para **UVs por vértice** vindas dos templates: blocos com shapes customizados e texturas reais futuras precisam de mapeamento por face (ex.: grama no topo × terra na lateral, atlas), que o triplanar não expressa (ele mistura três projeções e suaviza fronteiras). Com o fim do payload task→mesh (ADR-B10), não há limite de bytes no transporte — `MeshVertex` é saída do mesh shader, e o limite de componentes de saída (`maxMeshOutputComponents`, tipicamente 128/vértice) sobra largamente (hoje 8, com UV 10).

## Requisitos relacionados

- REQ-UV-01..04 e REQ-SIM-08 da [[VS-11-uvs-templates|VS-11]]; amenda à REQ-SHADE-03 da [[VS-02-task-mesh-templates|VS-02]].

## Opções

### Opção A — UV como atributo de template, com fallback triplanar (sentinela)

- `MeshVertex` ganha `uv: float2 (TEXCOORD0)`. Templates ganham pool de UVs (`template_uvs`, binding 19, paralelo a `template_vertices`) e o `MeshTemplate` um campo `uv_offset`. Built-ins (cubo/planta) recebem UVs ([0,1]²). Template **sem** UV emite a sentinela `(-1,-1)`; o fragment amostra por UV quando presente e cai no triplanar atual caso contrário — mods procedurais sem unwrap continuam funcionando. Normais seguem por derivadas (REQ-SHADE-02, inalterado).
- Vantagens: caminho UV definitivo sem quebrar nada existente; fallback gratuito; orçamento mesh shader inalterado (atributo não adiciona vértice/triângulo — regra 5 do AGENTS.md preservada).
- Desvantagens: dois caminhos de amostragem no fragment (branch simples por sentinela); contrato de templates cresce (pool + offset).

### Opção B — UV obrigatória, remover triplanar

- Todo template deve ter UV; triplanar deletado.
- Vantagens: um caminho só.
- Desvantagens: remove o "funciona sem unwrap" que o triplanar dava de graça a mods procedurais; quebra a promessa da REQ-SHADE-03 sem ganho imediato (a paleta atual é cor sólida — UV e triplanar produzem imagem idêntica).

### Opção C — Manter só triplanar

- Zero mudança; texturas por face/atlases ficam impossíveis; shapes customizados com grão direcional ficam limitados.

## Decisão

**Opção A** — UV como atributo de template com fallback triplanar via sentinela: binding 19 (`template_uvs`), `MeshVertex` +`TEXCOORD0`, built-ins com UV, sentinela `(-1,-1)` para templates sem UV. Ratificada pelo mantenedor em 2026-11-06, junto à aprovação da VS-11.

## Consequências

- Contratos: binding 19 (`template_uvs`), `MeshVertex` 8→10 componentes, `MeshTemplate.uv_offset` (reusa padding), revisão da VS-00 (nota no histórico), emenda da REQ-SHADE-03 da VS-02 ("caminho índice→textura→UV; triplanar vira fallback").
- **Rotação yaw × UV** fica registrada como questão aberta: hoje o mesh shader rotaciona as posições; UVs de templates com texturas direcionais exigem unwraps simétricos à rotação ou templates por rotação — com a paleta sólida atual o efeito é nulo. Backlog, não bloqueia.
- Simulação estendida antes da integração (REQ-SIM-08): bounds de UV, sentinela/fallback, paridade de cor sobre paleta sólida.

## Histórico

- 2026-11-06 — Decisão registrada como pendente, com recomendação da Opção A; bloqueia a aprovação da VS-11 até a ratificação do mantenedor.
- 2026-11-06 — **Opção A ratificada pelo mantenedor**; status `aceita`; desbloqueia a VS-11.
