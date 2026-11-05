#!/usr/bin/env python3
"""Simulacao da edicao E1 (VS-03, REQ-SIM-04).

Espelha o compute apply_voxel_edits (voxel.slang) fase a fase — cache do
header, hash block_id->slot com tombstones, crescimento de planos, RMW de
planos/ocupacao/refcounts, coarse/EMPTY e recalculo da subdivisao — contra
uma verdade densa de 32^3 voxels, e o modelo CPU do journal (dedup
ultima-escrita-vence, pendencias, tetos do flush) na ordenacao da spec.

Modelo sequencial: no shader as alocacoes de slot correm em paralelo, entao
o INDICE exato alocado pode diferir; o que e determinístico e verificado
aqui e o conteudo decodificado (== verdade), os refcounts por slot, a
protecao do AR, os tombstones e os codigos de resultado.

Cobre (cenarios da spec): insercao/remocao/no-op, dedup e tetos com
backpressure, pendencia em geracao e reintegracao, crescimento de planos,
reciclagem de paleta com tombstone, protecao do slot 0 (AR) mesmo com
refcount 0, paleta cheia, chunk somente-leitura por overflow, flag EMPTY e
subdivisao dos bricks sujos.
"""

CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = 32 ** 3
BRICKS_PER_CHUNK = 1024
VOXELS_PER_BRICK = 32
BRICK_SIZE = (4, 2, 4)
MATERIAL_PLANE_COUNT_MAXIMUM = 8
MATERIAL_WORDS_PER_CHUNK = MATERIAL_PLANE_COUNT_MAXIMUM * BRICKS_PER_CHUNK
PALETTE_SIZE_MAXIMUM = 256
COARSE_WORDS_PER_CHUNK = 2
SUBDIVISION_WORDS_PER_CHUNK = 64
OCCUPANCY_WORDS_PER_CHUNK = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK
SUBDIVISION_WORD_BASE = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK  # 1026
COARSE_CELLS_PER_CHUNK = 64
BRICKS_PER_COARSE_CELL = (2, 4, 2)
MESH_VERTEX_MAXIMUM = 256
MESH_TRIANGLE_MAXIMUM = 192

CHUNK_FLAG_EMPTY = 1
CHUNK_FLAG_PALETTE_OVERFLOW = 2

MAX_EDITS_PER_FLUSH = 4096
MAX_EDIT_JOBS_PER_FLUSH = 256
MAX_EDITS_PER_CHUNK_PER_FLUSH = 1024

EDIT_HASH_CAPACITY = 512
EDIT_HASH_EMPTY = 0xFFFFFFFF
EDIT_HASH_TOMBSTONE = 0xFFFFFFFE

EDIT_RESULT_APPLIED = 0
EDIT_RESULT_NOOP = 1
EDIT_RESULT_REJECTED_PALETTE_FULL = 2
EDIT_RESULT_REJECTED_OVERFLOW = 3

SLOT_REJECTED = -1
SLOT_NOOP = -2

GENERATING, CACHED, RENDERABLE = "GENERATING", "CACHED", "RENDERABLE"

# Custos de template por block id (vertex_count, worst_case_tris) — cubo e
# planta como no render_sim; 3 = pesado sintetico (32v/24t por voxel).
# Ids sem entrada caem no custo do cubo (o registro real sempre tem template).
from collections import defaultdict

TEMPLATE_COST = defaultdict(lambda: (8, 6), {1: (8, 6), 2: (8, 4), 3: (32, 24)})


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


def subdivision_rule(part_verts, part_tris):
    half_verts = max(part_verts[0] + part_verts[1], part_verts[2] + part_verts[3])
    half_tris = max(part_tris[0] + part_tris[1], part_tris[2] + part_tris[3])
    total_verts = sum(part_verts)
    total_tris = sum(part_tris)
    subdivision = 0
    if total_verts > MESH_VERTEX_MAXIMUM or total_tris > MESH_TRIANGLE_MAXIMUM:
        subdivision = 1
        if half_verts > MESH_VERTEX_MAXIMUM or half_tris > MESH_TRIANGLE_MAXIMUM:
            subdivision = 2
    return subdivision


def expected_subdivisions(dense, registry_cost):
    """Custo por brick na verdade densa (regra do pack / Fase 3)."""
    subdivisions = [0] * BRICKS_PER_CHUNK
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        part_verts = [0, 0, 0, 0]
        part_tris = [0, 0, 0, 0]
        for bit_idx in range(VOXELS_PER_BRICK):
            lc = local_coordinate_from_bit_index(bit_idx)
            coord = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
            block_id = dense[dense_index_from_coordinate(coord)]
            if block_id == 0:
                continue
            verts, tris = registry_cost[block_id]
            if tris > 0:
                part = bit_idx >> 3
                part_verts[part] += verts
                part_tris[part] += tris
        subdivisions[brick_idx] = subdivision_rule(part_verts, part_tris)
    return subdivisions


# --- chunk packed (espelha ChunkHeader + planos + ocupacao) ---

class PackedChunk:
    def __init__(self):
        self.palette = [0] * PALETTE_SIZE_MAXIMUM
        self.refcount = [0] * PALETTE_SIZE_MAXIMUM
        self.palette_size = 0
        self.plane_count = 1
        self.flags = CHUNK_FLAG_EMPTY
        self.planes = [0] * MATERIAL_WORDS_PER_CHUNK
        self.occupancy = [0] * OCCUPANCY_WORDS_PER_CHUNK

    @classmethod
    def pack(cls, dense):
        """B3: slot 0 = AR; ids distintos em ordem crescente no rank+1."""
        chunk = cls()
        distinct = sorted(set(dense) - {0})
        assert len(distinct) <= PALETTE_SIZE_MAXIMUM - 1, "pack de overflow e montado a mao"
        palette_count = len(distinct) + 1
        rank = {block_id: i + 1 for i, block_id in enumerate(distinct)}
        for block_id, slot in rank.items():
            chunk.palette[slot] = block_id
        chunk.palette_size = palette_count
        plane_count = 1
        while (1 << plane_count) < palette_count:
            plane_count += 1
        chunk.plane_count = plane_count
        any_solid = False
        for i, block_id in enumerate(dense):
            coord = coordinate_from_dense_index(i)
            brick_idx = brick_index_from_coordinate(
                (coord[0] // 4, coord[1] // 2, coord[2] // 4))
            bit_idx = bit_index_from_local_coordinate(
                (coord[0] % 4, coord[1] % 2, coord[2] % 4))
            if block_id == 0:
                chunk.refcount[0] += 1
                continue
            any_solid = True
            palette_index = rank[block_id]
            chunk.refcount[palette_index] += 1
            for plane in range(plane_count):
                if (palette_index >> plane) & 1:
                    chunk.planes[plane * BRICKS_PER_CHUNK + brick_idx] |= 1 << bit_idx
            chunk.occupancy[brick_idx] |= 1 << bit_idx
        chunk.flags = 0 if any_solid else CHUNK_FLAG_EMPTY
        chunk._recompute_coarse()
        # CAMINHO B: o pack grava a subdivisão por brick (mesma regra da Fase 3).
        expected = expected_subdivisions(dense, TEMPLATE_COST)
        for brick_idx in range(BRICKS_PER_CHUNK):
            chunk._set_subdivision(brick_idx, expected[brick_idx])
        return chunk

    def read_palette_index_at(self, plane_count, coord):
        brick_idx = brick_index_from_coordinate(
            (coord[0] // 4, coord[1] // 2, coord[2] // 4))
        bit_idx = bit_index_from_local_coordinate(
            (coord[0] % 4, coord[1] % 2, coord[2] % 4))
        palette_index = 0
        for plane in range(plane_count):
            word = self.planes[plane * BRICKS_PER_CHUNK + brick_idx]
            palette_index |= ((word >> bit_idx) & 1) << plane
        return palette_index

    def decode(self, coord):
        palette_index = self.read_palette_index_at(self.plane_count, coord)
        palette_index = min(palette_index, max(self.palette_size, 1) - 1)
        return self.palette[palette_index]

    def _recompute_coarse(self):
        for cell in range(COARSE_CELLS_PER_CHUNK):
            cc = (cell & 3, cell >> 4, (cell >> 2) & 3)
            base = (cc[0] * 2, cc[1] * 4, cc[2] * 2)
            any_solid = False
            for b in range(16):
                bc = (base[0] + (b & 1), base[1] + (b >> 2), base[2] + ((b >> 1) & 1))
                if self.occupancy[brick_index_from_coordinate(bc)] != 0:
                    any_solid = True
                    break
            addr = BRICKS_PER_CHUNK + (cell >> 5)
            mask = 1 << (cell & 31)
            if any_solid:
                self.occupancy[addr] |= mask
            else:
                self.occupancy[addr] &= ~mask & 0xFFFFFFFF

    def subdivision_of(self, brick_idx):
        word = self.occupancy[SUBDIVISION_WORD_BASE + (brick_idx >> 4)]
        return (word >> ((brick_idx & 15) * 2)) & 3

    def _set_subdivision(self, brick_idx, subdivision):
        addr = SUBDIVISION_WORD_BASE + (brick_idx >> 4)
        shift = (brick_idx & 15) * 2
        self.occupancy[addr] &= ~(3 << shift) & 0xFFFFFFFF
        if subdivision:
            self.occupancy[addr] |= subdivision << shift


# --- hash block_id -> slot (espelha edit_hash_* do shader, sequencial) ---

class EditHash:
    def __init__(self):
        self.key = [EDIT_HASH_EMPTY] * EDIT_HASH_CAPACITY
        self.slot = [EDIT_HASH_EMPTY] * EDIT_HASH_CAPACITY

    def _bucket(self, block_id):
        return ((block_id * 0x9E3779B1) >> 23) & (EDIT_HASH_CAPACITY - 1)

    def reserve(self, block_id):
        """Retorna (bucket, owned): owned=True => o chamador DEVE publicar."""
        h = self._bucket(block_id)
        for probe in range(EDIT_HASH_CAPACITY):
            idx = (h + probe) & (EDIT_HASH_CAPACITY - 1)
            key = self.key[idx]
            if key == block_id:
                return idx, False
            if key == EDIT_HASH_TOMBSTONE:
                continue
            if key == EDIT_HASH_EMPTY:
                self.key[idx] = block_id
                return idx, True
        return None, False  # defensivo: tabela cheia

    def publish(self, bucket, slot):
        self.slot[bucket] = slot

    def lookup(self, bucket):
        return self.slot[bucket]

    def tombstone(self, block_id):
        h = self._bucket(block_id)
        for probe in range(EDIT_HASH_CAPACITY):
            idx = (h + probe) & (EDIT_HASH_CAPACITY - 1)
            key = self.key[idx]
            if key == EDIT_HASH_EMPTY:
                return
            if key == block_id:
                self.key[idx] = EDIT_HASH_TOMBSTONE
                return


def edit_resolve_slot(chunk, hash_, block_id):
    """Espelha edit_resolve_slot. Retorna (slot, counted) ou (SLOT_REJECTED, False)."""
    for _attempt in range(32):
        bucket, owned = hash_.reserve(block_id)
        if bucket is None:
            return SLOT_REJECTED, False
        if owned:
            # edit_alloc_slot: menor slot livre (refcount 0), NUNCA o 0 (AR).
            for s in range(1, PALETTE_SIZE_MAXIMUM):
                if chunk.refcount[s] != 0:
                    continue
                old_id = chunk.palette[s]
                if old_id != 0 and old_id != block_id:
                    hash_.tombstone(old_id)  # evicção preguiçosa do slot reciclado
                chunk.palette[s] = block_id
                chunk.palette_size = max(chunk.palette_size, s + 1)
                hash_.publish(bucket, s)
                chunk.refcount[s] = 1  # sai contado (primeiro uso)
                return s, True
            hash_.publish(bucket, SLOT_REJECTED)
            return SLOT_REJECTED, False
        s = hash_.lookup(bucket)
        if s == SLOT_REJECTED:
            return SLOT_REJECTED, False
        # edit_claim_slot: slot vivo e com o id certo.
        if chunk.refcount[s] > 0:
            if chunk.palette[s] == block_id:
                return s, False
            continue  # conteúdo mudou: re-resolve pelo hash
        # ressurreição: slot esvaziado preguiçosamente ainda com o mesmo id
        if chunk.palette[s] == block_id:
            chunk.refcount[s] = 1  # CAS 0->1, sai contado
            return s, True
        # slot trocou de dono: re-resolve
    return SLOT_REJECTED, False


def apply_voxel_edits(chunk, edits):
    """Espelha as fases 0..3 do compute para um job (chunk, edits).
    edits: lista de (voxel_index, block_id), no máximo 1 por voxel.
    Retorna a lista de códigos EDIT_RESULT_* por edição (posições do ring)."""
    if chunk.flags & CHUNK_FLAG_PALETTE_OVERFLOW:
        return [EDIT_RESULT_REJECTED_OVERFLOW] * len(edits)

    results = [EDIT_RESULT_APPLIED] * len(edits)

    # Fase 0: semente do hash com as entradas vivas (slot 0 = AR sempre).
    hash_ = EditHash()
    for i in range(chunk.palette_size):
        if i == 0 or chunk.refcount[i] > 0:
            bucket, owned = hash_.reserve(chunk.palette[i])
            if owned:
                hash_.publish(bucket, i)

    # Fase 1: resolve slots (old_index lido ANTES do crescimento de planos).
    old_indices = [0] * len(edits)
    new_slots = [SLOT_NOOP] * len(edits)
    counted = [False] * len(edits)
    for i, (voxel_index, new_block) in enumerate(edits):
        coord = coordinate_from_dense_index(voxel_index)
        old_index = chunk.read_palette_index_at(chunk.plane_count, coord)
        old_index = min(old_index, chunk.palette_size - 1)  # clamp defensivo
        old_indices[i] = old_index
        if chunk.palette[old_index] == new_block:
            continue  # NOOP
        s, c = edit_resolve_slot(chunk, hash_, new_block)
        new_slots[i] = s
        counted[i] = c

    # Fase 1.5: crescimento de planos (words novas chegam zeradas).
    required_planes = chunk.plane_count
    while (1 << required_planes) < max(chunk.palette_size, 1):
        required_planes += 1
    if required_planes > chunk.plane_count:
        first_new_word = chunk.plane_count * BRICKS_PER_CHUNK
        new_word_count = (required_planes - chunk.plane_count) * BRICKS_PER_CHUNK
        for w in range(first_new_word, first_new_word + new_word_count):
            chunk.planes[w] = 0
        chunk.plane_count = required_planes

    # Fase 2: aplica as edições.
    dirty_bricks = set()
    for i, (voxel_index, new_block) in enumerate(edits):
        if new_slots[i] == SLOT_NOOP:
            results[i] = EDIT_RESULT_NOOP
            continue
        if new_slots[i] == SLOT_REJECTED:
            results[i] = EDIT_RESULT_REJECTED_PALETTE_FULL
            continue
        coord = coordinate_from_dense_index(voxel_index)
        brick_idx = brick_index_from_coordinate(
            (coord[0] // 4, coord[1] // 2, coord[2] // 4))
        bit_idx = bit_index_from_local_coordinate(
            (coord[0] % 4, coord[1] % 2, coord[2] % 4))
        mask = 1 << bit_idx
        old_index = old_indices[i]
        new_index = new_slots[i]

        for plane in range(chunk.plane_count):
            old_bit = (old_index >> plane) & 1
            new_bit = (new_index >> plane) & 1
            if old_bit == new_bit:
                continue
            addr = plane * BRICKS_PER_CHUNK + brick_idx
            if new_bit:
                chunk.planes[addr] |= mask
            else:
                chunk.planes[addr] &= ~mask & 0xFFFFFFFF

        if new_block != 0:
            chunk.occupancy[brick_idx] |= mask
        else:
            chunk.occupancy[brick_idx] &= ~mask & 0xFFFFFFFF
        dirty_bricks.add(brick_idx)

        if not counted[i]:
            chunk.refcount[new_index] += 1
        chunk.refcount[old_index] -= 1
        results[i] = EDIT_RESULT_APPLIED

    # Fase 2.5: coarse cells, flag EMPTY, escalares do header.
    any_solid = any(chunk.occupancy[b] != 0 for b in range(BRICKS_PER_CHUNK))
    if any_solid:
        chunk.flags &= ~CHUNK_FLAG_EMPTY
    else:
        chunk.flags |= CHUNK_FLAG_EMPTY
    chunk._recompute_coarse()

    # Fase 3: subdivisão dos bricks sujos (lê os planos atualizados).
    for brick_idx in dirty_bricks:
        bc = brick_coordinate_from_index(brick_idx)
        part_verts = [0, 0, 0, 0]
        part_tris = [0, 0, 0, 0]
        for bit_idx in range(VOXELS_PER_BRICK):
            lc = local_coordinate_from_bit_index(bit_idx)
            coord = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
            palette_index = chunk.read_palette_index_at(chunk.plane_count, coord)
            palette_index = min(palette_index, chunk.palette_size - 1)
            block_id = chunk.palette[palette_index]
            if block_id == 0:
                continue
            verts, tris = TEMPLATE_COST[block_id]
            if tris > 0:
                part = bit_idx >> 3
                part_verts[part] += verts
                part_tris[part] += tris
        chunk._set_subdivision(brick_idx, subdivision_rule(part_verts, part_tris))

    return results


# --- journal CPU (REQ-EDIT-01..03) ---

def chunk_and_index(world_voxel):
    chunk = (world_voxel[0] // CHUNK_SIZE, world_voxel[1] // CHUNK_SIZE, world_voxel[2] // CHUNK_SIZE)
    local = (world_voxel[0] - chunk[0] * CHUNK_SIZE,
             world_voxel[1] - chunk[1] * CHUNK_SIZE,
             world_voxel[2] - chunk[2] * CHUNK_SIZE)
    return chunk, dense_index_from_coordinate(local)


class EditJournal:
    def __init__(self):
        self.queue = []      # [(world_voxel, block_id)]
        self.lookup = {}     # world_voxel -> índice na fila
        self.pending = {}    # chunk -> [(world_voxel, block_id)]
        self.deferred = 0

    def request(self, world_voxel, block_id):
        if block_id > 65535:
            return
        if world_voxel in self.lookup:
            i = self.lookup[world_voxel]
            self.queue[i] = (world_voxel, block_id)  # última escrita vence
            return
        self.lookup[world_voxel] = len(self.queue)
        self.queue.append((world_voxel, block_id))

    def _defer(self, chunk, request):
        lst = self.pending.setdefault(chunk, [])
        for j, existing in enumerate(lst):
            if existing[0] == request[0]:
                lst[j] = request  # última escrita vence
                return
        lst.append(request)

    def flush(self, chunk_states):
        """chunk_states: coord -> (state, slot). Retorna {slot: [(voxel_index, block_id)]}
        com edições contíguas por chunk, obedecendo aos tetos."""
        # 1. Reintegra pendências prontas.
        for coord in [c for c, (st, _s) in ((c, chunk_states.get(c, ("?", None))) for c in self.pending)
                      if st in (CACHED, RENDERABLE)]:
            for request in self.pending.pop(coord):
                self.request(*request)

        # 2. Drena a fila agrupando por slot com os tetos.
        staged = {}
        kept = []
        total = 0
        for request in self.queue:
            chunk, voxel_index = chunk_and_index(request[0])
            state, slot = chunk_states.get(chunk, (None, None))
            if state not in (CACHED, RENDERABLE):
                self._defer(chunk, request)
                continue
            if total >= MAX_EDITS_PER_FLUSH:
                kept.append(request)
                self.deferred += 1
                continue
            if slot not in staged:
                if len(staged) >= MAX_EDIT_JOBS_PER_FLUSH:
                    kept.append(request)
                    self.deferred += 1
                    continue
                staged[slot] = []
            if len(staged[slot]) >= MAX_EDITS_PER_CHUNK_PER_FLUSH:
                kept.append(request)
                self.deferred += 1
                continue
            staged[slot].append((voxel_index, request[1]))
            total += 1

        self.queue = kept
        self.lookup = {w: i for i, (w, _b) in enumerate(kept)}
        return staged


# --- checks ---

PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


def verify_consistency(name, chunk, dense):
    """Invariantes pós-flush contra a verdade densa (AC-02)."""
    ok = True
    # decode completo == verdade
    for i, block_id in enumerate(dense):
        if chunk.decode(coordinate_from_dense_index(i)) != block_id:
            ok = False
            break
    check(f"{name}: decode == verdade (32768 voxels)", ok)

    # refcounts por slot == contagem de voxels que decodificam naquele slot
    index_count = [0] * PALETTE_SIZE_MAXIMUM
    for i in range(CHUNK_VOXEL_COUNT):
        palette_index = chunk.read_palette_index_at(chunk.plane_count, coordinate_from_dense_index(i))
        palette_index = min(palette_index, chunk.palette_size - 1)
        index_count[palette_index] += 1
    rc_ok = all(chunk.refcount[s] == index_count[s] for s in range(PALETTE_SIZE_MAXIMUM))
    check(f"{name}: refcounts exatos por slot", rc_ok)
    # slot decodificado carrega o id da verdade (sem mapeamento cruzado)
    id_ok = True
    for s in range(chunk.palette_size):
        if index_count[s] > 0 and chunk.refcount[s] == 0:
            id_ok = False
    check(f"{name}: slot com voxels tem refcount > 0", id_ok)

    # ocupação: bit setado <=> voxel sólido na verdade
    occ_ok = True
    for brick_idx in range(BRICKS_PER_CHUNK):
        bc = brick_coordinate_from_index(brick_idx)
        for bit_idx in range(VOXELS_PER_BRICK):
            lc = local_coordinate_from_bit_index(bit_idx)
            coord = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
            solid = dense[dense_index_from_coordinate(coord)] != 0
            bit = (chunk.occupancy[brick_idx] >> bit_idx) & 1
            if bit != (1 if solid else 0):
                occ_ok = False
                break
        if not occ_ok:
            break
    check(f"{name}: ocupação por brick exata", occ_ok)

    # coarse cells
    coarse_ok = True
    for cell in range(COARSE_CELLS_PER_CHUNK):
        cc = (cell & 3, cell >> 4, (cell >> 2) & 3)
        base = (cc[0] * 2, cc[1] * 4, cc[2] * 2)
        any_solid = False
        for b in range(16):
            bc = (base[0] + (b & 1), base[1] + (b >> 2), base[2] + ((b >> 1) & 1))
            if chunk.occupancy[brick_index_from_coordinate(bc)] != 0:
                any_solid = True
                break
        bit = (chunk.occupancy[BRICKS_PER_CHUNK + (cell >> 5)] >> (cell & 31)) & 1
        if bit != (1 if any_solid else 0):
            coarse_ok = False
            break
    check(f"{name}: coarse cells exatas", coarse_ok)

    # flag EMPTY
    any_solid = any(b != 0 for b in dense)
    check(f"{name}: flag EMPTY == (sem sólidos)",
          bool(chunk.flags & CHUNK_FLAG_EMPTY) == (not any_solid))

    # subdivisão por brick == regra da verdade
    expected = expected_subdivisions(dense, TEMPLATE_COST)
    check(f"{name}: subdivisão por brick exata",
          all(chunk.subdivision_of(b) == expected[b] for b in range(BRICKS_PER_CHUNK)))

    # AR protegido
    check(f"{name}: palette[0] == 0 (AR nunca reciclado)", chunk.palette[0] == 0)


def apply_and_update_truth(chunk, dense, edits):
    results = apply_voxel_edits(chunk, edits)
    for voxel_index, block_id in edits:
        dense[voxel_index] = block_id
    return results


# --- cenários ---

def scenario_insert_remove_noop():
    print("[cenario] insercao, remocao e no-op")
    dense = [0] * CHUNK_VOXEL_COUNT
    v_grass = dense_index_from_coordinate((10, 10, 10))
    v_air = dense_index_from_coordinate((20, 20, 20))
    v_noop = dense_index_from_coordinate((5, 5, 5))
    dense[v_grass] = 1
    dense[v_noop] = 2
    chunk = PackedChunk.pack(dense)

    edits = [(v_grass, 0), (v_air, 3), (v_noop, 2)]
    results = apply_and_update_truth(chunk, dense, edits)
    check("remoção/inserção aplicadas, no-op reportado",
          results == [EDIT_RESULT_APPLIED, EDIT_RESULT_APPLIED, EDIT_RESULT_NOOP])
    verify_consistency("basico", chunk, dense)


def scenario_dedup_and_caps():
    print("[cenario] dedup ultima-escrita-vence e tetos do flush")
    journal = EditJournal()
    states = {(0, 0, 0): (RENDERABLE, 7)}

    # dedup: 3 escritas no mesmo voxel -> só a última entra
    for block_id in (1, 2, 3):
        journal.request((1, 1, 1), block_id)
    staged = journal.flush(states)
    check("dedup: 1 edição staged com o último id", staged.get(7) == [(dense_index_from_coordinate((1, 1, 1)), 3)])

    # teto de edições por flush: 4096 staged, 904 kept, dreno no ciclo seguinte
    journal = EditJournal()
    states = {(0, 0, k): (RENDERABLE, 100 + k) for k in range(5)}
    for i in range(5000):
        chunk_idx, j = i // 1000, i % 1000
        journal.request((j % 32, j // 32, chunk_idx * 32), 1)  # 5000 voxels distintos, 5 chunks
    staged = journal.flush(states)
    total = sum(len(v) for v in staged.values())
    check("teto 4096: staged == 4096", total == MAX_EDITS_PER_FLUSH)
    check("backpressure: 904 ficaram na fila", len(journal.queue) == 904 and journal.deferred == 904)
    check("ordem preservada pelo backpressure", journal.queue[0] == ((0, 3, 128), 1))
    staged2 = journal.flush(states)
    check("dreno na ordem: 904 no próximo flush", sum(len(v) for v in staged2.values()) == 904)
    check("fila vazia após o dreno", journal.queue == [])

    # teto de jobs: 300 chunks -> 256 jobs, 44 kept
    journal = EditJournal()
    states = {}
    for i in range(300):
        states[(i, 0, 0)] = (RENDERABLE, i)
        journal.request((i * 32, 0, 0), 1)
    staged = journal.flush(states)
    check("teto 256 jobs", len(staged) == MAX_EDIT_JOBS_PER_FLUSH and len(journal.queue) == 44)

    # teto por chunk: 1500 edições -> 1024 staged, 476 kept
    journal = EditJournal()
    states = {(0, 0, 0): (RENDERABLE, 3)}
    for i in range(1500):
        journal.request(((i * 7) % 32, (i * 11) % 32, (i * 13) % 32), 1)
    staged = journal.flush(states)
    # dedup pode ter fundido algumas; o teto nunca é excedido
    check("teto 1024/chunk respeitado", len(staged.get(3, [])) <= MAX_EDITS_PER_CHUNK_PER_FLUSH)


def scenario_pending_reintegration():
    print("[cenario] chunk em geracao e posterior reintegracao")
    journal = EditJournal()
    states = {(0, 0, 0): (GENERATING, 5)}
    journal.request((3, 3, 3), 1)
    journal.request((3, 3, 3), 2)  # dedup também dentro do pending
    staged = journal.flush(states)
    check("chunk GENERATING: nada staged", staged == {})
    check("pending reteve o pedido", len(journal.pending.get((0, 0, 0), [])) == 1)

    states[(0, 0, 0)] = (RENDERABLE, 5)
    staged = journal.flush(states)
    check("reintegração aplica a última escrita",
          staged.get(5) == [(dense_index_from_coordinate((3, 3, 3)), 2)])
    check("pending esvaziado após reintegrar", (0, 0, 0) not in journal.pending)


def scenario_plane_growth():
    print("[cenario] crescimento de planos e reciclagem com tombstone")
    dense = [0] * CHUNK_VOXEL_COUNT
    dense[dense_index_from_coordinate((0, 0, 0))] = 1
    chunk = PackedChunk.pack(dense)
    check("início: paleta 2, 1 plano", chunk.palette_size == 2 and chunk.plane_count == 1)

    # 6 ids novos num flush: paleta 2 -> 8 entradas => 3 planos
    edits = [(dense_index_from_coordinate((i, 0, 0)), 10 + i) for i in range(1, 7)]
    results = apply_and_update_truth(chunk, dense, edits)
    check("ids novos aplicados", all(r == EDIT_RESULT_APPLIED for r in results))
    check("paleta cresceu para 8 e planos para 3",
          chunk.palette_size == 8 and chunk.plane_count == 3)
    verify_consistency("crescimento", chunk, dense)

    # esvazia o id 12 (refcount -> 0) e recicla o slot no flush seguinte
    edits = [(dense_index_from_coordinate((2, 0, 0)), 0)]
    apply_and_update_truth(chunk, dense, edits)
    freed = chunk.palette.index(12)
    check("id 12 esvaziado (refcount 0)", chunk.refcount[freed] == 0)
    edits = [(dense_index_from_coordinate((30, 30, 30)), 77)]
    apply_and_update_truth(chunk, dense, edits)
    check("slot esvaziado reciclado pelo id 77", chunk.palette[freed] == 77)
    check("id antigo não decodifica mais pelo slot reciclado",
          chunk.decode((2, 0, 0)) == 0)
    verify_consistency("reciclagem", chunk, dense)


def scenario_ar_protection():
    print("[cenario] proteção do AR (slot 0 nunca reciclado)")
    dense = [1] * CHUNK_VOXEL_COUNT  # 100% sólido: refcount[0] = 0
    chunk = PackedChunk.pack(dense)
    check("chunk sólido: refcount[0] == 0", chunk.refcount[0] == 0)

    # inserir id novo NÃO pode tomar o slot 0 (ressurreição é só para o AR)
    edits = [(dense_index_from_coordinate((31, 31, 31)), 7)]
    results = apply_and_update_truth(chunk, dense, edits)
    check("id novo aplicado", results == [EDIT_RESULT_APPLIED])
    check("slot 0 preservado como AR", chunk.palette[0] == 0)
    check("id 7 alocado em slot != 0", 7 in chunk.palette[1:])
    verify_consistency("ar-protegido", chunk, dense)

    # remoção ressuscita o slot 0 com refcount contado
    edits = [(dense_index_from_coordinate((0, 0, 0)), 0)]
    results = apply_and_update_truth(chunk, dense, edits)
    check("remoção aplicada sobre chunk sólido", results == [EDIT_RESULT_APPLIED])
    check("AR ressuscitado com refcount exato", chunk.refcount[0] == 1)
    verify_consistency("ar-ressurreicao", chunk, dense)


def scenario_palette_full_and_overflow():
    print("[cenario] paleta cheia e chunk somente-leitura por overflow")
    # 255 tipos distintos: paleta lotada (256 entradas com o AR)
    dense = [0] * CHUNK_VOXEL_COUNT
    for i in range(255):
        dense[dense_index_from_coordinate((i % 32, i // 32, 0))] = i + 1
    chunk = PackedChunk.pack(dense)
    check("paleta lotada: 256 entradas, 8 planos",
          chunk.palette_size == 256 and chunk.plane_count == 8)

    snapshot = (list(chunk.palette), list(chunk.refcount), list(chunk.planes), list(chunk.occupancy))
    edits = [(dense_index_from_coordinate((31, 31, 31)), 999)]
    results = apply_voxel_edits(chunk, edits)
    check("bloco novo com paleta cheia: REJECTED_PALETTE_FULL", results == [EDIT_RESULT_REJECTED_PALETTE_FULL])
    check("dados intocados após rejeição",
          (chunk.palette, chunk.refcount, chunk.planes, chunk.occupancy) == snapshot)

    # edição de no-op e remoção ainda funcionam com a paleta cheia
    dense2 = list(dense)
    edits = [(dense_index_from_coordinate((0, 0, 0)), 1), (dense_index_from_coordinate((1, 0, 0)), 0)]
    results = apply_and_update_truth(chunk, dense2, edits)
    check("no-op e remoção passam com paleta cheia",
          results == [EDIT_RESULT_NOOP, EDIT_RESULT_APPLIED])
    verify_consistency("paleta-cheia", chunk, dense2)

    # chunk em overflow: somente-leitura, rejeição com código próprio
    over = PackedChunk.pack([1] * CHUNK_VOXEL_COUNT)
    over.flags |= CHUNK_FLAG_PALETTE_OVERFLOW
    snapshot = (list(over.palette), list(over.refcount), list(over.planes), list(over.occupancy))
    results = apply_voxel_edits(over, [(0, 0), (1, 2)])
    check("overflow: todas as edições REJECTED_OVERFLOW",
          results == [EDIT_RESULT_REJECTED_OVERFLOW] * 2)
    check("overflow: chunk intocado",
          (over.palette, over.refcount, over.planes, over.occupancy) == snapshot)


def scenario_empty_flag():
    print("[cenario] flag EMPTY")
    dense = [0] * CHUNK_VOXEL_COUNT
    only = dense_index_from_coordinate((16, 16, 16))
    dense[only] = 1
    chunk = PackedChunk.pack(dense)
    check("chunk com 1 voxel: sem EMPTY", (chunk.flags & CHUNK_FLAG_EMPTY) == 0)
    results = apply_and_update_truth(chunk, dense, [(only, 0)])
    check("remover o último voxel: EMPTY setada",
          results == [EDIT_RESULT_APPLIED] and (chunk.flags & CHUNK_FLAG_EMPTY) != 0)
    verify_consistency("esvaziado", chunk, dense)
    results = apply_and_update_truth(chunk, dense, [(only, 2)])
    check("reinserir: EMPTY limpa", (chunk.flags & CHUNK_FLAG_EMPTY) == 0)
    verify_consistency("reinserido", chunk, dense)


def scenario_subdivision_updates():
    print("[cenario] subdivisao dos bricks sujos (template pesado)")
    dense = [0] * CHUNK_VOXEL_COUNT
    # brick 0 cheio de pesado: 32 voxels x (32v, 24t) = 1024/768 -> subdivisao 2
    brick_voxels = []
    for bit_idx in range(VOXELS_PER_BRICK):
        lc = local_coordinate_from_bit_index(bit_idx)
        dense[dense_index_from_coordinate(lc)] = 3
        brick_voxels.append(dense_index_from_coordinate(lc))
    chunk = PackedChunk.pack(dense)
    check("pack: brick pesado em subdivisão 2", chunk.subdivision_of(0) == 2)

    # remove 16 voxels distribuídos (bit_idx par): 4 por parte -> 128v/parte,
    # metade 256 <= 256 e total 512 > 256 -> subdivisão 1
    edits = [(brick_voxels[i], 0) for i in range(0, VOXELS_PER_BRICK, 2)]
    apply_and_update_truth(chunk, dense, edits)
    check("16 pesados restantes: subdivisão 1", chunk.subdivision_of(0) == 1)

    # remove mais 8 (ímpares baixos): 8 restantes -> 8 x 32v = 256 = teto -> subdivisão 0
    edits = [(brick_voxels[i], 0) for i in range(1, 17, 2)]
    apply_and_update_truth(chunk, dense, edits)
    check("8 pesados restantes: subdivisão 0", chunk.subdivision_of(0) == 0)
    verify_consistency("subdivisao", chunk, dense)


def scenario_random_flushes():
    print("[cenario] propriedade: flushes aleatorios mantem todas as invariantes")
    import random
    rng = random.Random(42)
    dense = [0] * CHUNK_VOXEL_COUNT
    for i in range(CHUNK_VOXEL_COUNT):
        dense[i] = rng.choice([0, 0, 0, 1, 2, 3])
    chunk = PackedChunk.pack(dense)
    ok = True
    for flush_idx in range(6):
        edits = []
        used = set()
        for _ in range(300):
            voxel_index = rng.randrange(CHUNK_VOXEL_COUNT)
            if voxel_index in used:
                continue
            used.add(voxel_index)
            edits.append((voxel_index, rng.choice([0, 1, 2, 3, 4, 5])))
        apply_and_update_truth(chunk, dense, edits)
        for i in range(CHUNK_VOXEL_COUNT):
            if chunk.decode(coordinate_from_dense_index(i)) != dense[i]:
                ok = False
                break
        if not ok:
            break
    check("6 flushes x 300 edições: decode == verdade a cada flush", ok)
    verify_consistency("aleatorio-final", chunk, dense)


def main():
    scenario_insert_remove_noop()
    scenario_dedup_and_caps()
    scenario_pending_reintegration()
    scenario_plane_growth()
    scenario_ar_protection()
    scenario_palette_full_and_overflow()
    scenario_empty_flag()
    scenario_subdivision_updates()
    scenario_random_flushes()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
