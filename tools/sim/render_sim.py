#!/usr/bin/env python3
"""Simulacao da renderizacao task/mesh (VS-02, REQ-SIM-03).

Espelha src/assets/shaders/common.slang + select_bricks/build_brick_mesh
(voxel.slang). A leitura de bloco usa o grid denso diretamente: pack_sim.py
ja validou decode == denso, entao aqui o que interessa e a geometria.

Cobre: orcamento 256v/192t por grupo (AC-01), selecao de bricks e estouro do
payload, face_mask com redirecionamento B2 (AC-02), dois chunks adjacentes sem
faces internas duplicadas (AC-02), rotacao yaw 0..3 vs ROTATED_FACE e tag 7
nunca culpada (AC-03).
"""

CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = 32 ** 3
BRICK_SIZE = (4, 2, 4)
BRICKS_PER_CHUNK = 1024
VOXELS_PER_BRICK = 32
MESH_VERTEX_MAXIMUM = 256
MESH_TRIANGLE_MAXIMUM = 192
CULL_FACE_NEVER = 7
NEIGHBOR_SLOT_INVALID = 0xFFFFFFFF
# Payload: 2 entradas de 14 bits (brick 10b | parte 2b | subdivisao 2b) por word.
# 2048 words = 4096 entradas = pior caso exato (1024 bricks x 4 partes).
TASK_PAYLOAD_WORDS = 2048
TASK_PAYLOAD_BRICK_CAPACITY = 4096
BRICKS_PER_CHUNK_AXIS = (8, 16, 8)
CHUNK_FLAG_EMPTY = 1

FACE_NORMALS = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
ROTATED_FACE = [
    0, 1, 2, 3, 4, 5,  # r=0
    5, 4, 2, 3, 0, 1,  # r=1
    1, 0, 2, 3, 5, 4,  # r=2
    4, 5, 2, 3, 1, 0,  # r=3
]


# --- helpers (espelham common.slang) ---

def brick_index_from_coordinate(c):
    return c[0] + 8 * (c[2] + 8 * c[1])


def brick_coordinate_from_index(i):
    return (i & 7, i >> 6, (i >> 3) & 7)


def bit_index_from_local_coordinate(c):
    return c[0] + 4 * (c[2] + 4 * c[1])


def local_coordinate_from_bit_index(i):
    return (i & 3, i >> 4, (i >> 2) & 3)


def dense_index_from_coordinate(c):
    return c[0] | (c[2] << 5) | (c[1] << 10)


def coordinate_from_dense_index(i):
    return (i & 31, i >> 10, (i >> 5) & 31)


def rotate_vertex_yaw(p, r):
    r &= 3
    if r == 1:
        return (p[2], p[1], 1.0 - p[0])
    if r == 2:
        return (1.0 - p[0], p[1], 1.0 - p[2])
    if r == 3:
        return (1.0 - p[2], p[1], p[0])
    return p


def triangle_survives_culling(packed_tri, rotation, face_mask):
    cull_face = (packed_tri >> 24) & 7
    if cull_face == CULL_FACE_NEVER:
        return True
    rotated_face = ROTATED_FACE[(rotation & 3) * 6 + cull_face]
    return (face_mask & (1 << rotated_face)) != 0


def pack_triangle(v0, v1, v2, cull_face):
    return (v0 & 0xFF) | ((v1 & 0xFF) << 8) | ((v2 & 0xFF) << 16) | ((cull_face & 7) << 24)


# --- templates (espelham voxel_gpu.odin: 0 = ar, 1 = cubo, 2 = planta) ---

CUBE_VERTICES = [
    (0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0),
    (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1),
]
CUBE_TRIANGLES = [  # (v0, v1, v2, face) — winding CCW visto de fora
    (1, 3, 7, 0), (1, 7, 5, 0),  # +X
    (0, 4, 6, 1), (0, 6, 2, 1),  # -X
    (2, 7, 3, 2), (2, 6, 7, 2),  # +Y
    (0, 1, 5, 3), (0, 5, 4, 3),  # -Y
    (4, 5, 7, 4), (4, 7, 6, 4),  # +Z
    (0, 3, 1, 5), (0, 2, 3, 5),  # -Z
]
PLANT_VERTICES = [
    (0, 0, 0), (1, 0, 1), (1, 1, 1), (0, 1, 0),
    (1, 0, 0), (0, 0, 1), (0, 1, 1), (1, 1, 0),
]
PLANT_TRIANGLES = [
    (0, 1, 2, CULL_FACE_NEVER), (0, 2, 3, CULL_FACE_NEVER),
    (4, 5, 6, CULL_FACE_NEVER), (4, 6, 7, CULL_FACE_NEVER),
]
# Template sintetico pesado: 32 vertices, 24 triangulos todos tag NEVER.
HEAVY_VERTICES = [(x / 3.0, y / 3.0, z / 3.0) for x in range(4) for y in range(4) for z in range(2)][:32]
HEAVY_TRIANGLES = [(i % 32, (i + 1) % 32, (i + 2) % 32, CULL_FACE_NEVER) for i in range(24)]


class Template:
    def __init__(self, vertices, triangles):
        self.vertices = vertices
        self.triangles = triangles
        self.vertex_count = len(vertices)
        self.triangle_count = len(triangles)
        self.has_flush_faces = any(t[3] != CULL_FACE_NEVER for t in triangles)
        # compute_worst_case_tris (voxel_types.odin)
        never = sum(1 for t in triangles if t[3] == CULL_FACE_NEVER)
        faces = [0] * 6
        for t in triangles:
            if t[3] != CULL_FACE_NEVER:
                faces[t[3]] += 1
        self.worst_case_tris = never + sum(max(faces[a], faces[a + 1]) for a in (0, 2, 4))
        self.packed = [pack_triangle(*t) for t in triangles]


TEMPLATES = {
    0: Template([], []),                  # ar
    1: Template(CUBE_VERTICES, CUBE_TRIANGLES),
    2: Template(PLANT_VERTICES, PLANT_TRIANGLES),
    3: Template(HEAVY_VERTICES, HEAVY_TRIANGLES),
}


class BlockDef:
    def __init__(self, template_index, rotation=0):
        self.template_index = template_index
        self.rotation = rotation


# --- chunks simulados: slot -> {dense, origin, neighbors} ---

def make_chunk(origin, fill):
    return {
        "dense": [fill(coordinate_from_dense_index(i)) for i in range(CHUNK_VOXEL_COUNT)],
        "origin": origin,
        "neighbors": [NEIGHBOR_SLOT_INVALID] * 6,
        "subdivisions": None,  # preenchido por pack_subdivisions
    }


def is_solid(chunks, slot, coord):
    return chunks[slot]["dense"][dense_index_from_coordinate(coord)] != 0


def is_voxel_solid(chunks, slot, coord, neighbor_slots):
    if all(0 <= c < CHUNK_SIZE for c in coord):
        return is_solid(chunks, slot, coord)
    c = list(coord)
    neighbor_slot = NEIGHBOR_SLOT_INVALID
    if c[0] < 0:
        neighbor_slot = neighbor_slots[1]; c[0] += CHUNK_SIZE
    elif c[0] >= CHUNK_SIZE:
        neighbor_slot = neighbor_slots[0]; c[0] -= CHUNK_SIZE
    elif c[1] < 0:
        neighbor_slot = neighbor_slots[3]; c[1] += CHUNK_SIZE
    elif c[1] >= CHUNK_SIZE:
        neighbor_slot = neighbor_slots[2]; c[1] -= CHUNK_SIZE
    elif c[2] < 0:
        neighbor_slot = neighbor_slots[5]; c[2] += CHUNK_SIZE
    else:
        neighbor_slot = neighbor_slots[4]; c[2] -= CHUNK_SIZE
    if neighbor_slot == NEIGHBOR_SLOT_INVALID:
        return False
    if not all(0 <= v < CHUNK_SIZE for v in c):
        return False
    return is_solid(chunks, neighbor_slot, tuple(c))


def compute_visible_face_mask(chunks, slot, coord, neighbor_slots, camera_position):
    origin = chunks[slot]["origin"]
    voxel_min_world = tuple(origin[i] + coord[i] for i in range(3))
    face_mask = 0
    for face_index in range(6):
        n = FACE_NORMALS[face_index]
        neighbor_coord = tuple(coord[i] + n[i] for i in range(3))
        if is_voxel_solid(chunks, slot, neighbor_coord, neighbor_slots):
            continue
        axis = face_index >> 1
        is_positive = (face_index & 1) == 0
        plane = voxel_min_world[axis] + (1.0 if is_positive else 0.0)
        sees = camera_position[axis] > plane if is_positive else camera_position[axis] < plane
        if sees:
            face_mask |= 1 << face_index
    return face_mask


# --- pack (apenas a parte de subdivisao — o resto e coberto por pack_sim) ---

def pack_subdivisions(chunk, registry):
    subdivisions = [0] * BRICKS_PER_CHUNK
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        part_verts = [0, 0, 0, 0]
        part_tris = [0, 0, 0, 0]
        for bit_idx in range(VOXELS_PER_BRICK):
            lc = local_coordinate_from_bit_index(bit_idx)
            coord = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
            block_id = chunk["dense"][dense_index_from_coordinate(coord)]
            if block_id != 0:
                tmpl = TEMPLATES[registry[block_id].template_index]
                if tmpl.triangle_count > 0:
                    part = bit_idx >> 3
                    part_verts[part] += tmpl.vertex_count
                    part_tris[part] += tmpl.worst_case_tris
        half_verts = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3])
        half_tris = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3])
        total_verts = sum(part_verts)
        total_tris = sum(part_tris)
        subdivision = 0
        if total_verts > MESH_VERTEX_MAXIMUM or total_tris > MESH_TRIANGLE_MAXIMUM:
            subdivision = 1
            if half_verts > MESH_VERTEX_MAXIMUM or half_tris > MESH_TRIANGLE_MAXIMUM:
                subdivision = 2
        subdivisions[brick_idx] = subdivision
    chunk["subdivisions"] = subdivisions
    return subdivisions


# --- task shader (select_bricks) ---

def brick_occupancy_word(chunks, slot, brick_coord):
    """Word de 32 bits com a ocupacao dos voxels do brick."""
    mask = 0
    for bit in range(VOXELS_PER_BRICK):
        lc = local_coordinate_from_bit_index(bit)
        coord = (brick_coord[0] * 4 + lc[0], brick_coord[1] * 2 + lc[1], brick_coord[2] * 4 + lc[2])
        if chunks[slot]["dense"][dense_index_from_coordinate(coord)] != 0:
            mask |= 1 << bit
    return mask


def read_brick_occupancy_b2(chunks, slot, brick_coord, neighbor_slots):
    """Ocupacao de um brick vizinho com redirecionamento B2 entre chunks.
    Vizinho invalido => 0 (conservador: nao-chevio, nunca culpa)."""
    if all(0 <= brick_coord[i] < BRICKS_PER_CHUNK_AXIS[i] for i in range(3)):
        return brick_occupancy_word(chunks, slot, brick_coord)
    c = list(brick_coord)
    neighbor_slot = NEIGHBOR_SLOT_INVALID
    if c[0] < 0:
        neighbor_slot = neighbor_slots[1]; c[0] += BRICKS_PER_CHUNK_AXIS[0]
    elif c[0] >= BRICKS_PER_CHUNK_AXIS[0]:
        neighbor_slot = neighbor_slots[0]; c[0] -= BRICKS_PER_CHUNK_AXIS[0]
    elif c[1] < 0:
        neighbor_slot = neighbor_slots[3]; c[1] += BRICKS_PER_CHUNK_AXIS[1]
    elif c[1] >= BRICKS_PER_CHUNK_AXIS[1]:
        neighbor_slot = neighbor_slots[2]; c[1] -= BRICKS_PER_CHUNK_AXIS[1]
    elif c[2] < 0:
        neighbor_slot = neighbor_slots[5]; c[2] += BRICKS_PER_CHUNK_AXIS[2]
    else:
        neighbor_slot = neighbor_slots[4]; c[2] -= BRICKS_PER_CHUNK_AXIS[2]
    if neighbor_slot == NEIGHBOR_SLOT_INVALID:
        return 0
    return brick_occupancy_word(chunks, neighbor_slot, tuple(c))


FULL_BRICK = (1 << VOXELS_PER_BRICK) - 1


def is_brick_occluded(chunks, slot, brick_coord, neighbor_slots):
    """Brick cheio com os 6 bricks vizinhos cheios: nenhum voxel tem face
    exposta (independente da camera), entao o grupo nao emitiria geometria."""
    for face in range(6):
        n = FACE_NORMALS[face]
        nb = (brick_coord[0] + n[0], brick_coord[1] + n[1], brick_coord[2] + n[2])
        if read_brick_occupancy_b2(chunks, slot, nb, neighbor_slots) != FULL_BRICK:
            return False
    return True


def pack_brick_entry(brick_idx, part, subdivision):
    return brick_idx | (part << 10) | (subdivision << 12)


def pack_payload_words(entries):
    words = [0] * TASK_PAYLOAD_WORDS
    for pos, entry in enumerate(entries):
        words[pos >> 1] |= entry << ((pos & 1) * 14)
    return words


def unpack_payload_words(words, count):
    return [(words[pos >> 1] >> ((pos & 1) * 14)) & 0x3FFF for pos in range(count)]


def select_bricks(chunks, slot):
    """Retorna (entries, selecionados); entries truncado na capacidade."""
    chunk = chunks[slot]
    if all(b == 0 for b in chunk["dense"]):
        return None, 0  # CHUNK_FLAG_EMPTY: task retorna sem DispatchMesh
    entries = []
    selected = 0
    for brick_idx in range(BRICKS_PER_CHUNK):
        occupancy = brick_occupancy_word(chunks, slot, brick_coordinate_from_index(brick_idx))
        if occupancy == 0:
            continue
        # Culling de brick ocluso: cheio + 6 vizinhos cheios = zero faces.
        if occupancy == FULL_BRICK and is_brick_occluded(
            chunks, slot, brick_coordinate_from_index(brick_idx), chunk["neighbors"]
        ):
            continue
        subdivision = chunk["subdivisions"][brick_idx]
        for part in range(1 << subdivision):
            selected += 1
            if len(entries) < TASK_PAYLOAD_BRICK_CAPACITY:
                entries.append(pack_brick_entry(brick_idx, part, subdivision))
    return entries, selected


# --- mesh shader (build_brick_mesh, somente contagens) ---

def mesh_group_counts(entry, chunks, slot, registry, camera_position):
    brick_idx = entry & 1023
    part = (entry >> 10) & 3
    subdivision_log2 = (entry >> 12) & 3
    voxels_in_group = VOXELS_PER_BRICK >> subdivision_log2
    total_v = 0
    total_t = 0
    bc = brick_coordinate_from_index(brick_idx)
    chunk = chunks[slot]
    for i in range(voxels_in_group):
        voxel_slot = part * voxels_in_group + i
        lc = local_coordinate_from_bit_index(voxel_slot)
        coord = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
        block_id = chunk["dense"][dense_index_from_coordinate(coord)]
        if block_id == 0:
            continue
        definition = registry[block_id]
        tmpl = TEMPLATES[definition.template_index]
        if tmpl.triangle_count == 0:
            continue
        face_mask = 0
        if tmpl.has_flush_faces:
            face_mask = compute_visible_face_mask(chunks, slot, coord, chunk["neighbors"], camera_position)
        t_cnt = sum(1 for tri in tmpl.packed if triangle_survives_culling(tri, definition.rotation, face_mask))
        if t_cnt > 0:
            total_v += tmpl.vertex_count
            total_t += t_cnt
    return total_v, total_t


# --- checks ---

PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


CAMERAS_6 = [
    (1e6, 16, 16), (-1e6, 16, 16),
    (16, 1e6, 16), (16, -1e6, 16),
    (16, 16, 1e6), (16, 16, -1e6),
]


def scenario_budget():
    print("[cenario] orcamento 256v/192t por construcao (cubo, planta, pesado)")
    registry = {1: BlockDef(1), 2: BlockDef(2), 3: BlockDef(3)}
    for block_id, label in ((1, "cubo"), (2, "planta"), (3, "pesado")):
        chunks = {0: make_chunk((0, 0, 0), lambda c, b=block_id: b)}
        pack_subdivisions(chunks[0], registry)
        payload, _ = select_bricks(chunks, 0)
        check(f"{label}: payload nao vazio", payload)
        worst_v = 0
        worst_t = 0
        for entry in payload:
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(entry, chunks, 0, registry, camera)
                worst_v = max(worst_v, v)
                worst_t = max(worst_t, t)
        check(f"{label}: vertices <= {MESH_VERTEX_MAXIMUM} (pior {worst_v})", worst_v <= MESH_VERTEX_MAXIMUM)
        check(f"{label}: triangulos <= {MESH_TRIANGLE_MAXIMUM} (pior {worst_t})", worst_t <= MESH_TRIANGLE_MAXIMUM)
    # pesado no teto exato: 8 voxels x (32v, 24t) = 256/192
    chunks = {0: make_chunk((0, 0, 0), lambda c: 3)}
    pack_subdivisions(chunks[0], registry)
    check("pesado: subdivisao 2 em todos os bricks", all(s == 2 for s in chunks[0]["subdivisions"]))
    check("pesado: 8 voxels x 32v = 256 no teto", TEMPLATES[3].vertex_count * 8 == MESH_VERTEX_MAXIMUM)
    check("pesado: 8 voxels x 24t = 192 no teto", TEMPLATES[3].worst_case_tris * 8 == MESH_TRIANGLE_MAXIMUM)


def scenario_selection():
    print("[cenario] selecao de bricks, chunk vazio e capacidade do payload")
    registry = {1: BlockDef(1)}

    chunks = {0: make_chunk((0, 0, 0), lambda c: 0)}
    pack_subdivisions(chunks[0], registry)
    payload, selected = select_bricks(chunks, 0)
    check("chunk vazio: sem dispatch", payload is None and selected == 0)

    # bricks 0, 5 e 1000 ocupados (canto do brick 0 basta)
    def sparse(c):
        bc = (c[0] // 4, c[1] // 2, c[2] // 4)
        return 1 if brick_index_from_coordinate(bc) in (0, 5, 1000) else 0
    chunks = {0: make_chunk((0, 0, 0), sparse)}
    pack_subdivisions(chunks[0], registry)
    payload, selected = select_bricks(chunks, 0)
    check("3 bricks ocupados -> 3 grupos", selected == 3 and len(payload) == 3)
    bricks = sorted(e & 1023 for e in payload)
    check("grupos apontam os bricks certos", bricks == [0, 5, 1000])
    check("entry roundtrip (brick|parte|subdivisao)",
          all(((e & 1023) | (((e >> 10) & 3) << 10) | (((e >> 12) & 3) << 12)) == e for e in payload))
    check("subdivisao 0 para cubos esparsos", all(((e >> 12) & 3) == 0 for e in payload))

    # capacidade 4096 = pior caso exato: 1024 bricks x 4 partes (subdivisao 2),
    # mesmo que o culling de oclusao nao remova nada (todos com vizinho aberto)
    check("capacidade cobre o pior caso sem culling", TASK_PAYLOAD_BRICK_CAPACITY >= 1024 * 4)


def scenario_payload_packing():
    print("[cenario] empacotamento 2x14 bits por word do payload")
    entries = [
        pack_brick_entry(0, 0, 0),          # entrada zero (indistingue de word zerada)
        pack_brick_entry(1023, 3, 2),       # maximo: 14 bits cheios
        pack_brick_entry(1, 0, 0),
        pack_brick_entry(517, 2, 1),
        pack_brick_entry(64, 1, 2),
    ]
    check("entrada cabe em 14 bits", all(e < (1 << 14) for e in entries))
    words = pack_payload_words(entries)
    check("N entradas ocupam ceil(N/2) words",
          words[: (len(entries) + 1) // 2] and all(
              w == 0 for w in words[(len(entries) + 1) // 2:]
          ))
    check("roundtrip pack/unpack", unpack_payload_words(words, len(entries)) == entries)
    check("metades nao vazam: entrada 0 nao corrompe a vizinha",
          unpack_payload_words(pack_payload_words([0, pack_brick_entry(1023, 3, 2)]), 2)
          == [0, pack_brick_entry(1023, 3, 2)])
    # worldgen real: chunk cheio de cubos cabe inteiro apos culling de oclusao
    registry = {1: BlockDef(1)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    payload, selected = select_bricks(chunks, 0)
    check("chunk cheio de cubos: selecionados <= capacidade", selected <= TASK_PAYLOAD_BRICK_CAPACITY)
    check("chunk cheio de cubos: nenhum grupo descartado", len(payload) == selected)


def scenario_occlusion_culling():
    print("[cenario] culling de brick ocluso (cheio + 6 vizinhos cheios)")
    registry = {1: BlockDef(1)}

    # chunk cheio isolado: vizinhos invalidos => faces da casca preservadas
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    payload, selected = select_bricks(chunks, 0)
    # casca = 1024 - interior (6 x 14 x 6 = 504) = 520 bricks
    # (cubo cheio: 32v x 8 = 256 e 32 x 6t = 192 = teto exato => subdivisao 0)
    check("chunk isolado: so a casca selecionada (520 bricks, subdivisao 0)", selected == 520)

    # todo brick descartado emite ZERO geometria, para qualquer camera
    selected_entries = set(payload)
    culled = 0
    culling_sound = True
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        occupancy = brick_occupancy_word(chunks, 0, bc)
        if occupancy != FULL_BRICK or not is_brick_occluded(chunks, 0, bc, chunks[0]["neighbors"]):
            continue
        culled += 1
        for part in range(4):
            entry = pack_brick_entry(brick_idx, part, 2)
            if entry in selected_entries:
                culling_sound = False
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(entry, chunks, 0, registry, camera)
                if (v, t) != (0, 0):
                    culling_sound = False
    check("504 bricks interiores culpados", culled == 504)
    check("nenhum brick ocluso entra no payload nem emitiria geometria (6 cameras)", culling_sound)

    # dois chunks adjacentes: bricks da face compartilhada viram interiores
    chunks = {
        0: make_chunk((0, 0, 0), lambda c: 1),
        1: make_chunk((32, 0, 0), lambda c: 1),
    }
    for c in chunks.values():
        pack_subdivisions(c, registry)
    chunks[0]["neighbors"][0] = 1  # +X de A = B
    chunks[1]["neighbors"][1] = 0  # -X de B = A
    payload_a, selected_a = select_bricks(chunks, 0)
    payload_b, selected_b = select_bricks(chunks, 1)
    # da face compartilhada (8x16 = 128 bricks), so os que nao tocam outra
    # face aberta viram interiores: 14 x 6 = 84 por lado (520 - 84 = 436)
    check("fronteira +X: 84 bricks internos da face compartilhada culpados",
          selected_a == 436 and selected_b == 436)

    # geometria preservada na uniao: todo brick culpado emitiria zero faces
    for slot in (0, 1):
        for brick_idx in range(BRICKS_PER_CHUNK):
            bc = brick_coordinate_from_index(brick_idx)
            if brick_occupancy_word(chunks, slot, bc) != FULL_BRICK:
                continue
            if not is_brick_occluded(chunks, slot, bc, chunks[slot]["neighbors"]):
                continue
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(pack_brick_entry(brick_idx, 0, 2), chunks, slot, registry, camera)
                if (v, t) != (0, 0):
                    check(f"uniao: brick {brick_idx} do slot {slot} emitiria geometria", False)
    check("uniao de 2 chunks: culling nao remove geometria visivel", True)

    # conservador: brick na casca com vizinho INVALIDO nunca e culpado
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    check("face com vizinho invalido: brick nao culpado",
          not is_brick_occluded(chunks, 0, (0, 8, 4), chunks[0]["neighbors"]))
    check("interior com 6 vizinhos cheios: culpado",
          is_brick_occluded(chunks, 0, (4, 8, 4), chunks[0]["neighbors"]))


def scenario_b2():
    print("[cenario] fronteira B2: redirecionamento e faces internas")
    registry = {1: BlockDef(1)}
    chunks = {
        0: make_chunk((0, 0, 0), lambda c: 1),
        1: make_chunk((32, 0, 0), lambda c: 1),
    }
    for c in chunks.values():
        pack_subdivisions(c, registry)
    chunks[0]["neighbors"][0] = 1  # +X de A = B
    chunks[1]["neighbors"][1] = 0  # -X de B = A
    camera = (16, 1e6, 16)  # muito acima: mascara so depende dos vizinhos laterais

    # voxel na fronteira de A (x=31): face +X suprimida pelo vizinho solido
    for y in range(0, CHUNK_SIZE, 5):
        for z in range(0, CHUNK_SIZE, 5):
            mask_a = compute_visible_face_mask(chunks, 0, (31, y, z), chunks[0]["neighbors"], camera)
            check(f"A(31,{y},{z}): face +X culpada", (mask_a & 1) == 0)
            mask_b = compute_visible_face_mask(chunks, 1, (0, y, z), chunks[1]["neighbors"], camera)
            check(f"B(0,{y},{z}): face -X culpada", (mask_b & 2) == 0)

    # sem vizinho publicado (NEIGHBOR_SLOT_INVALID): a face de fronteira volta
    chunks[0]["neighbors"][0] = NEIGHBOR_SLOT_INVALID
    mask_a = compute_visible_face_mask(chunks, 0, (31, 0, 0), chunks[0]["neighbors"], (1e6, 16, 16))
    check("vizinho invalido: face +X reaparece (camera em +X)", (mask_a & 1) == 1)
    mask_a = compute_visible_face_mask(chunks, 0, (31, 0, 0), chunks[0]["neighbors"], (-1e6, 16, 16))
    check("camera do outro lado: face +X nao emitida", (mask_a & 1) == 0)
    chunks[0]["neighbors"][0] = 1

    # contagem total de triangulos internos no plano x=32, dos dois lados
    internal = 0
    for slot, x in ((0, 31), (1, 0)):
        for y in range(CHUNK_SIZE):
            for z in range(CHUNK_SIZE):
                mask = compute_visible_face_mask(chunks, slot, (x, y, z), chunks[slot]["neighbors"], camera)
                for tri in TEMPLATES[1].packed:
                    cull = (tri >> 24) & 7
                    if cull in (0, 1) and triangle_survives_culling(tri, 0, mask):
                        internal += 1
    check("zero faces internas no plano x=32 (dois chunks)", internal == 0)


def scenario_rotation():
    print("[cenario] rotacao yaw 0..3 vs ROTATED_FACE e tag 7")
    # vertices permanecem em [0,1]^3 sob qualquer yaw
    for r in range(4):
        for v in CUBE_VERTICES + PLANT_VERTICES:
            p = rotate_vertex_yaw(tuple(float(x) for x in v), r)
            check(f"r={r} {v} em [0,1]^3", all(0.0 <= c <= 1.0 for c in p))

    # normal geometrica do triangulo rotacionado == FACE_NORMALS[ROTATED_FACE]
    def normal_of(v0, v1, v2):
        a = tuple(v1[i] - v0[i] for i in range(3))
        b = tuple(v2[i] - v0[i] for i in range(3))
        n = (
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        )
        return tuple(int(round(x)) for x in n)

    mismatches = 0
    for r in range(4):
        for v0, v1, v2, cull in CUBE_TRIANGLES:
            rotated = [rotate_vertex_yaw(tuple(float(x) for x in CUBE_VERTICES[i]), r) for i in (v0, v1, v2)]
            n = normal_of(*rotated)
            expected = FACE_NORMALS[ROTATED_FACE[r * 6 + cull]]
            if n != expected:
                mismatches += 1
    check("48 triangulos x 4 rotacoes: normal == ROTATED_FACE", mismatches == 0)

    # tag 7: planta totalmente cercada (face_mask = 0) ainda emite tudo
    registry = {2: BlockDef(2)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 2)}
    pack_subdivisions(chunks[0], registry)
    interior = (16, 16, 16)
    mask = compute_visible_face_mask(chunks, 0, interior, chunks[0]["neighbors"], (16, 1e6, 16))
    check("voxel cercado: face_mask == 0", mask == 0)
    surviving = sum(1 for tri in TEMPLATES[2].packed if triangle_survives_culling(tri, 0, mask))
    check("planta (tag 7) nunca culpada: 4/4 triangulos", surviving == 4)

    # cubo cercado nao emite nada
    registry = {1: BlockDef(1)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    v, t = mesh_group_counts(0, chunks, 0, registry, (16, 1e6, 16))  # brick 0: interior em y
    check("brick interior de cubos: 0 vertices, 0 triangulos", (v, t) == (0, 0))

    # rotacao afeta o culling: face +X do cubo com r=1 passa a responder a -Z
    mask = 1 << 5  # so -Z visivel
    tri_px = pack_triangle(1, 3, 7, 0)
    check("r=0: face +X nao sobrevive com mascara -Z", not triangle_survives_culling(tri_px, 0, mask))
    check("r=1: face +X rotacionada sobrevive com mascara -Z", triangle_survives_culling(tri_px, 1, mask))


def main():
    scenario_budget()
    scenario_selection()
    scenario_payload_packing()
    scenario_occlusion_culling()
    scenario_b2()
    scenario_rotation()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
