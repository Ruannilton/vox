#!/usr/bin/env python3
# VS-12 (REQ-VAL-07) / VS-14 (REQ-SIM-11) — validador offline de
# assets/blocks.json: schema, referências por nome, limites e bounds — sem
# rodar a engine. Uso: python3 assets_check.py <arquivo.json> ; exit 0 = válido, 1 = inválido.
# As mensagens espelham o carregador em src/engine/voxel_assets.odin.
# VS-14: campo opcional 'transparent' (bool) por bloco e contrato ids 1..4.

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
REQUIRED_BLOCK_IDS = (1, 2, 3, 4)  # contrato do worldgen (grama/terra/pedra/planta)


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
        transparent = block.get("transparent")
        if transparent is not None and not isinstance(transparent, bool):
            errors.append(f"{where}: campo 'transparent' deve ser booleano (recebido {transparent!r})")
        # VS-14 (emenda 2026-11-07): 'solid' opcional (default true); false
        # marca NON_SOLID (planta). Separado de 'transparent' (vidro futuro:
        # transparente mas sólido).
        solid = block.get("solid")
        if solid is not None and not isinstance(solid, bool):
            errors.append(f"{where}: campo 'solid' deve ser booleano (recebido {solid!r})")
        # VS-19 (REQ-PHY-01): 'physics' opcional — objeto com chaves
        # conhecidas (blocking/hittable bool; friction/restitution números
        # com limites documentados) validado citando o bloco.
        physics = block.get("physics")
        if physics is not None:
            if not isinstance(physics, dict):
                errors.append(f"{where}: campo 'physics' deve ser um objeto (recebido {physics!r})")
            else:
                for key, value in physics.items():
                    if key in ("blocking", "hittable"):
                        if not isinstance(value, bool):
                            errors.append(f"{where}: 'physics.{key}' deve ser booleano (recebido {value!r})")
                    elif key in ("friction", "restitution"):
                        if isinstance(value, bool) or not isinstance(value, (int, float)):
                            errors.append(f"{where}: 'physics.{key}' deve ser número (recebido {value!r})")
                        elif key == "friction" and value < 0:
                            errors.append(f"{where}: 'physics.friction' = {value} fora do limite documentado (≥ 0)")
                        elif key == "restitution" and not (0 <= value <= 1):
                            errors.append(f"{where}: 'physics.restitution' = {value} fora do limite documentado ([0,1])")
                    else:
                        errors.append(
                            f"{where}: flag física desconhecida 'physics.{key}' "
                            "(conhecidas: blocking, hittable, friction, restitution)"
                        )
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
        ref = block.get("mesh")
        if not isinstance(ref, str) or ref == "":
            errors.append(f"{where}: campo 'mesh' ausente ou vazio")
        elif ref not in mesh_names:
            errors.append(f"{where}: malha '{ref}' não encontrada")
        # VS-21 (REQ-TEX-04): 'texture' aceita string (todas as faces iguais —
        # compatível) ou objeto com as 6 faces top/bottom/front/back/left/right
        # (front=+Z, back=-Z, right=+X, left=-X). Loader e validador
        # compartilham a semântica; string é normalizada para o objeto.
        texture = block.get("texture")
        if isinstance(texture, str):
            if texture == "":
                errors.append(f"{where}: campo 'texture' ausente ou vazio")
            elif texture not in texture_names:
                errors.append(f"{where}: textura '{texture}' não encontrada")
        elif isinstance(texture, dict):
            faces = ("top", "bottom", "front", "back", "left", "right")
            keys = set(texture.keys())
            if keys != set(faces):
                missing = sorted(set(faces) - keys)
                extra = sorted(keys - set(faces))
                detail = []
                if missing:
                    detail.append(f"faltando {missing}")
                if extra:
                    detail.append(f"extras {extra}")
                errors.append(f"{where}: objeto 'texture' incompleto ({', '.join(detail)})")
            else:
                for face in faces:
                    value = texture[face]
                    if not isinstance(value, str) or value == "":
                        errors.append(
                            f"{where}: 'texture.{face}' deve ser string não vazia (recebido {value!r})"
                        )
                    elif value not in texture_names:
                        errors.append(f"{where}: textura '{value}' não encontrada (texture.{face})")
        else:
            errors.append(
                f"{where}: campo 'texture' deve ser string ou objeto de 6 faces (recebido {texture!r})"
            )

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
