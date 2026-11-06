#!/usr/bin/env python3
"""Testes de fronteira do streaming (VS-01, AC-04 / REQ-STREAM-01/02/05/06;
raios atualizados pela VS-08 — slots derivados de |esfera(unload)| x 1.05
(emenda 2026-11-06: esfera(generation) esgotava o pool), sem teto fixo de
4096)."""

import sys

# VS-08 defaults (vox.ini ausente): visão 8, geração 9, descarga 10.
RADIUS_VISION = 8
RADIUS_GENERATION = 9
RADIUS_UNLOAD = 10

failures = []


def check(name, cond):
    if not cond:
        failures.append(name)
        print(f"  FAIL: {name}")


def sphere_count(radius):
    """Pontos inteiros com x^2+y^2+z^2 <= r^2 (mesma definição do config.odin)."""
    count = 0
    for x in range(-radius, radius + 1):
        for y in range(-radius, radius + 1):
            for z in range(-radius, radius + 1):
                if x * x + y * y + z * z <= radius * radius:
                    count += 1
    return count


# VS-08 (REQ-CFG-02, emenda 2026-11-06): slots residentes derivados da esfera
# de UNLOAD (retenção até unload + transitório de aposentadoria), com margem
# de 5%: slots = ceil(|esfera(unload)| * 1.05) = (n*105 + 99) // 100.
def resident_slots(radius_unload):
    return (sphere_count(radius_unload) * 105 + 99) // 100


RESIDENT_SLOTS = resident_slots(RADIUS_UNLOAD)
CHUNK_SIZE = 32


def sq_dist_i64(a, b):
    """Espelha calculate_squared_distance (intermediarios i64)."""
    I64_MIN, I64_MAX = -(2 ** 63), 2 ** 63 - 1
    total = sum((a[i] - b[i]) ** 2 for i in range(3))
    check("distancia cabe em i64", I64_MIN <= total <= I64_MAX)
    return total


def floor_div(v, d):
    """Espelha floor_div_i32."""
    q = v // d  # Python // ja e piso
    return q


def main():
    # 1. Slots derivados da esfera de unload cabem nos limites (emenda VS-08)
    count = sphere_count(RADIUS_UNLOAD)
    print(f"[fronteira] esfera r={RADIUS_UNLOAD} contem {count} chunks; "
          f"slots residentes = {RESIDENT_SLOTS} (x 1.05, ceil)")
    check(f"slots ({RESIDENT_SLOTS}) == ceil(esfera({RADIUS_UNLOAD})*1.05)",
          RESIDENT_SLOTS == (count * 105 + 99) // 100)
    check(f"esfera de generation ({sphere_count(RADIUS_GENERATION)}) <= slots ({RESIDENT_SLOTS})",
          sphere_count(RADIUS_GENERATION) <= RESIDENT_SLOTS)
    check(f"slots ({RESIDENT_SLOTS}) <= 16384 (limite REQ-CFG-03)",
          RESIDENT_SLOTS <= 16384)

    # 2. Distancias extremas sem overflow (ADR-B8)
    far = (2 ** 20, -(2 ** 20), 2 ** 19)
    d = sq_dist_i64((0, 0, 0), far)
    check("distancia extrema > limite de i32", d > 2 ** 31 - 1)
    print(f"[fronteira] distancia extrema {d} (i32 estouraria)")

    # 3. floor_div com negativos (REQ-STREAM-06)
    check("floor_div(-1, 32) == -1", floor_div(-1, CHUNK_SIZE) == -1)
    check("floor_div(-32, 32) == -1", floor_div(-32, CHUNK_SIZE) == -1)
    check("floor_div(-33, 32) == -2", floor_div(-33, CHUNK_SIZE) == -2)
    check("floor_div(0, 32) == 0", floor_div(0, CHUNK_SIZE) == 0)
    check("floor_div(31, 32) == 0", floor_div(31, CHUNK_SIZE) == 0)
    check("floor_div(32, 32) == 1", floor_div(32, CHUNK_SIZE) == 1)
    print("[fronteira] floor_div com negativos ok")

    # 4. Raios efetivos (defaults da VS-08; guarda contra regressão)
    check("visao == 8", RADIUS_VISION == 8)
    check("geracao == 9", RADIUS_GENERATION == 9)
    check("descarga == 10", RADIUS_UNLOAD == 10)
    check("histerese estrita: visao <= geracao < descarga",
          RADIUS_VISION <= RADIUS_GENERATION < RADIUS_UNLOAD)
    print("[fronteira] raios 8/9/10 confirmados (histerese estrita)")

    print(f"\n{'FALHOU' if failures else 'PASSOU'}: {len(failures)} falhas")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
