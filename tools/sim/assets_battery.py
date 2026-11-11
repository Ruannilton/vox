#!/usr/bin/env python3
# VS-12 (AC-01) — bateria de arquivos inválidos para assets_check.py.
# Gera um caso por classe em /tmp/vs12_battery e roda o validador.

import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "assets_check.py")
TMP = os.path.join(HERE, "__pycache__", "vs12_battery")
SRC = os.path.normpath(os.path.join(HERE, "..", "..", "assets"))

CUBE_VERTS = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1]]
CUBE_TRIS = [[1, 3, 7], [1, 7, 5], [0, 4, 6], [0, 6, 2], [2, 7, 3], [2, 6, 7], [0, 1, 5], [0, 5, 4], [4, 5, 7], [4, 7, 6], [0, 3, 1], [0, 2, 3]]
CUBE_TAGS = [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]
CUBE_UVS = [[0, 0], [1, 0], [0, 0], [1, 0], [0, 1], [1, 1], [0, 1], [1, 1]]

# VS-14: mesh "planta" em X (mesmo formato do template built-in 2)
PLANT_VERTS = [[0, 0, 0], [1, 0, 1], [1, 1, 1], [0, 1, 0],
               [1, 0, 0], [0, 0, 1], [0, 1, 1], [1, 1, 0]]
PLANT_TRIS = [[0, 1, 2], [0, 2, 3], [4, 5, 6], [4, 6, 7]]
PLANT_TAGS = [7, 7, 7, 7]
PLANT_UVS = [[0, 0], [1, 0], [1, 1], [0, 1]] * 2


def doc(verts=CUBE_VERTS, tris=CUBE_TRIS, tags=CUBE_TAGS, uvs=CUBE_UVS, blocks=None, textures=None,
        meshes=None):
    return {
        "meshes": meshes if meshes is not None else [
            {"name": "cubo", "vertices": verts, "triangles": tris, "cull_tags": tags, "uvs": uvs},
            {"name": "planta", "vertices": PLANT_VERTS, "triangles": PLANT_TRIS,
             "cull_tags": PLANT_TAGS, "uvs": PLANT_UVS},
        ],
        "textures": textures if textures is not None else [
            {"name": "grama", "path": "textures/grass.png"},
            {"name": "terra", "path": "textures/dirt.png"},
            {"name": "pedra", "path": "textures/stone.png"},
            {"name": "planta", "path": "textures/plant.png"},
        ],
        "blocks": blocks if blocks is not None else [
            {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama"},
            {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
            {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
            {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "transparent": True},
        ],
    }


CASES = {
    "json_quebrado": None,  # texto inválido
    "ref_quebrada": doc(blocks=[{"id": 1, "name": "grama", "mesh": "inexistente", "texture": "grama"}]),
    "id_duplicado": doc(blocks=[{"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama"}, {"id": 1, "name": "terra", "mesh": "cubo", "texture": "terra"}]),
    "id_zero": doc(blocks=[{"id": 0, "name": "ar", "mesh": "cubo", "texture": "grama"}]),
    "uv_fora": doc(uvs=[[0, 0], [1, 0], [0, 0], [1.5, 0], [0, 1], [1, 1], [0, 1], [1, 1]]),
    "muitos_vertices": doc(verts=CUBE_VERTS * 5),
    "ids_1_3_ausentes": doc(blocks=[{"id": 9, "name": "extra", "mesh": "cubo", "texture": "grama"}]),
    "cull_tag_invalido": doc(tags=CUBE_TAGS[:-1] + [6]),
    "vertice_fora": doc(verts=[v[:] if i else [2, 0, 0] for i, v in enumerate(CUBE_VERTS)]),
    "indice_fora": doc(tris=CUBE_TRIS[:-1] + [[0, 3, 99]]),
    "png_ausente": doc(textures=[{"name": "grama", "path": "textures/nada.png"}]),
    # VS-14: contrato ids 1..4, 'transparent' com tipo errado, textura da planta
    "id4_ausente": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama"},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
    ]),
    "transparent_tipo_errado": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama"},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "transparent": "sim"},
    ]),
    # VS-14 (emenda 2026-11-07): 'solid' com tipo errado (planta não-sólida)
    "solid_tipo_errado": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama"},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": "não"},
    ]),
    "textura_planta_ausente": doc(textures=[
        {"name": "grama", "path": "textures/grass.png"},
        {"name": "terra", "path": "textures/dirt.png"},
        {"name": "pedra", "path": "textures/stone.png"},
        {"name": "planta", "path": "textures/nada_plant.png"},
    ]),
    # VS-21 (REQ-TEX-04): objeto de 6 faces — válido, incompleto, extra, tipo
    # errado e referência ausente por face
    "textura_faces_incompleto": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": {"top": "grama"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "textura_faces_extra": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture":
         {"top": "grama", "bottom": "terra", "front": "terra", "back": "terra",
          "left": "terra", "right": "terra", "diag": "planta"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "textura_faces_tipo_errado": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture":
         {"top": 42, "bottom": "terra", "front": "terra", "back": "terra",
          "left": "terra", "right": "terra"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "textura_faces_ref_ausente": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture":
         {"top": "nada", "bottom": "terra", "front": "terra", "back": "terra",
          "left": "terra", "right": "terra"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "textura_tipo_errado": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": 42},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "dimensao_divergente": doc(textures=[
        {"name": "grama", "path": "textures/grass.png"},
        {"name": "terra", "path": "textures/dirt_8.png"},
        {"name": "pedra", "path": "textures/stone.png"},
    ]),
    # VS-19 (REQ-PHY-01): schema físico — tipo errado, flag desconhecida e
    # materiais fora dos limites documentados (fricção ≥ 0; restituição [0,1])
    "physics_tipo_errado": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama",
         "physics": {"blocking": "sim"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "physics_flag_desconhecida": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama",
         "physics": {"bouncy": True}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "physics_friccao_negativa": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama",
         "physics": {"friction": -0.5}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
    "physics_restituicao_fora": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama",
         "physics": {"restitution": 1.5}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False},
    ]),
}

# VS-19 (REQ-PHY-01): casos VÁLIDOS — o validador aceita objeto completo,
# objeto parcial (defaults) e ausente.
VALID_CASES = {
    "textura_faces_valido": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture":
         {"top": "grama", "bottom": "terra", "front": "terra", "back": "terra",
          "left": "terra", "right": "terra"}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "transparent": True},
    ]),
    "physics_completo_valido": doc(blocks=[
        {"id": 1, "name": "grama", "mesh": "cubo", "texture": "grama",
         "physics": {"blocking": True, "hittable": True, "friction": 0.6, "restitution": 0.0}},
        {"id": 2, "name": "terra", "mesh": "cubo", "texture": "terra"},
        {"id": 3, "name": "pedra", "mesh": "cubo", "texture": "pedra"},
        {"id": 4, "name": "planta", "mesh": "planta", "texture": "planta", "solid": False,
         "physics": {"blocking": False, "hittable": True}},
    ]),
}


def main():
    os.makedirs(TMP, exist_ok=True)
    shutil.rmtree(TMP)
    os.makedirs(TMP)
    shutil.copytree(os.path.join(SRC, "textures"), os.path.join(TMP, "textures"))
    # PNG divergente (16x8) para o caso dimensao_divergente
    from png_min import encode_png
    with open(os.path.join(TMP, "textures", "dirt_8.png"), "wb") as fh:
        fh.write(encode_png(16, 8, bytes([128, 89, 51, 255]) * 16 * 8))
    failures = 0
    for name, d in CASES.items():
        path = os.path.join(TMP, f"{name}.json")
        if d is None:
            with open(path, "w") as fh:
                fh.write('{"meshes": [ {"name": "cubo", ] }')
        else:
            with open(path, "w") as fh:
                json.dump(d, fh)
        proc = subprocess.run([sys.executable, CHECK, path], capture_output=True, text=True)
        status = "OK" if proc.returncode == 1 else f"FALHA (exit {proc.returncode})"
        if proc.returncode != 1:
            failures += 1
        print(f"--- {name}: {status}")
        for line in (proc.stdout + proc.stderr).strip().splitlines():
            print(f"    {line}")
    # VS-19: casos válidos devem passar (exit 0)
    for name, d in VALID_CASES.items():
        path = os.path.join(TMP, f"{name}.json")
        with open(path, "w") as fh:
            json.dump(d, fh)
        proc = subprocess.run([sys.executable, CHECK, path], capture_output=True, text=True)
        status = "OK" if proc.returncode == 0 else f"FALHA (exit {proc.returncode})"
        if proc.returncode != 0:
            failures += 1
        print(f"--- {name}: {status}")
        for line in (proc.stdout + proc.stderr).strip().splitlines():
            print(f"    {line}")
    print(f"\n{'TODOS OK' if failures == 0 else str(failures) + ' FALHAS'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
