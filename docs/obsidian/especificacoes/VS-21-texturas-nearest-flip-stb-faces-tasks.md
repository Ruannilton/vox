---
id: VS-21-TASKS
titulo: Tarefas — nearest, flip Y, stb_image e multi-face
tipo: tarefas
spec: VS-21
status: concluida
ultima_atualizacao: 2026-11-08
---

# VS-21 — Tarefas de implementação

ADR-T5 aceita e VS-21 aprovada (com emenda de 6 faces). Etapas VS-21-IMPL-01..06 **concluídas em 2026-11-09** — atenção: a coluna da IMPL-03 descrevia o desenho pré-emenda; a implementação seguiu a emenda aprovada (`albedo_faces[6]`, eixo dominante). Ver ACs e histórico da spec.

| ID | Etapa e alterações | Requisitos / ACs | Validação obrigatória |
| --- | --- | --- | --- |
| VS-21-IMPL-01 | **stb_image e flip.** Trocar decoder por `load_from_memory(...,4)`, validar/liberar com `image_free`, implementar `flip_rows` stride RGBA e integrar antes das camadas; zone `assets_texture_decode`. Verificar linkage dos scripts sem adicionar flags desnecessárias. | REQ-TEX-01/02/09; AC-01 | Pixel sim com cantos/rows, RGB/RGBA, dupla inversão e erro de decode; `run.bat` e `run_tracy.bat` linkam com a lib da distribuição; sem vazamento no teardown. |
| VS-21-IMPL-02 | **Sampler NEAREST.** Alterar mag/min/mipmap nos dois caminhos de criação, mantendo REPEAT, um mip e maxLod=0; dummy PBR acompanha. | REQ-TEX-03; AC-02 | Build/validation limpos; inspeção dos CreateInfo; captura ampliada com contraste sem blur; dummy PBR válido. |
| VS-21-IMPL-03 | **Sims, loader multi-face e shader.** Primeiro estender sims de face/UV/triplanar e flip. Depois implementar schema string/objeto no loader+validador, `albedo_texture_top` no antigo padding e seleção por normal.y>0,5. Notas VS-02/VS-12. | REQ-TEX-04..06/08; AC-01/03/04 | Sims novas e antigas verdes antes do shader; bateria completa de schema/refs; assert 48 B; Slang + `spirv-val`; planta/highlight/alpha-test sem regressão. |
| VS-21-IMPL-04 | **Assets e fallback.** Grama id 1 com objeto top=grama/demais=terra; demais blocos strings (normalizadas); built-in equivalente. | REQ-TEX-07; AC-03/04 | Validador no JSON real; sessão JSON e fallback com grama correta; capturas +Y/−Y/laterais e bloco rotacionado seguem +Y mundial. |
| VS-21-IMPL-05 | **Instrumentação e validação integrada.** Completar contadores/zones, docs arquitetura/manual/tracking e replay de gameplay/edições para cobrir UV/triplanar/planta. | REQ-TEX-08/09; AC-01..06 | Builds default/Tracy; evidência visual e readbacks; zero VUIDs; custo de startup/render observável no trace. |
| VS-21-IMPL-06 | **Stress, captura e fechamento.** 5× por build com `--full-teardown`; captura `bin/debug/<version>/tracy/VS-21_texturas_nearest_flip_stb_faces.tracy`; comparação por subagente K2.8 thinking low contra VS-20; evidências nos ACs e commit com nome da spec. | AC-01..06 | 10/10 sem VUIDs/threading/deadlock; captura íntegra e comparação registrada; validação verificada e working tree limpo. |
