# Motor de Voxels — Transferência de Conhecimento para Kimi Code CLI

> Documento de handover. Coloque este arquivo (ou o conteúdo dele dividido) na raiz do repositório como contexto permanente dos agentes do Kimi Code.
> Data de corte: 2026-11-03.

---

## 1. Visão do Projeto

Motor de voxels moderno com filosofia **GPU-driven / data-driven**:

- **Vulkan 1.4** (timeline semaphores, Sync2)
- **Host:** Odin (`voxel.odin`)
- **Shading:** Slang (`voxel.slang`)
- **Pipeline:** compute (`generate_voxels`, `pack_chunk`) → task shader (culling + payload) → mesh shader (geometria genérica por templates) → fragment (triplanar)
- Sem draw calls tradicionais de vértices; geometria nasce na GPU a partir de dados.

## 2. Modelo de Dados (constantes e layouts)

| Item | Valor |
| --- | --- |
| Slots fixos de chunks | 4096 |
| Tamanho do chunk | 32³ voxels (32768) |
| Brick | 4×2×4 voxels = 32 bits (1 word de bitmask) |
| Coarse cells | 8³ por chunk |
| Paleta | 8 planos × 256 entradas/chunk; **slot 0 da paleta = AR (sempre)** |
| `OCCUPANCY_WORDS_PER_CHUNK` | **1090** (1024 bitmask + 2 coarse + 64 subdivisão Caminho B) |
| `ChunkHeader` | **2064 B** (inclui `refcount[256]`) |
| `BlockDefinition` | 48 B std430 (`mesh_template_index`, `rotation`, pbr, emissão…) |
| `VisibleChunk` | 48 B (com `neighbor_slots[6]`) |
| PushConstants | 88 B (inclui `edit_job_offset`) |
| Task payload | 2048 entradas ≈ 8,2 KB (< 16 KB limite) |
| Orçamento mesh shader | **256 vértices / 192 triângulos por workgroup, garantido por construção** |

**Regra inegociável da engine:** voxel = 1 unidade³ sempre. Objetos maiores são divididos em múltiplos voxels-parte.

## 3. Funcionalidades Implementadas (estado do código)

### B1–B4, B9 — bugs corrigidos

- **B1 (crítico):** ciclo de vida de slots — geração por slot anti-ABA, claim atômico do worker sob `queue_mutex`, aposentadoria dual (timeline compute p/ GENERATING, gráfica p/ CACHED/RENDERABLE). `submitted_mutex` removido.
- **B2 (alto):** faces entre chunks em dobro — `VisibleChunk.neighbor_slots[6]`, CPU publica por frame, `is_voxel_solid` redireciona fronteira ao vizinho via TaskPayload.
- **B3 (alto):** `pack_chunk` implementado em 4 fases (ocupação+presença → coarse+prefixo popcount → paleta → planos); rank por prefixo; overflow → `CHUNK_FLAG_PALETTE_OVERFLOW=2` + `SpecialVoxelRecord`.
- **B4 (médio):** worker drena até 16 tarefas/claim por prioridade; dispatches generate (4,4,4·N) e pack (N,1,1); 1 claim = 1 lote = 1 valor de timeline.
- **B9 (alto):** `generate_voxels` corrigido para `numthreads(8,8,8)`, `job = thread_id.z/32` (antes só 8192 de 32768 voxels/chunk escritos e chunks 8..N-1 do lote zerados).

### Caminho B — templates de malha data-driven

- `BlockDefinition.mesh_template_index` → tabela global `MeshTemplate` em SSBO (binding 10; vértices f32x3 em [0,1]³ no binding 11; triângulos packed u32 no binding 12; tri = `v0|v1<<8|v2<<16|face_culling<<24`, face 0..5 = culpável, 7 = nunca).
- `BlockDefinition.rotation` (0..3, yaw 90°) gira vértices e faces no shader (`ROTATED_FACE`).
- Built-ins: 0=vazio (AR), 1=cubo, 2=planta. Mods registram via `validate_template` (verts≤32, worst_case_tris≤24).
- Orçamento garantido por **subdivisão de brick**: pack soma worst_case_tris e grava 2 bits/brick; task shader despacha 1/2/4 mesh groups (payload entry = `brick | parte<<10 | subd<<12`). Mesh shader 100% genérico.

### E1 — edição de voxels bufferizada

- API agnóstica: `request_voxel_edit(world_voxel, block_id)`; dedup "última escrita vence"; flush a cada `EDIT_FLUSH_INTERVAL_MS=100` (0 = todo frame; `force_next_flush`).
- Flush agrupa por chunk (`EditChunkJob` 16B), despacha `apply_voxel_edits` (1 workgroup × 128 threads/chunk) **no command buffer do frame, antes do render pass**, barreira COMPUTE→TASK|MESH — malha reflete no mesmo frame.
- Só chunks CACHED/RENDERABLE; demais ficam em `pending` e reintegram. Tetos: 4096 edições/flush, 256 chunks/flush, 1024 edições/chunk.
- Ring host-visible de 2 frames (bindings 13/14/15); feedback lido 2 frames depois.
- `refcount[256]` no header: alocação de slot de paleta por CAS, tombstones em hash de 512 buckets, `plane_count` só cresce no flush, flag EMPTY recalculada (task shader dá early-out), bits de subdivisão recomputados. `wait_compute` do submit gráfico inclui estágio COMPUTE_SHADER. Chunks com PALETTE_OVERFLOW são somente-leitura.

### C2 — mirror CPU-side

- Verdade = worldgen + journal do E1; GPU e RAM são views materializadas convergentes.
- `ChunkPage` 32³ ~68,1 KiB: bitmask `solid[1024]u32` + ids densos `u16` SEM paleta, **layout y-contíguo `y | z<<5 | x<<10` (DIFERENTE do scratch GPU x-contíguo)**.
- `ChunkGenerationJob` 32B com `mirror_ring_slot`; binding 16 `mirror_export_ring` (64 slots × 64 KiB = 4 MiB host-visible+coherent; requer `storageBuffer16BitAccess`).
- **O generate escreve DIRETO no ring host-visible — a escrita do shader É o readback** (sem vkCmdCopyBuffer).
- Bolha de simulação `RADIUS_SIMULATION=5` (independente do render); handler materializa com `WaitSemaphores(0)` como acquire host; replay de `page.pending`.
- Retry: `mirror_service_retries` todo frame; tarefas `export_only` em fila separada (worker: 1 por lote, SEM pack — repackar apagaria edições).
- Descarte: `mirror_forget_chunk`; exports EM VOO só liberados pelo handler de conclusão (anti-ABA coord+geração — **NUNCA liberar slot de ring em voo**).
- Pool 768 páginas (~50 MiB, endereços estáveis) + `map[ChunkCoordinate]^MirrorChunkPage`.
- API tri-state: `voxel_get`/`voxel_is_solid` → `(amostra, ok)`; `mirror_column_ground`; `mirror_request`.

## 4. TODOs de Integração Pendentes (marcados no código)

1. **E1:** criar os 3 buffers do ring de edição (jobs 8KiB + edits 32KiB + results 32KiB × 2 frames), `edit_pipeline`, e `chunk_headers` com 2064 B.
2. **Caminho B:** criar os 3 buffers device-local de templates no init e popular built-ins (cubo, planta).
3. **C2:** criar buffer do binding 16 e habilitar `storageBuffer16BitAccess` nas device features.

## 5. Backlog de Bugs Conhecidos

| ID | Sev | Descrição | Sugestão |
| --- | --- | --- | --- |
| B5 | médio | Raio de geração 12 (≈7238 chunks) > 4096 slots; alocação lexicográfica | raio ~9 ou ~8k slots — **próximo candidato** |
| B6 | médio | Plantas sem alpha-test; pipeline precisa `CULL_MODE_NONE` (obrigatório p/ face tag 7 do Caminho B) |  |
| B7 | médio | "PBR" não implementado: roughness/metallic nunca amostrados (só Lambert + emissão) |  |
| B8 | baixo | Overflow int32 em `calculate_squared_distance` | usar i64 |

## 6. Melhorias de Perf/Arquitetura Pendentes

- Worker bloqueia em `WaitSemaphores`; fila de prioridade por varredura linear → usar heap (`core:container/priority_queue` do Odin).
- Mesh groups de 32 threads subutilizam AMD; scratch denso 131 KB/chunk ida+volta → fundir generate+pack.
- Frustum culling é stub; sem occlusion/LOD/transparência.
- Planos da paleta alocados no máximo (78% da memória do slot) → alocação adaptativa por `plane_count`.
- Falta readback GPU→CPU genérico (E1 tem só edit_results) e persistência de mundo (edições morrem no unload; pendings sem TTL).
- Camera-relative rendering; fallback clássico p/ GPUs sem `VK_EXT_mesh_shader` (não é core no 1.4); consultar `VkPhysicalDeviceMeshShaderPropertiesEXT` em runtime.
- Command pool precisa `RESET_COMMAND_BUFFER_BIT`; caminho de leitura p/ `SpecialVoxelRecord`.

## 7. Fatos Verificados (não "consertar")

- Visibilidade cross-queue via signal/wait de timeline semaphore está correta.
- Layouts Odin↔Slang consistentes (BlockDefinition 48B std430; header 2064B; push constants 88B).
- Payload task ≈8,2 KB < 16 KB.
- Orçamento 256v/192t garantido por construção (caps de template + subdivisão).

## 8. Convenções do Código

- Invariantes do B1: **1 claim = 1 lote = 1 valor de timeline**; cancelamento/conclusão varrem `tasks[:task_count]`.
- Anti-ABA: coord+geração em todo recurso reciclável (slots de chunk E slots de ring do mirror).
- Simulações Python bit-a-bit são a forma de validar mudanças de shader antes de integrar (11 cenários × 7 invariantes no E1; paridade GPU==mirror em 163.840 voxels no C2).
- Documentos de referência gerados: Arquitetura v3.0 (7 págs), Manual Técnico v3.0 (8 págs), Tutorial (13 págs — **desatualizado: sem E1/C2**).

---

## 9. Estrutura Recomendada do Repositório (para melhor desempenho dos agentes)

```javascript
vulkan-voxel/
├── AGENTS.md                  ← contexto permanente (ver §10)
├── README.md                  ← build, dependências, como rodar
├── docs/
│   ├── arquitetura.md         ← conteúdo da Arquitetura v3.0
│   ├── manual-tecnico.md      ← conteúdo do Manual v3.0
│   ├── decisoes.md            ← ADRs: B1-B9, Caminho B, E1, C2 (problema→solução→motivo)
│   └── backlog.md             ← seção 5 e 6 deste documento
├── src/
│   ├── voxel.odin             ← ou quebrar: main/queue/gpu/mirror/edit
│   └── shaders/
│       ├── common.slang       ← structs, layouts, constantes (fonte única de verdade)
│       ├── generate.slang
│       ├── pack.slang
│       ├── edit.slang
│       ├── task.slang
│       ├── mesh.slang
│       └── fragment.slang
├── tools/
│   └── sim/                   ← simulações Python bit-a-bit (validação pré-integração)
└── tests/
```

### Por quê

- **Arquivos menores por responsabilidade** reduzem o contexto que o agente precisa ler e o risco de edições conflitantes (hoje voxel.odin e voxel.slang são monolíticos).
- **`common.slang` como fonte única** dos layouts: os bugs mais caros do projeto foram divergência de layout Odin↔Slang; com um arquivo só, o agente não "adivinha" offsets.
- **ADRs curtos por decisão** (`decisoes.md`) são o formato que agentes melhor aproveitam: problema→solução→motivo→invariantes.

## 10. AGENTS.md — modelo sugerido

```markdown
# AGENTS.md — Motor de Voxels (Vulkan 1.4 / Odin / Slang)

## Contexto
Motor GPU-driven/data-driven. Leia docs/arquitetura.md antes de alterar pipeline.
Constantes e layouts: src/shaders/common.slang é a fonte única de verdade.

## Regras inegociáveis
1. Voxel = 1 unidade³ sempre. Objetos maiores = múltiplos voxels-parte.
2. Slot 0 da paleta é AR. Nunca reciclar.
3. 1 claim = 1 lote = 1 valor de timeline (B1). Anti-ABA por coord+geração.
4. Nunca liberar slot de ring em voo; só o handler de conclusão libera (C2).
5. Orçamento mesh shader 256v/192t garantido por subdivisão — não assumir culling direcional.
6. Chunk com CHUNK_FLAG_PALETTE_OVERFLOW é somente-leitura.
7. Layout do mirror é y-contíguo (y|z<<5|x<<10); o scratch GPU é x-contíguo. Não misturar.

## Workflow
- Mudança de shader → escrever/estender simulação Python em tools/sim/ antes de integrar.
- Marcar integrações pendentes com TODO(E1)/TODO(B)/TODO(C2) (convenção existente).
- Não atualizar docs/ sem atualizar o código correspondente (o Tutorial está desatualizado — conhecido).

## Comandos
- Build: <preencher>
- Simulações: python3 tools/sim/<arquivo>.py
```

## 11. Dicas de uso do Kimi Code neste projeto

1. **Peça uma tarefa por vez, referenciando IDs** ("implementar B5", "fechar o TODO(C2) do binding 16") — o vocabulário B1–B9/Caminho B/E1/C2 está neste documento e deve ir para o AGENTS.md/backlog.md.
2. **Sempre exija a simulação Python** antes de aceitar mudança de shader — é a prática que validou E1 e C2.
3. **Para refactors grandes (quebrar voxel.odin), peça primeiro um plano de split** com a lista de símbolos por arquivo; revise antes de executar.
4. **Cole o erro completo do compilador** (Odin/Slang) ao iterar — os layouts std430 e as capabilities (`storageBuffer16BitAccess`, mesh shader props) são as fontes mais prováveis de erro.
5. **Atualize o backlog.md ao fechar cada item** para manter o contexto dos agentes honesto em sessões futuras.