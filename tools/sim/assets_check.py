#!/usr/bin/env python3
# VS-12 (REQ-VAL-07) — validador offline de assets/blocks.json: schema,
# referências por nome, limites e bounds — sem rodar a engine.
# Uso: python3 assets_check.py <arquivo.json> ; exit 0 = válido, 1 = inválido.
# As mensagens espelham o carregador em src/engine/voxel_assets.odin.

import json
import os
import sys

from png_min import PngError, decode_png

MAX_TEMPLATES = 256
MAX_TEXTURES = 256
MAX_VERTICES = 32
MAX_TRIANGLES = 24
MAX_TEXTURE_DIM = 256
VERTEX_POOL_CAPACITY = 1024
CULL_FACE_NEVER = 7
REQUIRED_BLOCK_IDS = (1, 2, 3)  # contrato do worldgen (grama/terra/pedra)


def fail(msg):
    print(f"ERRO: {msg}")
    return None


def fmt_float(v):
    return f"{v:g}"


def validate(doc, base_dir):
    """Retorna lista de mensagens de erro (vazia = válido)."""
    errors = []
    if not isinstance(doc, dict):
        return ["raiz: esperado objeto com seções 'meshes', 'textures', 'blocks'"]

    meshes = doc.get("meshes", [])
    textures = doc.get("textures", [])
    blocks = doc.get("blocks", [])
    for section, value in (("meshes", meshes), ("textures", textures), ("blocks", blocks)):
        if not isinstance(value, list):
            errors.append(f"seção '{section}': esperado array")
    if errors:
        return errors

    # --- malhas ---
    mesh_names = {}
    mesh_list = []
    if len(meshes) > MAX_TEMPLATES:
        errors.append(f"mais de {MAX_TEMPLATES} malhas (templates)")
    for i, mesh in enumerate(meshes):
        where = f"malha[{i}]"
        if not isinstance(mesh, dict):
            errors.append(f"{where}: esperado objeto")
            continue
        name = mesh.get("name")
        if not isinstance(name, str) or name == "":
            errors.append(f"{where}: campo 'name' ausente ou vazio")
            continue
        where = f"malha '{name}'"
        if name in mesh_names:
            errors.append(f"{where}: nome duplicado")
            continue
        vertices = mesh.get("vertices")
        triangles = mesh.get("triangles")
        uvs = mesh.get("uvs")
        cull_tags = mesh.get("cull_tags")
        if not isinstance(vertices, list) or not vertices:
            errors.append(f"{where}: campo 'vertices' ausente ou vazio")
            continue
        if not isinstance(triangles, list) or not triangles:
            errors.append(f"{where}: campo 'triangles' ausente ou vazio")
            continue
        mesh_names[name] = True
        mesh_list.append(mesh)
        if len(vertices) > MAX_VERTICES:
            errors.append(f"{where}: {len(vertices)} vértices excede o máximo de {MAX_VERTICES}")
        if len(triangles) > MAX_TRIANGLES:
            errors.append(
                f"{where}: {len(triangles)} triângulos excede o máximo de {MAX_TRIANGLES}"
            )
        nv = len(vertices)
        for j, v in enumerate(vertices):
            if (
                not isinstance(v, list)
                or len(v) != 3
                or any(not isinstance(x, (int, float)) or isinstance(x, bool) for x in v)
            ):
                errors.append(f"{where}: vértice {j} malformado (esperado [x, y, z])")
                continue
            if not (0 <= v[0] <= 1 and 0 <= v[1] <= 1 and 0 <= v[2] <= 1):
                errors.append(
                    f"{where}: vértice {j} fora de [0,1]³: ({fmt_float(v[0])}, {fmt_float(v[1])}, {fmt_float(v[2])})"
                )
        for j, t in enumerate(triangles):
            if (
                not isinstance(t, list)
                or len(t) != 3
                or any(not isinstance(x, int) or isinstance(x, bool) for x in t)
            ):
                errors.append(f"{where}: triângulo {j} malformado (esperado [i0, i1, i2])")
                continue
            for idx in t:
                if idx >= nv:
                    errors.append(
                        f"{where}: triângulo {j} índice {idx} fora do range 0..{nv - 1}"
                    )
        if cull_tags is not None:
            if not isinstance(cull_tags, list) or len(cull_tags) != len(triangles):
                errors.append(
                    f"{where}: {0 if not isinstance(cull_tags, list) else len(cull_tags)} cull_tags para {len(triangles)} triângulos"
                )
            else:
                for j, tag in enumerate(cull_tags):
                    if not isinstance(tag, int) or isinstance(tag, bool) or not (0 <= tag <= 5 or tag == CULL_FACE_NEVER):
                        errors.append(
                            f"{where}: cull_tag do triângulo {j} inválido: {tag} (esperado 0..5 ou {CULL_FACE_NEVER})"
                        )
        if uvs is not None:
            if not isinstance(uvs, list) or len(uvs) != nv:
                errors.append(f"{where}: {0 if not isinstance(uvs, list) else len(uvs)} UVs para {nv} vértices")
            else:
                for j, uv in enumerate(uvs):
                    if (
                        not isinstance(uv, list)
                        or len(uv) != 2
                        or any(not isinstance(x, (int, float)) or isinstance(x, bool) for x in uv)
                    ):
                        errors.append(f"{where}: UV do vértice {j} malformado (esperado [u, v])")
                        continue
                    if not (0 <= uv[0] <= 1 and 0 <= uv[1] <= 1):
                        errors.append(
                            f"{where}: UV do vértice {j} fora de [0,1]²: ({fmt_float(uv[0])}, {fmt_float(uv[1])})"
                        )
        # pior caso de triângulos (mesma conta do compute_worst_case_tris)
        tags = cull_tags if isinstance(cull_tags, list) and len(cull_tags) == len(triangles) else [CULL_FACE_NEVER] * len(triangles)
        never = sum(1 for t in tags if t == CULL_FACE_NEVER)
        per_face = [0] * 6
        for t in tags:
            if 0 <= t <= 5:
                per_face[t] += 1
        worst = never + max(per_face[0], per_face[1]) + max(per_face[2], per_face[3]) + max(per_face[4], per_face[5])
        if worst > MAX_TRIANGLES:
            errors.append(
                f"{where}: pior caso de {worst} triângulos excede o máximo de {MAX_TRIANGLES} (culling direcional)"
            )

    total_vertices = sum(len(m.get("vertices", [])) for m in mesh_list)
    if total_vertices > VERTEX_POOL_CAPACITY:
        errors.append(
            f"pools de template excedem a capacidade de {VERTEX_POOL_CAPACITY} vértices ({total_vertices} no total)"
        )

    # --- texturas ---
    texture_names = {}
    texture_dims = {}
    if len(textures) > MAX_TEXTURES:
        errors.append(f"mais de {MAX_TEXTURES} texturas")
    for i, tex in enumerate(textures):
        where = f"textura[{i}]"
        if not isinstance(tex, dict):
            errors.append(f"{where}: esperado objeto")
            continue
        name = tex.get("name")
        if not isinstance(name, str) or name == "":
            errors.append(f"{where}: campo 'name' ausente ou vazio")
            continue
        where = f"textura '{name}'"
        if name in texture_names:
            errors.append(f"{where}: nome duplicado")
            continue
        path = tex.get("path")
        if not isinstance(path, str) or path == "":
            errors.append(f"{where}: campo 'path' ausente ou vazio")
            continue
        texture_names[name] = True
        full = os.path.join(base_dir, path)
        if not os.path.isfile(full):
            errors.append(f"{where}: PNG não encontrado: {path}")
            continue
        try:
            with open(full, "rb") as fh:
                w, h, _pixels = decode_png(fh.read())
        except PngError as e:
            errors.append(f"{where}: falha ao decodificar PNG {path}: {e}")
            continue
        texture_dims[name] = (w, h)

    if texture_dims:
        ref_dim = next(iter(texture_dims.values()))
        divergent = sorted(f"{n} {d[0]}x{d[1]}" for n, d in texture_dims.items() if d != ref_dim)
        for n, d in texture_dims.items():
            if d[0] > MAX_TEXTURE_DIM or d[1] > MAX_TEXTURE_DIM:
                errors.append(
                    f"textura '{n}' {d[0]}x{d[1]}: dimensão excede o máximo de {MAX_TEXTURE_DIM}x{MAX_TEXTURE_DIM}"
                )
        if divergent:
            dims_list = ", ".join(sorted(f"{n} {d[0]}x{d[1]}" for n, d in texture_dims.items()))
            errors.append(f"texturas com dimensões divergentes: {dims_list}")

    # --- blocos ---
    block_ids = {}
    for i, block in enumerate(blocks):
        where = f"bloco[{i}]"
        if not isinstance(block, dict):
            errors.append(f"{where}: esperado objeto")
            continue
        name = block.get("name")
        if not isinstance(name, str) or name == "":
            errors.append(f"{where}: campo 'name' ausente ou vazio")
            continue
        where = f"bloco '{name}'"
        bid = block.get("id")
        if not isinstance(bid, int) or isinstance(bid, bool):
            errors.append(f"{where}: campo 'id' ausente ou malformado (esperado inteiro)")
            continue
        if bid == 0:
            errors.append(f"{where}: id 0 é reservado (AR) e não pode ser definido")
            continue
        if bid < 0 or bid > 255:
            errors.append(f"{where}: id {bid} fora do intervalo 1..255")
            continue
        if bid in block_ids:
            errors.append(f"{where}: id {bid} duplicado (já usado por '{block_ids[bid]}')")
        else:
            block_ids[bid] = name
        for field in ("mesh", "texture"):
            ref = block.get(field)
            if not isinstance(ref, str) or ref == "":
                errors.append(f"{where}: campo '{field}' ausente ou vazio")
                continue
            if field == "mesh" and ref not in mesh_names:
                errors.append(f"{where}: malha '{ref}' não encontrada")
            if field == "texture" and ref not in texture_names:
                errors.append(f"{where}: textura '{ref}' não encontrada")

    missing = [str(b) for b in REQUIRED_BLOCK_IDS if b not in block_ids]
    if missing:
        errors.append(f"blocos obrigatórios do worldgen ausentes: ids {', '.join(missing)}")

    return errors


def main():
    if len(sys.argv) != 2:
        print("Uso: python3 assets_check.py <arquivo.json>")
        return 1
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        print(f"ERRO: não foi possível ler {path}: {e}")
        return 1
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        print(f"ERRO: {path}: JSON inválido: linha {e.lineno}, coluna {e.colno}: {e.msg}")
        return 1
    errors = validate(doc, os.path.dirname(os.path.abspath(path)))
    for msg in errors:
        print(f"ERRO: {msg}")
    if errors:
        return 1
    print(f"OK: {path} válido")
    return 0


if __name__ == "__main__":
    sys.exit(main())
