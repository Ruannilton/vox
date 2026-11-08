#!/usr/bin/env python3
"""Simulacao do heightmap do generate (VS-13, REQ-SIM-10a).

Modelo Python do mapeamento de threads do `generate_voxels` reestruturado:
cada workgroup (8x8x8) cobre uma fatia de 8x8 colunas (x,z) do chunk; as
threads com y-local 0 calculam a altura da coluna UMA vez (mock noise) e
gravam num groupshared uint16[8][8]; apos barrier todos os 512 threads leem
a altura da sua coluna e derivam o block_id.

Cobertura:
- indexacao: qual thread (global) calcula qual coluna (x,z) de qual fatia;
- equivalencia bit a bit contra a computacao por voxel (mock noise
  deterministico, NAO e a FastNoiseLite — so prova a indexacao e a
  equivalencia estrutural da altura/block_id);
- export do heightmap para o ring (binding 20, indice z-contiguo x|z<<5,
  slot = mirror_ring_slot), escrito pelas threads de coluna — o ring e
  MANTIDO como reserva futura (emenda do mantenedor, 2026-11-08), mas o
  materialize o ignora;
- VS-19 (REQ-PHY-07): as 1.024 colunas `heights` da pagina sao derivadas
  do bitmask `solid` (topo sólido real, 0xFFFF = vazia), cobrindo
  arcos/flutuantes que o ruído analítico não prevê;
- contagem de avaliacoes de ruído: por voxel (65.536/chunk) vs heightmap
  (threads de coluna, 4 grupos-y por fatia => 256/chunk). A otimizacao
  groupshared do worldgen PERMANECE.

VS-14 (REQ-SIM-11): spawn de planta (id 4) por coluna via wang hash de
(x,z) mundial (10%: hash % 1000 < 100) — voxel y == altura+1 recebe o id 4.
Emenda 2026-11-07: a planta NÃO é sólida — o heightmap exporta `altura`
(não altura+1); o topo sólido é o terreno. O hash é espelhado em Python
(mock do algoritmo do shader, sem FastNoiseLite).

Cenario executado nos ACs da VS-13 (AC-01) e VS-14 (AC-01).
"""

PLANT_BLOCK_ID = 4
PLANT_PROBABILITY_PERCENT = 10  # hash % 1000 < 100 (constante do shader)

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

CHUNK_SIZE = 32
CHUNK_VOXEL_COUNT = CHUNK_SIZE ** 3
GROUP = 8  # numthreads(8,8,8)
DISPATCH_X = CHUNK_SIZE // GROUP  # 4 grupos por eixo x/y
DISPATCH_Y = CHUNK_SIZE // GROUP
DISPATCH_Z = CHUNK_SIZE // GROUP  # 4 grupos por chunk no eixo z
MIRROR_RING_SLOTS = 64

PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


# --- mock noise (deterministico; NAO portar a FastNoiseLite) ---

def mock_noise1(x, z):
    """OpenSimplex2 @0.02 (mock): determinístico, varia com (x,z)."""
    v = ((x * 374761393 + z * 668265263) ^ ((x * 1274126177 + z * 972663749) >> 3)) & 0xFFFFFFFF
    v = (v ^ (v >> 13)) * 1103515245 & 0xFFFFFFFF
    return ((v & 0xFFFF) / 0xFFFF) * 2.0 - 1.0


def mock_noise2(z, x):
    """Perlin @0.07 (mock): args TROCADOS (z,x) como no generate real."""
    v = ((z * 2246822519 + x * 3266489917) ^ ((z * 951274213 + x * 435987131) >> 5)) & 0xFFFFFFFF
    v = (v ^ (v >> 11)) * 2654435761 & 0xFFFFFFFF
    return ((v & 0xFFFF) / 0xFFFF) * 2.0 - 1.0


# --- VS-14: wang hash da coluna (espelha voxel.slang; mock, sem ruído) ---

def wang_hash(a):
    a &= 0xFFFFFFFF
    a = (a ^ 61) ^ (a >> 16)
    a = (a + (a << 3)) & 0xFFFFFFFF
    a = a ^ (a >> 4)
    a = (a * 0x27D4EB2D) & 0xFFFFFFFF
    a = a ^ (a >> 15)
    return a & 0xFFFFFFFF


def hash_u32(x, z):
    """Hash u32 determinístico de (x,z) mundial: wang(wang(x) ^ z)."""
    return wang_hash(wang_hash(x & 0xFFFFFFFF) ^ (z & 0xFFFFFFFF))


def plant_spawns(wx, wz):
    """VS-14 (REQ-PLT-03): 10% das colunas ganham planta (y == altura+1)."""
    return hash_u32(wx, wz) % 1000 < PLANT_PROBABILITY_PERCENT * 10


def column_height(wx, wz):
    """Mesma expressão do generate: 32 + uint(h1*10) + uint(h2*5)."""
    h1 = int(mock_noise1(wx, wz) * 10)
    h2 = int(mock_noise2(wz, wx) * 5)
    return 32 + h1 + h2


def is_solid_block(block_id):
    """Emenda 2026-11-07: solidez é do tipo — planta (id 4) ocupa o voxel mas
    não é sólida (espelha block_is_solid do registry)."""
    return block_id != 0 and block_id != PLANT_BLOCK_ID


def column_top_local(chunk_base_y, wx, wz):
    """Altura analítica do worldgen (heightfield): y do SÓLIDO mais alto da
    coluna DENTRO do chunk (0xFFFF se a coluna é toda ar neste chunk).
    Emenda 2026-11-07: planta não é sólida — o export é `altura` (não
    altura+1); acima do terreno só há plantas. É o que o RING exporta."""
    height = column_height(wx, wz)
    top = min(height - chunk_base_y, CHUNK_SIZE - 1)
    return 0xFFFF if top < 0 else top


def block_id_from_height(wy, height, wx=0, wz=0):
    # VS-14: voxel acima da grama (y == altura+1) vira planta quando a coluna
    # sorteia spawn; demais y inalterados.
    if wy == height + 1 and plant_spawns(wx, wz):
        return PLANT_BLOCK_ID
    if wy > height:
        return 0
    if wy < height - 8:
        return 3
    if wy < height:
        return 2
    return 1  # wy == height


# --- modelo por voxel (baseline pre-VS-13) ---

def generate_per_voxel(origin):
    """Cada thread avalia o ruído 2x (65.536 avaliações/chunk). Baseline
    pré-VS-13 (sem groupshared, sem ring)."""
    noise_evals = 0
    dense = [0] * CHUNK_VOXEL_COUNT
    for tz in range(CHUNK_SIZE):
        for ty in range(CHUNK_SIZE):
            for tx in range(CHUNK_SIZE):
                wx, wy, wz = origin[0] + tx, origin[1] + ty, origin[2] + tz
                h1 = int(mock_noise1(wx, wz) * 10); noise_evals += 1
                h2 = int(mock_noise2(wz, wx) * 5); noise_evals += 1
                height = 32 + h1 + h2
                bid = block_id_from_height(wy, height, wx, wz)
                dense[tx | (tz << 5) | (ty << 10)] = bid
    return dense, noise_evals


# --- modelo heightmap por workgroup (pós-VS-13) ---

def generate_heightmap(origin, mirror_ring_slot=-1):
    """Threads y-local 0 calculam as 64 colunas da fatia 8x8 (groupshared).

    Espelha o shader: dispatch (4,4,4) por chunk, numthreads(8,8,8).
    Cada workgroup (gx,gy,gz) cobre x=[8gx,8gx+8), y=[8gy,8gy+8),
    z-local=[8gz,8gz+8). heights_gs[lx][lz] preenchido pelas threads ly==0,
    barrier, todos leem. Avaliações: 64 por workgroup x 64 workgroups.
    Com mirror_ring_slot >= 0 espelha também o export do ring (binding 20),
    mantido como reserva futura (o materialize o ignora — VS-19).
    """
    noise_evals = 0
    dense = [0] * CHUNK_VOXEL_COUNT
    ring_heights = [0xFFFF] * (MIRROR_RING_SLOTS * 1024)

    heights_gs = [[0] * GROUP for _ in range(GROUP)]  # groupshared uint16[8][8]

    for gz in range(DISPATCH_Z):
        for gy in range(DISPATCH_Y):
            for gx in range(DISPATCH_X):
                # --- fase 1: threads com y-local 0 calculam as colunas ---
                for lx in range(GROUP):
                    for lz in range(GROUP):
                        tx = gx * GROUP + lx
                        tz = gz * GROUP + lz
                        wx, wz = origin[0] + tx, origin[2] + tz
                        h1 = int(mock_noise1(wx, wz) * 10); noise_evals += 1
                        h2 = int(mock_noise2(wz, wx) * 5); noise_evals += 1
                        heights_gs[lx][lz] = 32 + h1 + h2
                        # export z-contíguo x|z<<5 (chunk-local), slot do job:
                        # altura analítica (heightfield) — reserva futura
                        if mirror_ring_slot >= 0:
                            ring_heights[mirror_ring_slot * 1024 + (tx | (tz << 5))] = \
                                column_top_local(origin[1], wx, wz)
                # --- barrier (GroupMemoryBarrierWithGroupSync) ---
                # --- fase 2: os 512 threads leem a altura da sua coluna ---
                for ly in range(GROUP):
                    for lx in range(GROUP):
                        for lz in range(GROUP):
                            tx = gx * GROUP + lx
                            ty = gy * GROUP + ly
                            tz = gz * GROUP + lz
                            wx, wz = origin[0] + tx, origin[2] + tz
                            height = heights_gs[lx][lz]
                            bid = block_id_from_height(origin[1] + ty, height, wx, wz)
                            dense[tx | (tz << 5) | (ty << 10)] = bid
    return dense, ring_heights, noise_evals


def derive_heights(dense):
    """VS-19 (REQ-PHY-07): as 1.024 colunas derivadas do bitmask sólido na
    materialização — y do SÓLIDO mais alto de cada coluna (0xFFFF = vazia).
    Cobre arcos/flutuantes: é sempre o topo medido, nunca o ruído. É o que a
    página `ChunkPage.heights` guarda; o materialize ignora o ring."""
    heights = [0xFFFF] * (CHUNK_SIZE * CHUNK_SIZE)
    for z in range(CHUNK_SIZE):
        for x in range(CHUNK_SIZE):
            for y in range(CHUNK_SIZE - 1, -1, -1):
                if is_solid_block(dense[x | (z << 5) | (y << 10)]):
                    heights[x | (z << 5)] = y
                    break
    return heights


def scenario_thread_mapping():
    print("[cenario] mapeamento de threads: qual thread calcula qual coluna")
    # workgroup (gx,gy,gz): threads y-local 0 => 64 colunas (x fatia, z fatia)
    origin = (128, 0, -64)
    dense, ring_heights, _ = generate_heightmap(origin, mirror_ring_slot=0)

    # cada coluna (x,z) calculada uma vez por fatia com posição mundo certa
    # (ring = altura analítica heightfield, export das threads de coluna)
    ok = True
    for tz in range(CHUNK_SIZE):
        for tx in range(CHUNK_SIZE):
            wx, wz = origin[0] + tx, origin[2] + tz
            ok = ok and ring_heights[tx | (tz << 5)] == column_top_local(origin[1], wx, wz)
    check("cada coluna (x,z) calculada uma vez por fatia com posição mundo certa", ok)

    # a altura NÃO depende de y: todos os voxels da coluna usam a mesma altura
    ok = True
    for tz in (0, 5, 17, 31):
        for tx in (0, 3, 8, 31):
            h = column_height(origin[0] + tx, origin[2] + tz)
            for ty in range(CHUNK_SIZE):
                if dense[tx | (tz << 5) | (ty << 10)] != block_id_from_height(
                    origin[1] + ty, h, origin[0] + tx, origin[2] + tz
                ):
                    ok = False
    check("coluna inteira deriva do mesmo height", ok)


def scenario_bit_exact_equivalence():
    print("[cenario] equivalencia bit a bit heightmap vs computacao por voxel")
    ok_all = True
    total_evals_voxel = 0
    total_evals_heightmap = 0
    for origin in ((0, 0, 0), (128, 32, -64), (-256, -32, 96)):
        dense_ref, evals_ref = generate_per_voxel(origin)
        dense_new, _ring, evals_new = generate_heightmap(origin, mirror_ring_slot=7)
        ok_all = ok_all and dense_ref == dense_new
        total_evals_voxel += evals_ref
        total_evals_heightmap += evals_new
    check("saída bit a bit idêntica (dense) em 3 chunks", ok_all)
    # 64 workgroups/chunk x 64 colunas x 2 evals = 8.192 avaliações/chunk
    # (as 4 fatias-y de um mesmo (x,z) recalculam a mesma coluna — o groupshared
    # é por workgroup; redução real: 65.536 -> 8.192, 8x)
    check(
        f"avaliações de ruído: {total_evals_voxel} (por voxel) -> {total_evals_heightmap} (heightmap)",
        total_evals_voxel == 3 * 2 * CHUNK_VOXEL_COUNT and total_evals_heightmap == 3 * 2 * 4096,
    )


def scenario_ring_write():
    print("[cenario] export do heightmap no ring (binding 20, reserva futura)")
    origin = (0, 0, 0)
    dense_ref, _ = generate_per_voxel(origin)
    _dense, ring_h, _ = generate_heightmap(origin, mirror_ring_slot=3)

    # apenas as threads de coluna escrevem; slot certo; índice x|z<<5
    ok_slot = True
    for tz in range(CHUNK_SIZE):
        for tx in range(CHUNK_SIZE):
            # recompute da coluna pela definição (topo SÓLIDO do baseline —
            # planta não conta; emenda 2026-11-07)
            top = 0xFFFF
            for ty in range(CHUNK_SIZE - 1, -1, -1):
                if is_solid_block(dense_ref[tx | (tz << 5) | (ty << 10)]):
                    top = ty
                    break
            ok_slot = ok_slot and ring_h[3 * 1024 + (tx | (tz << 5))] == top
    check("ring binding 20: slot correto, índice z-contíguo x|z<<5", ok_slot)


def scenario_heights_derived():
    print("[cenario] VS-19: heights derivado do solid na materializacao")
    origin = (0, 0, 0)
    dense, _ = generate_per_voxel(origin)
    heights = derive_heights(dense)

    # 1.024 colunas: topo SÓLIDO medido == altura do ruído (worldgen é
    # heightfield: terreno contínuo, planta não-sólida não move o topo)
    ok = True
    for tz in range(CHUNK_SIZE):
        for tx in range(CHUNK_SIZE):
            top = min(column_height(origin[0] + tx, origin[2] + tz), CHUNK_SIZE - 1)
            if heights[tx | (tz << 5)] != top:
                ok = False
    check("heightfield: heights == topo sólido medido em 1.024 colunas", ok)

    # ring (analítico) == derivado (medido) no heightfield — reserva coerente
    _d2, ring_h, _ = generate_heightmap(origin, mirror_ring_slot=0)
    check("heightfield: ring analítico == topo medido (reserva coerente)",
          ring_h[0:1024] == heights)

    # topologia NÃO-heightfield: arco/flutuante acima do terreno — o topo
    # derivado aponta para o sólido mais alto REAL, não para o ruído. Escolhe
    # uma coluna baixa do mock (topo < 19) para o flutuante ficar acima.
    wx, wz = next(
        (x, z)
        for x in range(CHUNK_SIZE)
        for z in range(CHUNK_SIZE)
        if column_height(x, z) <= 18
    )
    arch_y = 20
    dense_arch = list(dense)
    dense_arch[wx | (wz << 5) | (arch_y << 10)] = 3
    heights_arch = derive_heights(dense_arch)
    noise_top = min(column_height(wx, wz), CHUNK_SIZE - 1)
    check(
        "flutuante: heights medido aponta o bloco flutuante (y=%d), não o ruído (y=%d)"
        % (arch_y, noise_top),
        heights_arch[wx | (wz << 5)] == arch_y,
    )

    # coluna de ar pura: 0xFFFF
    dense_air = [0] * CHUNK_VOXEL_COUNT
    heights_air = derive_heights(dense_air)
    check("coluna de ar: 0xFFFF", all(h == 0xFFFF for h in heights_air))


def scenario_plant_spawn():
    print("[cenario] VS-14: spawn determinístico da planta (wang hash por coluna)")

    # determinismo: puro função de (x,z) — mesma resposta em chamadas e em
    # chunks diferentes (a coluna na fronteira nasce igual nos dois chunks)
    ok = True
    for wx, wz in ((0, 0), (1, 0), (0, 1), (-1, 7), (12345, -6789), (31, 0), (32, 0)):
        a = plant_spawns(wx, wz)
        ok = ok and a == plant_spawns(wx, wz) and a == plant_spawns(wx, wz)
    check("hash puro função de (x,z): mesma resposta em repetições", ok)

    # taxa ~10% numa amostra larga de colunas de mundo (faixa 9%..11%)
    total, plants = 0, 0
    for wx in range(-256, 256):
        for wz in range(-128, 128):
            total += 1
            plants += 1 if plant_spawns(wx, wz) else 0
    ratio = plants / total
    check(f"taxa de spawn ~10% ({plants}/{total} = {ratio:.3f})", 0.09 <= ratio <= 0.11)

    # dense: voxel y == altura+1 com spawn -> id 4; demais inalterados; coluna
    # sem planta idêntica ao worldgen da VS-13
    origin = (0, 0, 0)
    dense, _ring, _ = generate_heightmap(origin)
    ok_id = True
    ok_others = True
    for tz in range(CHUNK_SIZE):
        for tx in range(CHUNK_SIZE):
            wx, wz = origin[0] + tx, origin[2] + tz
            height = column_height(wx, wz)
            for ty in range(CHUNK_SIZE):
                bid = dense[tx | (tz << 5) | (ty << 10)]
                if plant_spawns(wx, wz) and origin[1] + ty == height + 1:
                    ok_id = ok_id and bid == PLANT_BLOCK_ID
                elif not plant_spawns(wx, wz):
                    ok_others = ok_others and bid != PLANT_BLOCK_ID
    check("voxel y == altura+1 da coluna com spawn -> id 4", ok_id)
    check("coluna sem spawn: nenhum voxel com id 4", ok_others)

    # heights derivado: coluna com planta aponta o terreno (planta não-sólida)
    heights = derive_heights(dense)
    ok_h = True
    ok_p = True
    for tz in range(CHUNK_SIZE):
        for tx in range(CHUNK_SIZE):
            wx, wz = origin[0] + tx, origin[2] + tz
            top = min(column_height(wx, wz), CHUNK_SIZE - 1)
            ok_h = ok_h and heights[tx | (tz << 5)] == top
            if plant_spawns(wx, wz):
                ok_p = ok_p and heights[tx | (tz << 5)] == top
    check("heights derivado: coluna (com e sem planta) == topo sólido", ok_h)
    check("heights derivado: planta não sobe o topo", ok_p)

    # altura+1 fora do chunk (topo na linha de cima do chunk): sem planta.
    # alturas do mock: 17..47; topo no limite exige height == base+31 — só
    # base_y=0 (height 31) é alcançável com planta na amostra
    found = False
    for wx in range(-512, 512):
        for wz in range(-512, 512):
            if column_height(wx, wz) == CHUNK_SIZE - 1 and plant_spawns(wx, wz):
                dense2, _r2, _ = generate_heightmap((wx, 0, wz))
                col_has_plant = any(
                    dense2[0 | (0 << 5) | (ty << 10)] == PLANT_BLOCK_ID
                    for ty in range(CHUNK_SIZE)
                )
                check("altura+1 fora do chunk: planta não nasce", not col_has_plant)
                found = True
                break
        if found:
            break
    check("caso de topo no limite do chunk encontrado", found)


def main():
    scenario_thread_mapping()
    scenario_bit_exact_equivalence()
    scenario_ring_write()
    scenario_heights_derived()
    scenario_plant_spawn()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
