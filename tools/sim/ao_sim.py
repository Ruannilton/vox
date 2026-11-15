#!/usr/bin/env python3
"""Simulacao do AO por fragmento (VS-23, T2.1).

Espelha voxel_ao/corner_ao do lighting.slang: voxel à frente da face, oito
leituras de opacidade (dois lados por eixo tangente + quatro cantos) e
interpolação bilinear por u/w. Gabarito: cálculo independente por canto
(conferência posição a posição e interpolação em centro/bordas).

Inclui: canto livre, lados, diagonal, ambos os lados, coordenadas negativas,
fronteiras de chunk, vidro transparente (não contribui) e face diagonal
(sem AO). Tolerância: igualdade exata (aritmética racional 1/3).
"""

import math
import random
from fractions import Fraction

NON_SOLID = 2
TRANSPARENT = 1
FLAGS = {0: 0, 1: 0, 2: 0, 3: TRANSPARENT, 4: NON_SOLID}


def is_opaque(b):
    return b != 0 and (FLAGS[b] & (NON_SOLID | TRANSPARENT)) == 0


class World:
    def __init__(self):
        self.vox = {}

    def set(self, w, b):
        self.vox[tuple(w)] = b

    def opaque(self, w):
        return is_opaque(self.vox.get(tuple(w), 0))


def corner_ao(s1, s2, c):
    if s1 and s2:
        return Fraction(0)
    return Fraction(3 - int(s1) - int(s2) - int(c), 3)


def voxel_ao(world, world_pos, normal):
    an = [abs(v) for v in normal]
    if max(an) < 0.99:
        return Fraction(1)
    n = tuple(int(round(v)) for v in normal)
    t1 = (0, 1, 0) if an[0] > 0.5 else (1, 0, 0)
    t2 = (1, 0, 0) if an[2] > 0.5 else (0, 0, 1)
    own = tuple(math.floor(world_pos[i] - normal[i] * 0.01) for i in range(3))
    v = tuple(own[i] + n[i] for i in range(3))
    fr = [world_pos[i] - own[i] for i in range(3)]
    u = min(max(sum(fr[i] * t1[i] for i in range(3)), 0.0), 1.0)
    w = min(max(sum(fr[i] * t2[i] for i in range(3)), 0.0), 1.0)

    def add(a, b):
        return tuple(a[i] + b[i] for i in range(3))

    def mul(a, s):
        return tuple(a[i] * s for i in range(3))

    e1 = world.opaque(add(v, t1)); e2 = world.opaque(add(v, mul(t1, -1)))
    f1 = world.opaque(add(v, t2)); f2 = world.opaque(add(v, mul(t2, -1)))
    a00 = corner_ao(e2, f2, world.opaque(add(add(v, mul(t1, -1)), mul(t2, -1))))
    a10 = corner_ao(e1, f2, world.opaque(add(add(v, t1), mul(t2, -1))))
    a01 = corner_ao(e2, f1, world.opaque(add(add(v, mul(t1, -1)), t2)))
    a11 = corner_ao(e1, f1, world.opaque(add(add(v, t1), t2)))

    def lerp(a, b, t):
        return a + (b - a) * Fraction(t).limit_denominator(10 ** 6)

    return lerp(lerp(a00, a10, u), lerp(a01, a11, u), w)


def reference_ao(world, world_pos, normal):
    """Gabarito independente: mesma geometria, cantos computados um a um."""
    an = [abs(v) for v in normal]
    if max(an) < 0.99:
        return Fraction(1)
    n = tuple(int(round(v)) for v in normal)
    t1 = (0, 1, 0) if an[0] > 0.5 else (1, 0, 0)
    t2 = (1, 0, 0) if an[2] > 0.5 else (0, 0, 1)
    own = tuple(math.floor(world_pos[i] - normal[i] * 0.01) for i in range(3))
    v = tuple(own[i] + n[i] for i in range(3))
    fr = [world_pos[i] - own[i] for i in range(3)]
    u = min(max(fr[0] * t1[0] + fr[1] * t1[1] + fr[2] * t1[2], 0.0), 1.0)
    w = min(max(fr[0] * t2[0] + fr[1] * t2[1] + fr[2] * t2[2], 0.0), 1.0)

    def A(dx, dz):
        return (v[0] + dx * t1[0] + dz * t2[0],
                v[1] + dx * t1[1] + dz * t2[1],
                v[2] + dx * t1[2] + dz * t2[2])

    sides = {(-1, 0): world.opaque(A(-1, 0)), (1, 0): world.opaque(A(1, 0)),
             (0, -1): world.opaque(A(0, -1)), (0, 1): world.opaque(A(0, 1))}
    corners = {}
    for dx in (-1, 1):
        for dz in (-1, 1):
            corners[(dx, dz)] = corner_ao(sides[(dx, 0)], sides[(0, dz)], world.opaque(A(dx, dz)))

    def bil(c):
        return (c[(-1, -1)] * (1 - u) * (1 - w) + c[(1, -1)] * u * (1 - w)
                + c[(-1, 1)] * (1 - u) * w + c[(1, 1)] * u * w)

    return bil(corners)


def main():
    random.seed(11)
    errors = 0
    checked = 0

    for scenario in range(200):
        world = World()
        # blocos ao redor de uma face de teste em posição aleatória (negativa ou não)
        base = [random.randrange(-60, 60) for _ in range(3)]
        normal = random.choice([(0, 1, 0), (0, -1, 0), (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)])
        n = normal
        own = tuple(base[i] for i in range(3))
        v = tuple(own[i] + n[i] for i in range(3))
        an = [abs(x) for x in n]
        t1 = (0, 1, 0) if an[0] > 0.5 else (1, 0, 0)
        t2 = (1, 0, 0) if an[2] > 0.5 else (0, 0, 1)
        for dx in (-1, 0, 1):
            for dz in (-1, 1):
                if dx == 0 and dz == -1:
                    continue
                p = (v[0] + dx * t1[0] + dz * t2[0],
                     v[1] + dx * t1[1] + dz * t2[1],
                     v[2] + dx * t1[2] + dz * t2[2])
                world.set(p, random.choice([0, 1, 3]))  # inclui vidro (não opaco)
        for dx in (-1, 1):
            for dz in (-1, 1):
                p = (v[0] + dx * t1[0] + dz * t2[0],
                     v[1] + dx * t1[1] + dz * t2[1],
                     v[2] + dx * t1[2] + dz * t2[2])
                if random.random() < 0.5:
                    world.set(p, random.choice([1, 2, 4]))
        # posições de fragmento: centro, bordas e cantos da face
        for fu, fw in [(0.5, 0.5), (0.0, 0.5), (1.0, 0.5), (0.5, 0.0), (0.5, 1.0),
                       (0.0, 0.0), (1.0, 1.0), (0.25, 0.75)]:
            pos = [own[i] + 0.5 + n[i] * 0.5 for i in range(3)]
            for i in range(3):
                pos[i] += (fu - 0.5) * t1[i] + (fw - 0.5) * t2[i]
            got = voxel_ao(world, pos, normal)
            exp = reference_ao(world, pos, normal)
            checked += 1
            if abs(float(got - exp)) > 1e-9:
                errors += 1
                if errors < 5:
                    print(f"DIVERGE cenario={scenario} fu={fu} fw={fw}: got={float(got):.6f} exp={float(exp):.6f}")

    # casos direcionais
    world = World()
    # 1. canto livre (nada à frente): AO = 1 em qualquer ponto
    assert float(voxel_ao(world, (10.5, 10.0 + 0.5, 10.5), (0, -1, 0))) == 1.0
    # 2. ambos os lados opacos: AO = 0 no canto, com vidro ao redor não conta
    # face -Y em y=10.5: own=(10,10,10), voxel à frente v=(10,9,10); t1=x, t2=z
    world.set((10, 9, 11), 1)   # lado +z
    world.set((11, 9, 10), 1)   # lado +x
    world.set((11, 9, 11), 3)   # canto diagonal é vidro -> não eleva nada
    val = voxel_ao(world, (11.0, 10.5, 11.0), (0, -1, 0))
    assert val == 0, f"canto entre dois lados opacos deve ter AO 0, got {float(val)}"
    # 3. apenas um lado: (3-1)/3
    world2 = World()
    world2.set((10, 9, 11), 1)
    val = voxel_ao(world2, (10.5, 10.5, 10.999), (0, -1, 0))
    assert abs(float(val) - 2 / 3) < 2e-3, f"um lado opaco ≈ 2/3, got {float(val)}"
    # em z=10.0 exato u/w no limite: lado +z opaco -> e ao longo de z borda
    # 4. face diagonal (planta): sem AO
    assert float(voxel_ao(world2, (10.5, 10.5, 10.5), (0.7071, 0.7071, 0.0))) == 1.0
    # 5. vidro não contribui para oclusão
    world3 = World()
    world3.set((10, 9, 11), 3)
    assert float(voxel_ao(world3, (10.5, 10.5, 10.999), (0, -1, 0))) == 1.0

    if errors == 0:
        print(f"SIM OK voxel_ao: {checked} posições conferem com gabarito independente; "
              "vidro não oclui, face diagonal sem AO, canto com dois lados = 0")
    else:
        print(f"SIM FALHOU voxel_ao: {errors}/{checked} divergências")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
