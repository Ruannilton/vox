#!/usr/bin/env python3
"""Simulacao da mascara de opacidade por brick (VS-23, T0.1).

Espelha src/assets/shaders/common.slang (OPAQUE_WORD_BASE, layout do pool),
pack_chunk (voxel.slang) e apply_voxel_edits (edit.slang).

Regras verificadas:
  opaco = id != 0 e sem BLOCK_DEFINITION_FLAG_NON_SOLID nem _TRANSPARENT
  (ar, planta/NON_SOLID e vidro/TRANSPARENT nao sao opacos).
  pack acumula 'opacity' e grava occupancy_pool[base + OPAQUE_WORD_BASE + brick].
  edicao atualiza o bit com InterlockedOr/InterlockedAnd (simulado em Python).
  OPAQUE_WORD_BASE = 2114, OCCUPANCY_WORDS_PER_CHUNK = 3138.
"""

CHUNK_SIZE = 32
BRICK_SIZE = (4, 2, 4)
BRICKS_PER_CHUNK = 1024
VOXELS_PER_BRICK = 32
COARSE_WORDS_PER_CHUNK = 2
SUBDIVISION_WORDS_PER_CHUNK = 64
SOLID_WORD_BASE = BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK  # 1090
OPAQUE_WORD_BASE = SOLID_WORD_BASE + BRICKS_PER_CHUNK  # 2114
OCCUPANCY_WORDS_PER_CHUNK = 3 * BRICKS_PER_CHUNK + COARSE_WORDS_PER_CHUNK + SUBDIVISION_WORDS_PER_CHUNK  # 3138

BLOCK_DEFINITION_FLAG_TRANSPARENT = 1
BLOCK_DEFINITION_FLAG_NON_SOLID = 2

# registry simulado: id -> flags
FLAGS = {
    0: 0,                         # ar
    1: 0,                         # pedra/terra: opaco
    2: 0,                         # madeira: opaco
    3: BLOCK_DEFINITION_FLAG_TRANSPARENT,  # vidro: nao opaco
    4: BLOCK_DEFINITION_FLAG_NON_SOLID,    # planta: nao opaca
    5: BLOCK_DEFINITION_FLAG_TRANSPARENT | BLOCK_DEFINITION_FLAG_NON_SOLID,  # folhagem
}


def block_is_opaque(block_id):
    return block_id != 0 and (FLAGS[block_id] & (BLOCK_DEFINITION_FLAG_NON_SOLID | BLOCK_DEFINITION_FLAG_TRANSPARENT)) == 0


def brick_index_from_coordinate(c):
    return c[0] + 8 * (c[2] + 8 * c[1])


def bit_index_from_local_coordinate(c):
    return c[0] + 4 * (c[2] + 4 * c[1])


def local_coordinate_from_bit_index(i):
    return (i & 3, i >> 4, (i >> 2) & 3)


def brick_coordinate_from_index(i):
    return (i & 7, i >> 6, (i >> 3) & 7)


class ChunkPool:
    """Uma fatia do occupancy_pool para um slot (3138 words)."""

    def __init__(self):
        self.words = [0] * OCCUPANCY_WORDS_PER_CHUNK

    def pack(self, dense):
        """Espelha pack_chunk: acumula occupancy/solidity/opacity por brick."""
        for b in range(BRICKS_PER_CHUNK):
            bc = brick_coordinate_from_index(b)
            occupancy = 0
            solidity = 0
            opacity = 0
            for bit in range(VOXELS_PER_BRICK):
                lc = local_coordinate_from_bit_index(bit)
                coord = (bc[0] * BRICK_SIZE[0] + lc[0],
                         bc[1] * BRICK_SIZE[1] + lc[1],
                         bc[2] * BRICK_SIZE[2] + lc[2])
                idx = coord[0] | (coord[2] << 5) | (coord[1] << 10)
                block_id = dense[idx]
                if block_id != 0:
                    occupancy |= 1 << bit
                if block_id != 0 and (FLAGS[block_id] & BLOCK_DEFINITION_FLAG_NON_SOLID) == 0:
                    solidity |= 1 << bit
                if block_is_opaque(block_id):
                    opacity |= 1 << bit
            self.words[b] = occupancy
            self.words[SOLID_WORD_BASE + b] = solidity
            self.words[OPAQUE_WORD_BASE + b] = opacity

    def apply_edit(self, coord, new_block):
        """Espelha apply_voxel_edits: InterlockedOr/And no bit de opacidade."""
        bc = (coord[0] // BRICK_SIZE[0], coord[1] // BRICK_SIZE[1], coord[2] // BRICK_SIZE[2])
        lc = (coord[0] % BRICK_SIZE[0], coord[1] % BRICK_SIZE[1], coord[2] % BRICK_SIZE[2])
        b = brick_index_from_coordinate(bc)
        bit = bit_index_from_local_coordinate(lc)
        mask = 1 << bit
        if block_is_opaque(new_block):
            self.words[OPAQUE_WORD_BASE + b] |= mask    # InterlockedOr
        else:
            self.words[OPAQUE_WORD_BASE + b] &= ~mask & 0xFFFFFFFF  # InterlockedAnd

    def opaque_at(self, coord):
        bc = (coord[0] // BRICK_SIZE[0], coord[1] // BRICK_SIZE[1], coord[2] // BRICK_SIZE[2])
        lc = (coord[0] % BRICK_SIZE[0], coord[1] % BRICK_SIZE[1], coord[2] % BRICK_SIZE[2])
        word = self.words[OPAQUE_WORD_BASE + brick_index_from_coordinate(bc)]
        return ((word >> bit_index_from_local_coordinate(lc)) & 1) != 0


def run():
    assert SOLID_WORD_BASE == 1090
    assert OPAQUE_WORD_BASE == 2114, OPAQUE_WORD_BASE
    assert OCCUPANCY_WORDS_PER_CHUNK == 3138, OCCUPANCY_WORDS_PER_CHUNK

    import random
    random.seed(23)

    dense = [0] * (CHUNK_SIZE ** 3)
    ids = list(FLAGS.keys())
    for i in range(len(dense)):
        dense[i] = random.choice(ids)

    pool = ChunkPool()
    pool.pack(dense)

    errors = 0
    for y in range(CHUNK_SIZE):
        for z in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                idx = x | (z << 5) | (y << 10)
                expected = block_is_opaque(dense[idx])
                if pool.opaque_at((x, y, z)) != expected:
                    errors += 1

    # edicoes atomicas: vidro<->pedra, ar<->planta, folhagem<->madeira
    for _ in range(2000):
        x = random.randrange(CHUNK_SIZE)
        y = random.randrange(CHUNK_SIZE)
        z = random.randrange(CHUNK_SIZE)
        new_block = random.choice(ids)
        idx = x | (z << 5) | (y << 10)
        dense[idx] = new_block
        pool.apply_edit((x, y, z), new_block)

    for y in range(CHUNK_SIZE):
        for z in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                idx = x | (z << 5) | (y << 10)
                expected = block_is_opaque(dense[idx])
                if pool.opaque_at((x, y, z)) != expected:
                    errors += 1

    # casos direcionais: vidro nunca opaco, planta nunca opaca
    pool2 = ChunkPool()
    d2 = [0] * (CHUNK_SIZE ** 3)
    d2[0] = 3  # vidro na origem
    d2[1 | (0 << 5) | (0 << 10)] = 4  # planta
    pool2.pack(d2)
    assert not pool2.opaque_at((0, 0, 0)), "vidro nao pode ser opaco"
    assert not pool2.opaque_at((1, 0, 0)), "planta nao pode ser opaca"
    pool2.apply_edit((5, 5, 5), 3)
    assert not pool2.opaque_at((5, 5, 5))
    pool2.apply_edit((5, 5, 5), 1)
    assert pool2.opaque_at((5, 5, 5))
    pool2.apply_edit((5, 5, 5), 0)
    assert not pool2.opaque_at((5, 5, 5))

    if errors == 0:
        print("SIM OK opacity: pack + 2000 edicoes atomicas conferem voxel a voxel; "
              "vidro/planta nunca opacos; layout OPAQUE_WORD_BASE=2114, OCC=3138")
    else:
        print(f"SIM FALHOU opacity: {errors} divergencias")
        raise SystemExit(1)


if __name__ == "__main__":
    run()
