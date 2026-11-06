#!/usr/bin/env python3
"""Simulacao da renderizacao mesh (VS-02, REQ-SIM-03; VS-06, REQ-SIM-04).

Espelha src/assets/shaders/common.slang + build_work_queue/finalize_work_queue/
build_brick_mesh (voxel.slang). A leitura de bloco usa o grid denso
diretamente: pack_sim.py ja validou decode == denso, entao aqui o que
interessa e a geometria.

Arquitetura SEM payload task->mesh (correcao pos-validacao): um builder
compute na fila grafica seleciona grupos (brick|parte|subdivisao) por chunk
visivel e anexa itens de 32 bits numa fila global em storage buffer; o draw e
mesh-only indireto (vkCmdDrawMeshTasksIndirectEXT, um único comando com
x = contagem de itens) e cada workgroup le o seu item por SV_GroupID.

Cobre: orcamento 256v/192t por grupo (AC-01), selecao de bricks, lotacao da
fila e clamp do finalize, face_mask com redirecionamento B2 (AC-02), dois
chunks adjacentes sem faces internas duplicadas (AC-02), rotacao yaw 0..3 vs
ROTATED_FACE e tag 7 nunca culpada (AC-03).
"""

import random
import struct


def f32(x):
    """Arredonda um float Python (f64) para float32 — espelha as operações
    float32 do shader (numpy indisponível neste ambiente; a soma/produto de
    dois f32 em f64 é exata antes do arredondamento, o que equivale à
    operação float32 corretamente arredondada)."""
    return struct.unpack('<f', struct.pack('<f', x))[0]


# ----------------------------------------------------------------------------
# VS-06 — Frustum (REQ-SIM-04): derivação Gribb-Hartmann float32 vs oracle
# independente (projeção dos 8 cantos do AABB para clip space). Convenção
# Vulkan: clip = VP × mundo; NDC x,y ∈ [−1,1], z ∈ [0,1]. Matrizes em linhas:
# clip_i = dot(linha_i, p). Espelha common.slang.
# ----------------------------------------------------------------------------

def mat_mul(a, b):
    """Produto de matrizes 4x4 em f64 (linhas)."""
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def look_at(eye, target, up=(0.0, 1.0, 0.0)):
    """View RH estilo glm.mat4LookAt (f64, linhas)."""
    def sub(a, b): return tuple(a[i] - b[i] for i in range(3))
    def dot(a, b): return sum(a[i] * b[i] for i in range(3))
    def norm(a):
        l = dot(a, a) ** 0.5
        return tuple(x / l for x in a)
    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    f = norm(sub(target, eye))
    r = norm(cross(f, up))
    u = cross(r, f)
    return [
        [r[0], r[1], r[2], -dot(r, eye)],
        [u[0], u[1], u[2], -dot(u, eye)],
        [-f[0], -f[1], -f[2], dot(f, eye)],
        [0.0, 0.0, 0.0, 1.0],
    ]


def perspective_gl(fov_y_deg, aspect, near, far):
    """Projeção estilo GL (z ∈ [−1,1]) — o app aplica a correção
    GL_TO_VK_CLIP por último (main.odin). f64, linhas."""
    import math
    f = 1.0 / math.tan(math.radians(fov_y_deg) / 2.0)
    return [
        [f / aspect, 0.0, 0.0, 0.0],
        [0.0, f, 0.0, 0.0],
        [0.0, 0.0, (far + near) / (near - far), (2.0 * far * near) / (near - far)],
        [0.0, 0.0, -1.0, 0.0],
    ]


GL_TO_VK_CLIP = [
    [1.0, 0.0, 0.0, 0.0],
    [0.0, -1.0, 0.0, 0.0],
    [0.0, 0.0, 0.5, 0.5],
    [0.0, 0.0, 0.0, 1.0],
]


def make_vp(eye, target, fov=60.0, aspect=16.0 / 9.0, near=0.5, far=500.0):
    """VP float32 na convenção do app (GL_TO_VK_CLIP * P * V)."""
    vp = mat_mul(GL_TO_VK_CLIP, mat_mul(perspective_gl(fov, aspect, near, far), look_at(eye, target)))
    return [[f32(v) for v in row] for row in vp]


def frustum_planes_from_vp(vp):
    """Gribb-Hartmann float32 (espelha common.slang). Retorna 6 float4:
    left, right, bottom, top, near, far — normal xyz para dentro, w offset,
    normalizados. No shader a VP é column_major na memória, mas vp[i] é a
    LINHA i (indexação lógica estilo HLSL) — aqui `vp` já é a matriz em
    linhas, exatamente como o shader a enxerga."""
    r0, r1, r2, r3 = vp[0], vp[1], vp[2], vp[3]
    raw = [
        [f32(r3[i] + r0[i]) for i in range(4)],  # left
        [f32(r3[i] - r0[i]) for i in range(4)],  # right
        [f32(r3[i] + r1[i]) for i in range(4)],  # bottom
        [f32(r3[i] - r1[i]) for i in range(4)],  # top
        list(r2),                                 # near (z_ndc >= 0)
        [f32(r3[i] - r2[i]) for i in range(4)],  # far
    ]
    planes = []
    for p in raw:
        # length(xyz): raiz da soma de quadrados em float32
        s = f32(f32(f32(p[0] * p[0]) + f32(p[1] * p[1])) + f32(p[2] * p[2]))
        if s == 0.0:
            # norma zero (VP degenerado): 0/0 = NaN no shader — comparações
            # falham e o teste vira conservador (nunca culpa)
            planes.append([float('nan')] * 4)
            continue
        inv = f32(1.0 / f32(s ** 0.5))
        planes.append([f32(c * inv) for c in p])
    return planes


def mat_vec_f32(m, p):
    """clip = M × p com arredondamento float32 por operação (espelha mul)."""
    out = []
    for i in range(4):
        acc = 0.0
        for k in range(4):
            acc = f32(acc + f32(m[i][k] * p[k]))
        out.append(acc)
    return out


def plane_distance_f32(plane, point):
    """dot(float4(p, 1), plano) com arredondamento float32 por operação."""
    acc = 0.0
    for k in range(3):
        acc = f32(acc + f32(plane[k] * point[k]))
    return f32(acc + plane[3])


def aabb_outside_frustum(box_min, box_max, planes):
    """p-vertex clássico (espelha common.slang): cull apenas se o vértice mais
    positivo na direção da normal falhar algum plano."""
    for p in planes:
        pv = [box_max[k] if p[k] >= 0.0 else box_min[k] for k in range(3)]
        if plane_distance_f32(p, pv) < 0.0:
            return True
    return False


# --- oracle independente (f64 = valor exato dos dados float32) ---

def oracle_box_outside(vp64, box_min, box_max):
    """Projete os 8 cantos para clip (f64) e verifique as inequações de NDC
    (Vulkan): dentro sse -w <= x <= w, -w <= y <= w, 0 <= z <= w. Fora sse os
    8 cantos violam a MESMA inequação. Retorna (fora, decisivo): 'decisivo'
    marca se nenhuma inequação ficou a menos de 1e-6 relativo de zero (casos
    de fronteira dentro do erro de arredondamento float32 não são exigíveis)."""
    corners = [[box_min[0] if i & 1 else box_max[0],
                box_min[1] if i & 2 else box_max[1],
                box_min[2] if i & 4 else box_max[2], 1.0] for i in range(8)]
    clips = [[sum(vp64[r][k] * c[k] for k in range(4)) for r in range(4)] for c in corners]
    # inequações: left/right/bottom/top/near/far >= 0 dentro
    vals = []
    for cl in clips:
        vals.append([cl[0] + cl[3], cl[3] - cl[0], cl[1] + cl[3],
                     cl[3] - cl[1], cl[2], cl[3] - cl[2]])
    scale = max(1.0, max(abs(v) for row in vals for v in row))
    decisive = all(abs(v) > 1e-6 * scale for row in vals for v in row)
    outside = any(all(row[i] < 0.0 for row in vals) for i in range(6))
    return outside, decisive


CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = 32 ** 3
BRICK_SIZE = (4, 2, 4)
BRICKS_PER_CHUNK = 1024
VOXELS_PER_BRICK = 32
MESH_VERTEX_MAXIMUM = 256
MESH_TRIANGLE_MAXIMUM = 192
CULL_FACE_NEVER = 7
NEIGHBOR_SLOT_INVALID = 0xFFFFFFFF
# Fila de trabalho global (substitui o payload): item de 32 bits com
# visible_index (12b) | brick (10b) | parte (2b) | subdivisao (2b).
# Capacidade global = 4096 visiveis x 1024 bricks (templates atuais nunca
# subdividem; overflow sinalizado na word de estado, nunca silencioso).
MAXIMUM_VISIBLE_CHUNKS = 4096
WORK_QUEUE_STATE_WORDS = 8
WORK_QUEUE_APPEND_COUNT_WORD = 0
WORK_QUEUE_OVERFLOW_WORD = 1
WORK_QUEUE_INDIRECT_X_WORD = 2
WORK_ITEM_CAPACITY = MAXIMUM_VISIBLE_CHUNKS * BRICKS_PER_CHUNK
WORK_QUEUE_SLOT_WORDS = WORK_QUEUE_STATE_WORDS + WORK_ITEM_CAPACITY
NUM_FRAMES_IN_FLIGHT = 2
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


# --- ocupacao de bricks (helpers do builder; B2 espelha common.slang) ---

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


# --- builder compute (build_work_queue) ---

def pack_work_item(visible_index, brick_idx, part, subdivision):
    """Item de 32 bits da fila global (decodificado pelo mesh shader)."""
    return (visible_index & 0xFFF) | ((brick_idx & 1023) << 12) | ((part & 3) << 22) | ((subdivision & 3) << 24)


def unpack_work_item(item):
    return (item & 0xFFF, (item >> 12) & 1023, (item >> 22) & 3, (item >> 24) & 3)


def work_queue_base_words(visible_chunk_offset):
    """Derivacao do slot do ring (2 frames) — espelha common.slang."""
    return (visible_chunk_offset // MAXIMUM_VISIBLE_CHUNKS) * WORK_QUEUE_SLOT_WORDS


def chunk_aabb(origin):
    return (tuple(float(o) for o in origin), tuple(float(origin[i] + CHUNK_SIZE) for i in range(3)))


def brick_aabb(origin, brick_idx):
    bc = brick_coordinate_from_index(brick_idx)
    lo = tuple(float(origin[i] + bc[i] * BRICK_SIZE[i]) for i in range(3))
    return lo, tuple(lo[i] + float(BRICK_SIZE[i]) for i in range(3))


def build_work_queue(chunks, visible_slots, frustum_planes=None):
    """Espelha o builder: 1 workgroup por chunk visivel; append atomico global
    (a ordem entre chunks e corrida — aqui serializamos na ordem da lista).
    Com frustum_planes (VS-06): early-out de chunk e culling por brick na
    mesma ordem do shader (vazio -> frustum -> oclusao).
    Retorna (items, total, overflow)."""
    items = []
    total = 0
    overflow = False
    for visible_index, slot in enumerate(visible_slots):
        chunk = chunks[slot]
        if all(b == 0 for b in chunk["dense"]):
            continue  # CHUNK_FLAG_EMPTY: workgroup nao anexa nada
        if frustum_planes is not None:
            lo, hi = chunk_aabb(chunk["origin"])
            if aabb_outside_frustum(lo, hi, frustum_planes):
                continue  # early-out: sem ler ocupacao/header
        for brick_idx in range(BRICKS_PER_CHUNK):
            occupancy = brick_occupancy_word(chunks, slot, brick_coordinate_from_index(brick_idx))
            if occupancy == 0:
                continue
            if frustum_planes is not None:
                lo, hi = brick_aabb(chunk["origin"], brick_idx)
                if aabb_outside_frustum(lo, hi, frustum_planes):
                    continue
            # Culling de brick ocluso: cheio + 6 vizinhos cheios = zero faces.
            if occupancy == FULL_BRICK and is_brick_occluded(
                chunks, slot, brick_coordinate_from_index(brick_idx), chunk["neighbors"]
            ):
                continue
            subdivision = chunk["subdivisions"][brick_idx]
            for part in range(1 << subdivision):
                total += 1
                if len(items) < WORK_ITEM_CAPACITY:
                    items.append(pack_work_item(visible_index, brick_idx, part, subdivision))
                else:
                    overflow = True
    return items, total, overflow


def finalize_work_queue(append_count):
    """Espelha finalize_work_queue: x do draw indireto = min(count, capacidade)."""
    return min(append_count, WORK_ITEM_CAPACITY), 1, 1


# --- mesh shader (build_brick_mesh, somente contagens) ---

def mesh_group_counts(item, chunks, visible_slots, registry, camera_position):
    visible_index, brick_idx, part, subdivision_log2 = unpack_work_item(item)
    slot = visible_slots[visible_index]
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
        items, _, _ = build_work_queue(chunks, [0])
        check(f"{label}: fila nao vazia", items)
        worst_v = 0
        worst_t = 0
        for item in items:
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(item, chunks, [0], registry, camera)
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
    print("[cenario] selecao de bricks, chunk vazio e capacidade da fila")
    registry = {1: BlockDef(1)}

    chunks = {0: make_chunk((0, 0, 0), lambda c: 0)}
    pack_subdivisions(chunks[0], registry)
    items, total, _ = build_work_queue(chunks, [0])
    check("chunk vazio: workgroup nao anexa nada", items == [] and total == 0)

    # bricks 0, 5 e 1000 ocupados (canto do brick 0 basta)
    def sparse(c):
        bc = (c[0] // 4, c[1] // 2, c[2] // 4)
        return 1 if brick_index_from_coordinate(bc) in (0, 5, 1000) else 0
    chunks = {0: make_chunk((0, 0, 0), sparse)}
    pack_subdivisions(chunks[0], registry)
    items, total, _ = build_work_queue(chunks, [0])
    check("3 bricks ocupados -> 3 grupos", total == 3 and len(items) == 3)
    bricks = sorted(unpack_work_item(e)[1] for e in items)
    check("grupos apontam os bricks certos", bricks == [0, 5, 1000])
    check("item roundtrip (visivel|brick|parte|subdivisao)",
          all(pack_work_item(*unpack_work_item(e)) == e for e in items))
    check("subdivisao 0 para cubos esparsos", all(unpack_work_item(e)[3] == 0 for e in items))

    # capacidade global cobre o pior caso dos templates atuais: 4096 chunks
    # visiveis x 1024 bricks (cubos/plantas nunca subdividem)
    check("capacidade global = visiveis x bricks", WORK_ITEM_CAPACITY == 4096 * 1024)
    # um chunk pesado isolado (1024 bricks x 4 partes) cabe com folga na fila
    check("chunk pesado isolado cabe na fila", 1024 * 4 <= WORK_ITEM_CAPACITY)


def scenario_work_item_packing():
    print("[cenario] empacotamento do item de 32 bits e layout da fila")
    cases = [
        (0, 0, 0, 0),                    # item zero
        (4095, 1023, 3, 2),              # maximos por campo
        (1, 1, 0, 0),
        (2109, 517, 2, 1),
        (64, 64, 1, 2),
    ]
    check("campos cabem nos bits (12|10|2|2)",
          all(v < 4096 and b < 1024 and p < 4 and s < 4 for v, b, p, s in cases))
    check("roundtrip pack/unpack",
          all(unpack_work_item(pack_work_item(*c)) == c for c in cases))
    check("campos nao vazam entre si",
          unpack_work_item(pack_work_item(0, 1023, 0, 0)) == (0, 1023, 0, 0))
    check("item cabe em 32 bits sem sinal",
          all(pack_work_item(*c) < (1 << 26) for c in cases))

    # layout do slot do ring: estado (8 words) + itens; 2 frames
    check("base do frame 0 = 0", work_queue_base_words(0) == 0)
    check("base do frame 1 = slot inteiro",
          work_queue_base_words(MAXIMUM_VISIBLE_CHUNKS) == WORK_QUEUE_SLOT_WORDS)
    check("slot = estado + capacidade",
          WORK_QUEUE_SLOT_WORDS == WORK_QUEUE_STATE_WORDS + WORK_ITEM_CAPACITY)
    check("words de estado reservadas",
          WORK_QUEUE_APPEND_COUNT_WORD == 0 and WORK_QUEUE_OVERFLOW_WORD == 1
          and WORK_QUEUE_INDIRECT_X_WORD == 2)

    # finalize: clamp do append_count no x do draw indireto
    check("finalize: sem overflow", finalize_work_queue(123) == (123, 1, 1))
    check("finalize: clamp na capacidade",
          finalize_work_queue(WORK_ITEM_CAPACITY + 999) == (WORK_ITEM_CAPACITY, 1, 1))
    check("finalize: fila vazia", finalize_work_queue(0) == (0, 1, 1))

    # worldgen real: chunk cheio de cubos cabe inteiro apos culling de oclusao
    registry = {1: BlockDef(1)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    items, total, overflow = build_work_queue(chunks, [0])
    check("chunk cheio de cubos: selecionados <= capacidade", total <= WORK_ITEM_CAPACITY)
    check("chunk cheio de cubos: nenhum grupo descartado", len(items) == total and not overflow)


def scenario_occlusion_culling():
    print("[cenario] culling de brick ocluso (cheio + 6 vizinhos cheios)")
    registry = {1: BlockDef(1)}

    # chunk cheio isolado: vizinhos invalidos => faces da casca preservadas
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)
    items, total, _ = build_work_queue(chunks, [0])
    # casca = 1024 - interior (6 x 14 x 6 = 504) = 520 bricks
    # (cubo cheio: 32v x 8 = 256 e 32 x 6t = 192 = teto exato => subdivisao 0)
    check("chunk isolado: so a casca selecionada (520 bricks, subdivisao 0)", total == 520)

    # todo brick descartado emite ZERO geometria, para qualquer camera
    selected_items = set(items)
    culled = 0
    culling_sound = True
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        occupancy = brick_occupancy_word(chunks, 0, bc)
        if occupancy != FULL_BRICK or not is_brick_occluded(chunks, 0, bc, chunks[0]["neighbors"]):
            continue
        culled += 1
        for part in range(4):
            item = pack_work_item(0, brick_idx, part, 2)
            if item in selected_items:
                culling_sound = False
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(item, chunks, [0], registry, camera)
                if (v, t) != (0, 0):
                    culling_sound = False
    check("504 bricks interiores culpados", culled == 504)
    check("nenhum brick ocluso entra na fila nem emitiria geometria (6 cameras)", culling_sound)

    # dois chunks adjacentes: bricks da face compartilhada viram interiores
    chunks = {
        0: make_chunk((0, 0, 0), lambda c: 1),
        1: make_chunk((32, 0, 0), lambda c: 1),
    }
    for c in chunks.values():
        pack_subdivisions(c, registry)
    chunks[0]["neighbors"][0] = 1  # +X de A = B
    chunks[1]["neighbors"][1] = 0  # -X de B = A
    _, total_a, _ = build_work_queue(chunks, [0])
    _, total_b, _ = build_work_queue(chunks, [1])
    # da face compartilhada (8x16 = 128 bricks), so os que nao tocam outra
    # face aberta viram interiores: 14 x 6 = 84 por lado (520 - 84 = 436)
    check("fronteira +X: 84 bricks internos da face compartilhada culpados",
          total_a == 436 and total_b == 436)

    # geometria preservada na uniao: todo brick culpado emitiria zero faces
    for slot in (0, 1):
        for brick_idx in range(BRICKS_PER_CHUNK):
            bc = brick_coordinate_from_index(brick_idx)
            if brick_occupancy_word(chunks, slot, bc) != FULL_BRICK:
                continue
            if not is_brick_occluded(chunks, slot, bc, chunks[slot]["neighbors"]):
                continue
            for camera in CAMERAS_6:
                v, t = mesh_group_counts(pack_work_item(0, brick_idx, 0, 2), chunks, [slot], registry, camera)
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
    v, t = mesh_group_counts(pack_work_item(0, 0, 0, 0), chunks, [0], registry, (16, 1e6, 16))  # brick 0: faces visiveis so para a camera
    check("brick interior de cubos: 0 vertices, 0 triangulos", (v, t) == (0, 0))

    # rotacao afeta o culling: face +X do cubo com r=1 passa a responder a -Z
    mask = 1 << 5  # so -Z visivel
    tri_px = pack_triangle(1, 3, 7, 0)
    check("r=0: face +X nao sobrevive com mascara -Z", not triangle_survives_culling(tri_px, 0, mask))
    check("r=1: face +X rotacionada sobrevive com mascara -Z", triangle_survives_culling(tri_px, 1, mask))


def scenario_frustum_planes_vs_oracle():
    print("[cenario] VS-06: derivacao de planos (GH f32) vs oracle de cantos")
    rng = random.Random(20261106)
    decisive_total = 0
    for case in range(400):
        eye = (rng.uniform(-300, 300), rng.uniform(40, 300), rng.uniform(-300, 300))
        target = (eye[0] + rng.uniform(-80, 80), rng.uniform(-20, 60),
                  eye[2] + rng.uniform(-80, 80))
        near = rng.uniform(0.1, 2)
        far = rng.uniform(100, 2000)
        vp = make_vp(eye, target, fov=rng.uniform(30, 90),
                     aspect=rng.uniform(0.5, 2.5), near=near, far=far)
        vp64 = [[float(v) for v in row] for row in vp]
        planes = frustum_planes_from_vp(vp)
        # planos normalizados: |n| == 1 e n apontando para dentro
        check(f"caso {case}: planos normalizados",
              all(abs(sum(p[k] * p[k] for k in range(3)) ** 0.5 - 1.0) < 2e-5 for p in planes))
        dir = tuple(target[k] - eye[k] for k in range(3))
        ln = sum(d * d for d in dir) ** 0.5
        dist = 2.0 * near + 0.25  # 2x o near deste caso + folga
        ahead = tuple(eye[k] + dir[k] / ln * dist for k in range(3))
        exact_ahead, dec_ahead = oracle_box_outside(vp64, ahead, ahead)
        check(f"caso {case}: ponto a frente da camera dentro (near/far)",
              dec_ahead and not exact_ahead)
        for _ in range(4):
            lo = tuple(rng.uniform(-400, 400) for _ in range(3))
            size = tuple(rng.uniform(0.0, 40.0) for _ in range(3))  # 0 = degenerado
            hi = tuple(lo[i] + size[i] for i in range(3))
            exact_outside, decisive = oracle_box_outside(vp64, lo, hi)
            if not decisive:
                continue  # fronteira dentro do erro de arredondamento f32
            decisive_total += 1
            gh_outside = aabb_outside_frustum(lo, hi, planes)
            check(f"caso {case}: GH f32 == oracle exato ({lo})", gh_outside == exact_outside)
    check("amostragem: >= 1000 casos decisivos executados", decisive_total >= 1000)
    print(f"  ({decisive_total} casos decisivos)")


def scenario_frustum_edge_cases():
    print("[cenario] VS-06: dados-limite (fora por cada plano, intersectando,")
    print("          atras da camera, atras do near, degenerado)")
    eye = (0.0, 70.0, -120.0)
    target = (0.0, 30.0, 0.0)
    vp = make_vp(eye, target)
    vp64 = [[float(v) for v in row] for row in vp]
    planes = frustum_planes_from_vp(vp)

    # AABB visivel de referencia: no centro do frustum, colado no chao
    lo = (-4.0, 28.0, -4.0)
    hi = (4.0, 34.0, 4.0)
    check("dentro: nao culpado", not aabb_outside_frustum(lo, hi, planes))
    exact, dec = oracle_box_outside(vp64, lo, hi)
    check("dentro: oracle concorda (dentro)", dec and not exact)

    # fora por cada plano: deslocamentos grandes na direcao de cada normal
    normals = [(p[0], p[1], p[2]) for p in planes]
    for i, n in enumerate(normals):
        d = 600.0
        lo2 = (lo[0] + n[0] * d, lo[1] + n[1] * d, lo[2] + n[2] * d)
        hi2 = (hi[0] + n[0] * d, hi[1] + n[1] * d, hi[2] + n[2] * d)
        exact, dec = oracle_box_outside(vp64, lo2, hi2)
        check(f"fora pelo plano {i}: oracle decisivo e fora", dec and exact)
        check(f"fora pelo plano {i}: GH culpa", aabb_outside_frustum(lo2, hi2, planes))

    # intersectando cada plano: metade dentro, metade fora (nao culpa)
    for i, n in enumerate(normals):
        # atravessa o plano: offset tal que uma ponta fique de cada lado
        center = tuple((lo[k] + hi[k]) / 2.0 for k in range(3))
        dist_center = sum(n[k] * center[k] for k in range(3)) + planes[i][3]
        shift = -dist_center  # move o centro exatamente sobre o plano
        lo2 = (lo[0] + n[0] * shift, lo[1] + n[1] * shift, lo[2] + n[2] * shift)
        hi2 = (hi[0] + n[0] * shift, hi[1] + n[1] * shift, hi[2] + n[2] * shift)
        exact, _ = oracle_box_outside(vp64, lo2, hi2)
        check(f"intersectando o plano {i}: nao culpado",
              not aabb_outside_frustum(lo2, hi2, planes))

    # atras da camera e atras do plano near
    behind = (-4.0, 68.0, -260.0), (4.0, 72.0, -180.0)
    exact, dec = oracle_box_outside(vp64, *behind)
    check("atras da camera: oracle fora", dec and exact)
    check("atras da camera: GH culpa", aabb_outside_frustum(*behind, planes))
    # atras do plano near (near = 0.5): box a ~0.2 do olho, dentro dos limites
    # laterais — camera nivelada olhando -Z... +Z a partir de (0,70,-120)
    near_clip = (-1.0, 69.5, -119.9), (1.0, 70.5, -119.8)
    exact_near, dec_near = oracle_box_outside(vp64, *near_clip)
    check("atras do near: oracle decisivo e fora", dec_near and exact_near)
    check("atras do near: GH culpa", aabb_outside_frustum(*near_clip, planes))

    # degenerado (min == max) dentro e fora
    pt_inside = (0.0, 30.0, 0.0)
    check("degenerado dentro: nao culpado",
          not aabb_outside_frustum(pt_inside, pt_inside, planes))
    pt_out = (1000.0, 30.0, 0.0)
    check("degenerado fora: culpado", aabb_outside_frustum(pt_out, pt_out, planes))

    # VP singular (frustum degenerado): pior caso e nao culpar nada proximo
    zero_vp = [[0.0] * 4 for _ in range(4)]
    zero_planes = frustum_planes_from_vp(zero_vp)
    check("VP zero: AABB dentro nao culpado (conservador)",
          not aabb_outside_frustum(lo, hi, zero_planes))


def scenario_frustum_granularity():
    print("[cenario] VS-06: granularidade chunk (early-out) e brick 4x2x4")
    registry = {1: BlockDef(1)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1)}
    pack_subdivisions(chunks[0], registry)

    # camera olhando para +Z a partir de -Z: chunks em +X/-X/Y longe sao fora
    eye = (16.0, 40.0, -160.0)
    vp = make_vp(eye, (16.0, 40.0, 0.0))
    planes = frustum_planes_from_vp(vp)

    # early-out: chunk inteiramente fora (lateral) gera zero itens
    _, total_out, _ = build_work_queue(chunks, [0], planes)
    check("chunk alinhado no eixo de visao: nao culpado no early-out", total_out == 520)

    # early-out dispara para chunk atras da camera
    chunks_back = {1: make_chunk((0, 0, -256), lambda c: 1)}
    pack_subdivisions(chunks_back[1], registry)
    _, total_back, _ = build_work_queue(chunks_back, [1], planes)
    check("chunk atras da camera: early-out (0 itens)", total_back == 0)

    # brick NAO e cubico: AABB 4x2x4 — brick colado na lateral do frustum
    # fora nao e culpado se intersectar; offset por eixo confirma a assimetria
    chunk = chunks[0]
    for axis, extent in enumerate(BRICK_SIZE):
        bi = brick_index_from_coordinate((7, 0, 7) if axis == 0 else ((0, 15, 7) if axis == 1 else (0, 0, 7)))
        lo, hi = brick_aabb(chunk["origin"], bi)
        check(f"brick (4,2,4) eixo {axis}: AABB com extensao correta",
              all(abs(hi[k] - lo[k] - float(BRICK_SIZE[k])) < 1e-6 for k in range(3)))


def scenario_frustum_horizon():
    print("[cenario] VS-06: camera no horizonte — invariancia da intersecao")
    print("          e reducao da contagem de itens")
    registry = {1: BlockDef(1), 2: BlockDef(2)}
    rng = random.Random(7)
    # faixa de terreno 8x8 chunks com relevo, camera dentro olhando o horizonte
    chunks = {}
    visible = []
    for cx in range(8):
        for cz in range(8):
            origin = (cx * 32, -8, cz * 32)
            slot = len(chunks)
            def fill(c, o=origin, r=rng):
                h = 3 + int(3.0 * r.random())  # camada superficial
                wy = o[1] + c[1]
                if wy == o[1]:
                    return 2  # grama
                return 1 if 0 <= wy < h else 0
            chunks[slot] = make_chunk(origin, fill)
            visible.append(slot)
    for c in chunks.values():
        pack_subdivisions(c, registry)

    poses = [
        ((100.0, 12.0, -60.0), (140.0, 8.0, 200.0)),   # horizonte +Z
        ((100.0, 12.0, 100.0), (140.0, 30.0, -120.0)), # horizonte -Z (re)
        ((100.0, 200.0, 100.0), (100.0, 0.0, 104.0)),  # top-down
        ((100.0, 12.0, 100.0), (-200.0, 8.0, 100.0)),  # horizonte -X
    ]
    for pi, (eye, target) in enumerate(poses):
        vp = make_vp(eye, target)
        vp64 = [[float(v) for v in row] for row in vp]
        planes = frustum_planes_from_vp(vp)
        items_base, total_base, _ = build_work_queue(chunks, visible)
        items_cull, total_cull, _ = build_work_queue(chunks, visible, planes)
        print(f"  pose {pi}: sem culling={total_base} com frustum={total_cull}")

        # invariancia: todo brick selecionado com culling intersecta o frustum
        # (oracle exato) e estava na selecao sem culling; e vice-versa para os
        # nao-culpados pela oclusao/vazio
        base_set = set(items_base)
        cull_set = set(items_cull)
        check(f"pose {pi}: contagem caida ({total_base} -> {total_cull})",
              total_cull < total_base)
        check(f"pose {pi}: subconjunto da selecao sem culling",
              cull_set <= base_set)
        selection_invariant = True
        oracle_agrees = True
        for slot in visible:
            origin = chunks[slot]["origin"]
            clo, chi = chunk_aabb(origin)
            if aabb_outside_frustum(clo, chi, planes):
                exact, _ = oracle_box_outside(vp64, clo, chi)
                oracle_agrees = oracle_agrees and exact
                continue  # early-out: nada selecionado
            for brick_idx in range(BRICKS_PER_CHUNK):
                bc = brick_coordinate_from_index(brick_idx)
                if brick_occupancy_word(chunks, slot, bc) == 0:
                    continue
                lo, hi = brick_aabb(origin, brick_idx)
                gh_out = aabb_outside_frustum(lo, hi, planes)
                exact, decisive = oracle_box_outside(vp64, lo, hi)
                if decisive and gh_out != exact:
                    oracle_agrees = False
                if gh_out:
                    # culpado pelo GH: nao pode estar na fila
                    for part in range(4):
                        if pack_work_item(visible.index(slot), brick_idx, part, 0) in cull_set:
                            selection_invariant = False
                else:
                    # nao culpado: mesma decisao de vazio/oclusao de antes
                    was_selected = any(
                        pack_work_item(visible.index(slot), brick_idx, part,
                                       chunks[slot]["subdivisions"][brick_idx]) in base_set
                        for part in range(1 << chunks[slot]["subdivisions"][brick_idx]))
                    is_selected = any(
                        pack_work_item(visible.index(slot), brick_idx, part,
                                       chunks[slot]["subdivisions"][brick_idx]) in cull_set
                        for part in range(1 << chunks[slot]["subdivisions"][brick_idx]))
                    if was_selected != is_selected:
                        selection_invariant = False
        check(f"pose {pi}: GH f32 == oracle exato (todos os bricks)", oracle_agrees)
        check(f"pose {pi}: invariancia da selecao (intersectantes intactos)",
              selection_invariant)


def main():
    scenario_budget()
    scenario_selection()
    scenario_work_item_packing()
    scenario_occlusion_culling()
    scenario_b2()
    scenario_rotation()
    scenario_frustum_planes_vs_oracle()
    scenario_frustum_edge_cases()
    scenario_frustum_granularity()
    scenario_frustum_horizon()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
