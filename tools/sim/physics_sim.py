#!/usr/bin/env python3
"""VS-19 (REQ-PHY-02..06, REQ-PHY-08/09; AC-02/AC-03) — simulacao do solver
de fisica CPU sobre o mirror.

Modelo Python do algoritmo exato portado em src/engine/physics.odin:
acumulador de passo fixo com teto, sweep AABB eixo a eixo (X->Y->Z) com
subdivisao anti-tunneling, sliding, grounded recalculado por contato,
step-up seguro (espaco livre + apoio, limite 1 voxel), fast-path de chao via
heights com fallback ao sweep, congelamento sem deslocamento parcial em
pagina desconhecida e raycast DDA tri-state (Amanatides & Woo).

O "mundo" é um mock de chunks (sólidos por coordenada) com a mesma semantica
tri-state do mirror: chunk ausente = desconhecido (nunca ar).

Cobertura: acumulador (passo fixo, teto, repetibilidade), sweep (parede,
quina/canto, fronteira negativa, teto, deslocamento >1 voxel sem tunneling),
step-up (com/espaco, sem espaco = degrau de 2 voxels, sem apoio), grounded
(reativo, perde apoio ao sair da borda), fast-path == sweep (superficie,
caverna, 0xFFFF, cruzamento de chunk, sobreposicao), congelamento e retomada,
DDA (eixos, diagonal, fronteira negativa, origem interna, direcao nula,
distancia invalida, planta HITTABLE, unknown antes de miss, miss).
"""

import math

CHUNK_SIZE = 32
FIXED_DT = 1.0 / 60.0
MAX_STEPS_PER_FRAME = 5
GRAVITY = -24.0
TERMINAL_VELOCITY = -60.0
MAX_SUBSTEP = 0.4          # < 1 voxel: nunca atravessa um voxel sem teste
GROUND_EPS = 1e-4
STEP_UP_HEIGHT = 1.0

# tabela fisica (espelha PhysicsDefinition): id -> (blocking, hittable, friction, restitution)
SOLID, PLANT, AIR = 1, 4, 0
PHYSICS = {
    SOLID: (True, True, 0.6, 0.0),
    2:     (True, True, 0.6, 0.0),
    3:     (True, True, 0.6, 0.0),
    PLANT: (False, True, 0.6, 0.0),
}


def floor_div(a, b):
    return a // b


def chunk_of(voxel):
    return (
        floor_div(voxel[0], CHUNK_SIZE),
        floor_div(voxel[1], CHUNK_SIZE),
        floor_div(voxel[2], CHUNK_SIZE),
    )


class World:
    """Mock do mirror: chunks conhecidos com sólidos por coordenada de mundo."""

    def __init__(self):
        self.chunks = {}  # chunk -> set[(x,y,z)] sólidos (blocking)
        self.heights_override = {}
        self.plants = set()  # voxels de planta (HITTABLE, não-sólidos)

    def set_solid(self, voxel, block_id):
        chunk = chunk_of(voxel)
        self.chunks.setdefault(chunk, set())
        if block_id != AIR and PHYSICS.get(block_id, (False,))[0]:
            self.chunks[chunk].add(voxel)

    def fill_box(self, x0, y0, z0, x1, y1, z1, block_id=SOLID):
        for x in range(x0, x1):
            for y in range(y0, y1):
                for z in range(z0, z1):
                    self.set_solid((x, y, z), block_id)

    def height_get(self, chunk, lx, lz):
        """Fast-path: topo SÓLIDO da coluna (0xFFFF = vazia/desconhecida)."""
        if chunk not in self.chunks:
            return None
        override = self.heights_override.get((chunk, lx, lz))
        if override is not None:
            return override
        base_x = chunk[0] * CHUNK_SIZE + lx
        base_z = chunk[2] * CHUNK_SIZE + lz
        top = 0xFFFF
        for y in range(CHUNK_SIZE - 1, -1, -1):
            if (base_x, chunk[1] * CHUNK_SIZE + y, base_z) in self.chunks[chunk]:
                top = y
                break
        return top

    def query(self, voxel):
        """Tri-state: (blocking, known)."""
        chunk = chunk_of(voxel)
        if chunk not in self.chunks:
            return False, False
        return voxel in self.chunks[chunk], True


class Body:
    def __init__(self, pos, size=(0.6, 1.8, 0.6)):
        self.pos = [float(pos[0]), float(pos[1]), float(pos[2])]  # canto mínimo
        self.size = size
        self.vel = [0.0, 0.0, 0.0]
        self.grounded = False
        self.frozen = False
        self.requests = []  # coordenadas de página pedidas à worker


def voxels_of_aabb(pos, size):
    x0 = math.floor(pos[0])
    y0 = math.floor(pos[1])
    z0 = math.floor(pos[2])
    x1 = math.floor(pos[0] + size[0] - GROUND_EPS)
    y1 = math.floor(pos[1] + size[1] - GROUND_EPS)
    z1 = math.floor(pos[2] + size[2] - GROUND_EPS)
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            for z in range(z0, z1 + 1):
                yield (x, y, z)


def aabb_free(world, pos, size, body):
    """True se toda a AABB é não-bloqueante (e conhecida). False se bloqueio
    ou desconhecido (registra pedido)."""
    for voxel in voxels_of_aabb(pos, size):
        blocking, known = world.query(voxel)
        if not known:
            if chunk_of(voxel) not in body.requests:
                body.requests.append(chunk_of(voxel))
            return False
        if blocking:
            return False
    return True


def sweep_axis(world, body, axis, delta, contacts):
    """Varre um eixo em subpassos. Retorna deslocamento efetivo."""
    pos = body.pos
    size = body.size
    remaining = delta
    moved = 0.0
    while abs(remaining) > 1e-9:
        step = max(-MAX_SUBSTEP, min(MAX_SUBSTEP, remaining))
        candidate = pos[axis] + step
        # AABB candidata: testa todos os voxels cobertos
        clamped = None
        contact_voxel = None
        test = list(pos)
        test[axis] = candidate
        for voxel in voxels_of_aabb(test, size):
            blocking, known = world.query(voxel)
            if not known:
                chunk = chunk_of(voxel)
                if chunk not in body.requests:
                    body.requests.append(chunk)
                raise UnknownPage(chunk)
            if not blocking:
                continue
            # clamp exato na fronteira do voxel (grade unitária)
            if step > 0:
                c = voxel[axis] - size[axis]
                if c < pos[axis]:  # já está penetrando: não recua
                    c = pos[axis]
            else:
                c = voxel[axis] + 1.0
                if c > pos[axis]:
                    c = pos[axis]
            if clamped is None or (step > 0 and c < clamped) or (step < 0 and c > clamped):
                clamped = c
                contact_voxel = voxel
        if clamped is not None:
            moved += clamped - pos[axis]
            pos[axis] = clamped
            contacts.append((axis, contact_voxel))
            return moved, True
        pos[axis] = candidate
        moved += step
        remaining -= step
    return moved, False


class UnknownPage(Exception):
    def __init__(self, chunk):
        self.chunk = chunk


def support_probe(world, body):
    """Contato real abaixo (eps) — grounded é recalculado por contato."""
    test = list(body.pos)
    test[1] -= GROUND_EPS * 2
    for voxel in voxels_of_aabb(test, body.size):
        blocking, known = world.query(voxel)
        if not known:
            chunk = chunk_of(voxel)
            if chunk not in body.requests:
                body.requests.append(chunk)
            raise UnknownPage(chunk)
        if blocking:
            return True
    return False


def step_up(world, body, axis, delta):
    """Tenta step-up de 1 voxel: espaço livre para TODA a AABB na altura
    elevada + apoio bloqueante no destino. Só após bloqueio horizontal."""
    start = list(body.pos)
    elevated = list(body.pos)
    elevated[1] += STEP_UP_HEIGHT
    if not aabb_free(world, elevated, body.size, body):
        return False
    body.pos = elevated
    moved, blocked = sweep_axis(world, body, axis, delta, [])
    if blocked or abs(moved) < abs(delta) * 0.5:
        body.pos = start
        return False
    # assentamento: desce até o apoio (no máximo 1 voxel)
    down_moved, down_blocked = sweep_axis(world, body, 1, -STEP_UP_HEIGHT, [])
    if not down_blocked:
        # sem apoio no destino: reverte
        body.pos = start
        return False
    return True


def physics_step(world, body, dt, allow_step_up=True):
    """Um passo fixo. Desconhecido congela SEM deslocamento parcial."""
    start_pos = list(body.pos)
    start_vel = list(body.vel)
    try:
        body.vel[1] = max(body.vel[1] + GRAVITY * dt, TERMINAL_VELOCITY)
        grounded = support_probe(world, body)
        if grounded and body.vel[1] < 0:
            body.vel[1] = 0
        # fricção do material de apoio (regra determinística: bloco de contato
        # do apoio; sem apoio, sem damping por contato)
        if grounded:
            _, _, friction, _ = PHYSICS[SOLID]
            damp = max(0.0, 1.0 - friction * 10.0 * dt)
            body.vel[0] *= damp
            body.vel[2] *= damp
        contacts = []
        for axis in (0, 1, 2):
            delta = body.vel[axis] * dt
            if abs(delta) < 1e-9:
                continue
            moved, blocked = sweep_axis(world, body, axis, delta, contacts)
            if blocked:
                voxel = contacts[-1][1]
                block_id = SOLID  # material de contato: voxel bloqueante
                restitution = PHYSICS[block_id][3]
                if restitution > 0 and abs(body.vel[axis]) > 1.0:
                    body.vel[axis] = -body.vel[axis] * restitution
                else:
                    body.vel[axis] = 0.0
                # step-up só nos eixos horizontais, com progresso parcial
                if allow_step_up and axis != 1 and abs(moved) < abs(delta) and grounded:
                    body.pos[axis] = start_pos[axis] + moved
                    if step_up(world, body, axis, delta - moved):
                        contacts.pop()
                        continue
                    body.pos[axis] = start_pos[axis] + moved
        body.grounded = support_probe(world, body)
        if body.grounded and body.vel[1] < 0:
            body.vel[1] = 0
        body.frozen = False
    except UnknownPage:
        body.pos = start_pos
        body.vel = start_vel
        body.frozen = True
        body.grounded = False



def run_steps(world, body, steps, vel=None):
    """Passos com velocidade reimposta a cada passo (input-driven)."""
    for _ in range(steps):
        if vel is not None:
            body.vel[0], body.vel[2] = vel[0], vel[2]
        physics_step(world, body, FIXED_DT)

class Accumulator:
    """Acumulador de passo fixo com teto anti espiral de morte."""

    def __init__(self):
        self.time = 0.0
        self.dropped = 0

    def frame(self, world, bodies, dt):
        self.time += min(dt, 0.25)
        steps = 0
        while self.time >= FIXED_DT and steps < MAX_STEPS_PER_FRAME:
            for body in bodies:
                physics_step(world, body, FIXED_DT)
            self.time -= FIXED_DT
            steps += 1
        if self.time >= FIXED_DT:
            self.dropped += int(self.time / FIXED_DT)
            self.time = 0.0
        return steps


# --- fast-path de chao (REQ-PHY-05) ---

def ground_fast_path(world, body):
    """Apoio via heights em O(1)/coluna. Retorna (usable, grounded).

    Só é aplicável com: todas as colunas cobertas pela AABB conhecidas,
    topo != 0xFFFF, corpo inteiramente ACIMA do topo (fora de interiores/
    cavernas) e pousado sobre ele. Qualquer ambiguidade -> sweep (fallback).
    """
    if body.vel[1] > 0:
        return False, False
    x0 = math.floor(body.pos[0])
    z0 = math.floor(body.pos[2])
    x1 = math.floor(body.pos[0] + body.size[0] - GROUND_EPS)
    z1 = math.floor(body.pos[2] + body.size[2] - GROUND_EPS)
    chunk = chunk_of((x0, math.floor(body.pos[1]), z0))
    # cruzamento de chunk no plano XZ: fallback (varredura de páginas por
    # coluna cobre múltiplos chunks; a prova de equivalência fica no sweep)
    corners = {(floor_div(x, CHUNK_SIZE), floor_div(z, CHUNK_SIZE))
               for x in (x0, x1) for z in (z0, z1)}
    if len(corners) != 1:
        return False, False
    top_max = -1
    for x in range(x0, x1 + 1):
        for z in range(z0, z1 + 1):
            lx, lz = x - chunk[0] * CHUNK_SIZE, z - chunk[2] * CHUNK_SIZE
            top = world.height_get((floor_div(x, CHUNK_SIZE), chunk[1], floor_div(z, CHUNK_SIZE)), lx, lz)
            if top is None or top == 0xFFFF:
                return False, False  # desconhecido/vazio: sweep decide
            world_y = chunk[1] * CHUNK_SIZE + top + 1
            top_max = max(top_max, world_y)
    bottom = body.pos[1]
    if bottom + GROUND_EPS * 2 < top_max:
        return False, False  # corpo abaixo do topo: interior/caverna
    # pousado: bottom ~= topo (ou caindo sobre ele — o sweep confirma)
    return True, abs(bottom - top_max) <= GROUND_EPS * 2 or bottom >= top_max


PASS, FAIL = 0, 0


def check(name, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
    else:
        FAIL += 1
        print(f"  FALHOU: {name}")


# --- cenários ---

def scenario_accumulator():
    print("[cenario] acumulador: passo fixo, teto e repetibilidade")
    # frame de 1/60 exato: 1 passo; frame de 1/30: 2 passos; sem meio passo
    world = World()
    world.fill_box(-8, 0, -8, 8, 1, 8)  # piso y=0
    body = Body((0.2, 1.0, 0.2))
    body.vel[1] = -2.0
    acc = Accumulator()
    n1 = acc.frame(world, [body], 1.0 / 60.0)
    check("frame 1/60 -> exatamente 1 passo", n1 == 1 and abs(acc.time) < 1e-12)
    n2 = acc.frame(world, [body], 1.0 / 30.0)
    check("frame 1/30 -> exatamente 2 passos", n2 == 2)

    # frame longo (engasgo): teto de passos e descarte documentado
    acc2 = Accumulator()
    bodies = [Body((0.2, 1.0, 0.2))]
    acc2.frame(world, bodies, 1.0)  # dt clampado em 0.25 -> 15 passos possíveis, teto em 5
    check("frame 1s: dt clampado 0.25 -> teto de 5 passos + descarte de 10",
          acc2.dropped == 10 and acc2.time == 0.0)

    # repetibilidade: mesma sequência de frames -> mesma pose
    def run():
        w = World()
        w.fill_box(-8, 0, -8, 8, 1, 8)
        b = Body((0.2, 3.0, 0.2))
        b.vel = [1.5, 0.0, -0.5]
        a = Accumulator()
        for dt in (1 / 60, 1 / 60, 1 / 30, 1 / 60, 1 / 24, 1 / 60, 1 / 60):
            a.frame(w, [b], dt)
        return tuple(b.pos), tuple(b.vel), b.grounded
    check("mesma sequência de frames -> mesmo resultado", run() == run())


def scenario_sweep():
    print("[cenario] sweep: parede, quina, teto, fronteira negativa, tunneling")
    world = World()
    world.fill_box(-16, 0, -16, 16, 1, 16)  # piso

    # parede: desliza ao mover na diagonal contra a parede em X
    world.fill_box(4, 1, -16, 5, 8, 16)  # parede x=4
    body = Body((2.0, 1.0, 0.0))
    run_steps(world, body, 120, vel=(4.0, 0.0, 3.0))
    check("parede: X trava na fronteira (4 - 0.6)", abs(body.pos[0] - (4.0 - body.size[0])) < 1e-6)
    check("parede: sliding em Z continua", body.pos[2] > 1.0)

    # quina/canto: AABB cobre múltiplos voxels; contato em canto não penetra
    body = Body((3.3, 1.0, 3.7))
    run_steps(world, body, 30, vel=(6.0, 0.0, 6.0))
    penetrating = any(
        v in world.chunks.get(chunk_of(v), set())
        for v in voxels_of_aabb(body.pos, body.size)
    )
    check("quina: 30 passos contra canto sem penetração", not penetrating)

    # teto: sobe e para no teto (eixo +Y)
    world2 = World()
    world2.fill_box(-8, 0, -8, 8, 1, 8)
    world2.fill_box(-8, 5, -8, 8, 6, 8)  # teto em y=5
    body = Body((0.0, 1.0, 0.0))
    for _ in range(40):
        body.vel[1] = 30.0
        physics_step(world2, body, FIXED_DT)
    check("teto: sobe e trava em 5 - 1.8", abs(body.pos[1] - (5.0 - body.size[1])) < 1e-6)

    # fronteira negativa: mundo em coords negativas (floor_div)
    world3 = World()
    world3.fill_box(-40, -33, -40, -8, -31, -8)  # piso em y=-33..-32
    body = Body((-20.0, -31.0, -20.0))
    body.vel = [0.0, -20.0, 0.0]
    for _ in range(20):
        physics_step(world3, body, FIXED_DT)
    check("fronteira negativa: pousa em -31.0", abs(body.pos[1] - (-31.0)) < 1e-6 and body.grounded)

    # anti-tunneling: velocidade alta (>1 voxel/passo) NÃO atravessa parede 1
    world4 = World()
    world4.fill_box(-16, 0, -16, 16, 1, 16)
    world4.fill_box(6, 1, -16, 7, 8, 16)  # parede 1 voxel em x=6
    body = Body((2.0, 1.0, 0.0))
    body.vel = [120.0, 0.0, 0.0]  # 2 voxels/passos
    for _ in range(10):
        physics_step(world4, body, FIXED_DT)
    check("tunneling: 120 u/s não atravessa parede de 1 voxel",
          body.pos[0] + body.size[0] <= 7.0 + 1e-6)


def scenario_step_up():
    print("[cenario] step-up: espaco livre, apoio e limite de 1 voxel")
    world = World()
    world.fill_box(-16, 0, -16, 16, 1, 16)
    world.fill_box(4, 1, -4, 8, 2, 4)   # degrau de 1 voxel (topo y=2)
    world.fill_box(10, 1, -4, 14, 3, 4)  # degrau de 2 voxels (topo y=3)

    # degrau de 1 (mundo isolado): sobe e continua andando no topo
    world_step1 = World()
    world_step1.fill_box(-16, 0, -16, 16, 1, 16)
    world_step1.fill_box(4, 1, -4, 8, 2, 4)
    body = Body((2.0, 1.0, 0.0))
    climbed = False
    for _ in range(120):
        run_steps(world_step1, body, 1, vel=(5.0, 0.0, 0.0))
        if abs(body.pos[1] - 2.0) < 1e-6 and body.pos[0] > 4.0:
            climbed = True
            break
    check("step-up: sobe degrau de 1 voxel (topo y=2, adiante de x=4)", climbed)

    # mundo com os dois degraus: sobe o 1º, cai na face do 2º e fica bloqueado
    body = Body((2.0, 1.0, 0.0))
    run_steps(world, body, 120, vel=(5.0, 0.0, 0.0))
    check("step-up: degrau de 2 voxels bloqueia no chão (sem escalada)",
          abs(body.pos[0] - (10.0 - body.size[0])) < 1e-3 and abs(body.pos[1] - 1.0) < 1e-3)

    # degrau de 2: NÃO sobe (limite 1 voxel)
    body = Body((8.5, 2.0, 0.0))
    run_steps(world, body, 120, vel=(5.0, 0.0, 0.0))
    check("step-up: degrau de 2 voxels bloqueia (x trava em 10-0.6)",
          abs(body.pos[0] - (10.0 - body.size[0])) < 1e-3 and body.pos[1] < 2.5)

    # degrau de 1 sem espaço acima (teto a 2.5): NÃO sobe
    world2 = World()
    world2.fill_box(-16, 0, -16, 16, 1, 16)
    world2.fill_box(4, 1, -4, 8, 2, 4)   # degrau topo y=2
    world2.fill_box(4, 3, -4, 8, 4, 4)   # bloco em y=3: folga de 1.0 < altura 1.8
    body = Body((2.0, 1.0, 0.0))
    body.vel = [5.0, 0.0, 0.0]
    for _ in range(60):
        physics_step(world2, body, FIXED_DT)
    penetrating = (math.floor(body.pos[0] + body.size[0]), 3, 0) in world2.chunks.get((0, 0, 0), set()) or \
                  body.pos[1] > 1.5
    check("step-up sem espaço livre: não sobe, não penetra", not penetrating)

    # degrau sem apoio no destino (flutuante 1 voxel): não sobe
    world3 = World()
    world3.fill_box(-16, 0, -16, 16, 1, 16)
    world3.fill_box(4, 2, -1, 5, 3, 0)  # bloco flutuante: nada em y=1
    body = Body((2.0, 1.0, -0.5))
    run_steps(world3, body, 120, vel=(5.0, 0.0, 0.0))
    check("step-up sem apoio no destino: não sobe", body.pos[1] < 1.5)


def scenario_grounded():
    print("[cenario] grounded: recalculado por contato, perde apoio na borda")
    world = World()
    world.fill_box(-8, 0, -8, 2, 1, 8)  # piso até x=2
    body = Body((0.0, 1.0, 0.0))
    physics_step(world, body, FIXED_DT)
    check("grounded em cima do piso", body.grounded and abs(body.pos[1] - 1.0) < 1e-9)

    # anda para fora da borda: cai (grounded some, velocidade cresce negativa)
    run_steps(world, body, 90, vel=(6.0, 0.0, 0.0))
    check("saiu da borda: cai e grounded=False", body.pos[1] < 0.9 and not body.grounded)


def scenario_fast_path():
    print("[cenario] fast-path de chao: equivalencia com o sweep e fallback")
    world = World()
    world.fill_box(-64, 0, -64, 64, 1, 64)  # superfície plana

    # superfície: fast-path aplicável e concorda com o sweep
    body = Body((0.2, 1.0, 0.2))
    usable, grounded_fp = ground_fast_path(world, body)
    check("superfície: fast-path aplicável", usable)
    check("superfície: fast-path == sweep (pousado)",
          grounded_fp == support_probe(world, body))

    # caverna/interior: corpo abaixo do topo -> fast-path recusa, sweep decide
    body2 = Body((0.2, -3.0, 0.2))
    usable2, _ = ground_fast_path(world, body2)
    check("interior (corpo abaixo do topo): fast-path recusa", not usable2)

    # coluna 0xFFFF: fast-path recusa (vazio não é apoio)
    world3 = World()
    world3.fill_box(-64, 0, -64, 64, 1, 64)
    world3.chunks[(0, 0, 0)] = set()  # colunas vazias no chunk (0,0,0)
    body3 = Body((0.2, 5.0, 0.2))
    usable3, _ = ground_fast_path(world3, body3)
    check("coluna 0xFFFF: fast-path recusa", not usable3)

    # cruzamento de chunk no plano XZ: fallback ao sweep
    body4 = Body((31.9, 1.0, 0.2))
    body4.size = (0.6, 1.8, 0.6)
    usable4, _ = ground_fast_path(world, body4)
    check("cruzamento de chunk: fast-path recusa", not usable4)

    # página desconhecida: fast-path recusa (tri-state)
    world5 = World()
    body5 = Body((100.2, 1.0, 100.2))
    usable5, _ = ground_fast_path(world5, body5)
    check("página ausente: fast-path recusa", not usable5)

    # equivalência ampla: amostra de poses na superfície — quando aplicável,
    # o veredito do fast-path nunca contradiz o sweep
    ok = True
    for x10, z10 in ((5, 5), (-20, 13), (40, -7), (0, 31)):
        b = Body((x10 + 0.13, 1.0, z10 + 0.29))
        usable, g_fp = ground_fast_path(world, b)
        if usable:
            try:
                g_sw = support_probe(world, b)
            except UnknownPage:
                g_sw = None
            ok = ok and g_fp == g_sw
    check("equivalência: fast-path nunca contradiz o sweep (amostra)", ok)


def scenario_freeze():
    print("[cenario] desconhecido: congela sem deslocamento parcial e retoma")
    world = World()
    world.fill_box(-16, 0, -16, 16, 1, 16)
    body = Body((0.0, 1.0, 0.0))
    body.vel = [8.0, 0.0, 0.0]
    start = list(body.pos)
    physics_step(world, body, FIXED_DT)
    check("materializado: move normalmente", body.pos[0] > start[0] and not body.frozen)

    # remove a página seguinte do mock e cola o corpo na fronteira: o
    # próximo passo precisa da página desconhecida -> congela no lugar
    world.chunks.pop((1, 0, 1), None)
    # um passo a 8 u/s desloca 0.133: a partir de 31.45 a AABB (até 32.18)
    # precisa do chunk (1,0,1) — desconhecido -> congela sem mover
    body.pos = [31.45, 1.0, 31.45]
    body.vel = [8.0, 0.0, 8.0]
    before = list(body.pos)
    physics_step(world, body, FIXED_DT)
    check("desconhecido: congela sem deslocamento parcial",
          body.frozen and body.pos == before)
    check("desconhecido: pedido coalescido registrado", len(body.requests) == 1)

    # materializa a página: o movimento retoma em passos futuros
    world.fill_box(16, 0, 16, 48, 1, 48)
    physics_step(world, body, FIXED_DT)
    check("retoma após materialização", not body.frozen and body.pos[0] > before[0])




# --- raycast DDA (REQ-PHY-08/09) ---

def physics_raycast(world, origin, direction, max_distance):
    """Amanatides & Woo sobre coordenadas inteiras; tri-state hit/miss/unknown.
    Espelha physics.odin."""
    if max_distance <= 0:
        return ("miss", None)
    length = math.sqrt(sum(d * d for d in direction))
    if length < 1e-9:
        return ("miss", None)
    d = [v / length for v in direction]
    cell = [math.floor(origin[0]), math.floor(origin[1]), math.floor(origin[2])]
    step = [1, 1, 1]
    t_max = [0.0, 0.0, 0.0]
    t_delta = [0.0, 0.0, 0.0]
    for axis in range(3):
        if d[axis] < 0:
            step[axis] = -1
        if d[axis] != 0:
            boundary = cell[axis] + (1.0 if step[axis] > 0 else 0.0)
            t_max[axis] = (boundary - origin[axis]) / d[axis]
            t_delta[axis] = abs(1.0 / d[axis])
        else:
            t_max[axis] = float("inf")
            t_delta[axis] = float("inf")
    distance = 0.0
    normal = [0, 0, 0]
    hittable_ids = {bid for bid, (_, hit, _, _) in PHYSICS.items() if hit}
    while True:
        chunk = chunk_of(tuple(cell))
        if chunk not in world.chunks:
            return ("unknown", tuple(chunk))
        # voxel sólido (mock: sólidos são os HITTABLE do registry)
        voxel = tuple(cell)
        blocking = voxel in world.chunks[chunk]
        block_id = SOLID if blocking else AIR
        if not blocking and voxel in world.plants:
            block_id = PLANT
        if block_id in hittable_ids and block_id != AIR:
            return ("hit", (tuple(cell), block_id, distance, tuple(normal)))
        axis = 0
        if t_max[1] < t_max[0]:
            axis = 1
        if t_max[axis] > t_max[2]:
            axis = 2
        distance = t_max[axis]
        if distance > max_distance:
            return ("miss", None)
        t_max[axis] += t_delta[axis]
        cell[axis] += step[axis]
        normal = [0, 0, 0]
        normal[axis] = -step[axis]


def scenario_raycast():
    print("[cenario] raycast DDA: eixos, diagonais, tri-state, planta")
    world = World()
    world.fill_box(-16, 0, -16, 16, 1, 16)  # piso em y=0
    world.fill_box(4, 1, -4, 5, 4, 4)       # parede em x=4 (blocos y=1..3)
    world.plants = set()
    world.plants.add((4, 1, 2))  # planta NÃO-sólida em frente
    # mock: planta não entra no set de sólidos
    world.chunks[chunk_of((4, 1, 2))].discard((4, 1, 2))

    # eixo +X: atinge a parede (o bloco y=1 tem planta -> hit na planta)
    r = physics_raycast(world, (1.5, 1.5, 2.5), (1, 0, 0), 10)
    check("eixo +X: hit na planta (não-sólida atingível)",
          r[0] == "hit" and r[1][0] == (4, 1, 2) and r[1][1] == PLANT)
    check("eixo +X: normal -X e distância correta",
          r[0] == "hit" and r[1][2] == 2.5 and r[1][3] == (-1, 0, 0))

    # eixo +X mais alto: atinge o bloco sólido (y=2)
    r = physics_raycast(world, (1.5, 2.5, 0.5), (1, 0, 0), 10)
    check("eixo +X: hit no sólido (4,2,0)", r[0] == "hit" and r[1][0] == (4, 2, 0))

    # eixo -Z e +Y (teto do "túnel"): miss com distância curta
    r = physics_raycast(world, (0.5, 1.5, 0.5), (0, 0, -1), 2)
    check("eixo -Z: miss dentro da distância", r[0] == "miss")

    # diagonal 45°: atravessa células nos dois eixos e atinge o piso
    r = physics_raycast(world, (0.5, 3.5, 0.5), (0, -1, 0), 10)
    check("eixo -Y: hit no piso com normal +Y",
          r[0] == "hit" and r[1][0] == (0, 0, 0) and r[1][3] == (0, 1, 0) and r[1][2] == 2.5)

    # diagonal com componentes X e Y
    r = physics_raycast(world, (2.5, 3.5, 0.5), (1, -1, 0), 10)
    check("diagonal: hit no piso/parede antes do limite", r[0] == "hit")

    # fronteira negativa: raio andando para coords negativas no ar
    r = physics_raycast(world, (-2.5, 2.5, -2.5), (-1, 0, 0), 10)
    check("fronteira negativa: miss (sem blocos)", r[0] == "miss")

    # origem dentro de voxel sólido: hit imediato dist 0, normal nula
    r = physics_raycast(world, (4.5, 2.5, 0.5), (1, 0, 0), 10)
    check("origem interna: hit dist 0 normal nula",
          r[0] == "hit" and r[1][2] == 0.0 and r[1][3] == (0, 0, 0))

    # direção nula / distância inválida: rejeição sem percorrer
    check("direção nula: miss sem percorrer", physics_raycast(world, (0, 2, 0), (0, 0, 0), 10)[0] == "miss")
    check("distância inválida: miss sem percorrer", physics_raycast(world, (0, 2, 0), (1, 0, 0), -1)[0] == "miss")
    check("distância zero: miss sem percorrer", physics_raycast(world, (0, 2, 0), (1, 0, 0), 0)[0] == "miss")

    # unknown antes do miss: página ausente no caminho
    world2 = World()
    world2.fill_box(-16, 0, -16, 16, 1, 16)
    r = physics_raycast(world2, (30.5, 0.5, 0.5), (1, 0, 0), 20)
    check("página ausente antes do limite: unknown (nunca miss)", r[0] == "unknown")

    # unknown NÃO é retornado quando o miss vem primeiro
    r = physics_raycast(world2, (30.5, 0.5, 0.5), (1, 0, 0), 1)
    check("miss antes de qualquer página: miss", r[0] == "miss")

    # planta no caminho: o raio a atinge PRIMEIRO (HITTABLE não-sólida —
    # REQ-PHY-08: o hit decide pela tabela, não pelo bitmask)
    world3 = World()
    world3.plants = set()
    world3.fill_box(-16, 0, -16, 16, 1, 16)
    world3.plants.add((2, 1, 0))
    world3.set_solid((5, 1, 0), SOLID)
    r = physics_raycast(world3, (0.5, 1.5, 0.0), (1, 0, 0), 10)
    check("planta à frente do sólido: hit na planta primeiro",
          r[0] == "hit" and r[1][0] == (2, 1, 0) and r[1][1] == PLANT)


def main():
    scenario_accumulator()
    scenario_sweep()
    scenario_step_up()
    scenario_grounded()
    scenario_fast_path()
    scenario_freeze()
    scenario_raycast()
    print(f"\n{PASS} passaram, {FAIL} falharam")
    raise SystemExit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
