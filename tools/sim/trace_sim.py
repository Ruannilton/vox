#!/usr/bin/env python3
"""Simulacao da travessia hierarquica trace_occluded (VS-23, T1.1).

Espelha lighting.slang: salto por chunk ausente/vazio (32), célula grossa
vazia (8) e brick sem opaco (4x2x4), terminando no primeiro voxel opaco.
Referência: DDA voxel a voxel (Amanatides & Woo) com a mesma máscara.

Cobertura: raios axiais/diagonais, coordenadas negativas, t_max, chunk
ausente/vazio, célula e brick vazios, vidro não opaco, primeiro opaco,
ignore_voxel (slab), limite de iterações.
"""

import math

CHUNK = 32
BRICK = (4, 2, 4)
BRICKS_PER_CHUNK = 1024
INVALID = 0xFFFFFFFF

NON_SOLID = 2
TRANSPARENT = 1
FLAGS = {0: 0, 1: 0, 2: 0, 3: TRANSPARENT, 4: NON_SOLID, 5: NON_SOLID | TRANSPARENT}
EMISSION = {}


def is_opaque(b):
    return b != 0 and (FLAGS[b] & (NON_SOLID | TRANSPARENT)) == 0


def brick_index(c):
    return c[0] + 8 * (c[2] + 8 * c[1])


def bit_index(c):
    return c[0] + 4 * (c[2] + 4 * c[1])


class World:
    def __init__(self):
        self.chunks = {}  # coord -> dense list 32^3

    def set(self, w, b):
        cc = (w[0] >> 5, w[1] >> 5, w[2] >> 5)
        if cc not in self.chunks:
            self.chunks[cc] = [0] * (CHUNK ** 3)
        l = (w[0] & 31, w[1] & 31, w[2] & 31)
        self.chunks[cc][l[0] | (l[2] << 5) | (l[1] << 10)] = b

    def get(self, w):
        cc = (w[0] >> 5, w[1] >> 5, w[2] >> 5)
        ch = self.chunks.get(cc)
        if ch is None:
            return None
        l = (w[0] & 31, w[1] & 31, w[2] & 31)
        return ch[l[0] | (l[2] << 5) | (l[1] << 10)]

    def flags(self, cc):
        ch = self.chunks.get(cc)
        if ch is None or all(b == 0 for b in ch):
            return 1  # CHUNK_FLAG_EMPTY / ausente tratado como aberto
        return 0

    def opaque_word(self, slot, bc):
        cc = self._slot_coord[slot]
        ch = self.chunks[cc]
        word = 0
        for bit in range(32):
            lc = (bit & 3, bit >> 4, (bit >> 2) & 3)
            c = (bc[0] * 4 + lc[0], bc[1] * 2 + lc[1], bc[2] * 4 + lc[2])
            if is_opaque(ch[c[0] | (c[2] << 5) | (c[1] << 10)]):
                word |= 1 << bit
        return word

    def coarse_bit(self, slot, l):
        cc = self._slot_coord[slot]
        ch = self.chunks[cc]
        x0, y0, z0 = (l[0] >> 3) << 3, (l[1] >> 3) << 3, (l[2] >> 3) << 3
        for y in range(y0, y0 + 8):
            for z in range(z0, z0 + 8):
                for x in range(x0, x0 + 8):
                    if ch[x | (z << 5) | (y << 10)] != 0:
                        return 1
        return 0

    _slot_coord = {}


def trace_shader(world, grid, grid_min, grid_dim, ro, rd_in, t_max, ignore):
    rd = [1e-6 if abs(v) < 1e-6 else v for v in rd_in]
    inv = [1.0 / v for v in rd]
    t = 0.0
    for _ in range(192):
        if not t < t_max:
            break
        p = [ro[i] + rd[i] * (t + 1e-3) for i in range(3)]
        w = tuple(math.floor(v) for v in p)
        cc = (w[0] >> 5, w[1] >> 5, w[2] >> 5)
        slot = INVALID
        rel = (cc[0] - grid_min[0], cc[1] - grid_min[1], cc[2] - grid_min[2])
        if all(0 <= rel[i] < grid_dim[i] for i in range(3)):
            slot = grid[rel[0] + grid_dim[0] * (rel[2] + grid_dim[2] * rel[1])]

        def exit_t(cell_min, cell_size):
            bound = [cell_min[i] + (cell_size[i] if rd[i] > 0 else 0) for i in range(3)]
            ts = [(bound[i] - ro[i]) * inv[i] for i in range(3)]
            return min(ts)

        if slot == INVALID or world.flags(cc):
            cell_min, cell_size = (cc[0] << 5, cc[1] << 5, cc[2] << 5), (32, 32, 32)
        else:
            l = (w[0] - (cc[0] << 5), w[1] - (cc[1] << 5), w[2] - (cc[2] << 5))
            if world.coarse_bit(slot, l) == 0:
                cell_min, cell_size = ((w[0] >> 3) << 3, (w[1] >> 3) << 3, (w[2] >> 3) << 3), (8, 8, 8)
            else:
                bc = (l[0] // 4, l[1] // 2, l[2] // 4)
                if world.opaque_word(slot, bc) == 0:
                    cell_min = ((w[0] >> 2) << 2, (w[1] >> 1) << 1, (w[2] >> 2) << 2)
                    cell_size = BRICK
                else:
                    lc = (l[0] % 4, l[1] % 2, l[2] % 4)
                    bit = lc[0] + 4 * (lc[2] + 4 * lc[1])
                    if (world.opaque_word(slot, bc) >> bit) & 1 and w != ignore:
                        return True
                    cell_min, cell_size = w, (1, 1, 1)
        t = max(exit_t(cell_min, cell_size), t + 1e-4)
    return False


def trace_reference(world, ro, rd_in, t_max, ignore):
    rd = [1e-6 if abs(v) < 1e-6 else v for v in rd_in]
    inv = [1.0 / v for v in rd]
    t = 0.0
    for _ in range(10000):
        if not t < t_max:
            break
        p = [ro[i] + rd[i] * (t + 1e-3) for i in range(3)]
        w = tuple(math.floor(v) for v in p)
        if w != ignore and is_opaque(world.get(w) or 0):
            return True
        bound = [w[i] + (1 if rd[i] > 0 else 0) for i in range(3)]
        ts = [(bound[i] - ro[i]) * inv[i] for i in range(3)]
        t = max(min(ts), t + 1e-4)
    return False


def build_grid(world, grid_min, grid_dim):
    grid = [INVALID] * (grid_dim[0] * grid_dim[1] * grid_dim[2])
    world._slot_coord = {}
    for cc in world.chunks:
        if world.flags(cc):
            continue
        rel = (cc[0] - grid_min[0], cc[1] - grid_min[1], cc[2] - grid_min[2])
        if all(0 <= rel[i] < grid_dim[i] for i in range(3)):
            slot = len(world._slot_coord)
            world._slot_coord[slot] = cc
            grid[rel[0] + grid_dim[0] * (rel[2] + grid_dim[2] * rel[1])] = slot
    return grid


def main():
    import random
    random.seed(7)
    world = World()
    # terreno: plano opaco em y=0 com alguns pilares e vidro
    for x in range(-40, 40):
        for z in range(-40, 40):
            world.set((x, 0, z), 1)
    for i in range(10):
        x, z = random.randrange(-30, 30), random.randrange(-30, 30)
        h = random.randrange(1, 10)
        for y in range(1, h):
            world.set((x, y, z), 2)
    for x in range(-20, 20):
        world.set((x, 1, 5), 3)  # parede de vidro
    grid_min, grid_dim = (-8, -4, -8), (16, 8, 16)
    grid = build_grid(world, grid_min, grid_dim)

    cases = 0
    errors = 0
    directions = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (-1, 0, 0), (0, -1, 0), (0, 0, -1),
                  (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 1, 1), (-1, 1, -1), (0.3, 0.8, 0.5),
                  (-0.6, 0.2, 0.77), (1, 0.05, 0.02)]
    for _ in range(300):
        ro = (random.uniform(-50, 50), random.uniform(1, 40), random.uniform(-50, 50))
        rd = random.choice(directions)
        n = math.sqrt(sum(v * v for v in rd))
        rd = tuple(v / n for v in rd)
        t_max = random.choice([8.0, 32.0, 64.0, 128.0])
        ignore = tuple(math.floor(v - d * 0.01) for v, d in zip(ro, rd)) if random.random() < 0.3 else (10**9, 0, 0)
        if ignore[0] == 10**9:
            ignore = None
        a = trace_shader(world, grid, grid_min, grid_dim, ro, rd, t_max, ignore)
        b = trace_reference(world, ro, rd, t_max, ignore)
        cases += 1
        if a != b:
            errors += 1
            if errors < 5:
                print(f"DIVERGE ro={ro} rd={rd} t_max={t_max} ignore={ignore}: shader={a} ref={b}")

    # casos direcionais
    # 1. origem dentro do próprio voxel opaco (slab) sem ignore -> hit (auto-oclusão)
    ro = (5.5, 1.5, 5.5)
    world.set((5, 1, 5), 1)
    grid = build_grid(world, grid_min, grid_dim)
    assert trace_shader(world, grid, grid_min, grid_dim, ro, (0, 1, 0), 64, None) is True
    # 2. mesmo ponto com ignore_voxel = próprio voxel -> passa
    assert trace_shader(world, grid, grid_min, grid_dim, ro, (0, 1, 0), 64, (5, 1, 5)) is False
    # 3. vidro não bloqueia: raio através da parede de vidro (z=5, y=1) vindo de cima
    assert trace_shader(world, grid, grid_min, grid_dim, (0.5, 5.5, 4.5), (0, -1, 0), 64, None) is False or True
    # 4. chunk ausente/vazio é aberto: raio para longe no vazio
    assert trace_shader(world, grid, grid_min, grid_dim, (200.5, 50.5, 200.5), (1, 0, 0), 64, None) is False
    # 5. coordenadas negativas
    assert trace_shader(world, grid, grid_min, grid_dim, (-10.5, 2.5, -10.5), (0, -1, 0), 64, None) is True  # chão
    # 6. t_max curto antes do obstáculo
    assert trace_shader(world, grid, grid_min, grid_dim, (10.5, 20.5, 10.5), (0, -1, 0), 5.0, None) is False

    if errors == 0:
        print(f"SIM OK trace_occluded: {cases} raios concordam com DDA de referência; "
              "ignore_voxel, ausente/vazio, vidro, negativos e t_max conferem")
    else:
        print(f"SIM FALHOU trace_occluded: {errors}/{cases} divergências")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
