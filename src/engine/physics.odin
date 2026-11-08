package engine

// VS-19 (REQ-PHY-02..10; ADR-F1): solver de física de gameplay na CPU sobre
// o mirror C2. Corpos AABB, passo fixo com acumulador, sweep eixo a eixo
// (X→Y→Z) com subdivisão anti-tunneling, sliding, grounded recalculado por
// contato, step-up seguro e fast-path de chão via `heights`. Mundo
// desconhecido congela o corpo (sem deslocamento parcial) e coalesce o
// pedido de página para a worker. Algoritmo espelhado bit a bit por
// tools/sim/physics_sim.py (28 checks).

import "core:log"
import "core:math"
import "core:sync"

PHYSICS_FIXED_DT :: 1.0 / 60.0
PHYSICS_MAX_STEPS_PER_FRAME :: 5 // teto anti espiral de morte (excesso descartado)
PHYSICS_MAX_FRAME_DT :: f32(0.25)     // clamp do dt de frame antes do acumulador
PHYSICS_GRAVITY :: f32(-24.0)
PHYSICS_TERMINAL_VELOCITY :: f32(-60.0)
PHYSICS_MAX_SUBSTEP :: f32(0.4) // < 1 voxel: nunca atravessa um voxel sem teste
PHYSICS_STEP_UP_HEIGHT :: f32(1.0) // limite de 1 voxel por step-up
PHYSICS_GROUND_EPS :: f32(0.0001)
PHYSICS_FRICTION_DAMPING :: f32(10.0) // damping horizontal = friction * 10 * dt

PhysicsBody :: struct {
	position:    [3]f32, // canto mínimo da AABB
	size:        [3]f32,
	velocity:    [3]f32,
	grounded:    bool,
	frozen:      bool, // página desconhecida: congelado no último estado válido
	allow_step_up: bool,
}

PhysicsHandle :: distinct u32
PHYSICS_HANDLE_INVALID :: PhysicsHandle(max(u32))

PhysicsRayResult :: enum u8 {
	HIT,
	MISS,
	UNKNOWN,
}

PhysicsRayHit :: struct {
	result:       PhysicsRayResult,
	voxel:        [3]i32,
	block_id:     u16,
	distance:     f32,
	normal:       [3]i32, // zero quando a origem já está dentro do voxel
	unknown_chunk: ChunkCoordinate,
}

PhysicsManager :: struct {
	bodies:              [dynamic]PhysicsBody,
	free_handles:        [dynamic]PhysicsHandle,
	accumulator:         f32,
	dropped_steps:       u64,
	pending_requests:    map[ChunkCoordinate]struct {}, // coalescido p/ a worker
	// estatísticas (plots Tracy)
	stats_steps:         u64,
	stats_contacts:      u64,
	stats_voxels:        u64,
	stats_frozen_frames: u64,
	unknown_hits:        u64, // monotônico: detecta desconhecido dentro do passo
}

physics_init :: proc(ve: ^VoxelEngine) {
	ve.physics.bodies = make([dynamic]PhysicsBody, 0, 16)
	ve.physics.free_handles = make([dynamic]PhysicsHandle, 0, 16)
	ve.physics.pending_requests = make(map[ChunkCoordinate]struct {})
}

physics_destroy :: proc(ve: ^VoxelEngine) {
	delete(ve.physics.bodies)
	delete(ve.physics.free_handles)
	delete(ve.physics.pending_requests)
}

// --- API pública (REQ-PHY-10): ciclo de vida/consulta de corpos ---

physics_body_create :: proc(ve: ^VoxelEngine, position, size: [3]f32, allow_step_up := true) -> PhysicsHandle {
	body := PhysicsBody {
		position      = position,
		size          = size,
		allow_step_up = allow_step_up,
	}
	if len(ve.physics.free_handles) > 0 {
		handle := pop(&ve.physics.free_handles)
		ve.physics.bodies[int(handle)] = body
		return handle
	}
	append(&ve.physics.bodies, body)
	return PhysicsHandle(len(ve.physics.bodies) - 1)
}

physics_body_remove :: proc(ve: ^VoxelEngine, handle: PhysicsHandle) {
	index := int(handle)
	if index < 0 || index >= len(ve.physics.bodies) do return
	ve.physics.bodies[index] = {}
	append(&ve.physics.free_handles, handle)
}

physics_body_get :: proc(ve: ^VoxelEngine, handle: PhysicsHandle) -> ^PhysicsBody {
	index := int(handle)
	if index < 0 || index >= len(ve.physics.bodies) do return nil
	return &ve.physics.bodies[index]
}

// Tick do acumulador (REQ-PHY-02): avança o estado somente em passos fixos.
physics_tick :: proc(ve: ^VoxelEngine, frame_dt: f32) {
	ZoneN("physics_tick")
	ve.physics.accumulator += min(frame_dt, PHYSICS_MAX_FRAME_DT)
	steps := 0
	for ve.physics.accumulator >= PHYSICS_FIXED_DT && steps < PHYSICS_MAX_STEPS_PER_FRAME {
		for &body in ve.physics.bodies {
			if body.size.x <= 0 do continue // handle removido
			ZoneN("physics_body_step")
			physics_step(ve, &body)
		}
		ve.physics.accumulator -= PHYSICS_FIXED_DT
		steps += 1
	}
	if ve.physics.accumulator >= PHYSICS_FIXED_DT {
		// espiral de morte: descarte documentado do excesso
		ve.physics.dropped_steps += u64(math.floor(ve.physics.accumulator / PHYSICS_FIXED_DT))
		ve.physics.accumulator = 0
	}
	ve.physics.stats_steps += u64(steps)
	if TracingIsConnected() {
		PlotInt("physics_steps", i64(steps))
		PlotInt("physics_bodies", i64(len(ve.physics.bodies) - len(ve.physics.free_handles)))
		PlotInt("physics_contacts", i64(ve.physics.stats_contacts))
		PlotInt("physics_voxels", i64(ve.physics.stats_voxels))
	}
}

// Drena os pedidos coalescidos na worker (chamada sob mirror.mutex pela
// worker em mirror_update_bubble — REQ-PHY-06).
physics_drain_requests :: proc(ve: ^VoxelEngine) {
	for coord in ve.physics.pending_requests {
		if record, active := ve.active_chunks[coord]; active {
			mirror_request_page(ve, coord, record)
		}
	}
	clear(&ve.physics.pending_requests)
}

// --- consulta tri-state ao mundo ---

physics_request_chunk :: proc(ve: ^VoxelEngine, coord: ChunkCoordinate) {
	// coalescido: map dedup; consumido pela worker em physics_drain_requests
	sync.mutex_lock(&ve.mirror.mutex)
	ve.physics.pending_requests[coord] = {}
	sync.mutex_unlock(&ve.mirror.mutex)
}

physics_voxel_query :: proc(ve: ^VoxelEngine, voxel: [3]i32) -> (blocking: bool, known: bool, block_id: u16) {
	sample, ok := voxel_get(ve, voxel)
	if !ok do return false, false, 0
	return block_is_blocking(u32(sample.block_id)), true, sample.block_id
}

@(private)
physics_aabb_voxels :: proc "contextless" (pos, size: [3]f32) -> ([3]i32, [3]i32) {
	epsilon: f32 = PHYSICS_GROUND_EPS
	lo := [3]i32 {
		i32(math.floor(pos.x)),
		i32(math.floor(pos.y)),
		i32(math.floor(pos.z)),
	}
	hi := [3]i32 {
		i32(math.floor(pos.x + size.x - epsilon)),
		i32(math.floor(pos.y + size.y - epsilon)),
		i32(math.floor(pos.z + size.z - epsilon)),
	}
	return lo, hi
}

// Congela e registra o pedido; sinalizado por ok=false no retorno das
// rotinas de varredura (padrão tri-state — nunca presumir ar).
@(private)
physics_unknown :: proc(ve: ^VoxelEngine, voxel: [3]i32) {
	chunk, _ := mirror_chunk_and_local(voxel)
	ve.physics.unknown_hits += 1
	physics_request_chunk(ve, chunk)
}

// AABB inteiramente livre (e conhecida). False também congela o pedido.
@(private)
physics_aabb_free :: proc(ve: ^VoxelEngine, body: ^PhysicsBody, pos: [3]f32) -> bool {
	lo, hi := physics_aabb_voxels(pos, body.size)
	for x in lo.x ..= hi.x {
		for y in lo.y ..= hi.y {
			for z in lo.z ..= hi.z {
				ve.physics.stats_voxels += 1
				blocking, known, _ := physics_voxel_query(ve, {x, y, z})
				if !known {
					physics_unknown(ve, {x, y, z})
					return false
				}
				if blocking do return false
			}
		}
	}
	return true
}

@(private)
physics_sweep_axis :: proc(ve: ^VoxelEngine, body: ^PhysicsBody, axis: int, delta: f32, contacts: ^[dynamic][3]i32) -> (moved: f32, blocked: bool) {
	remaining := delta
	pos := &body.position
	for math.abs(remaining) > 1e-9 {
		step := math.clamp(remaining, -PHYSICS_MAX_SUBSTEP, PHYSICS_MAX_SUBSTEP)
		candidate := pos[axis] + step
		clamped: f32 = 0
		has_clamp := false
		contact: [3]i32
		test := pos^
		test[axis] = candidate
		lo, hi := physics_aabb_voxels(test, body.size)
		scan: for x in lo.x ..= hi.x {
			for y in lo.y ..= hi.y {
				for z in lo.z ..= hi.z {
					ve.physics.stats_voxels += 1
					voxel := [3]i32{x, y, z}
					blocking, known, _ := physics_voxel_query(ve, voxel)
					if !known {
						physics_unknown(ve, voxel)
						// desconhecido: aborta o passo inteiro (freeze)
						return moved, true
					}
					if !blocking do continue
					c: f32
					if step > 0 {
						c = f32(voxel[axis]) - body.size[axis]
						if c < pos[axis] do c = pos[axis]
					} else {
						c = f32(voxel[axis]) + 1.0
						if c > pos[axis] do c = pos[axis]
					}
					if !has_clamp ||
					   (step > 0 && c < clamped) ||
					   (step < 0 && c > clamped) {
						clamped = c
						contact = voxel
						has_clamp = true
					}
				}
			}
		}
		if has_clamp {
			moved += clamped - pos[axis]
			pos[axis] = clamped
			if contacts != nil do append(contacts, contact)
			ve.physics.stats_contacts += 1
			return moved, true
		}
		pos[axis] = candidate
		moved += step
		remaining -= step
	}
	return moved, false
}

// Apoio real abaixo (eps) — grounded é recalculado por contato a cada passo.
@(private)
physics_support_probe :: proc(ve: ^VoxelEngine, body: ^PhysicsBody) -> bool {
	test := body.position
	test.y -= PHYSICS_GROUND_EPS * 2
	lo, hi := physics_aabb_voxels(test, body.size)
	for x in lo.x ..= hi.x {
		for y in lo.y ..= hi.y {
			for z in lo.z ..= hi.z {
				ve.physics.stats_voxels += 1
				blocking, known, _ := physics_voxel_query(ve, {x, y, z})
				if !known {
					physics_unknown(ve, {x, y, z})
					return false
				}
				if blocking do return true
			}
		}
	}
	return false
}

// Fast-path de chão (REQ-PHY-05): apoio via `heights` em O(1)/coluna quando
// TODAS as colunas cobertas pela AABB têm topo conhecido != 0xFFFF, estão no
// mesmo chunk no plano XZ e o corpo está inteiramente acima do topo mais
// alto (fora de interiores/cavernas). Qualquer ambiguidade (0xFFFF, travessia
// de chunk, corpo abaixo do topo, página ausente, deslocamento vertical)
// cai no sweep completo — prova de equivalência em tools/sim/physics_sim.py.
@(private)
physics_ground_probe :: proc(ve: ^VoxelEngine, body: ^PhysicsBody) -> bool {
	ZoneN("physics_ground_probe")
	if body.velocity.y > 0 do return physics_support_probe(ve, body)
	epsilon := f32(PHYSICS_GROUND_EPS)
	x0 := i32(math.floor(body.position.x))
	z0 := i32(math.floor(body.position.z))
	x1 := i32(math.floor(body.position.x + body.size.x - epsilon))
	z1 := i32(math.floor(body.position.z + body.size.z - epsilon))
	chunk_y := floor_div_i32(i32(math.floor(body.position.y)), CHUNK_SIZE)
	chunk_x0 := floor_div_i32(x0, CHUNK_SIZE)
	chunk_x1 := floor_div_i32(x1, CHUNK_SIZE)
	chunk_z0 := floor_div_i32(z0, CHUNK_SIZE)
	chunk_z1 := floor_div_i32(z1, CHUNK_SIZE)
	// travessia de chunk no plano XZ: fallback
	if chunk_x0 != chunk_x1 || chunk_z0 != chunk_z1 do return physics_support_probe(ve, body)
	top_max := f32(min(i32) / 2)
	usable := true
	ZoneN("physics_fastpath_scan")
	for x in x0 ..= x1 {
		for z in z0 ..= z1 {
			local_x := u32(x - chunk_x0 * CHUNK_SIZE)
			local_z := u32(z - chunk_z0 * CHUNK_SIZE)
			ve.physics.stats_voxels += 1
			ok, height := mirror_height_get(ve, {chunk_x0, chunk_y, chunk_z0}, local_x, local_z)
			if !ok || height == 0xFFFF {
				usable = false // desconhecido ou coluna vazia (apoio pode estar
				break           // no chunk de baixo): sweep decide
			}
			world_top := f32(chunk_y * CHUNK_SIZE + i32(height) + 1)
			top_max = max(top_max, world_top)
		}
	}
	if !usable do return physics_support_probe(ve, body)
	// corpo abaixo do topo mais alto: interior/caverna/sobreposição → sweep
	if body.position.y + epsilon < top_max do return physics_support_probe(ve, body)
	if math.abs(body.position.y - top_max) <= epsilon * 2 {
		return true // pousado: mesmo apoio que o sweep mediria
	}
	// acima da superfície (caindo): o contato real é do sweep
	return physics_support_probe(ve, body)
}

// Step-up de 1 voxel: espaço livre para TODA a AABB na altura elevada + apoio
// bloqueante no destino (REQ-PHY-04). Só após bloqueio horizontal.
@(private)
physics_step_up :: proc(ve: ^VoxelEngine, body: ^PhysicsBody, axis: int, delta: f32) -> bool {
	start := body.position
	elevated := body.position
	elevated.y += PHYSICS_STEP_UP_HEIGHT
	if !physics_aabb_free(ve, body, elevated) do return false
	body.position = elevated
	moved, blocked := physics_sweep_axis(ve, body, axis, delta, nil)
	if blocked || math.abs(moved) < math.abs(delta) * 0.5 {
		body.position = start
		return false
	}
	// assentamento: desce até o apoio (no máximo 1 voxel)
	_, down_blocked := physics_sweep_axis(ve, body, 1, -PHYSICS_STEP_UP_HEIGHT, nil)
	if !down_blocked {
		body.position = start // sem apoio no destino: reverte
		return false
	}
	return true
}

@(private)
physics_step :: proc(ve: ^VoxelEngine, body: ^PhysicsBody) {
	dt := f32(PHYSICS_FIXED_DT)
	start_pos := body.position
	start_vel := body.velocity
	start_grounded := body.grounded

	// tri-state: qualquer desconhecido aborta o passo INTEIRO (freeze sem
	// deslocamento parcial — REQ-PHY-06). physics_unknown incrementa o
	// contador monotônico unknown_hits; qualquer incremento dentro do passo
	// reverte tudo (o map de pedidos é coalescido, não serve de marcador).
	unknown_before := ve.physics.unknown_hits

	body.velocity.y = max(body.velocity.y + PHYSICS_GRAVITY * dt, PHYSICS_TERMINAL_VELOCITY)
	grounded := physics_ground_probe(ve, body)
	if grounded && body.velocity.y < 0 do body.velocity.y = 0
	if grounded {
		// material neutro padrão (o probe de apoio não devolve id; a regra de
		// combinação determinística usa a definição do bloco de contato nas
		// respostas — a fricção de apoio usa o default documentado)
		friction := f32(PHYSICS_DEFAULT_FRICTION)
		damp := max(0.0, 1.0 - friction * PHYSICS_FRICTION_DAMPING * dt)
		body.velocity.x *= damp
		body.velocity.z *= damp
	}
	contacts: [dynamic][3]i32
	defer delete(contacts)
	for axis in 0 ..= 2 {
		delta := body.velocity[axis] * dt
		if math.abs(delta) < 1e-9 do continue
		contacts_before := len(contacts)
		moved, blocked := physics_sweep_axis(ve, body, axis, delta, &contacts)
		if !blocked do continue
		if len(contacts) == contacts_before {
			continue // abortado por página desconhecida: o freeze ao fim do passo reverte tudo
		}
		// material de contato: definição física do voxel bloqueante
		contact := contacts[len(contacts) - 1]
		_, _, block_id := physics_voxel_query(ve, contact)
		restitution := voxel_physics[u32(block_id)].restitution
		if restitution > 0 && math.abs(body.velocity[axis]) > 1.0 {
			body.velocity[axis] = -body.velocity[axis] * restitution
		} else {
			body.velocity[axis] = 0
		}
		// step-up só nos eixos horizontais, com progresso parcial e apoio
		if body.allow_step_up && axis != 1 && math.abs(moved) < math.abs(delta) && grounded {
			body.position[axis] = start_pos[axis] + moved
			if physics_step_up(ve, body, axis, delta - moved) {
				unordered_remove(&contacts, len(contacts) - 1)
				continue
			}
			body.position[axis] = start_pos[axis] + moved
		}
	}
	body.grounded = physics_ground_probe(ve, body)
	if body.grounded && body.velocity.y < 0 do body.velocity.y = 0

	if ve.physics.unknown_hits > unknown_before {
		// mundo desconhecido: descarta o passo INTEIRO e congela
		ZoneN("physics_freeze")
		body.position = start_pos
		body.velocity = start_vel
		body.grounded = start_grounded
		body.frozen = true
		ve.physics.stats_frozen_frames += 1
		return
	}
	body.frozen = false
}

// --- Raycast DDA (REQ-PHY-08/09): Amanatides & Woo, resultado tri-state ---

// Distância máxima obrigatória (> 0) e direção não nula; caso contrário o
// resultado é MISS sem percorrer a grade (rejeição definida).
physics_raycast :: proc(ve: ^VoxelEngine, origin, direction: [3]f32, max_distance: f32) -> PhysicsRayHit {
	ZoneN("physics_raycast")
	if max_distance <= 0 do return PhysicsRayHit{result = .MISS}
	length := math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
	if length < 1e-9 do return PhysicsRayHit{result = .MISS}
	dir := direction / length

	cell := [3]i32 {
		i32(math.floor(origin.x)),
		i32(math.floor(origin.y)),
		i32(math.floor(origin.z)),
	}
	step := [3]i32{1, 1, 1}
	t_max: [3]f32
	t_delta: [3]f32
	for axis in 0 ..= 2 {
		if dir[axis] < 0 do step[axis] = -1
		if dir[axis] != 0 {
			boundary := f32(cell[axis]) + (step[axis] > 0 ? 1.0 : 0.0)
			t_max[axis] = (boundary - origin[axis]) / dir[axis]
			t_delta[axis] = math.abs(1.0 / dir[axis])
		} else {
			t_max[axis] = max(f32) / 4
			t_delta[axis] = max(f32) / 4
		}
	}

	// origem dentro de voxel: primeira célula testada é a da origem
	distance: f32 = 0
	normal := [3]i32{0, 0, 0}
	for {
		ve.physics.stats_voxels += 1
		sample, ok := voxel_get(ve, cell)
		if !ok {
			// página ausente/em readback ANTES do limite: unknown (nunca miss)
			chunk, _ := mirror_chunk_and_local(cell)
			physics_request_chunk(ve, chunk)
			return PhysicsRayHit{result = .UNKNOWN, unknown_chunk = chunk, distance = distance}
		}
		if block_is_hittable(u32(sample.block_id)) {
			return PhysicsRayHit {
				result = .HIT,
				voxel = cell,
				block_id = sample.block_id,
				distance = distance,
				normal = normal,
			}
		}
		// avança para a próxima célula atravessada
		axis := 0
		if t_max.y < t_max.x do axis = 1
		if t_max[axis] > t_max.z do axis = 2
		distance = t_max[axis]
		if distance > max_distance do break
		t_max[axis] += t_delta[axis]
		cell[axis] += step[axis]
		normal = {0, 0, 0}
		normal[axis] = -step[axis]
	}
	return PhysicsRayHit{result = .MISS}
}
