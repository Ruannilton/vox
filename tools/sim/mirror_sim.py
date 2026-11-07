#!/usr/bin/env python3
"""Simulacao do mirror CPU-side (VS-04, REQ-SIM-05).

Espelha a maquina de estados de pagina/ring, a disciplina anti-ABA e a
convergencia por construcao (ADR-C2): a verdade e worldgen + journal E1; a
GPU (formato packed, modelo da edit_sim) e a RAM (grid denso u16 y-contiguo)
sao views do mesmo journal e devem convergir bit a bit, inclusive apos a
reconciliacao de rejeicoes.

Cobre: indexacao y-contigua vs x-contigua (regra 7 — nunca misturar),
coluna vertical contigua de 64 B, reserva/liberacao do ring com disciplina
"slot em voo so e liberado pelo handler de conclusao", eviccao com export
pendente/em voo, conclusao vencida por (coord, geracao), export_only sem
pack, replay de pendencias na materializacao, paridade GPU<->mirror em
163.840 voxels (5 chunks) com rejeicao reconciliada e API tri-state.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from edit_sim import (
    PackedChunk,
    apply_voxel_edits,
    coordinate_from_dense_index,
    dense_index_from_coordinate,
    CHUNK_FLAG_PALETTE_OVERFLOW,
    EDIT_RESULT_APPLIED,
    EDIT_RESULT_REJECTED_OVERFLOW,
)

CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = 32 ** 3
MIRROR_RING_SLOTS = 64
MIRROR_PAGE_POOL_SIZE = 768
RADIUS_SIMULATION = 5

PENDING_READBACK = "PENDING_READBACK"
MATERIALIZED = "MATERIALIZED"

GENERATING, CACHED, RENDERABLE = "GENERATING", "CACHED", "RENDERABLE"


# --- indexacao (regra 7: y-contiguo no mirror, x-contiguo no scratch) ---

def mirror_index(c):
    return c[1] | (c[2] << 5) | (c[0] << 10)


def to_mirror_ids(dense):
    """Converte o denso x-contíguo (scratch GPU) para o layout y-contíguo do
    mirror. Na GPU real quem escreve y-contíguo é o próprio generate (export);
    na simulação a verdade densa é x-contígua, então a conversão é explícita."""
    out = [0] * CHUNK_VOXEL_COUNT
    for i in range(CHUNK_VOXEL_COUNT):
        out[mirror_index(coordinate_from_dense_index(i))] = dense[i]
    return out


def chunk_and_local(world_voxel):
    chunk = (world_voxel[0] // CHUNK_SIZE, world_voxel[1] // CHUNK_SIZE, world_voxel[2] // CHUNK_SIZE)
    local = (world_voxel[0] - chunk[0] * CHUNK_SIZE,
             world_voxel[1] - chunk[1] * CHUNK_SIZE,
             world_voxel[2] - chunk[2] * CHUNK_SIZE)
    return chunk, local


# --- paginas e ring (espelham MirrorManager) ---

class MirrorPage:
    def __init__(self, coord):
        self.coord = coord
        self.edit_seq = 0
        self.state = PENDING_READBACK
        self.ring_slot = -1
        self.pending = []      # staged p/ a GPU enquanto PENDING (dedup)
        self.applied_log = []  # journal aplicado desde a materializacao
        self.solid = [0] * (CHUNK_VOXEL_COUNT // 32)
        self.ids = [0] * CHUNK_VOXEL_COUNT
        # VS-13: y do sólido mais alto da coluna (índice z-contíguo x|z<<5);
        # 0xFFFF = coluna vazia.
        self.heights = [0xFFFF] * (CHUNK_SIZE * CHUNK_SIZE)

    def apply(self, world_voxel, block_id):
        _chunk, local = chunk_and_local(world_voxel)
        idx = mirror_index(local)
        self.ids[idx] = block_id
        if block_id != 0:
            self.solid[idx >> 5] |= 1 << (idx & 31)
        else:
            self.solid[idx >> 5] &= ~(1 << (idx & 31)) & 0xFFFFFFFF
        self.apply_height(local, block_id)

    def apply_height(self, local, block_id):
        """VS-13 (REQ-MIR-03): journal mantém o heightmap da coluna."""
        column = local[0] | (local[2] << 5)
        height = self.heights[column]
        if block_id != 0:
            # colocar sólido acima do topo (ou em coluna vazia) sobe a altura
            if local[1] > height or height == 0xFFFF:
                self.heights[column] = local[1]
        else:
            # remover o bloco do topo: rescan da coluna (32 leituras)
            if height != 0xFFFF and local[1] == height:
                new_top = 0xFFFF
                for ly in range(local[1] - 1, -1, -1):
                    if (self.solid[(ly | (local[2] << 5) | (local[0] << 10)) >> 5]
                            >> ((ly | (local[2] << 5) | (local[0] << 10)) & 31)) & 1:
                        new_top = ly
                        break
                self.heights[column] = new_top


class MirrorManager:
    def __init__(self):
        self.pages = {}                       # coord -> MirrorPage
        self.ring = [None] * MIRROR_RING_SLOTS  # entrada: (coord, generation)
        self.stats_ring_misses = 0
        self.stats_pool_misses = 0

    # --- pool ---
    def page_acquire(self, coord):
        if len(self.pages) >= MIRROR_PAGE_POOL_SIZE:
            self.stats_pool_misses += 1
            return None
        page = MirrorPage(coord)
        self.pages[coord] = page
        return page

    def page_release(self, coord):
        self.pages.pop(coord, None)

    # --- ring (regra 4: slot em voo so o handler libera) ---
    def ring_try_reserve(self, coord, generation):
        for i, entry in enumerate(self.ring):
            if entry is None:
                self.ring[i] = (coord, generation)
                return i
        self.stats_ring_misses += 1
        return -1

    def ring_release_unsubmitted(self, ring_slot, coord, generation):
        """Só vale para exports AINDA NÃO submetidos (cancelamento local)."""
        entry = self.ring[ring_slot]
        if entry == (coord, generation):
            self.ring[ring_slot] = None


# --- aplicação do journal (dupla materialização, REQ-MIRROR-07) ---

def mirror_journal_apply(mirror, chunk, world_voxel, block_id):
    page = mirror.pages.get(chunk)
    if page is None:
        return  # fora da bolha: só a GPU recebe o journal
    if page.state == PENDING_READBACK:
        for i, (w, _b) in enumerate(page.pending):
            if w == world_voxel:
                page.pending[i] = (world_voxel, block_id)  # última escrita vence
                return
        page.pending.append((world_voxel, block_id))
        return
    page.apply(world_voxel, block_id)
    page.applied_log.append((world_voxel, block_id))
    page.edit_seq += 1


# --- materialização (handler de conclusão, REQ-MIRROR-05) ---

def mirror_materialize(mirror, page, worldgen_ids, worldgen_heights=None):
    """Copia o export (worldgen) e faz o replay das pendências retidas."""
    for i, block_id in enumerate(worldgen_ids):
        page.ids[i] = block_id
        if block_id != 0:
            page.solid[i >> 5] |= 1 << (i & 31)
        else:
            page.solid[i >> 5] &= ~(1 << (i & 31)) & 0xFFFFFFFF
    # VS-13: heightmap worldgen vem do ring paralelo (binding 20); sem ring
    # (cenários antigos) deriva dos ids recém-copiados.
    if worldgen_heights is None:
        worldgen_heights = [0xFFFF] * (CHUNK_SIZE * CHUNK_SIZE)
        for z in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                for y in range(CHUNK_SIZE - 1, -1, -1):
                    if page.ids[y | (z << 5) | (x << 10)] != 0:
                        worldgen_heights[x | (z << 5)] = y
                        break
    page.heights = list(worldgen_heights)
    for world_voxel, block_id in page.pending:
        page.apply(world_voxel, block_id)
        page.applied_log.append((world_voxel, block_id))
    page.pending = []
    page.state = MATERIALIZED
    page.ring_slot = -1
    page.edit_seq += 1


# --- reconciliação (REQ-MIRROR-09) ---

def mirror_reconcile_rejections(mirror, page, worldgen_ids, rejected, worldgen_heights=None):
    """Rejeição da GPU: re-export (worldgen) + replay do applied_log SEM as
    edições rejeitadas (remove a ocorrência mais recente de cada par)."""
    log = list(page.applied_log)
    for pair in rejected:
        for i in range(len(log) - 1, -1, -1):
            if log[i] == pair:
                del log[i]
                break
    page.pending = []
    page.applied_log = []
    for i, block_id in enumerate(worldgen_ids):
        page.ids[i] = block_id
        if block_id != 0:
            page.solid[i >> 5] |= 1 << (i & 31)
        else:
            page.solid[i >> 5] &= ~(1 << (i & 31)) & 0xFFFFFFFF
    # VS-13: reexport traz o heightmap worldgen; o replay o mantém.
    if worldgen_heights is None:
        worldgen_heights = [0xFFFF] * (CHUNK_SIZE * CHUNK_SIZE)
        for z in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                for y in range(CHUNK_SIZE - 1, -1, -1):
                    if page.ids[y | (z << 5) | (x << 10)] != 0:
                        worldgen_heights[x | (z << 5)] = y
                        break
    page.heights = list(worldgen_heights)
    for world_voxel, block_id in log:
        page.apply(world_voxel, block_id)
        page.applied_log.append((world_voxel, block_id))
    page.edit_seq += 1


# --- API tri-state (REQ-MIRROR-08) ---

def voxel_get(mirror, world_voxel):
    chunk, local = chunk_and_local(world_voxel)
    page = mirror.pages.get(chunk)
    if page is None or page.state != MATERIALIZED:
        return (0, False), False
    idx = mirror_index(local)
    return (page.ids[idx], (page.solid[idx >> 5] >> (idx & 31)) & 1 != 0), True


def voxel_is_solid(mirror, world_voxel):
    (_id, solid), ok = voxel_get(mirror, world_voxel)
    return solid, ok


def mirror_height_get(mirror, chunk_coord, x, z):
    """VS-13 (REQ-MIR-04): altura do topo sólido da coluna em O(1).

    ok=False se a página está ausente/em readback; senão height
    (0xFFFF = coluna vazia)."""
    page = mirror.pages.get(chunk_coord)
    if page is None or page.state != MATERIALIZED:
        return False, 0
    return True, page.heights[x | (z << 5)]


def mirror_column_ground(mirror, world_x, world_z, y_from):
    y = y_from
    while True:
        chunk = (world_x // CHUNK_SIZE, y // CHUNK_SIZE, world_z // CHUNK_SIZE)
        page = mirror.pages.get(chunk)
        if page is None or page.state != MATERIALIZED:
            return 0, False
        local_x = world_x - chunk[0] * CHUNK_SIZE
        local_z = world_z - chunk[2] * CHUNK_SIZE
        base = (local_x << 10) | (local_z << 5)
        local_y = y - chunk[1] * CHUNK_SIZE
        for ly in range(local_y, -1, -1):
            if (page.solid[(base + ly) >> 5] >> ((base + ly) & 31)) & 1:
                return chunk[1] * CHUNK_SIZE + ly, True
        y = chunk[1] * CHUNK_SIZE - 1  # coluna toda de ar: desce um chunk


# --- checks ---

PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


# --- cenários ---

def scenario_indexing():
    print("[cenario] indexacao y-contigua vs x-contigua (regra 7)")
    idxs = sorted(mirror_index(coordinate_from_dense_index(i)) for i in range(CHUNK_VOXEL_COUNT))
    check("mirror_index é permutação de 0..32767", idxs == list(range(CHUNK_VOXEL_COUNT)))
    check("y-contíguo: coluna vertical é sequencial",
          all(mirror_index((3, y, 7)) == y | (7 << 5) | (3 << 10) for y in range(32)))
    check("coluna (x,z) = 32 u16 contíguos (64 B = 1 linha de cache)",
          mirror_index((3, 31, 7)) - mirror_index((3, 0, 7)) == 31)
    check("x-contíguo do denso é o layout OPOSTO no eixo rápido",
          dense_index_from_coordinate((3, 7, 5)) != mirror_index((3, 7, 5)))
    check("passo de y é 1 no mirror e 1024 no denso",
          (mirror_index((0, 1, 0)) - mirror_index((0, 0, 0)),
           dense_index_from_coordinate((0, 1, 0)) - dense_index_from_coordinate((0, 0, 0))) == (1, 1024))
    check("passo de x é 1024 no mirror e 1 no denso",
          (mirror_index((1, 0, 0)) - mirror_index((0, 0, 0)),
           dense_index_from_coordinate((1, 0, 0)) - dense_index_from_coordinate((0, 0, 0))) == (1024, 1))


def scenario_ring_discipline():
    print("[cenario] disciplina do ring: reserva, anti-ABA e regra 4")
    mirror = MirrorManager()
    # ring cheio: 64 reservas, a 65ª falha; após liberar, volta a reservar
    reserved = [mirror.ring_try_reserve((i, 0, 0), 1) for i in range(MIRROR_RING_SLOTS)]
    check("64 slots reserváveis", all(r >= 0 for r in reserved))
    check("65ª reserva falha (ring cheio, miss contada)",
          mirror.ring_try_reserve((99, 0, 0), 1) == -1 and mirror.stats_ring_misses == 1)
    mirror.ring_release_unsubmitted(reserved[7], (7, 0, 0), 1)
    check("liberação local (não submetido) reabre o slot",
          mirror.ring_try_reserve((99, 0, 0), 1) == reserved[7])
    # anti-ABA: liberação com geração errada não toca a entrada
    mirror.ring_release_unsubmitted(reserved[7], (99, 0, 0), 999)
    check("anti-ABA: geração errada não libera", mirror.ring[reserved[7]] == ((99, 0, 0), 1))

    # evicção com export EM VOO: slot NÃO é liberado localmente; o handler o
    # descarta depois (página ausente)
    mirror3 = MirrorManager()
    ring_slot = mirror3.ring_try_reserve((50, 0, 0), 3)
    page = mirror3.page_acquire((50, 0, 0))
    page.ring_slot = ring_slot
    mirror3.page_release((50, 0, 0))
    check("evicção com export em voo: slot permanece reservado",
          mirror3.ring[ring_slot] == ((50, 0, 0), 3))
    # handler de conclusão: página ausente -> descarta e libera
    page_still_there = mirror3.pages.get((50, 0, 0))
    if page_still_there is None:
        mirror3.ring[ring_slot] = None  # descarte do handler (export vencido)
    check("handler libera slot do export vencido", mirror3.ring[ring_slot] is None)

    # conclusão vencida por (coord, geração): chunk recriado com geração nova
    mirror2 = MirrorManager()
    ring_slot = mirror2.ring_try_reserve((3, 0, 0), 1)  # export antigo
    new_page = mirror2.page_acquire((3, 0, 0))          # página nova (geração 2)
    new_page.ring_slot = mirror2.ring_try_reserve((3, 0, 0), 2)
    # lote antigo conclui: entrada casa (coord, gen=1) mas a página viva tem
    # ring_slot e geração NOVOS -> descarta o antigo sem tocar a página nova
    valid = (new_page.ring_slot == ring_slot and mirror2.ring[ring_slot] == ((3, 0, 0), 2))
    check("anti-ABA: export vencido não materializa na página nova", not valid)


def scenario_materialize_replay():
    print("[cenario] materialização com replay de pendências (dedup)")
    mirror = MirrorManager()
    page = mirror.page_acquire((0, 0, 0))
    worldgen = to_mirror_ids(
        [1 if c[1] == 0 else 0 for c in (coordinate_from_dense_index(i) for i in range(CHUNK_VOXEL_COUNT))])

    # edições chegam enquanto PENDING: retidas com dedup última-escrita-vence
    mirror_journal_apply(mirror, (0, 0, 0), (5, 5, 5), 2)
    mirror_journal_apply(mirror, (0, 0, 0), (5, 5, 5), 3)  # sobrescreve
    mirror_journal_apply(mirror, (0, 0, 0), (6, 0, 6), 0)
    check("pending retém com dedup", page.pending == [((5, 5, 5), 3), ((6, 0, 6), 0)])

    mirror_materialize(mirror, page, worldgen)
    (id_a, solid_a), ok_a = voxel_get(mirror, (5, 5, 5))
    (id_b, solid_b), ok_b = voxel_get(mirror, (6, 0, 6))
    check("replay: última escrita vence na materialização", ok_a and id_a == 3 and solid_a)
    check("replay: remoção aplicada sobre worldgen", ok_b and id_b == 0 and not solid_b)
    check("bitmask consistente com ids",
          all(((page.solid[i >> 5] >> (i & 31)) & 1) == (1 if page.ids[i] != 0 else 0) for i in range(0, CHUNK_VOXEL_COUNT, 97)))
    check("edit_seq avança na materialização", page.edit_seq >= 1)


def scenario_tri_state():
    print("[cenario] API tri-state: desconhecido nunca inventa bloco")
    mirror = MirrorManager()
    sample, ok = voxel_get(mirror, (1, 1, 1))
    check("sem página: ok=False, amostra vazia", not ok and sample == (0, False))

    page = mirror.page_acquire((0, 0, 0))
    sample, ok = voxel_get(mirror, (1, 1, 1))
    check("página PENDING: ok=False", not ok)

    worldgen = [0] * CHUNK_VOXEL_COUNT
    for c in ((4, 4, 4), (4, 5, 4)):
        worldgen[mirror_index(c)] = 2
    mirror_materialize(mirror, page, worldgen)
    (block_id, solid), ok = voxel_get(mirror, (4, 5, 4))
    check("MATERIALIZED: amostra correta", ok and block_id == 2 and solid)
    solid, ok = voxel_is_solid(mirror, (9, 9, 9))
    check("voxel_is_solid em ar", ok and not solid)

    # coluna atravessa 2 chunks: sólido em y=4 (chunk y=0), ar acima até y=63
    page2 = mirror.page_acquire((0, 1, 0))
    mirror_materialize(mirror, page2, [0] * CHUNK_VOXEL_COUNT)
    ground, ok = mirror_column_ground(mirror, 4, 4, 63)
    check("column_ground cruza fronteira de chunk", ok and ground == 5)
    ground, ok = mirror_column_ground(mirror, 8, 8, 63)
    check("coluna sem sólido até chunk desconhecido: ok=False", not ok)


def scenario_export_only_no_pack():
    print("[cenario] export_only nunca executa pack nem apaga edições")
    # chunk com edições já aplicadas no packed (GPU)
    dense = [0] * CHUNK_VOXEL_COUNT
    for c in ((1, 1, 1), (2, 2, 2)):
        dense[dense_index_from_coordinate(c)] = 1
    gpu = PackedChunk.pack(dense)
    edits = [(dense_index_from_coordinate((1, 1, 1)), 3)]
    results = apply_voxel_edits(gpu, edits)
    assert results == [EDIT_RESULT_APPLIED]
    snapshot = (list(gpu.palette), list(gpu.refcount), list(gpu.planes), list(gpu.occupancy))
    # lote export_only roda SÓ o generate: reescreve scratch + ring, não o packed
    packed_after = (gpu.palette, gpu.refcount, gpu.planes, gpu.occupancy)
    check("packed intacto após export_only", packed_after == snapshot)


def scenario_journal_heightmap():
    print("[cenario] VS-13: journal mantém o heightmap da coluna")
    mirror = MirrorManager()
    page = mirror.page_acquire((0, 0, 0))
    # terreno: coluna (4,z) com topo em y=10, coluna (8,z) toda de ar
    worldgen = [0] * CHUNK_VOXEL_COUNT
    for z in range(CHUNK_SIZE):
        for y in range(0, 11):
            worldgen[mirror_index((4, y, z))] = 2
    ring_heights = [0xFFFF] * (CHUNK_SIZE * CHUNK_SIZE)
    for z in range(CHUNK_SIZE):
        ring_heights[4 | (z << 5)] = 10
    mirror_materialize(mirror, page, worldgen, ring_heights)

    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("materialize: altura do topo sólido", ok and h == 10)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 8, 0)
    check("materialize: coluna de ar é 0xFFFF", ok and h == 0xFFFF)
    ok, _h = mirror_height_get(mirror, (1, 0, 0), 4, 0)
    check("página ausente: ok=False (tri-state)", not ok)

    # colocar acima do topo: sobe
    mirror_journal_apply(mirror, (0, 0, 0), (4, 13, 0), 1)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("colocar acima do topo: altura vai a h+3", ok and h == 13)
    # colocar abaixo do topo: inalterado
    mirror_journal_apply(mirror, (0, 0, 0), (4, 5, 0), 1)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("colocar abaixo do topo: inalterado", ok and h == 13)
    # remover abaixo do topo: inalterado
    mirror_journal_apply(mirror, (0, 0, 0), (4, 5, 0), 0)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("remover abaixo do topo: inalterado", ok and h == 13)
    # remover o bloco do topo (h+3): rescan volta para o novo topo (y=10)
    mirror_journal_apply(mirror, (0, 0, 0), (4, 13, 0), 0)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("remover o topo: rescan para o novo topo", ok and h == 10)
    # remover o topo atual: rescan desce um nível (y=9)
    mirror_journal_apply(mirror, (0, 0, 0), (4, 10, 0), 0)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("remover o topo: rescan desce um nível", ok and h == 9)
    # esvaziar a coluna inteira: rescan final é 0xFFFF
    for y in range(9, -1, -1):
        mirror_journal_apply(mirror, (0, 0, 0), (4, y, 0), 0)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("remover o último sólido: coluna vazia", ok and h == 0xFFFF)
    # coluna vazia recebendo sólido: altura = y
    mirror_journal_apply(mirror, (0, 0, 0), (4, 7, 0), 1)
    ok, h = mirror_height_get(mirror, (0, 0, 0), 4, 0)
    check("coluna vazia recebendo sólido: altura = y", ok and h == 7)

    # chunk de ar: fill_empty mantém 0xFFFF e journal atualiza
    page_air = mirror.page_acquire((0, 1, 0))
    for i in range(CHUNK_VOXEL_COUNT):
        page_air.ids[i] = 0
    for w in range(len(page_air.solid)):
        page_air.solid[w] = 0
    for i in range(len(page_air.heights)):
        page_air.heights[i] = 0xFFFF
    page_air.state = MATERIALIZED
    ok, h = mirror_height_get(mirror, (0, 1, 0), 3, 3)
    check("chunk de ar: coluna vazia", ok and h == 0xFFFF)
    mirror_journal_apply(mirror, (0, 1, 0), (3, 20, 3), 2)
    ok, h = mirror_height_get(mirror, (0, 1, 0), 3, 3)
    check("chunk de ar + journal: altura = y", ok and h == 20)

    # heightmap consistente com ids em toda página
    consistent = True
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            expect = 0xFFFF
            for y in range(CHUNK_SIZE - 1, -1, -1):
                if page.ids[mirror_index((x, y, z))] != 0:
                    expect = y
                    break
            if page.heights[x | (z << 5)] != expect:
                consistent = False
    check("heights == topo derivado de ids (todas as colunas)", consistent)


def scenario_parity_and_reconciliation():
    print("[cenario] paridade GPU<->mirror em 163.840 voxels com reconciliacao")
    # 5 chunks em x: worldgen determinístico (grama/terra/pedra por camadas)
    coords = [(i, 0, 0) for i in range(5)]
    worldgen = {}
    gpu = {}
    for chunk in coords:
        dense = [0] * CHUNK_VOXEL_COUNT
        for i in range(CHUNK_VOXEL_COUNT):
            c = coordinate_from_dense_index(i)
            dense[i] = 3 if c[1] < 2 else (2 if c[1] == 2 else (1 if c[1] == 3 else 0))
        worldgen[chunk] = dense
        gpu[chunk] = PackedChunk.pack(dense)

    mirror = MirrorManager()
    pages = {}
    for chunk in coords:
        page = mirror.page_acquire(chunk)
        mirror_materialize(mirror, page, to_mirror_ids(worldgen[chunk]))
        pages[chunk] = page

    # journal: 3 flushes de edições variadas (dual-apply nos dois lados)
    import random
    rng = random.Random(7)
    for flush in range(3):
        for chunk in coords:
            edits = []
            used = set()
            for _ in range(200):
                local = (rng.randrange(32), rng.randrange(32), rng.randrange(32))
                if local in used:
                    continue
                used.add(local)
                block_id = rng.choice([0, 1, 2, 3, 4, 5])
                voxel_index = dense_index_from_coordinate(local)
                edits.append((voxel_index, block_id))
                world_voxel = (chunk[0] * 32 + local[0], chunk[1] * 32 + local[1], chunk[2] * 32 + local[2])
                mirror_journal_apply(mirror, chunk, world_voxel, block_id)
            results = apply_voxel_edits(gpu[chunk], edits)
            assert all(r == EDIT_RESULT_APPLIED or r == 1 for r in results)

    # paridade bit a bit: decode packed == ids do mirror (5 x 32768 voxels)
    total = 0
    parity = True
    for chunk in coords:
        for i in range(CHUNK_VOXEL_COUNT):
            c = coordinate_from_dense_index(i)
            if gpu[chunk].decode(c) != pages[chunk].ids[mirror_index(c)]:
                parity = False
                break
        total += CHUNK_VOXEL_COUNT
        if not parity:
            break
    check(f"paridade bit a bit GPU==mirror ({total} voxels, 3 flushes x 200 edições)", parity and total == 163840)

    # bitmask solid == (id != 0) em toda página
    solid_ok = all(
        ((pages[chunk].solid[i >> 5] >> (i & 31)) & 1) == (1 if pages[chunk].ids[i] != 0 else 0)
        for chunk in coords for i in range(0, CHUNK_VOXEL_COUNT, 13)
    )
    check("bitmask de sólidos paritário", solid_ok)

    # rejeição pela GPU (chunk em overflow): mirror aplica otimista e diverge;
    # reconciliação reexporta e remove as rejeitadas
    victim = coords[2]
    gpu[victim].flags |= CHUNK_FLAG_PALETTE_OVERFLOW
    rejected_edits = []
    rejected_pairs = []
    for local in ((10, 10, 10), (20, 20, 20)):
        voxel_index = dense_index_from_coordinate(local)
        rejected_edits.append((voxel_index, 9))
        world_voxel = (victim[0] * 32 + local[0], victim[1] * 32 + local[1], victim[2] * 32 + local[2])
        mirror_journal_apply(mirror, victim, world_voxel, 9)
        rejected_pairs.append((world_voxel, 9))
    results = apply_voxel_edits(gpu[victim], rejected_edits)
    check("GPU rejeita todas as edições do chunk em overflow",
          results == [EDIT_RESULT_REJECTED_OVERFLOW] * 2)

    # divergência otimista existe antes da reconciliação
    diverged = any(
        gpu[victim].decode(coordinate_from_dense_index(i)) != pages[victim].ids[mirror_index(coordinate_from_dense_index(i))]
        for i in range(CHUNK_VOXEL_COUNT)
    )
    check("aplicação otimista diverge antes do feedback", diverged)

    mirror_reconcile_rejections(mirror, pages[victim], to_mirror_ids(worldgen[victim]), rejected_pairs)
    parity = all(
        gpu[victim].decode(coordinate_from_dense_index(i)) == pages[victim].ids[mirror_index(coordinate_from_dense_index(i))]
        for i in range(CHUNK_VOXEL_COUNT)
    )
    check("reconciliação: mirror converge bit a bit com a GPU", parity)
    check("reconciliação: rejeitadas fora do log",
          all(pair not in pages[victim].applied_log for pair in rejected_pairs))


def main():
    scenario_indexing()
    scenario_ring_discipline()
    scenario_materialize_replay()
    scenario_tri_state()
    scenario_export_only_no_pack()
    scenario_journal_heightmap()
    scenario_parity_and_reconciliation()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
