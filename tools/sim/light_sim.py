#!/usr/bin/env python3
"""Simulacao de seed, propagacao e selecao de jobs de relight (VS-23, T3.0).

Espelha light.slang: emissao RGB quantizada em 4 bits (round(saturate(c)*15)),
seed reescrevendo o volume (fontes apagadas somem), propagacao in-place
monotonica max(vizinhos 6)-1 por canal, opacos bloqueiam, convergencia em
<= 15 passes. Gabarito: BFS com queda de um nivel por voxel.

Cobertura: fontes adicionadas/removidas, 15 niveis, canais independentes,
barreiras opacas, selecao chunk + 26 vizinhos com deduplicacao, chunks
ausentes e descarregamento.
"""

import math
from collections import deque

CHUNK = 32
NON_SOLID = 2
TRANSPARENT = 1
OPAQUE_FLAGS = NON_SOLID | TRANSPARENT


def is_opaque(block_id, flags):
    return block_id != 0 and (flags[block_id] & OPAQUE_FLAGS) == 0


def quantize(color):
    return tuple(min(15, max(0, int(math.floor(c * 15 + 0.5)))) for c in color)


def pack(c):
    return c[0] | (c[1] << 4) | (c[2] << 8)


def unpack(v):
    return (v & 15, (v >> 4) & 15, (v >> 8) & 15)


class World:
    def __init__(self):
        self.blocks = {}     # w -> block_id
        self.flags = {0: 0}
        self.emission = {}

    def set(self, w, b):
        self.blocks[tuple(w)] = b

    def block_at(self, w):
        return self.blocks.get(tuple(w), 0)


def seed_chunk(world, origin, dense):
    """Espelha light_seed: volume inteiro reescrito a partir da emissao."""
    out = {}
    for i in range(CHUNK ** 3):
        out[i] = 0
    for w, b in world.blocks.items():
        rel = (w[0] - origin[0], w[1] - origin[1], w[2] - origin[2])
        if all(0 <= rel[i] < CHUNK for i in range(3)):
            idx = rel[0] | (rel[2] << 5) | (rel[1] << 10)
            if b != 0:
                out[idx] = pack(quantize(world.emission.get(b, (0, 0, 0))))
    dense.update(out)


def propagate_world(world, dense_by_origin, origins_set):
    """Espelha light_propagate para todos os chunks do conjunto de jobs."""
    deltas = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]

    def light_at(w):
        o = ((w[0] >> 5) * CHUNK, (w[1] >> 5) * CHUNK, (w[2] >> 5) * CHUNK)
        d = dense_by_origin.get(o)
        if d is None:
            return (0, 0, 0)
        l = (w[0] & 31, w[1] & 31, w[2] & 31)
        return unpack(d[l[0] | (l[2] << 5) | (l[1] << 10)])

    for o in origins_set:
        d = dense_by_origin[o]
        new_d = dict(d)
        for y in range(CHUNK):
            for z in range(CHUNK):
                for x in range(CHUNK):
                    w = (o[0] + x, o[1] + y, o[2] + z)
                    if is_opaque(world.block_at(w), world.flags):
                        continue
                    best = [0, 0, 0]
                    for dx, dy, dz in deltas:
                        c = light_at((w[0] + dx, w[1] + dy, w[2] + dz))
                        for k in range(3):
                            best[k] = max(best[k], c[k])
                    idx = x | (z << 5) | (y << 10)
                    cur = unpack(d[idx])
                    nxt = tuple(max(cur[k], max(best[k], 1) - 1) for k in range(3))
                    new_d[idx] = pack(nxt)
        dense_by_origin[o] = new_d


def relight(world, dense_by_origin, origins_set):
    for o in origins_set:
        seed_chunk(world, o, dense_by_origin.setdefault(o, {}))
    for _ in range(15):
        propagate_world(world, dense_by_origin, origins_set)


def bfs_reference(world, sources):
    """Gabarito: BFS exato por canal com queda de 1 por voxel, opacos bloqueiam.
    A fonte pode ser opaca (tocha): ela guarda a própria emissão e irradia
    a partir dos vizinhos — mesmo contrato do seed/propagate do light.slang."""
    dist = {}
    q = deque()
    deltas = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    result = {}
    source_set = set()
    for w, c in sources:
        result[w] = c  # voxel da fonte: emissão independente de opacidade
        source_set.add(w)
        for dx, dy, dz in deltas:
            q.append(((w[0] + dx, w[1] + dy, w[2] + dz), tuple(max(0, v - 1) for v in c)))
    while q:
        w, c = q.popleft()
        if is_opaque(world.block_at(w), world.flags) and w not in source_set:
            continue  # opaco bloqueia: só guarda a própria emissão (seed)
        cur = result.get(w)
        if cur is not None and all(cur[k] >= c[k] for k in range(3)):
            continue  # dominado: nada melhora por canal
        merged = tuple(max(cur[k], c[k]) if cur is not None else c[k] for k in range(3))
        if cur == merged:
            continue
        result[w] = merged
        if max(merged) <= 1:
            continue
        for dx, dy, dz in deltas:
            n = (w[0] + dx, w[1] + dy, w[2] + dz)
            q.append((n, tuple(max(0, v - 1) for v in merged)))
    return result


def select_jobs(active_chunks, dirty):
    """Espelha light_build_jobs: chunk sujo + 26 vizinhos, dedup, só carregados."""
    selected = {}
    order = []
    for d in dirty:
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    c = (d[0] + dx, d[1] + dy, d[2] + dz)
                    if c in active_chunks and c not in selected:
                        selected[c] = True
                        order.append(c)
    return order


def main():
    world = World()
    # bloco emissor id 10: laranja forte; id 11: verde; ambos opacos? emissores
    # tipicamente opacos (tocha). opaco = sem flags.
    world.flags[10] = 0
    world.emission[10] = (1.0, 0.5, 0.1)
    world.flags[11] = 0
    world.emission[11] = (0.1, 1.0, 0.2)
    world.flags[1] = 0  # pedra opaca (sem emissão)

    dense = {}
    origins = set()

    def origin_of(w):
        return ((w[0] >> 5) * CHUNK, (w[1] >> 5) * CHUNK, (w[2] >> 5) * CHUNK)

    # cena 1: tocha no ar, 15 niveis de alcance
    torch = (5, 20, 5)
    world.set(torch, 10)
    o = origin_of(torch)
    origins.add(o)
    relight(world, dense, origins)
    ref = bfs_reference(world, [(torch, quantize(world.emission[10]))])
    errors = 0
    for w, c in ref.items():
        if max(c) == 0:
            continue
        oo = origin_of(w)
        if oo not in dense:
            continue
        l = (w[0] & 31, w[1] & 31, w[2] & 31)
        got = unpack(dense[oo][l[0] | (l[2] << 5) | (l[1] << 10)])
        if got != c:
            errors += 1
            if errors < 5:
                print(f"DIVERGE {w}: got={got} ref={c}")
    # alcance: 15 niveis = 14 passos de queda a partir da fonte (15 no voxel da fonte)
    far = (5 + 14, 20, 5)
    assert unpack(dense[origin_of(far)][far[0] & 31 | ((far[2] & 31) << 5) | ((far[1] & 31) << 10)])[0] == 1
    beyond = (5 + 15, 20, 5)
    assert unpack(dense[origin_of(beyond)][beyond[0] & 31 | ((beyond[2] & 31) << 5) | ((beyond[1] & 31) << 10)]) == (0, 0, 0)

    # cena 2: barreira opaca: a luz não passa PELA parede, mas contorna;
    # o volume tem que coincidir com o BFS (que também contorna)
    world.set((8, 20, 5), 1)  # 1 = opaco sem emissao
    dense2 = {o: dict(dense[o])}
    relight(world, dense2, {o})
    ref2 = bfs_reference(world, [(torch, quantize(world.emission[10]))])
    for w, c in ref2.items():
        if origin_of(w) != o:
            continue
        l = (w[0] & 31) | ((w[2] & 31) << 5) | ((w[1] & 31) << 10)
        got = unpack(dense2[o][l])
        assert got == c, f"parede: {w} got={got} ref={c}"
    assert is_opaque(world.block_at((8, 20, 5)), world.flags)

    # cena 3: remoção da fonte apaga toda a luz derivada
    world.set(torch, 0)
    dense3 = {o: dict(dense2[o])}
    relight(world, dense3, {o})
    assert all(v == 0 for v in dense3[o].values()), "fonte removida: volume deve zerar"

    # cena 4: canais independentes (duas fontes de cores distintas se encontram)
    world.set(torch, 10)
    world.set((20, 20, 5), 11)
    o2 = origin_of((20, 20, 5))
    d4 = {}
    origins4 = {o, o2}
    relight(world, d4, origins4)
    mid = (13, 20, 5)
    gm = unpack(d4[origin_of(mid)][(mid[0] & 31) | ((mid[2] & 31) << 5) | ((mid[1] & 31) << 10)])
    ref_mid = bfs_reference(world, [(torch, quantize(world.emission[10])), ((20, 20, 5), quantize(world.emission[11]))])
    assert gm == ref_mid[mid], f"encontro de canais: got={gm} ref={ref_mid[mid]}"
    assert gm[1] > 0 and gm[0] > 0

    # cena 5: selecao de jobs com deduplicacao (presença no map = carregado)
    active = {(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (2, 0, 0), (2, 2, 2)}
    jobs = select_jobs(active, [(0, 0, 0)])
    assert len(jobs) == 4, f"chunk + 3 vizinhos carregados => 4 jobs, got {len(jobs)}"
    assert set(jobs) == {(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0)}
    jobs2 = select_jobs(active, [(0, 0, 0), (1, 0, 0)])
    assert len(jobs2) == len(set(jobs2)), "sem duplicatas"
    assert (2, 0, 0) in jobs2 and (2, 2, 2) not in jobs2 and set(jobs) <= set(jobs2)

    if errors == 0:
        print("SIM OK block light: seed+15 passes == BFS de referência; remoção zera volume; "
              "opaco bloqueia; 15 níveis; canais independentes; seleção de jobs sem duplicatas")
    else:
        print(f"SIM FALHOU block light: {errors} divergências")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
