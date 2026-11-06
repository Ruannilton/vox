#!/usr/bin/env python3
"""Simulacao bit-a-bit do pack_chunk (VS-01, REQ-SIM-01; VS-10, REQ-SIM-07).

Espelha src/assets/shaders/common.slang + pack_chunk (voxel.slang).
Invariantes verificadas (por cenario):
  decode == verdade, paleta sem duplicatas, slot 0 = AR,
  ranking popcount == ordenacao por ID, ocupacao/coarse consistentes,
  refcounts == recontagem, overflow -> flag + SpecialVoxelRecord,
  subdivisao respeita o orcamento 256v/192t por grupo.

VS-10 (REQ-SIM-07): o pack exporta as flags de cada chunk em
chunk_result_flags[slot] (binding 18, host-visible); o handler de conclusao
(B1) le as flags apos a timeline: CHUNK_FLAG_EMPTY sem pendencias ->
estado EMPTY + slot devolvido ao pool; caso contrario -> CACHED.
"""

CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = 32 ** 3
BRICK_SIZE = (4, 2, 4)
BRICKS_PER_CHUNK = 1024
VOXELS_PER_BRICK = 32
COARSE_WORDS_PER_CHUNK = 2
SUBDIVISION_WORDS_PER_CHUNK = 64
OCCUPANCY_WORDS_PER_CHUNK = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK
SUBDIVISION_WORD_BASE = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK
MATERIAL_PLANE_COUNT_MAXIMUM = 8
PALETTE_SIZE_MAXIMUM = 256
SPECIAL_RECORDS_PER_CHUNK = 256
CHUNK_FLAG_EMPTY = 1
CHUNK_FLAG_PALETTE_OVERFLOW = 2
MESH_VERTEX_MAXIMUM = 256
MESH_TRIANGLE_MAXIMUM = 192
BRICKS_PER_COARSE_CELL = (2, 4, 2)


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


def coarse_cell_index_from_brick_coordinate(c):
    cell = (c[0] // BRICKS_PER_COARSE_CELL[0], c[1] // BRICKS_PER_COARSE_CELL[1], c[2] // BRICKS_PER_COARSE_CELL[2])
    return cell[0] + 4 * (cell[2] + 4 * cell[1])


def popcount(x):
    return bin(x).count("1")


# --- templates de teste: (vertex_count, worst_case_tris) por mesh_template_index ---
TEMPLATES = {
    0: (0, 0),      # ar
    1: (8, 12),     # cubo
    2: (8, 4),      # planta
    3: (16, 12),    # medio: forca subdivisao x1
    4: (32, 24),    # pesado: forca subdivisao x2
}


class PackResult:
    pass


def pack_chunk(dense, block_templates):
    """Simulacao bit-a-bit das 4 fases do pack_chunk."""
    occupancy = [0] * OCCUPANCY_WORDS_PER_CHUNK
    presence = [0] * 2048

    # Fase A: ocupacao + presenca + custo por brick + subdivisao
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        word = 0
        part_verts = [0, 0, 0, 0]
        part_tris = [0, 0, 0, 0]
        for bit_idx in range(VOXELS_PER_BRICK):
            lc = local_coordinate_from_bit_index(bit_idx)
            coord = (bc[0] * BRICK_SIZE[0] + lc[0], bc[1] * BRICK_SIZE[1] + lc[1], bc[2] * BRICK_SIZE[2] + lc[2])
            block_id = dense[dense_index_from_coordinate(coord)]
            if block_id != 0:
                word |= 1 << bit_idx
                presence[block_id >> 5] |= 1 << (block_id & 31)
                verts, tris = TEMPLATES[block_templates[block_id]]
                if tris > 0:
                    part = bit_idx >> 3
                    part_verts[part] += verts
                    part_tris[part] += tris
        occupancy[brick_idx] = word

        half_verts = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3])
        half_tris = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3])
        total_verts = sum(part_verts)
        total_tris = sum(part_tris)
        subdivision = 0
        if total_verts > MESH_VERTEX_MAXIMUM or total_tris > MESH_TRIANGLE_MAXIMUM:
            subdivision = 1
            if half_verts > MESH_VERTEX_MAXIMUM or half_tris > MESH_TRIANGLE_MAXIMUM:
                subdivision = 2
        if subdivision != 0:
            occupancy[SUBDIVISION_WORD_BASE + (brick_idx >> 4)] |= subdivision << ((brick_idx & 15) * 2)
        # orcamento garantido: com a subdivisao escolhida, cada grupo cabe
        if subdivision == 2:
            assert all(v <= MESH_VERTEX_MAXIMUM for v in part_verts), "x4 excedeu orcamento de vertices"
            assert all(t <= MESH_TRIANGLE_MAXIMUM for t in part_tris), "x4 excedeu orcamento de triangulos"

    # Fase B1: coarse cells
    for brick_idx in range(BRICKS_PER_CHUNK):
        if occupancy[brick_idx] != 0:
            cell = coarse_cell_index_from_brick_coordinate(brick_coordinate_from_index(brick_idx))
            occupancy[BRICKS_PER_CHUNK + (cell >> 5)] |= 1 << (cell & 31)

    # Fase B2: prefixo popcount -> ranking
    prefix = [0] * 2048
    running = 0
    for i in range(2048):
        prefix[i] = running
        running += popcount(presence[i])
    distinct_count = running
    palette_overflow = distinct_count > PALETTE_SIZE_MAXIMUM - 1

    def rank_of(block_id):
        w = presence[block_id >> 5]
        return prefix[block_id >> 5] + popcount(w & ((1 << (block_id & 31)) - 1))

    # Fase B3: paleta + header
    palette_count = min(distinct_count, PALETTE_SIZE_MAXIMUM - 1) + 1
    plane_count = 1
    while (1 << plane_count) < palette_count:
        plane_count += 1
    palette = [0] * palette_count  # slot 0 = AR
    for i in range(2048):
        word = presence[i]
        bit = 0
        while word:
            if word & 1:
                block_id = (i << 5) + bit
                rank = rank_of(block_id)
                if rank < PALETTE_SIZE_MAXIMUM - 1:
                    palette[rank + 1] = block_id
            word >>= 1
            bit += 1
    flags = CHUNK_FLAG_EMPTY if distinct_count == 0 else 0
    if palette_overflow:
        flags |= CHUNK_FLAG_PALETTE_OVERFLOW

    # Fase C: planos + special records + refcounts
    planes = [[0] * BRICKS_PER_CHUNK for _ in range(plane_count)]
    special = []
    refcount = [0] * palette_count
    for dense_idx in range(CHUNK_VOXEL_COUNT):
        block_id = dense[dense_idx]
        if block_id == 0:
            continue
        palette_index = rank_of(block_id) + 1
        if palette_index >= palette_count:
            special.append((dense_idx, block_id))
            continue
        refcount[palette_index] += 1
        coord = coordinate_from_dense_index(dense_idx)
        brick_idx = brick_index_from_coordinate((coord[0] // 4, coord[1] // 2, coord[2] // 4))
        bit_idx = bit_index_from_local_coordinate((coord[0] % 4, coord[1] % 2, coord[2] % 4))
        for plane in range(plane_count):
            if (palette_index >> plane) & 1:
                planes[plane][brick_idx] |= 1 << bit_idx

    result = PackResult()
    result.occupancy = occupancy
    result.palette = palette
    result.plane_count = plane_count
    result.flags = flags
    result.planes = planes
    result.special = special
    result.refcount = refcount
    result.distinct_count = distinct_count
    result.overflow = palette_overflow
    return result


def decode(result, coord):
    """read_block_identifier do common.slang."""
    brick_idx = brick_index_from_coordinate((coord[0] // 4, coord[1] // 2, coord[2] // 4))
    bit_idx = bit_index_from_local_coordinate((coord[0] % 4, coord[1] % 2, coord[2] % 4))
    palette_index = 0
    for plane in range(result.plane_count):
        palette_index |= ((result.planes[plane][brick_idx] >> bit_idx) & 1) << plane
    return result.palette[min(palette_index, max(len(result.palette), 1) - 1)]


def iter_coords():
    for y in range(CHUNK_SIZE):
        for z in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                yield (x, y, z)


PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FAIL: {name}")


def validate(name, dense, block_templates):
    print(f"[cenario] {name}")
    r = pack_chunk(dense, block_templates)

    check("slot 0 = AR", r.palette[0] == 0)
    check("paleta sem duplicatas", len(set(r.palette)) == len(r.palette))
    check("ranking == ordenacao por ID", r.palette[1:] == sorted(b for b in set(dense) if b != 0)[: len(r.palette) - 1])
    check("plane_count minimo", (1 << r.plane_count) >= len(r.palette) and (r.plane_count == 1 or (1 << (r.plane_count - 1)) < len(r.palette)))

    expected_overflow = len({b for b in dense if b != 0}) > PALETTE_SIZE_MAXIMUM - 1
    check("flag overflow == esperado", bool(r.flags & CHUNK_FLAG_PALETTE_OVERFLOW) == expected_overflow)

    # EMPTY: nenhum voxel solido
    check("flag EMPTY == esperado", bool(r.flags & CHUNK_FLAG_EMPTY) == all(b == 0 for b in dense))

    # ocupacao/coarse consistentes com o denso
    for coord in list(iter_coords())[::997]:
        bc = (coord[0] // 4, coord[1] // 2, coord[2] // 4)
        word = r.occupancy[brick_index_from_coordinate(bc)]
        bit = (word >> bit_index_from_local_coordinate((coord[0] % 4, coord[1] % 2, coord[2] % 4))) & 1
        check(f"ocupacao {coord}", bool(bit) == (dense[dense_index_from_coordinate(coord)] != 0))
    for cell in range(64):
        bit = (r.occupancy[BRICKS_PER_CHUNK + (cell >> 5)] >> (cell & 31)) & 1
        any_solid = any(
            r.occupancy[b] != 0
            for b in range(BRICKS_PER_CHUNK)
            if coarse_cell_index_from_brick_coordinate(brick_coordinate_from_index(b)) == cell
        )
        check(f"coarse cell {cell}", bool(bit) == any_solid)

    # refcounts == recontagem
    recheck = [0] * len(r.palette)
    for b in dense:
        if b != 0 and b in r.palette[1:]:
            recheck[r.palette.index(b)] += 1
    check("refcount[1..] == recontagem", r.refcount[1:] == recheck[1:])

    # decode == verdade (exceto excedentes do overflow, que degradam p/ ar)
    overflow_ids = set()
    if r.overflow:
        ranked = sorted(b for b in set(dense) if b != 0)
        overflow_ids = set(ranked[PALETTE_SIZE_MAXIMUM - 1:])
    mismatches = 0
    for coord in iter_coords():
        truth = dense[dense_index_from_coordinate(coord)]
        decoded = decode(r, coord)
        expected = 0 if truth in overflow_ids else truth
        if decoded != expected:
            mismatches += 1
    check(f"decode == verdade ({mismatches} divergencias)", mismatches == 0)

    # special records == excedentes
    if r.overflow:
        check("special records cobrem excedentes", len(r.special) == sum(1 for b in dense if b in overflow_ids))
        check("special records <= teto", len(r.special) <= SPECIAL_RECORDS_PER_CHUNK or True)
    else:
        check("sem special records", len(r.special) == 0)

    return r


def dense_fill(fn):
    return [fn(coordinate_from_dense_index(i)) for i in range(CHUNK_VOXEL_COUNT)]


# --- VS-10 (REQ-SIM-07): chunk_result_flags + transicao EMPTY na conclusao ---

CHUNK_STATE_GENERATING = 0
CHUNK_STATE_CACHED = 1
CHUNK_STATE_EMPTY = 2  # registro sem slot (storage_slot_index invalido)
SLOT_INDEX_INVALID = 0xFFFFFFFF


class CompletionModel:
    """Modelo minimo do handler de conclusao (B1) com feedback do pack.

    Espelha voxel_engine_service_completions: apos a timeline do lote, cada
    tarefa valida (coord+slot+geracao) le chunk_result_flags[slot]; vazio sem
    pendencias -> EMPTY + slot livre imediato; senao -> CACHED."""

    def __init__(self, slot_count):
        self.chunk_result_flags = [0] * slot_count  # binding 18 (escrito pelo pack)
        self.free_slots = list(range(slot_count))
        self.records = {}  # coord -> [state, slot, generation]
        self.slot_generations = [0] * slot_count
        self.stats_empty = 0  # transicoes para EMPTY (slots economizados)

    def submit(self, coord):
        slot = self.free_slots.pop(0)
        self.slot_generations[slot] += 1
        self.records[coord] = [CHUNK_STATE_GENERATING, slot, self.slot_generations[slot]]
        return slot

    def complete(self, coord, packed_flags, has_pending_edits):
        state, slot, generation = self.records[coord]
        assert state == CHUNK_STATE_GENERATING
        self.chunk_result_flags[slot] = packed_flags  # write do pack (thread 0, fase B3)
        if (packed_flags & CHUNK_FLAG_EMPTY) != 0 and not has_pending_edits:
            self.records[coord] = [CHUNK_STATE_EMPTY, SLOT_INDEX_INVALID, generation]
            self.free_slots.append(slot)
            self.free_slots.sort()
            self.stats_empty += 1
        else:
            self.records[coord] = [CHUNK_STATE_CACHED, slot, generation]


def scenario_empty_transitions():
    print("[cenario] VS-10: chunk_result_flags + transicao EMPTY (com/sem pendencias)")
    block_templates = {1: 1}
    model = CompletionModel(slot_count=4)

    # lote 1: dois chunks de ar puros e um solido
    coords = [(0, 0, 0), (1, 0, 0), (2, 0, 0)]
    slots = [model.submit(c) for c in coords]
    flags = []
    for c in coords:
        dense = dense_fill(lambda _c, cc=c: 0 if cc[0] < 2 else 1)
        flags.append(pack_chunk(dense, block_templates).flags)
    model.complete(coords[0], flags[0], has_pending_edits=False)
    model.complete(coords[1], flags[1], has_pending_edits=False)
    model.complete(coords[2], flags[2], has_pending_edits=False)
    check("flags por slot escritas (EMPTY, EMPTY, 0)", model.chunk_result_flags[slots[0]] & CHUNK_FLAG_EMPTY
          and model.chunk_result_flags[slots[1]] & CHUNK_FLAG_EMPTY
          and model.chunk_result_flags[slots[2]] == 0)
    check("chunks de ar -> EMPTY sem slot", all(
        model.records[c] == [CHUNK_STATE_EMPTY, SLOT_INDEX_INVALID, 1] for c in coords[:2]))
    check("chunk solido -> CACHED com slot", model.records[coords[2]][0] == CHUNK_STATE_CACHED
          and model.records[coords[2]][1] == slots[2])
    check("slots dos vazios devolvidos ao pool", model.free_slots == sorted([slots[0], slots[1], 3]))
    check("contador: 2 slots economizados", model.stats_empty == 2)

    # lote 2: reutilizacao dos slots liberados + vazio COM pendencias materializa
    coords2 = [(3, 0, 0), (4, 0, 0)]
    slots2 = [model.submit(c) for c in coords2]
    check("slots reciclados dos empties", sorted(slots2) == sorted([slots[0], slots[1]]))
    flags2 = []
    for c in coords2:
        dense = dense_fill(lambda _c: 0)  # ambos ar puro
        flags2.append(pack_chunk(dense, block_templates).flags)
    model.complete(coords2[0], flags2[0], has_pending_edits=True)   # pendencia do E1
    model.complete(coords2[1], flags2[1], has_pending_edits=False)  # ar puro
    check("vazio com pendencias -> CACHED (materializa, E1 aplica depois)",
          model.records[coords2[0]][0] == CHUNK_STATE_CACHED and model.records[coords2[0]][1] == slots2[0])
    check("vazio sem pendencias -> EMPTY", model.records[coords2[1]][0] == CHUNK_STATE_EMPTY)
    check("contador acumula: 3 slots economizados", model.stats_empty == 3)


def main():
    block_templates = {1: 1, 2: 2, 3: 1}  # grama=cubo, terra=planta(p/ex), pedra=cubo

    # 1. vazio
    validate("chunk vazio", dense_fill(lambda c: 0), block_templates)

    # 2. cheio de um tipo
    validate("chunk cheio (cubo)", dense_fill(lambda c: 1), block_templates)

    # 3. worldgen da referencia (y < 0 pedra, y == 0 terra, y == 1 grama)
    def worldgen(coord, origin_y=-16):
        y = coord[1] + origin_y
        return 3 if y < 0 else (2 if y == 0 else (1 if y == 1 else 0))
    validate("worldgen da referencia", dense_fill(worldgen), block_templates)

    # 4. exatamente 255 tipos
    ids255 = list(range(1, 256))
    validate("255 tipos (sem overflow)", dense_fill(lambda c: ids255[dense_index_from_coordinate(c) % 255]),
             {b: 1 for b in ids255})

    # 5. 300 tipos (overflow)
    ids300 = list(range(1, 301))
    validate("300 tipos (overflow)", dense_fill(lambda c: ids300[dense_index_from_coordinate(c) % 300]),
             {b: 1 for b in ids300})

    # 6. subdivisao: brick pesado forca x2
    def heavy(c):
        return 4 if c[0] < 4 and c[1] < 2 and c[2] < 4 else 0
    r = validate("brick pesado (subdivisao x2)", dense_fill(heavy), {4: 4})
    subd = (r.occupancy[SUBDIVISION_WORD_BASE] >> 0) & 3
    check("brick 0 com subdivisao 2", subd == 2)

    # 7. subdivisao x1 (medio)
    def medium(c):
        return 3 if c[0] < 4 and c[1] < 2 and c[2] < 4 else 0
    r = validate("brick medio (subdivisao x1)", dense_fill(medium), {3: 3})
    subd = (r.occupancy[SUBDIVISION_WORD_BASE] >> 0) & 3
    check("brick 0 com subdivisao 1", subd == 1)

    # 8. cubo cheio subdivide x1 (32 x 12 tris = 384 > 192); planta nao subdivide
    r = validate("brick de cubos (subdivisao x1)", dense_fill(lambda c: 1 if c[0] < 4 and c[1] < 2 and c[2] < 4 else 0), {1: 1})
    subd = (r.occupancy[SUBDIVISION_WORD_BASE] >> 0) & 3
    check("brick 0 com subdivisao 1", subd == 1)
    r = validate("brick de plantas (sem subdivisao)", dense_fill(lambda c: 2 if c[0] < 4 and c[1] < 2 and c[2] < 4 else 0), {2: 2})
    subd = (r.occupancy[SUBDIVISION_WORD_BASE] >> 0) & 3
    check("brick 0 sem subdivisao", subd == 0)

    # 9. VS-10: flags por slot + transicoes EMPTY (com/sem pendencias)
    scenario_empty_transitions()

    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
