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
ROTATED_FACE e tag 7 nunca culpada (AC-03), VS-10 (EMPTY como vizinho) e
VS-11 (REQ-SIM-08): bounds de UV, roundtrip sentinela -> fallback triplanar
e paridade de cor UV x triplanar na paleta solida; VS-14 (REQ-SIM-11):
template X da planta (orcamento, tags 7, UVs [0,1]^2) e alpha-test cutout
(flags bit 0: descarte com albedo.a < 0.5).
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
# Capacidade = visiveis x 1024 bricks; overflow sinalizado na word de estado,
# nunca silencioso. VS-08: a capacidade passa a ser derivada do raio de
# visão (|esfera(r)|); o default é vision=8 -> 2109 (antes: constante 4096).
def sphere_count(radius):
    """Pontos inteiros com x^2+y^2+z^2 <= r^2 (REQ-CFG-02)."""
    count = 0
    r = int(radius)
    for x in range(-r, r + 1):
        for y in range(-r, r + 1):
            for z in range(-r, r + 1):
                if x * x + y * y + z * z <= r * r:
                    count += 1
    return count


WORK_QUEUE_STATE_WORDS = 8
WORK_QUEUE_APPEND_COUNT_WORD = 0
WORK_QUEUE_OVERFLOW_WORD = 1
WORK_QUEUE_INDIRECT_X_WORD = 2
NUM_FRAMES_IN_FLIGHT = 2
# Capacidades de referência (REQ-SIM-05): mín r=2, default r=8, máx r=9.
VISIBLE_CAPACITY_MIN = sphere_count(2)            # 33
VISIBLE_CAPACITY_DEFAULT = sphere_count(8)        # 2109
VISIBLE_CAPACITY_MAX = sphere_count(9)            # 3053
MAXIMUM_VISIBLE_CHUNKS = VISIBLE_CAPACITY_DEFAULT # nome legado dos checks
WORK_ITEM_CAPACITY = MAXIMUM_VISIBLE_CHUNKS * BRICKS_PER_CHUNK
WORK_QUEUE_SLOT_WORDS = WORK_QUEUE_STATE_WORDS + WORK_ITEM_CAPACITY
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
# --- VS-11 (REQ-SIM-08): pool de UVs dos templates (binding 19) ---
# Sentinelas/contratos espelham common.slang/voxel_gpu.odin.
UV_SENTINEL = (-1.0, -1.0)      # emitida pelo mesh shader quando o template nao tem UV
NO_UV_OFFSET = 0xFFFFFFFF       # MeshTemplate.uv_offset: sem pool de UVs
MESH_VERTEX_COMPONENTS = 10     # clip4 + world3 + block_id1 + uv2 (REQ-UV-01)
MAX_MESH_OUTPUT_COMPONENTS = 128  # limite tipico auditado (REQ-UV-01)

# Built-ins com UV (espelham upload_builtin_templates em voxel_gpu.odin):
# cubo: 8 vertices compartilhados entre 3 faces cada — unwrap planar (x,z)
# (equivale a projetar a face +/-Y; simplificacao registrada na VS-11,
# questao aberta de rotacao/unwrap por face);
# planta: cada quad da cruz com [0,1]^2 completo.
CUBE_UVS = [(float(x), float(z)) for (x, y, z) in CUBE_VERTICES]
PLANT_UVS = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)] * 2


def uv_in_bounds(uv):
    """Validacao de carga (REQ-UV-04): UVs de template devem estar em
    [0,1]^2; a sentinela e interna ao mesh shader, nunca aparece num template."""
    return 0.0 <= uv[0] <= 1.0 and 0.0 <= uv[1] <= 1.0


def emit_vertex_uv(template, vertex_index):
    """Espelha a emissao no mesh shader: UV do pool quando o template tem
    pool (uv_offset != NO_UV_OFFSET), senao a sentinela (-1,-1)."""
    if template.uvs is None:
        return UV_SENTINEL
    return template.uvs[vertex_index]


def fragment_uses_triplanar(uv):
    """Espelha shade_voxel: uv.x >= 0 -> amostragem por UV; senao triplanar."""
    return uv[0] < 0.0


# --- VS-14 (REQ-SIM-11): alpha-test cutout no fragment ---

BLOCK_DEFINITION_FLAG_TRANSPARENT = 1  # bit 0 de BlockDefinition.flags
# VS-14 (emenda 2026-11-07): bit 1 — ocupa o voxel mas não é sólido (planta).
BLOCK_DEFINITION_FLAG_NON_SOLID = 2
ALPHA_TEST_THRESHOLD = 0.5  # limiar constante do shader (REQ-PLT-01)


def block_is_solid(block_id, registry):
    """Espelha block_is_solid (common.slang): id 0 nunca é sólido; bloco com
    bit NON_SOLID (planta) ocupa o voxel sem ser sólido."""
    if block_id == 0:
        return False
    if registry is None:
        return True  # cenários legados: ocupação == solidez
    return (registry[block_id].flags & BLOCK_DEFINITION_FLAG_NON_SOLID) == 0


def fragment_survives_alpha_test(block_flags, albedo_alpha):
    """Espelha shade_voxel: bloco transparente descarta fragmento com
    albedo.a < 0.5 (cutout opaco; blocos opacos nunca descartam)."""
    if (block_flags & BLOCK_DEFINITION_FLAG_TRANSPARENT) != 0:
        return albedo_alpha >= ALPHA_TEST_THRESHOLD
    return True


# Template sintetico pesado: 32 vertices, 24 triangulos todos tag NEVER.
HEAVY_VERTICES = [(x / 3.0, y / 3.0, z / 3.0) for x in range(4) for y in range(4) for z in range(2)][:32]
HEAVY_TRIANGLES = [(i % 32, (i + 1) % 32, (i + 2) % 32, CULL_FACE_NEVER) for i in range(24)]


class Template:
    def __init__(self, vertices, triangles, uvs=None):
        self.vertices = vertices
        self.triangles = triangles
        self.uvs = uvs
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
    1: Template(CUBE_VERTICES, CUBE_TRIANGLES, CUBE_UVS),
    2: Template(PLANT_VERTICES, PLANT_TRIANGLES, PLANT_UVS),
    3: Template(HEAVY_VERTICES, HEAVY_TRIANGLES),  # sem UV: fallback triplanar
}


class BlockDef:
    def __init__(self, template_index, rotation=0, flags=0):
        self.template_index = template_index
        self.rotation = rotation
        self.flags = flags


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


def voxel_solid_word_bit(chunks, slot, coord, registry=None):
    brick_coord = (coord[0] // 4, coord[1] // 2, coord[2] // 4)
    bit = bit_index_from_local_coordinate((coord[0] % 4, coord[1] % 2, coord[2] % 4))
    return (brick_solid_word(chunks, slot, brick_coord, registry) & (1 << bit)) != 0


def is_voxel_solid(chunks, slot, coord, neighbor_slots, registry=None):
    if all(0 <= c < CHUNK_SIZE for c in coord):
        return voxel_solid_word_bit(chunks, slot, coord, registry)
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
    return voxel_solid_word_bit(chunks, neighbor_slot, tuple(c), registry)


def compute_visible_face_mask(chunks, slot, coord, neighbor_slots, camera_position, registry=None):
    origin = chunks[slot]["origin"]
    voxel_min_world = tuple(origin[i] + coord[i] for i in range(3))
    face_mask = 0
    for face_index in range(6):
        n = FACE_NORMALS[face_index]
        neighbor_coord = tuple(coord[i] + n[i] for i in range(3))
        if is_voxel_solid(chunks, slot, neighbor_coord, neighbor_slots, registry):
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


def brick_solid_word(chunks, slot, brick_coord, registry=None):
    """Solid word produzida pela fase A do pack; leitura de um word no mesh."""
    mask = 0
    for bit in range(VOXELS_PER_BRICK):
        lc = local_coordinate_from_bit_index(bit)
        coord = (brick_coord[0] * 4 + lc[0], brick_coord[1] * 2 + lc[1], brick_coord[2] * 4 + lc[2])
        block_id = chunks[slot]["dense"][dense_index_from_coordinate(coord)]
        if block_is_solid(block_id, registry):
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


def brick_voxels_all_solid(chunks, slot, brick_coord, registry=None):
    """Interior sólido em O(1): compara a solid word com 0xFFFFFFFF."""
    return brick_solid_word(chunks, slot, brick_coord, registry) == FULL_BRICK


def is_brick_occluded(chunks, slot, brick_coord, neighbor_slots, registry=None):
    """Brick cheio de SÓLIDOS com os 6 bricks vizinhos cheios de sólidos:
    nenhum voxel tem face exposta (independente da camera), entao o grupo nao
    emitiria geometria. Vizinho ausente ou com planta => nao culpado."""
    if not brick_voxels_all_solid(chunks, slot, brick_coord, registry):
        return False
    for face in range(6):
        n = FACE_NORMALS[face]
        nb = (brick_coord[0] + n[0], brick_coord[1] + n[1], brick_coord[2] + n[2])
        if all(0 <= nb[i] < BRICKS_PER_CHUNK_AXIS[i] for i in range(3)):
            n_slot, n_bc = slot, nb
        else:
            c = list(nb)
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
                return False
            n_slot, n_bc = neighbor_slot, tuple(c)
        if not brick_voxels_all_solid(chunks, n_slot, n_bc, registry):
            return False
    return True


# --- builder compute (build_work_queue) ---

def pack_work_item(visible_index, brick_idx, part, subdivision):
    """Item de 32 bits da fila global (decodificado pelo mesh shader)."""
    # VS-09 (REQ-WID-01): visible_index 16 bits — layout 16|10|2|2
    return (visible_index & 0xFFFF) | ((brick_idx & 1023) << 16) | ((part & 3) << 26) | ((subdivision & 3) << 28)


def unpack_work_item(item):
    return (item & 0xFFFF, (item >> 16) & 1023, (item >> 26) & 3, (item >> 28) & 3)


def work_queue_base_words(visible_chunk_offset, visible_capacity=MAXIMUM_VISIBLE_CHUNKS):
    """Derivacao do slot do ring (2 frames) — espelha common.slang (VS-08:
    a capacidade vem do push constant visible_chunk_capacity)."""
    slot_words = WORK_QUEUE_STATE_WORDS + visible_capacity * BRICKS_PER_CHUNK
    return (visible_chunk_offset // visible_capacity) * slot_words


def chunk_aabb(origin):
    return (tuple(float(o) for o in origin), tuple(float(origin[i] + CHUNK_SIZE) for i in range(3)))


def brick_aabb(origin, brick_idx):
    bc = brick_coordinate_from_index(brick_idx)
    lo = tuple(float(origin[i] + bc[i] * BRICK_SIZE[i]) for i in range(3))
    return lo, tuple(lo[i] + float(BRICK_SIZE[i]) for i in range(3))


def build_work_queue(chunks, visible_slots, frustum_planes=None,
                     visible_capacity=MAXIMUM_VISIBLE_CHUNKS, registry=None):
    """Espelha o builder: 1 workgroup por chunk visivel; append atomico global
    (a ordem entre chunks e corrida — aqui serializamos na ordem da lista).
    Com frustum_planes (VS-06): early-out de chunk e culling por brick na
    mesma ordem do shader (vazio -> frustum -> oclusao).
    Retorna (items, total, overflow)."""
    work_item_capacity = visible_capacity * BRICKS_PER_CHUNK
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
            # Culling de brick ocluso: cheio de sólidos + 6 vizinhos cheios de
            # sólidos = zero faces.
            if occupancy == FULL_BRICK and is_brick_occluded(
                chunks, slot, brick_coordinate_from_index(brick_idx), chunk["neighbors"], registry
            ):
                continue
            subdivision = chunk["subdivisions"][brick_idx]
            for part in range(1 << subdivision):
                total += 1
                if len(items) < work_item_capacity:
                    items.append(pack_work_item(visible_index, brick_idx, part, subdivision))
                else:
                    overflow = True
    return items, total, overflow


def finalize_work_queue(append_count, visible_capacity=MAXIMUM_VISIBLE_CHUNKS):
    """Espelha finalize_work_queue: x do draw indireto = min(count, capacidade)."""
    return min(append_count, visible_capacity * BRICKS_PER_CHUNK), 1, 1


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
            face_mask = compute_visible_face_mask(chunks, slot, coord, chunk["neighbors"], camera_position, registry)
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

    # capacidade derivada cobre o pior caso dos templates atuais: visiveis x
    # 1024 bricks (cubos/plantas nunca subdividem)
    check("capacidade global = visiveis x bricks", WORK_ITEM_CAPACITY == VISIBLE_CAPACITY_DEFAULT * 1024)
    # um chunk pesado isolado (1024 bricks x 4 partes) cabe com folga na fila
    check("chunk pesado isolado cabe na fila", 1024 * 4 <= WORK_ITEM_CAPACITY)


def scenario_work_item_packing():
    print("[cenario] empacotamento do item de 32 bits e layout da fila")
    # VS-09 (REQ-WID-01): visible_index 16 bits; cantos nas fronteiras de campo
    corners = [(v, b, p, s)
               for v in (0, 4095, 4096, 65535)
               for b in (0, 1023)
               for p in (0, 3)
               for s in (0, 3)]
    check("roundtrip nos cantos (16|10|2|2)",
          all(unpack_work_item(pack_work_item(*c)) == c for c in corners))
    check("campos nao vazam entre si (16 bits)",
          unpack_work_item(pack_work_item(0, 1023, 0, 0)) == (0, 1023, 0, 0)
          and unpack_work_item(pack_work_item(65535, 0, 3, 3)) == (65535, 0, 3, 3))
    check("itens abaixo de 1<<30 (30 bits usados, 2 de reserva)",
          all(pack_work_item(*c) < (1 << 30) for c in corners))
    check("bit 12 antigo nao colide: 4096 != 0",
          pack_work_item(4096, 0, 0, 0) != pack_work_item(0, 0, 0, 0))

    # aritmetica do ring no pior caso (REQ-WID-03): 2 x (8 + 65535 x 1024)
    # words ~ 134 M < 2^32 — offsets/indices permanecem u32
    worst_words = 2 * (WORK_QUEUE_STATE_WORDS + 65535 * BRICKS_PER_CHUNK)
    check("pior caso do ring cabe em u32 (2^32)", worst_words < (1 << 32))

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


# --- VS-10 (REQ-SIM-07): publish/vizinhos com chunks EMPTY ---

CHUNK_STATE_GENERATING = 0
CHUNK_STATE_CACHED = 1
CHUNK_STATE_RENDERABLE = 2
CHUNK_STATE_EMPTY = 3  # registro sem slot — nunca publicado


def ve_publish_visible(records):
    """Espelha ve_publish_visible (VS-10/REQ-VRT-03): publica só
    CACHED/RENDERABLE (EMPTY nunca é RENDERABLE); vizinho contribui slot só
    se CACHED/RENDERABLE materializado — EMPTY/GENERATING = INVALID."""
    visible = []
    for coord in sorted(records):
        state, slot = records[coord]
        if state != CHUNK_STATE_RENDERABLE:
            continue
        entry = {"coord": coord, "slot": slot, "neighbors": [NEIGHBOR_SLOT_INVALID] * 6}
        for i, off in enumerate(FACE_NORMALS):
            nrec = records.get((coord[0] + off[0], coord[1] + off[1], coord[2] + off[2]))
            if nrec is not None and nrec[0] in (CHUNK_STATE_CACHED, CHUNK_STATE_RENDERABLE):
                entry["neighbors"][i] = nrec[1]
        visible.append(entry)
    return visible


def scenario_empty_neighbors():
    print("[cenario] VS-10: publish com EMPTY + vizinho INVALID == ar com slot")
    registry = {1: BlockDef(1)}
    camera = (16, 1e6, 16)  # muito acima

    def build_world(neighbor_mode):
        """Mundo A: vizinho +X = chunk de ar COM slot (CACHED).
        Mundo B: vizinho +X = registro EMPTY (sem slot). Geometria de A
        (chunk solido em x=0) deve ser identica nos dois."""
        chunks = {
            0: make_chunk((0, 0, 0), lambda c: 1),
            1: make_chunk((32, 0, 0), lambda c: 0),  # ar puro
        }
        for c in chunks.values():
            pack_subdivisions(c, registry)
        if neighbor_mode == "slot":
            records = {(0, 0, 0): (CHUNK_STATE_RENDERABLE, 0), (1, 0, 0): (CHUNK_STATE_CACHED, 1)}
        else:
            records = {(0, 0, 0): (CHUNK_STATE_RENDERABLE, 0), (1, 0, 0): (CHUNK_STATE_EMPTY, NEIGHBOR_SLOT_INVALID)}
        visible = ve_publish_visible(records)
        return chunks, visible

    worlds = {}
    for mode in ("slot", "empty"):
        chunks, visible = build_world(mode)
        # publica: preenche neighbor_slots do chunk visivel conforme o publish
        entry = visible[0]
        chunks[0]["neighbors"][0] = entry["neighbors"][0]
        check("somente RENDERABLE publicado (1 visivel)", len(visible) == 1)
        items, total, _ = build_work_queue(chunks, [0])
        tris = set()
        for item in items:
            v, t = mesh_group_counts(item, chunks, [0], registry, camera)
            if t > 0:
                tris.add(item)
        worlds[mode] = (set(items), tris, entry["neighbors"][0])

    check("vizinho EMPTY: slot INVALID publicado", worlds["empty"][2] == NEIGHBOR_SLOT_INVALID)
    check("vizinho ar-com-slot: slot publicado", worlds["slot"][2] == 1)
    check("render identico: mesma fila de trabalho", worlds["empty"][0] == worlds["slot"][0])
    check("render identico: mesma geometria emitida", worlds["empty"][1] == worlds["slot"][1])

    # EMPTY visivel na bolha nao publica nem despacha builder
    chunks, visible = build_world("empty")
    check("EMPTY: zero workgroups na fila", build_work_queue(chunks, [0])[1] > 0)
    empty_items, _, _ = build_work_queue({1: chunks[1]}, [1])
    check("chunk de ar (com slot): workgroup early-out, 0 itens", empty_items == [])


# --- VS-08 (REQ-SIM-05): capacidade parametrizada + regras de validação ---

def sphere_count_reference():
    """Contagens de referência (REQ-CFG-02): pontos inteiros com
    x^2+y^2+z^2 <= r^2 — mesma definição de frontier_test.py. Nota: a tabela
    original da spec (523/3053/4189/7238 para r=5/9/10/12) divergia da
    fórmula; os valores abaixo são os corretos (VS-08, 2026-11-06)."""
    return {2: 33, 3: 123, 5: 515, 8: 2109, 9: 3071, 10: 4169, 12: 7153,
            25: 65267, 26: 73525}


def resident_slots(radius_unload):
    """Emenda VS-08 (REQ-CFG-02): slots = ceil(|esfera(unload)| * 1.05) —
    mesmo arredondamento de config.odin: (n*105 + 99) // 100."""
    return (sphere_count(radius_unload) * 105 + 99) // 100


def validate_config_rules(vision, generation, unload, simulation,
                          chunks_per_batch, batches_in_flight):
    """Espelha as regras de coerência de REQ-CFG-03 (VS-09 emenda o formato:
    1 <= vision <= 25); retorna (ok, regra)."""
    if not (1 <= vision <= 25):
        return False, "vision 1..25"
    if simulation < 1:
        return False, "simulation >= 1"
    if generation < vision:
        return False, "generation >= vision"
    if generation >= unload:
        return False, "generation < unload"
    if not (1 <= chunks_per_batch <= 64):
        return False, "chunks_per_batch 1..64"
    if not (1 <= batches_in_flight <= 8):
        return False, "batches_in_flight 1..8"
    if chunks_per_batch * batches_in_flight > 256:
        return False, "scratch <= 256"
    if resident_slots(unload) > 16384:
        return False, "resident_slots <= 16384"
    return True, ""


def derive_config(vision, generation, unload, simulation,
                  chunks_per_batch, batches_in_flight):
    """Espelha config_derive_and_validate (REQ-CFG-02)."""
    visible = sphere_count(vision)
    scratch = chunks_per_batch * batches_in_flight
    ring = 1
    while ring < scratch:
        ring *= 2
    ring = max(64, ring)
    pages = (sphere_count(simulation) * 3 + 1) // 2
    return visible, scratch, ring, pages


def scenario_config():
    print("[cenario] VS-08: capacidade parametrizada da fila (REQ-SIM-05)")
    # contagens de esfera de referência
    for r, expected in sphere_count_reference().items():
        check(f"esfera({r}) == {expected}", sphere_count(r) == expected)

    # ring da fila e offsets de slot para mín/default/máx capacidade
    for cap in (VISIBLE_CAPACITY_MIN, VISIBLE_CAPACITY_DEFAULT, VISIBLE_CAPACITY_MAX):
        slot_words = WORK_QUEUE_STATE_WORDS + cap * BRICKS_PER_CHUNK
        check(f"cap {cap}: base do frame 0 = 0", work_queue_base_words(0, cap) == 0)
        check(f"cap {cap}: base do frame 1 = slot inteiro",
              work_queue_base_words(cap, cap) == slot_words)
        check(f"cap {cap}: base do frame 2 = 2 slots",
              work_queue_base_words(2 * cap, cap) == 2 * slot_words)
        check(f"cap {cap}: slot = estado + capacidade",
              slot_words == WORK_QUEUE_STATE_WORDS + cap * BRICKS_PER_CHUNK)
        check(f"cap {cap}: finalize sem overflow",
              finalize_work_queue(123, cap) == (123, 1, 1))
        check(f"cap {cap}: finalize clampa na capacidade",
              finalize_work_queue(cap * 1024 + 999, cap) == (cap * 1024, 1, 1))

    # overflow espelhando o builder para a capacidade mínima (33 visíveis)
    registry = {3: BlockDef(3)}  # template pesado: 1024 bricks x 4 partes
    chunks = {}
    visible = []
    for i in range(VISIBLE_CAPACITY_MIN):
        chunks[i] = make_chunk((i * 32, 0, 0), lambda c: 3)
        pack_subdivisions(chunks[i], registry)
        visible.append(i)
    # cena: 33 chunks de template pesado; oclusao remove os bricks interiores
    # (2080 de 4096 por chunk) => 68640 grupos > capacidade minima (33792)
    items, total, overflow = build_work_queue(chunks, visible,
                                              visible_capacity=VISIBLE_CAPACITY_MIN)
    check("cap mínima: overflow sinalizado (68640 grupos > 33x1024 itens)",
          total == 33 * 2080 and len(items) == 33 * 1024 and overflow)
    items_def, total_def, overflow_def = build_work_queue(
        chunks, visible, visible_capacity=VISIBLE_CAPACITY_MAX)
    check("cap máxima com mesma cena: sem overflow",
          total_def == 33 * 2080 and len(items_def) == total_def and not overflow_def)

    # derivações espelhando a spec (defaults e INI custom do cenário de sucesso)
    check("defaults: visíveis 2109, scratch 48, ring 64, páginas 773",
          derive_config(8, 9, 10, 5, 16, 3) == (2109, 48, 64, 773))
    check("custom vision=5/sim=3: visíveis 515, scratch 16, ring 64, páginas 185",
          derive_config(5, 6, 7, 3, 8, 2) == (515, 16, 64, 185))

    # derivação de slots residentes (emenda VS-08): ceil(esfera(unload)*1.05)
    for r in (2, 5, 8, 10, 25):
        n = sphere_count(r)
        expected = -(-n * 105 // 100)  # ceil(n*1.05) por aritmética exata
        check(f"slots: resident_slots({r}) == ceil(esfera({r})*1.05) == {expected}",
              resident_slots(r) == expected)
        check(f"slots: esfera({r}) <= resident_slots({r}) <= esfera({r})*1.05+1",
              n <= resident_slots(r) <= (n * 105) // 100 + 1)
    check("slots: esfera(generation=9) <= resident_slots(unload=10)",
          sphere_count(9) <= resident_slots(10))

    # regras de validação (uma violação por regra)
    base = dict(vision=8, generation=9, unload=10, simulation=5,
                chunks_per_batch=16, batches_in_flight=3)
    violations = [
        ("vision 1..25", {"vision": 26}),
        ("vision 1..25", {"vision": 0}),
        ("simulation >= 1", {"simulation": 0}),
        ("generation >= vision", {"vision": 6, "generation": 5}),
        ("generation < unload", {"unload": 9}),
        ("chunks_per_batch 1..64", {"chunks_per_batch": 65}),
        ("batches_in_flight 1..8", {"batches_in_flight": 9}),
        ("scratch <= 256", {"chunks_per_batch": 64, "batches_in_flight": 8}),
        ("resident_slots <= 16384", {"generation": 26, "unload": 27}),  # slots = ceil(esfera(27)*1.05) > 16384
    ]
    for rule, patch in violations:
        case = dict(base)
        case.update(patch)
        ok, failed_rule = validate_config_rules(**case)
        check(f"regra '{rule}': rejeita", not ok and failed_rule == rule)
    check("config base (defaults): aceita", validate_config_rules(**base)[0])
    ok_custom, _ = validate_config_rules(vision=5, generation=6, unload=7,
                                         simulation=3, chunks_per_batch=8,
                                         batches_in_flight=2)
    check("INI custom do cenário de sucesso: aceita", ok_custom)

    # VS-09 (REQ-SIM-06): fronteiras do novo cap de formato (16 bits)
    check("esfera(25) = 65267 <= 65535 (visíveis cabem no visible_index)",
          sphere_count(25) <= 65535)
    check("esfera(26) = 73525 > 65535 (estoura o visible_index de 16 bits)",
          sphere_count(26) > 65535)
    ok_v10, _ = validate_config_rules(vision=10, generation=11, unload=12,
                                      simulation=5, chunks_per_batch=16,
                                      batches_in_flight=3)
    check("vision=10 liberado pela validação de formato", ok_v10)
    # vision=25 passa pela REGRA DE FORMATO (o cap resident_slots 16384 da
    # VS-08, inalterado, limita a configuração completa — ver AC-03)
    ok_v25, failed_v25 = validate_config_rules(vision=25, generation=26, unload=27,
                                               simulation=5, chunks_per_batch=16,
                                               batches_in_flight=3)
    check("vision=25 (máximo de formato) não viola a regra de formato",
          failed_v25 != "vision 1..25")

    # capacidades representativas: default / vision 10 / máxima (REQ-SIM-06)
    for cap, label in ((2109, "default (vision 8)"), (4169, "vision 10"),
                       (65535, "máxima (vision 25)")):
        slot_words = WORK_QUEUE_STATE_WORDS + cap * BRICKS_PER_CHUNK
        check(f"cap {label}: finalize clampa em cap x 1024",
              finalize_work_queue(cap * 1024 + 999, cap) == (cap * 1024, 1, 1))
        check(f"cap {label}: 2 slots do ring cabem em u32",
              2 * slot_words < (1 << 32))


def scenario_uvs():
    print("[cenario] VS-11: UVs nos templates — bounds, sentinela, paridade de cor")
    rng = random.Random(1106)

    # REQ-UV-01: MeshVertex 8 -> 10 componentes, distante do limite
    check("MeshVertex: 10 componentes (8 antigos + uv f2)",
          MESH_VERTEX_COMPONENTS == 4 + 3 + 1 + 2)
    check("MeshVertex: 10 <= 128 (maxMeshOutputComponents, folga)",
          MESH_VERTEX_COMPONENTS <= MAX_MESH_OUTPUT_COMPONENTS)

    # REQ-UV-04a/REQ-SIM-08: bounds — built-ins em [0,1]^2
    for name, tmpl in (("cubo", TEMPLATES[1]), ("planta", TEMPLATES[2])):
        check(f"{name}: pool de UV paralelo aos vertices ({tmpl.vertex_count})",
              len(tmpl.uvs) == tmpl.vertex_count)
        check(f"{name}: todas as UVs em [0,1]^2",
              all(uv_in_bounds(uv) for uv in tmpl.uvs))
        check(f"{name}: UVs cobrem os cantos do quadrado unitario",
              {(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)} <= set(tmpl.uvs))

    # sentinela exclusa da faixa valida (e interna: nunca em template)
    check("sentinela (-1,-1) fora de [0,1]^2 (validacao rejeitaria)",
          not uv_in_bounds(UV_SENTINEL))
    check("validacao: UV com x=-0.5 rejeitada", not uv_in_bounds((-0.5, 0.25)))
    check("validacao: UV com y=1.5 rejeitada", not uv_in_bounds((0.25, 1.5)))
    check("validacao: template sem UVs e valido (fallback, sem erro)",
          TEMPLATES[3].uvs is None and TEMPLATES[0].uvs is None)

    # REQ-UV-02: roundtrip sentinela -> fallback triplanar; template com UV
    # emite UV do pool
    for i in range(TEMPLATES[1].vertex_count):
        check(f"cubo: emissao devolve a UV do pool (v{i})",
              emit_vertex_uv(TEMPLATES[1], i) == CUBE_UVS[i])
    check("pesado (sem UV): emissao devolve a sentinela",
          all(emit_vertex_uv(TEMPLATES[3], i) == UV_SENTINEL for i in range(32)))
    check("ar: sem vertices, sem emissao", TEMPLATES[0].vertex_count == 0)
    check("fragmento: uv.x >= 0 -> amostragem UV; sentinela -> triplanar",
          not fragment_uses_triplanar((0.3, 0.7))
          and fragment_uses_triplanar(UV_SENTINEL)
          and fragment_uses_triplanar((-0.0 - 1e-6, 0.5)))

    # REQ-UV-03/REQ-SIM-08: paridade de cor UV x triplanar na paleta solida.
    # Paleta (voxel_gpu.odin): camada sólida por albedo_texture_index — a
    # amostragem em qualquer UV devolve a mesma cor; o triplanar mistura tres
    # projecoes da MESMA cor solida. Logo as rotas sao identicas por bloco.
    SOLID_PALETTE = {1: (0.349, 0.749, 0.251),  # grama
                     2: (0.502, 0.349, 0.200), # terra
                     3: (0.549, 0.549, 0.580)} # pedra

    def sample_uv(block_id, uv):
        assert uv_in_bounds(uv)
        return SOLID_PALETTE[block_id]

    def sample_triplanar(block_id, world_pos, normal):
        nx, ny, nz = (abs(c) for c in normal)
        s = nx + ny + nz
        # tres projecoes da mesma camada solida -> pesos somam 1
        return SOLID_PALETTE[block_id]

    for block_id in SOLID_PALETTE:
        for _ in range(50):
            uv = (rng.random(), rng.random())
            pos = tuple(rng.uniform(-100, 100) for _ in range(3))
            axis = rng.randrange(3)
            sign = rng.choice((-1.0, 1.0))
            normal = tuple(sign if i == axis else 0.0 for i in range(3))
            check(f"bloco {block_id}: cor UV == cor triplanar",
                  sample_uv(block_id, uv) == sample_triplanar(block_id, pos, normal))

    # orcamento (REQ-UV-04b): uv e atributo — contagens de vertices/triangulos
    # inalteradas (mesmo cenario de orcamento, agora com UVs nos built-ins)
    registry = {1: BlockDef(1), 2: BlockDef(2)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1 if c[1] == 0 else 2)}
    pack_subdivisions(chunks[0], registry)
    items, _, _ = build_work_queue(chunks, [0])
    worst_v = 0
    worst_t = 0
    for item in items:
        for camera in CAMERAS_6:
            v, t = mesh_group_counts(item, chunks, [0], registry, camera)
            worst_v = max(worst_v, v)
            worst_t = max(worst_t, t)
    check("orcamento inalterado: vertices <= 256 (com UV nos built-ins)",
          worst_v <= MESH_VERTEX_MAXIMUM)
    check("orcamento inalterado: triangulos <= 192 (com UV nos built-ins)",
          worst_t <= MESH_TRIANGLE_MAXIMUM)


def scenario_plant_cutout():
    print("[cenario] VS-14: template X da planta e alpha-test cutout")

    # REQ-PLT-02: mesh "planta" em X — duas quads cruzadas (4 triângulos,
    # cull_tags 7, UVs [0,1]^2 por quad) — mesmo formato do built-in 2, agora
    # como asset reaproveitável no JSON (bloco id 4 -> template da planta)
    plant = TEMPLATES[2]
    check("planta X: 4 triângulos (<= 24 do orçamento)", plant.triangle_count == 4)
    check("planta X: 8 vértices", plant.vertex_count == 8)
    check("planta X: cull_tags 7 em todos os triângulos (nunca culpada)",
          all(t[3] == CULL_FACE_NEVER for t in plant.triangles))
    check("planta X: UVs [0,1]^2 por quad (pool paralelo aos vértices)",
          len(plant.uvs) == 8 and all(uv_in_bounds(uv) for uv in plant.uvs)
          and {(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)} <= set(plant.uvs))
    check("planta X: pior caso 4 triângulos (tag 7 não culpa)", plant.worst_case_tris == 4)

    # orçamento: brick inteiro de plantas (8 voxels x 8v/4t) não subdivide
    registry = {4: BlockDef(2)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 4)}
    pack_subdivisions(chunks[0], registry)
    check("brick cheio de plantas: subdivisão 0",
          all(s == 0 for s in chunks[0]["subdivisions"]))
    worst_v = 0
    worst_t = 0
    for item in build_work_queue(chunks, [0])[0]:
        for camera in CAMERAS_6:
            v, t = mesh_group_counts(item, chunks, [0], registry, camera)
            worst_v = max(worst_v, v)
            worst_t = max(worst_t, t)
    check(f"brick de plantas: vertices <= {MESH_VERTEX_MAXIMUM} (pior {worst_v})",
          worst_v <= MESH_VERTEX_MAXIMUM)
    check(f"brick de plantas: triângulos <= {MESH_TRIANGLE_MAXIMUM} (pior {worst_t})",
          worst_t <= MESH_TRIANGLE_MAXIMUM)

    # REQ-PLT-01: cutout — transparente descarta alpha < 0.5; opaco nunca
    check("cutout: alpha 0.4 descartado (transparente)",
          not fragment_survives_alpha_test(BLOCK_DEFINITION_FLAG_TRANSPARENT, 0.4))
    check("cutout: alpha 0.5 mantido (limiar inclusivo)",
          fragment_survives_alpha_test(BLOCK_DEFINITION_FLAG_TRANSPARENT, 0.5))
    check("cutout: alpha 0.0 descartado (fundo da textura)",
          not fragment_survives_alpha_test(BLOCK_DEFINITION_FLAG_TRANSPARENT, 0.0))
    check("cutout: bloco opaco com alpha 0.0 mantido (sem flag, sem descarte)",
          fragment_survives_alpha_test(0, 0.0))
    check("cutout: flags sem bit 0 (ex.: HAS_FLUSH_FACES=1<<k) não disparam",
          fragment_survives_alpha_test(2, 0.1))


def scenario_plant_nonsolid():
    print("[cenario] VS-14 emenda: planta nao-solido (culling de faces e oclusao)")
    registry = {1: BlockDef(1), 4: BlockDef(2, flags=BLOCK_DEFINITION_FLAG_NON_SOLID)}

    # bloco solido adjacente a planta emite a face voltada para ela
    def world(c):
        if c == (10, 10, 10):
            return 1  # pedra
        if c == (11, 10, 10):
            return 4  # planta
        return 0
    chunks = {0: make_chunk((0, 0, 0), world)}
    pack_subdivisions(chunks[0], registry)
    # camera em +X: a face +X do solido olha para a planta — nao-solido, emite
    mask = compute_visible_face_mask(chunks, 0, (10, 10, 10), chunks[0]["neighbors"],
                                     (1e6, 16, 16), registry)
    check("solido adjacente a planta: face +X presente via solid word", (mask & 1) == 1)
    check("solid word: bit da planta desligado",
          not voxel_solid_word_bit(chunks, 0, (11, 10, 10), registry))
    check("solid word: bit da grama ligado",
          voxel_solid_word_bit(chunks, 0, (10, 10, 10), registry))
    # camera em -X: a face -X do solido olha para ar — tambem emite (regressao)
    mask = compute_visible_face_mask(chunks, 0, (10, 10, 10), chunks[0]["neighbors"],
                                     (-1e6, 16, 16), registry)
    check("solido adjacente a ar: face -X presente", (mask & 2) == 2)
    # com a regra antiga (ocupado == solido) a face +X seria suprimida:
    mask_old = compute_visible_face_mask(chunks, 0, (10, 10, 10), chunks[0]["neighbors"],
                                         (1e6, 16, 16))
    check("regressao antiga teria suprimido a face (ocupado == solido)", (mask_old & 1) == 0)

    # a propria planta continua renderizando (ocupa voxel, template X, tag 7)
    chunks = {0: make_chunk((0, 0, 0), lambda c: 4 if c == (11, 10, 10) else 0)}
    pack_subdivisions(chunks[0], registry)
    plant_brick = brick_index_from_coordinate((11 // 4, 10 // 2, 10 // 4))
    v, t = mesh_group_counts(pack_work_item(0, plant_brick, 0, 0), chunks, [0], registry, (1e6, 16, 16))
    check("planta renderiza (ocupa voxel, template X): 8v/4t no grupo", (v, t) == (8, 4))

    # brick CHEIO DE PLANTAS (ocupancy 0xFFFFFFFF) nao e ocluso — nem isolado
    # nem cercado por bricks cheios de plantas
    chunks = {0: make_chunk((0, 0, 0), lambda c: 4)}
    pack_subdivisions(chunks[0], registry)
    check("brick cheio de plantas: solid word zero, sem decode",
          brick_solid_word(chunks, 0, (4, 8, 4), registry) == 0)
    check("brick cheio de plantas isolado: nao ocluso",
          not is_brick_occluded(chunks, 0, (4, 8, 4), chunks[0]["neighbors"], registry))
    chunks[1] = make_chunk((32, 0, 0), lambda c: 4)
    pack_subdivisions(chunks[1], registry)
    chunks[0]["neighbors"][0] = 1
    chunks[1]["neighbors"][1] = 0
    check("brick de plantas com vizinho de plantas: nao ocluso",
          not is_brick_occluded(chunks, 0, (7, 8, 4), chunks[0]["neighbors"], registry))

    # controle: brick cheio de cubos continua ocluso na mesma geometria
    registry_cube = {1: BlockDef(1)}
    chunks = {0: make_chunk((0, 0, 0), lambda c: 1), 1: make_chunk((32, 0, 0), lambda c: 1)}
    for c in chunks.values():
        pack_subdivisions(c, registry_cube)
    chunks[0]["neighbors"][0] = 1
    chunks[1]["neighbors"][1] = 0
    check("interior solido O(1): solid word cheia",
          brick_voxels_all_solid(chunks, 0, (7, 8, 4), registry_cube))
    check("controle: brick cheio de cubos com vizinho cheio: ocluso",
          is_brick_occluded(chunks, 0, (7, 8, 4), chunks[0]["neighbors"], registry_cube))




# ============================================================================
# VS-20 (REQ-GPL-02/04/05/06) — realce do alvo, regras de construção e pulo
# ============================================================================
# Espelha render.slang (tint no fragment por floor(world_position)) e as
# guardas de gameplay.odin (place/remove/pulo). Fator de clareamento
# constante documentado: HIGHLIGHT_TINT_FACTOR.

import math

HIGHLIGHT_TINT_FACTOR = 1.4


def apply_target_highlight(final_color, world_position, target_voxel, target_valid):
    """Espelha shade_voxel: flag 0 = saída bit a bit igual ao caminho anterior;
    flag 1 com floor(wp)==alvo tinge por HIGHLIGHT_TINT_FACTOR."""
    if target_valid != 0 and all(
        int(math.floor(world_position[i])) == target_voxel[i] for i in range(3)
    ):
        return [c * HIGHLIGHT_TINT_FACTOR for c in final_color]
    return final_color


def gameplay_place_destination(hit_result, hit_voxel, hit_normal):
    """REQ-GPL-04: destino = voxel + normal; rejeita normal zero/miss/unknown."""
    if hit_result != "hit":
        return None
    if hit_normal == (0, 0, 0):
        return None  # origem dentro do voxel (normal nula)
    if sum(1 for n in hit_normal if n != 0) != 1 or abs(sum(hit_normal)) != 1:
        return None  # normal não unitária válida
    return tuple(hit_voxel[i] + hit_normal[i] for i in range(3))


def aabb_intersects_voxel(body_min, body_size, voxel):
    """AABB do jogador [min, min+size) vs voxel [v, v+1)."""
    for i in range(3):
        if body_min[i] + body_size[i] <= voxel[i] or voxel[i] + 1 <= body_min[i]:
            return False
    return True


def gameplay_place_allowed(hit_result, hit_voxel, hit_normal, dest_known, dest_blocking,
                           body_min, body_size):
    """REQ-GPL-04: só solicita se destino conhecido, não-bloqueante e a pedra
    não intersectar a AABB do jogador."""
    dest = gameplay_place_destination(hit_result, hit_voxel, hit_normal)
    if dest is None:
        return None
    if not dest_known or dest_blocking:
        return None
    if aabb_intersects_voxel(body_min, body_size, dest):
        return None
    return dest


def gameplay_remove_target(hit_result, hit_voxel):
    """REQ-GPL-05: remove exatamente o voxel atingido; miss/unknown no-op."""
    return tuple(hit_voxel) if hit_result == "hit" else None


def gameplay_jump_velocity(grounded, frozen, gravity=-24.0, height=1.5):
    """REQ-GPL-06: impulso v0 = sqrt(2*|g|*h); None quando no ar/congelado."""
    if not grounded or frozen:
        return None
    return math.sqrt(2.0 * abs(gravity) * height)


def scenario_target_highlight():
    print("[cenario] VS-20: realce do voxel-alvo no fragment")
    base = [0.5, 0.4, 0.3]

    # flag 0: saída bit a bit idêntica (paridade sem alvo)
    check("flag 0: paridade bit a bit (cor inalterada)",
          apply_target_highlight(list(base), (4.5, 2.5, 1.5), (4, 2, 1), 0) == base)

    # flag 1, mesmo voxel: tint
    tinted = apply_target_highlight(list(base), (4.5, 2.5, 1.5), (4, 2, 1), 1)
    check("flag 1 no alvo: tint do fator",
          all(abs(tinted[i] - base[i] * HIGHLIGHT_TINT_FACTOR) < 1e-9 for i in range(3)))

    # flag 1, outro voxel: sem tint (só o alvo é tingido)
    check("flag 1 fora do alvo: sem tint",
          apply_target_highlight(list(base), (5.5, 2.5, 1.5), (4, 2, 1), 1) == base)

    # coordenadas negativas: floor(-0.2) = -1 (não trunca para 0)
    check("negativo: floor(-0.2) == -1 é o alvo",
          apply_target_highlight(list(base), (-0.2, -1.5, -3.9), (-1, -2, -4), 1)
          == [c * HIGHLIGHT_TINT_FACTOR for c in base])

    # fronteira exata do voxel: floor(4.0) == 4 pertence ao voxel superior
    check("fronteira exata: floor(4.0)=4 -> voxel 4",
          apply_target_highlight(list(base), (4.0, 2.5, 1.5), (4, 2, 1), 1)
          == [c * HIGHLIGHT_TINT_FACTOR for c in base])
    check("fronteira exata: (4.0-eps) -> voxel 3, sem tint",
          apply_target_highlight(list(base), (4.0 - 1e-6, 2.5, 1.5), (4, 2, 1), 1) == base)

    # cantos do voxel: todos os pontos internos do voxel são tingidos
    corners = [(4.0, 2.0, 1.0), (4.999, 2.999, 1.999), (4.001, 2.0, 1.0)]
    check("interior inteiro do voxel é tingido",
          all(apply_target_highlight(list(base), c, (4, 2, 1), 1) != base for c in corners))


def scenario_gameplay_rules():
    print("[cenario] VS-20: guardas de construção/remoção e pulo")
    body_min, body_size = (10.2, 33.0, 10.2), (0.6, 1.8, 0.6)

    # colocar: seis faces da normal unitária
    faces = [((1, 0, 0), (5, 2, 1)), ((-1, 0, 0), (3, 2, 1)),
             ((0, 1, 0), (4, 3, 1)), ((0, -1, 0), (4, 1, 1)),
             ((0, 0, 1), (4, 2, 2)), ((0, 0, -1), (4, 2, 0))]
    ok_faces = all(
        gameplay_place_allowed("hit", (4, 2, 1), n, True, False, body_min, body_size) == d
        for n, d in faces
    )
    check("place: seis faces -> destino voxel+normal", ok_faces)

    # no-ops: miss/unknown, normal zero, destino desconhecido/bloqueante
    check("place: miss/unknown no-op",
          gameplay_place_allowed("miss", (4, 2, 1), (1, 0, 0), True, False, body_min, body_size) is None
          and gameplay_place_allowed("unknown", (4, 2, 1), (1, 0, 0), True, False, body_min, body_size) is None)
    check("place: normal zero (origem interna) no-op",
          gameplay_place_allowed("hit", (4, 2, 1), (0, 0, 0), True, False, body_min, body_size) is None)
    check("place: normal não unitária no-op",
          gameplay_place_allowed("hit", (4, 2, 1), (1, 1, 0), True, False, body_min, body_size) is None)
    check("place: destino desconhecido no-op",
          gameplay_place_allowed("hit", (4, 2, 1), (0, 1, 0), False, False, body_min, body_size) is None)
    check("place: destino bloqueante no-op",
          gameplay_place_allowed("hit", (4, 2, 1), (0, 1, 0), True, True, body_min, body_size) is None)

    # interseção com o jogador: pedra adjacente sobre a AABB do corpo
    check("place: destino sobre o jogador no-op",
          gameplay_place_allowed("hit", (10, 32, 10), (0, 1, 0), True, False, body_min, body_size) is None)
    # pedra ao lado (fora da AABB 10.2..10.8) é permitida
    check("place: destino ao lado do jogador permitido",
          gameplay_place_allowed("hit", (8, 33, 10), (1, 0, 0), True, False, body_min, body_size) == (9, 33, 10))

    # remover: exatamente o hit; miss/unknown no-op
    check("remove: voxel atingido exato",
          gameplay_remove_target("hit", (7, 8, 9)) == (7, 8, 9))
    check("remove: miss/unknown no-op",
          gameplay_remove_target("miss", (7, 8, 9)) is None
          and gameplay_remove_target("unknown", (7, 8, 9)) is None)

    # pulo: v0 fixo, guardas grounded/congelado
    v0 = gameplay_jump_velocity(True, False)
    check("pulo: v0 = sqrt(2*24*1.5) ≈ 8.485", abs(v0 - 8.48528137423857) < 1e-9)
    check("pulo: no ar/congelado rejeita",
          gameplay_jump_velocity(False, False) is None and gameplay_jump_velocity(True, True) is None)

    # altura balística com o integrador semi-implícito do solver (dt=1/60)
    dt, g = 1.0 / 60.0, -24.0
    y, vy, apex, steps = 0.0, v0, 0.0, 0
    while vy > 0:
        vy += g * dt
        y += vy * dt
        apex = max(apex, y)
        steps += 1
    check(f"pulo: ápice {apex:.3f} em {steps} passos (1,5 ± um passo de subida)",
          1.35 <= apex <= 1.65)




# ============================================================================
# VS-21 (REQ-TEX-02/04/06/08) — flip_rows, seleção de face por normal e
# normalização string→objeto. Espelha voxel_assets.odin (flip_rows), o loader
# (schema de 6 faces) e render.slang (eixo dominante, empate Y→X→Z).
# ============================================================================

FACES_6 = ("top", "bottom", "front", "back", "left", "right")
# ordem FACE_NORMALS do registry: +X,-X,+Y,-Y,+Z,-Z
FACE_NORMALS_ORDER = ("right", "left", "top", "bottom", "front", "back")


def flip_rows(pixels, width, height):
    """Espelha flip_rows (voxel_assets.odin): troca y com height-1-y, stride w*4."""
    stride = width * 4
    px = list(pixels)
    for y in range(height // 2):
        opp = (height - 1 - y) * stride
        base = y * stride
        px[base:base + stride], px[opp:opp + stride] = px[opp:opp + stride], px[base:base + stride]
    return px


def dominant_face_index(normal):
    """Espelha o fragment: maior |componente|; empate Y→X→Z; sinal escolhe ±.
    Retorna o índice em FACE_NORMALS_ORDER (0=+X ... 5=-Z)."""
    ax, ay, az = abs(normal[0]), abs(normal[1]), abs(normal[2])
    if ay >= ax and ay >= az:
        return 2 if normal[1] > 0 else 3
    if ax >= az:
        return 0 if normal[0] > 0 else 1
    return 4 if normal[2] > 0 else 5


def normalize_texture_spec(spec, texture_names, block_name):
    """REQ-TEX-04: string → objeto com 6 faces iguais; objeto completo OK;
    incompleto/extra/tipo errado/refs ausentes → mensagem citando bloco."""
    if isinstance(spec, str):
        if spec == "":
            return None, f"bloco '{block_name}': campo 'texture' ausente ou vazio"
        if spec not in texture_names:
            return None, f"bloco '{block_name}': textura '{spec}' não encontrada"
        return {face: spec for face in FACES_6}, None
    if isinstance(spec, dict):
        keys = set(spec.keys())
        if keys != set(FACES_6):
            missing = sorted(set(FACES_6) - keys)
            extra = sorted(keys - set(FACES_6))
            detail = []
            if missing:
                detail.append(f"faltando {missing}")
            if extra:
                detail.append(f"extras {extra}")
            return None, f"bloco '{block_name}': objeto 'texture' incompleto ({', '.join(detail)})"
        for face in FACES_6:
            value = spec[face]
            if not isinstance(value, str) or value == "":
                return None, f"bloco '{block_name}': 'texture.{face}' deve ser string não vazia (recebido {value!r})"
            if value not in texture_names:
                return None, f"bloco '{block_name}': textura '{value}' não encontrada (texture.{face})"
        return dict(spec), None
    return None, f"bloco '{block_name}': campo 'texture' deve ser string ou objeto de 6 faces (recebido {spec!r})"


def scenario_vs21_flip():
    print("[cenario] VS-21: flip_rows pixel a pixel e normalização RGBA")
    # imagem 2x3 com cantos marcados: cada pixel carrega (x, y, x+y, 255)
    w, h = 2, 3
    px = []
    for y in range(h):
        for x in range(w):
            px += [x * 100, y * 100, (x + y) * 50, 255]

    def pix(buf, x, y):
        return tuple(buf[(y * w + x) * 4:(y * w + x) * 4 + 4])

    flipped = flip_rows(px, w, h)
    # canto superior-esquerdo (0,0) foi para baixo; cada pixel exato conferido
    ok = True
    for y in range(h):
        for x in range(w):
            if pix(flipped, x, y) != (x * 100, (h - 1 - y) * 100, (x + (h - 1 - y)) * 50, 255):
                ok = False
    check("flip: cada pixel na linha espelhada (y -> h-1-y)", ok)
    check("flip: canto (0,0) vai para (0,h-1)", pix(flipped, 0, 0) == (0, 200, 100, 255))
    check("flip: dupla inversão restaura a entrada", flip_rows(flipped, w, h) == px)
    check("flip: altura 1 é no-op", flip_rows([7, 8, 9, 10], 1, 1) == [7, 8, 9, 10])


def scenario_vs21_face_selection():
    print("[cenario] VS-21: seleção de face pelo eixo dominante da normal")
    # seis eixos puros
    pure = {(1, 0, 0): 0, (-1, 0, 0): 1, (0, 1, 0): 2, (0, -1, 0): 3,
            (0, 0, 1): 4, (0, 0, -1): 5}
    check("face: seis eixos puros (+X,-X,+Y,-Y,+Z,-Z)",
          all(dominant_face_index(n) == i for n, i in pure.items()))

    # empates determinísticos Y→X→Z
    check("face: empate |x|=|y| -> Y", dominant_face_index((1, 1, 0)) == 2)
    check("face: empate |y|=|z| -> Y", dominant_face_index((0, -1, 1)) == 3)
    check("face: empate |x|=|z| -> X", dominant_face_index((1, 0, -1)) == 0)
    check("face: empate triplo -> Y", dominant_face_index((1, 1, 1)) == 2)

    # normais não unitárias e negativas
    check("face: normal não unitária ok", dominant_face_index((0.2, 9.9, 0.1)) == 2)
    check("face: sinal negativo escolhe a face -", dominant_face_index((0, -0.7, 0.2)) == 3)

    # o índice alimenta UV e triplanar: camada = albedo_faces[face]
    faces = {"top": 1, "bottom": 2, "front": 2, "back": 2, "left": 2, "right": 2}
    registry_faces = [faces[f] for f in FACE_NORMALS_ORDER]
    check("face: grama top=1, demais=2 no registry (FACE_NORMALS)",
          registry_faces == [2, 2, 1, 2, 2, 2])
    layer = registry_faces[dominant_face_index((0.1, 0.9, 0.3))]
    check("face: normal +Y dominante -> camada grama", layer == 1)
    layer = registry_faces[dominant_face_index((0.9, 0.1, -0.2))]
    check("face: normal +X dominante -> camada terra", layer == 2)


def scenario_vs21_texture_spec():
    print("[cenario] VS-21: normalização string->objeto e erros de schema")
    names = {"grama", "terra", "pedra", "planta"}

    obj, err = normalize_texture_spec("terra", names, "terra")
    check("spec: string normaliza para 6 faces iguais",
          err is None and all(v == "terra" for v in obj.values()))

    full, err = normalize_texture_spec(
        {"top": "grama", "bottom": "terra", "front": "terra", "back": "terra",
         "left": "terra", "right": "terra"}, names, "grama")
    check("spec: objeto completo de 6 faces válido",
          err is None and full["top"] == "grama" and full["right"] == "terra")

    for bad, msg in (
        ({"top": "grama"}, "incompleto"),
        ({"top": "grama", "bottom": "terra", "front": "terra", "back": "terra",
          "left": "terra", "right": "terra", "diag": "x"}, "extra"),
        (42, "número"), (["grama"], "array"), (None, "null"),
    ):
        _o, err = normalize_texture_spec(bad, names, "grama")
        check(f"spec: {msg} rejeitado citando o bloco", err is not None and "bloco 'grama'" in err)

    _o, err = normalize_texture_spec("inexistente", names, "pedra")
    check("spec: referência ausente citada", err is not None and "'inexistente'" in err)
    _o, err = normalize_texture_spec(
        {"top": "x", "bottom": "terra", "front": "terra", "back": "terra",
         "left": "terra", "right": "terra"}, names, "pedra")
    check("spec: referência ausente por face citada",
          err is not None and "texture.top" in err and "'x'" in err)




# ============================================================================
# VS-21 correção (Frente 2) — cubo com 24 vértices e UVs [0,1]² por face.
# A projeção planar da VS-11 deixava U constante nas faces ±X e V constante
# nas ±Z (listra de uma coluna de texel). Espelha assets/blocks.json (mesh
# "cubo") e BUILTIN_CUBE_* em voxel_gpu.odin.
# ============================================================================

# 4 vértices por face, na ordem FACE_NORMALS dos triângulos:
# -X (v0..3), +X (v4..7), +Y (v8..11), -Y (v12..15), +Z (v16..19), -Z (v20..23).
CUBE24_VERTICES = [
    # -X (x=0): projeção (z, y)
    (0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0),
    # +X (x=1): projeção (z, y)
    (1, 0, 0), (1, 0, 1), (1, 1, 1), (1, 1, 0),
    # +Y (y=1): projeção (x, z)
    (0, 1, 0), (1, 1, 1), (1, 1, 0), (0, 1, 1),
    # -Y (y=0): projeção (x, z)
    (0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1),
    # +Z (z=1): projeção (x, y)
    (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
    # -Z (z=0): projeção (x, y)
    (0, 0, 0), (0, 1, 0), (1, 0, 0), (1, 1, 0),
]
CUBE24_TRIANGLES = [
    (0, 1, 2), (0, 2, 3),   # -X, cull 1
    (4, 5, 6), (4, 6, 7),   # +X, cull 0
    (8, 9, 10), (8, 10, 11),  # +Y, cull 2
    (12, 13, 14), (12, 14, 15),  # -Y, cull 3
    (16, 17, 18), (16, 18, 19),  # +Z, cull 4
    (20, 21, 22), (20, 22, 23),  # -Z, cull 5
]
CUBE24_TAGS = [1, 1, 0, 0, 2, 2, 3, 3, 4, 4, 5, 5]
# UVs por face: cada grupo de 4 cobre [0,1]² inteiro
CUBE24_UVS = [
    (0, 0), (1, 0), (1, 1), (0, 1),  # -X (z,y)
    (0, 0), (1, 0), (1, 1), (0, 1),  # +X (z,y)
    (0, 0), (1, 1), (1, 0), (0, 1),  # +Y (x,z)
    (0, 0), (1, 0), (1, 1), (0, 1),  # -Y (x,z)
    (0, 0), (1, 0), (1, 1), (0, 1),  # +Z (x,y)
    (0, 0), (0, 1), (1, 0), (1, 1),  # -Z (x,y)
]


def scenario_cube_uv_per_face():
    print("[cenario] VS-21 correcao: cubo 24 vértices com UV [0,1]² por face")
    check("cubo24: 24 vértices, 12 triângulos, 24 UVs",
          len(CUBE24_VERTICES) == 24 and len(CUBE24_TRIANGLES) == 12 and len(CUBE24_UVS) == 24)
    check("cubo24: triângulos indexam dentro do range",
          all(0 <= i < 24 for t in CUBE24_TRIANGLES for i in t))
    check("cubo24: cull tags por face (1,1,0,0,2,2,3,3,4,4,5,5)",
          CUBE24_TAGS == [1, 1, 0, 0, 2, 2, 3, 3, 4, 4, 5, 5])

    # nenhuma face com U ou V constante (o bug das listras): cada grupo de 4
    # UVs deve ter U e V variando em [0,1]
    ok_uv = True
    for face in range(6):
        uvs = CUBE24_UVS[face * 4:face * 4 + 4]
        us = {uv[0] for uv in uvs}
        vs = {uv[1] for uv in uvs}
        bounds = all(0 <= uv[0] <= 1 and 0 <= uv[1] <= 1 for uv in uvs)
        if len(us) < 2 or len(vs) < 2 or not bounds:
            ok_uv = False
    check("cubo24: nenhuma face com U ou V constante (listras eliminadas)", ok_uv)
    check("cubo24: cada face cobre [0,1]² inteiro (4 cantos)",
          all(set(CUBE24_UVS[f * 4:f * 4 + 4]) == {(0, 0), (1, 0), (1, 1), (0, 1)}
              for f in (0, 1, 3, 4)))

    # projeção planar antiga (VS-11): ±X tinham U constante, ±Z V constante
    planar_uvs = [(v[0], v[2]) for v in CUBE24_VERTICES]
    for face, axis_const in ((1, 0), (3, 0), (4, 1), (5, 1)):  # +X,-X U const; +Z,-Z V const
        uvs = planar_uvs[face * 4:face * 4 + 4]
        values = {uv[axis_const] for uv in uvs}
        if len(values) != 1:
            break
    else:
        check("regressao conhecida: projeção planar reproduz o bug (sanidade)", False)

    # cada triângulo fica numa única face do cubo (planaridade preservada)
    def face_of(v):
        x, y, z = CUBE24_VERTICES[v]
        on = [c for c, val in ((0, x), (1, y), (2, z)) if val in (0, 1)]
        return on
    planar = all(len(set.intersection(*[set(face_of(i)) for i in t])) >= 1
                 for t in CUBE24_TRIANGLES)
    check("cubo24: triângulos permanecem nas faces do cubo", planar)

    # worst case de triângulos (culling direcional) inalterado: 6
    never = sum(1 for t in CUBE24_TAGS if t == CULL_FACE_NEVER)
    per_face = [CUBE24_TAGS.count(f) for f in range(6)]
    worst = never + max(per_face[0], per_face[1]) + max(per_face[2], per_face[3]) + max(per_face[4], per_face[5])
    check("cubo24: pior caso de triângulos = 6 (<= 24)", worst == 6)




# ============================================================================
# VS-21 correção por verificação — auditoria completa das 6 faces do cubo 24v
# (winding outward, não-degeneração, UV [0,1]² por face, índices no range).
# Carrega a definição do assets/blocks.json e compara com o built-in.
# ============================================================================

CUBE24_GROUP_NORMALS = [(-1, 0, 0), (1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]


def cross3(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def sub3(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def audit_cube24(name, vertices, triangles, uvs):
    """Retorna lista de divergências (vazia = ok)."""
    problems = []
    if len(vertices) != 24 or len(triangles) != 12 or len(uvs) != 24:
        return ["tamanhos: v=%d t=%d uv=%d (esperado 24/12/24)" % (len(vertices), len(triangles), len(uvs))]
    for t in triangles:
        if any(i < 0 or i >= 24 for i in t):
            problems.append(f"triângulo {t} fora do range 0..23")
    for g in range(6):
        normal = CUBE24_GROUP_NORMALS[g]
        base = g * 4
        tris = (triangles[2 * g], triangles[2 * g + 1])
        for t in tris:
            e1 = sub3(vertices[t[1]], vertices[t[0]])
            e2 = sub3(vertices[t[2]], vertices[t[0]])
            c = cross3(e1, e2)
            dot = sum(c[i] * normal[i] for i in range(3))
            if dot <= 0:
                problems.append(
                    f"face grupo {g} (normal {normal}): tri {t} cross={c} sem componente outward (dot={dot})"
                )
            area2 = sum(abs(x) for x in c)
            if area2 == 0:
                problems.append(f"face grupo {g}: tri {t} degenerado")
        quad_uvs = set()
        for i in range(4):
            uv = (round(uvs[base + i][0], 6), round(uvs[base + i][1], 6))
            if not (0.0 <= uv[0] <= 1.0 and 0.0 <= uv[1] <= 1.0):
                problems.append(f"face grupo {g}: uv {uv} fora de [0,1]²")
            quad_uvs.add(uv)
        if quad_uvs != {(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)}:
            problems.append(f"face grupo {g}: UVs {sorted(quad_uvs)} não cobrem [0,1]² exatamente uma vez")
        # os 4 vértices do grupo devem estar no plano da face
        axis = 0 if normal[0] else (1 if normal[1] else 2)
        value = 1 if sum(normal) > 0 or normal[axis] > 0 else 0
        value = 1 if normal[axis] > 0 else 0
        for i in range(4):
            v = vertices[base + i]
            if v[axis] != value:
                problems.append(f"face grupo {g}: vértice {v} fora do plano (eixo {axis}={value})")
    return problems


def scenario_audit_cube24():
    print("[cenario] VS-21 verificação: auditoria completa das 6 faces do cubo 24v")
    import json as _json, os
    path = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "blocks.json"))
    doc = _json.load(open(path, encoding="utf-8"))
    cube = next(m for m in doc["meshes"] if m["name"] == "cubo")
    verts = [tuple(v) for v in cube["vertices"]]
    tris = [tuple(t) for t in cube["triangles"]]
    uvs = [tuple(u) for u in cube["uvs"]]
    problems = audit_cube24("json", verts, tris, uvs)
    for p in problems:
        check(f"JSON cubo: {p}", False)
    check(f"JSON cubo 24v: 6 faces com winding outward, UV [0,1]², índices ok ({len(problems)} problemas)", not problems)

    # built-in (espelha BUILTIN_CUBE_* em voxel_gpu.odin)
    b_verts = [
        (0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0),
        (1, 0, 0), (1, 0, 1), (1, 1, 1), (1, 1, 0),
        (0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0),
        (0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1),
        (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        (0, 0, 0), (0, 1, 0), (1, 0, 0), (1, 1, 0),
    ]
    b_tris = [
        (0, 1, 2), (0, 2, 3), (4, 6, 5), (4, 7, 6),
        (8, 9, 10), (8, 10, 11), (12, 13, 14), (12, 14, 15),
        (16, 17, 18), (16, 18, 19), (20, 21, 22), (20, 23, 22),
    ]
    b_uvs = [
        (0, 0), (1, 0), (1, 1), (0, 1),
        (0, 0), (1, 0), (1, 1), (0, 1),
        (0, 0), (1, 0), (1, 1), (0, 1),
        (0, 0), (1, 0), (1, 1), (0, 1),
        (0, 0), (1, 0), (1, 1), (0, 1),
        (0, 0), (0, 1), (1, 0), (1, 1),
    ]
    problems_b = audit_cube24("builtin", b_verts, b_tris, b_uvs)
    for p in problems_b:
        check(f"builtin cubo: {p}", False)
    check(f"builtin cubo 24v: 6 faces com winding outward, UV [0,1]², índices ok ({len(problems_b)} problemas)", not problems_b)


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
    scenario_empty_neighbors()
    scenario_config()
    scenario_uvs()
    scenario_plant_cutout()
    scenario_plant_nonsolid()
    scenario_target_highlight()
    scenario_gameplay_rules()
    scenario_vs21_flip()
    scenario_vs21_face_selection()
    scenario_vs21_texture_spec()
    scenario_cube_uv_per_face()
    scenario_audit_cube24()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
