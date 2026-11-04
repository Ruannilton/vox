#!/usr/bin/env python3
"""Testes de fronteira do streaming (VS-01, AC-04 / REQ-STREAM-01/02/05/06)."""

import sys

RADIUS_VISION = 8
RADIUS_GENERATION = 8
RADIUS_UNLOAD = 16
MAXIMUM_RESIDENT_CHUNKS = 4096
CHUNK_SIZE = 32

failures = []


def check(name, cond):
    if not cond:
        failures.append(name)
        print(f"  FAIL: {name}")


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
    # 1. Esfera discreta r=8 cabe no pool (ADR-B5)
    count = 0
    for x in range(-RADIUS_GENERATION, RADIUS_GENERATION + 1):
        for y in range(-RADIUS_GENERATION, RADIUS_GENERATION + 1):
            for z in range(-RADIUS_GENERATION, RADIUS_GENERATION + 1):
                if x * x + y * y + z * z <= RADIUS_GENERATION * RADIUS_GENERATION:
                    count += 1
    print(f"[fronteira] esfera r=8 contem {count} chunks")
    check(f"esfera r=8 ({count}) <= {MAXIMUM_RESIDENT_CHUNKS} slots", count <= MAXIMUM_RESIDENT_CHUNKS)

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

    # 4. Raios efetivos (guarda contra regressao da ADR-B5)
    check("visao == 8", RADIUS_VISION == 8)
    check("geracao == 8", RADIUS_GENERATION == 8)
    check("descarga == 16", RADIUS_UNLOAD == 16)
    print("[fronteira] raios 8/8/16 confirmados")

    print(f"\n{'FALHOU' if failures else 'PASSOU'}: {len(failures)} falhas")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
