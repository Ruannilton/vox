package engine

// VS-12 (REQ-AST-01..06, REQ-VAL-07): assets data-driven via JSON.
// `assets/blocks.json` define meshes reaproveitáveis, texturas (PNG única) e
// blocos por nome. Parse + validação rodam ANTES de CreateEngine; o resultado
// é consumido no init do motor de voxels. Ausente → warning + built-ins (paridade).

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"

ASSETS_DEFAULT_PATH :: "assets/blocks.json"

// Pools de templates têm capacidade fixa (buffers criados em voxel_gpu_init).
VERTEX_POOL_CAPACITY   :: 1024
TRIANGLE_POOL_CAPACITY :: 1024
UV_POOL_CAPACITY       :: 1024
MAX_ASSET_TEXTURE_DIM  :: 256

// VS-19 (REQ-PHY-01): tabela física exclusivamente CPU-side — o std430 de
// BlockDefinition (48 B) NÃO muda e nenhuma propriedade física vai ao shader.
PHYSICS_FLAG_BLOCKING  :: 1
PHYSICS_FLAG_HITTABLE  :: 2
PHYSICS_FLAG_CLIMBABLE :: 4 // reservado (líquidos/escaláveis fora de escopo)
PHYSICS_FLAG_LIQUID    :: 8 // reservado

// Defaults documentados (REQ-PHY-01): blocking deriva da solidez do tipo;
// hittable = true para qualquer bloco não-ar; fricção/restituição neutras.
PHYSICS_DEFAULT_FRICTION     :: 0.6
PHYSICS_DEFAULT_RESTITUTION  :: 0.0

PhysicsDefinition :: struct {
	flags:       u32,
	friction:    f32,
	restitution: f32,
}

VoxelAssets :: struct {
	loaded:      bool,
	templates:   []MeshTemplate, // inclui slot 0 (AR) na posição 0
	vertices:    [][4]f32,
	triangles:   []u32, // packed com cull tag nos bits 24–26
	uvs:         [][2]f32, // só malhas com UVs; indexado por uv_offset
	registry:    [BLOCK_REGISTRY_CAPACITY]BlockDefinition,
	block_names: []string, // por id ("" quando o id não tem bloco)
	texture_pixels: []u8, // RGBA8, w*h*4*layers (ordem de definição)
	texture_width:  u32,
	texture_height: u32,
	texture_layers: u32,
	layer_of:       map[string]int, // nome de textura → camada (privado ao build)
	// VS-21 (REQ-TEX-09): contadores de decode (zone assets_texture_decode)
	stats_textures_decoded: u64,
	stats_texture_bytes:    u64,
	stats_decode_ms:        f64,
}

// VS-19 (REQ-PHY-01): tabela física por id, paralela ao registry std430.
voxel_physics: [BLOCK_REGISTRY_CAPACITY]PhysicsDefinition

voxel_assets: VoxelAssets

assets_json_mesh :: struct {
	name:      string `json:"name"`,
	vertices:  [][3]f64 `json:"vertices"`,
	triangles: [][3]i64 `json:"triangles"`,
	cull_tags: []i64 `json:"cull_tags"`,
	uvs:       [][2]f64 `json:"uvs"`,
}

assets_json_texture :: struct {
	name: string `json:"name"`,
	path: string `json:"path"`,
}

assets_json_block :: struct {
	id:         i64 `json:"id"`,
	name:       string `json:"name"`,
	mesh:       string `json:"mesh"`,
	// VS-14 (REQ-PLT-01): opcional; tipo errado falha o unmarshal (fatal).
	transparent: bool `json:"transparent"`,
	// VS-14 (emenda): opcional, default true; false marca NON_SOLID (planta).
	solid: Maybe(bool) `json:"solid"`,
	// VS-19 (REQ-PHY-01): opcional; objeto validado campo a campo em
	// assets_parse_physics (tipos/flags/materiais citam o bloco).
	physics: json.Value `json:"physics"`,
	// VS-21 (REQ-TEX-04): string ou objeto de 6 faces — parse manual em
	// assets_parse_texture_faces (json.Value captura os dois formatos).
	texture: json.Value `json:"texture"`,
}

asset_tex_dim :: struct {
	name:   string,
	width:  int,
	height: int,
}

assets_json_doc :: struct {
	meshes:   []assets_json_mesh `json:"meshes"`,
	textures: []assets_json_texture `json:"textures"`,
	blocks:   []assets_json_block `json:"blocks"`,
}

// Carga + validação (REQ-AST-06). Ausente → loaded = false (fallback).
assets_load :: proc() {
	path := ASSETS_DEFAULT_PATH
	data, ferr := os.read_entire_file_from_path(path, context.allocator)
	if ferr != nil {
		log.warnf(
			"{} não encontrado; usando built-ins (templates cubo/planta, registry ids 1..3, paleta procedural)",
			path,
		)
		physics_init_builtin()
		return
	}

	doc: assets_json_doc
	unmarshal_err := json.unmarshal(data, &doc, allocator = context.allocator)
	if unmarshal_err != nil {
		assets_fatal("{}: JSON inválido: {}", path, unmarshal_err)
	}

	assets_build_meshes(&doc)
	assets_build_textures(&doc, path)
	assets_build_blocks(&doc)

	voxel_assets.loaded = true
	// VS-21 (REQ-TEX-09): contagem de decode dentro da zone
	// assets_texture_decode; resumo com texturas/bytes.
	log.infof(
		"VS-12: assets carregados de {} — {} malhas, {} texturas ({}x{}x{}), {} blocos | VS-21: {} texturas decodificadas, {} bytes",
		path,
		len(voxel_assets.templates) - 1,
		voxel_assets.texture_layers,
		voxel_assets.texture_width,
		voxel_assets.texture_height,
		voxel_assets.texture_layers,
		len(doc.blocks),
		voxel_assets.stats_textures_decoded,
		voxel_assets.stats_texture_bytes,
	)
	log.infof("VS-21: decode/flip de texturas em {:.2f} ms (zone assets_texture_decode no upload)", voxel_assets.stats_decode_ms)
}

// VS-14 (emenda 2026-11-07): solidez é propriedade do tipo de bloco. Com
// assets, consulta o registry carregado; sem assets, a regra built-in
// (ids 1..3 sólidos, 4 = planta não-sólida).
block_is_solid :: proc "contextless" (block_id: u32) -> bool {
	if block_id == 0 do return false
	if voxel_assets.loaded {
		return voxel_assets.registry[block_id].flags & BLOCK_DEFINITION_FLAG_NON_SOLID == 0
	}
	return block_id != 4
}

// VS-19 (REQ-PHY-01): o bitmask `solid` filtra candidatos; a semântica de
// bloqueio vem da tabela física (planta ocupa o voxel sem bloquear).
block_is_blocking :: proc "contextless" (block_id: u32) -> bool {
	return voxel_physics[block_id].flags & PHYSICS_FLAG_BLOCKING != 0
}

block_is_hittable :: proc "contextless" (block_id: u32) -> bool {
	return voxel_physics[block_id].flags & PHYSICS_FLAG_HITTABLE != 0
}

// VS-21 (REQ-TEX-02): inverte as linhas de um buffer RGBA8 (stride w·4),
// trocando y com height−1−y. Dupla aplicação restaura a entrada.
flip_rows :: proc(pixels: []u8, width, height: int) {
	stride := width * 4
	row := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< height / 2 {
		opposite := (height - 1 - y) * stride
		base := y * stride
		copy(row, pixels[base:base + stride])
		copy(pixels[base:base + stride], pixels[opposite:opposite + stride])
		copy(pixels[opposite:opposite + stride], row)
	}
}

// Fallback built-in (REQ-PHY-01): paridade semântica com o caminho do JSON —
// ids 1..3 bloqueantes e atingíveis, planta (4) não-bloqueante e atingível,
// fricção/restituição nos defaults documentados.
physics_init_builtin :: proc "contextless" () {
	for id in 1 ..= 3 {
		voxel_physics[id] = PhysicsDefinition{
			flags = PHYSICS_FLAG_BLOCKING | PHYSICS_FLAG_HITTABLE,
			friction = PHYSICS_DEFAULT_FRICTION,
			restitution = PHYSICS_DEFAULT_RESTITUTION,
		}
	}
	voxel_physics[4] = PhysicsDefinition{
		flags = PHYSICS_FLAG_HITTABLE,
		friction = PHYSICS_DEFAULT_FRICTION,
		restitution = PHYSICS_DEFAULT_RESTITUTION,
	}
}

@(private)
assets_build_meshes :: proc(doc: ^assets_json_doc) {
	if len(doc.meshes) > MESH_TEMPLATE_CAPACITY {
		assets_fatal("mais de {} malhas (templates)", MESH_TEMPLATE_CAPACITY)
	}

	templates := make([dynamic]MeshTemplate, 0, len(doc.meshes) + 1, context.allocator)
	append(&templates, MeshTemplate{uv_offset = NO_TEMPLATE_UV_OFFSET}) // 0 = AR
	vertices := make([dynamic][4]f32, 0, VERTEX_POOL_CAPACITY, context.allocator)
	triangles := make([dynamic]u32, 0, TRIANGLE_POOL_CAPACITY, context.allocator)
	uvs := make([dynamic][2]f32, 0, UV_POOL_CAPACITY, context.allocator)

	mesh_names := make(map[string]int, len(doc.meshes), context.allocator)

	for mesh, i in doc.meshes {
		ctx := fmt_mesh_where(mesh.name, i)
		if mesh.name == "" {
			assets_fatal("malha[{}]: campo 'name' ausente ou vazio", i)
		}
		if mesh.name in mesh_names {
			assets_fatal("{}: nome duplicado", ctx)
		}
		mesh_names[mesh.name] = i + 1
		if len(mesh.vertices) == 0 {
			assets_fatal("{}: campo 'vertices' ausente ou vazio", ctx)
		}
		if len(mesh.triangles) == 0 {
			assets_fatal("{}: campo 'triangles' ausente ou vazio", ctx)
		}

		// --- validações (mesmas regras do validate_template/validate_template_uvs,
		// agora com nome do objeto e índice na mensagem) ---
		if len(mesh.vertices) > MAX_TEMPLATE_VERTICES {
			assets_fatal("{}: {} vértices excede o máximo de {}", ctx, len(mesh.vertices), MAX_TEMPLATE_VERTICES)
		}
		if len(mesh.triangles) > MAX_TEMPLATE_TRIANGLES {
			assets_fatal("{}: {} triângulos excede o máximo de {}", ctx, len(mesh.triangles), MAX_TEMPLATE_TRIANGLES)
		}
		for v, j in mesh.vertices {
			if v.x < 0 || v.x > 1 || v.y < 0 || v.y > 1 || v.z < 0 || v.z > 1 {
				assets_fatal("{}: vértice {} fora de [0,1]³: ({}, {}, {})", ctx, j, v.x, v.y, v.z)
			}
		}
		has_uvs := mesh.uvs != nil
		if has_uvs && len(mesh.uvs) != len(mesh.vertices) {
			assets_fatal("{}: {} UVs para {} vértices", ctx, len(mesh.uvs), len(mesh.vertices))
		}
		packed: []u32 = make([]u32, len(mesh.triangles), context.temp_allocator)
		has_flush_faces := false
		for t, j in mesh.triangles {
			for idx in t {
				if idx < 0 || idx >= i64(len(mesh.vertices)) {
					assets_fatal("{}: triângulo {} índice {} fora do range 0..{}", ctx, j, idx, len(mesh.vertices) - 1)
				}
			}
			tag := u32(CULL_FACE_NEVER)
			if mesh.cull_tags != nil {
				if len(mesh.cull_tags) != len(mesh.triangles) {
					assets_fatal("{}: {} cull_tags para {} triângulos", ctx, len(mesh.cull_tags), len(mesh.triangles))
				}
				raw := mesh.cull_tags[j]
				if (raw >= 0 && raw <= 5) || raw == CULL_FACE_NEVER {
					tag = u32(raw)
				} else {
					assets_fatal("{}: cull_tag do triângulo {} inválido: {} (esperado 0..5 ou {})", ctx, j, raw, CULL_FACE_NEVER)
				}
			}
			if tag <= 5 do has_flush_faces = true
			packed[j] = pack_template_triangle(u32(t.x), u32(t.y), u32(t.z), tag)
		}
		worst := compute_worst_case_tris(packed)
		if worst > MAX_TEMPLATE_TRIANGLES {
			assets_fatal("{}: pior caso de {} triângulos excede o máximo de {} (culling direcional)", ctx, worst, MAX_TEMPLATE_TRIANGLES)
		}
		if has_uvs {
			for uv, j in mesh.uvs {
				if uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 {
					assets_fatal("{}: UV do vértice {} fora de [0,1]²: ({}, {})", ctx, j, uv.x, uv.y)
				}
			}
		}

		// --- formatação (REQ-AST-02): append nos pools ---
		if len(vertices) + len(mesh.vertices) > VERTEX_POOL_CAPACITY {
			assets_fatal("pools de template excedem a capacidade de {} vértices ({} no total)", VERTEX_POOL_CAPACITY, len(vertices) + len(mesh.vertices))
		}
		if len(triangles) + len(packed) > TRIANGLE_POOL_CAPACITY {
			assets_fatal("pools de template excedem a capacidade de {} triângulos ({} no total)", TRIANGLE_POOL_CAPACITY, len(triangles) + len(packed))
		}
		uv_offset := u32(NO_TEMPLATE_UV_OFFSET)
		if has_uvs {
			if len(uvs) + len(mesh.uvs) > UV_POOL_CAPACITY {
				assets_fatal("pool de UVs excede a capacidade de {} entradas ({} no total)", UV_POOL_CAPACITY, len(uvs) + len(mesh.uvs))
			}
			uv_offset = u32(len(uvs))
			for uv in mesh.uvs do append(&uvs, [2]f32{f32(uv.x), f32(uv.y)})
		}
		flags := u32(0)
		if has_flush_faces do flags = TEMPLATE_FLAG_HAS_FLUSH_FACES
		append(
			&templates,
			MeshTemplate {
				vertex_offset = u32(len(vertices)),
				vertex_count = u32(len(mesh.vertices)),
				triangle_offset = u32(len(triangles)),
				triangle_count = u32(len(packed)),
				worst_case_tris = worst,
				flags = flags,
				uv_offset = uv_offset,
			},
		)
		for v in mesh.vertices do append(&vertices, [4]f32{f32(v.x), f32(v.y), f32(v.z), 0})
		for t in packed do append(&triangles, t)
	}

	voxel_assets.templates = templates[:]
	voxel_assets.vertices = vertices[:]
	voxel_assets.triangles = triangles[:]
	voxel_assets.uvs = uvs[:]
}

@(private)
assets_build_textures :: proc(doc: ^assets_json_doc, json_path: string) {
	decode_start := time.tick_now()
	if len(doc.textures) > ALBEDO_PALETTE_LAYERS {
		assets_fatal("mais de {} texturas", ALBEDO_PALETTE_LAYERS)
	}

	names := make(map[string]int, len(doc.textures), context.temp_allocator)
	layer_of := make(map[string]int, len(doc.textures), context.temp_allocator)
	dims := make([dynamic]asset_tex_dim, 0, len(doc.textures), context.temp_allocator)
	ref_width, ref_height := 0, 0
	pixels: []u8

	base_dir := "."
	if index := strings.last_index(json_path, "/"); index >= 0 {
		base_dir = json_path[:index]
	}

	for tex, i in doc.textures {
		if tex.name == "" {
			assets_fatal("textura[{}]: campo 'name' ausente ou vazio", i)
		}
		ctx := fmt.tprintf("textura '%v'", tex.name)
		if tex.name in names do assets_fatal("{}: nome duplicado", ctx)
		names[tex.name] = i
		if tex.path == "" {
			assets_fatal("{}: campo 'path' ausente ou vazio", ctx)
		}

		full := tex.path
		if base_dir != "." {
			full = strings.concatenate({base_dir, "/", tex.path}, context.temp_allocator)
		}
		data, ferr := os.read_entire_file_from_path(full, context.temp_allocator)
		if ferr != nil {
			assets_fatal("{}: PNG não encontrado: {}", ctx, tex.path)
		}
		// VS-21 (REQ-TEX-01/02): stb_image normaliza tudo para RGBA8;
		// flip_rows explícito pós-decode corrige a orientação vertical
		// (nem o decoder antigo nem o upload invertiam linhas).
		w, h: c.int
		channels_in_file: c.int
		decoded := stbi.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels_in_file, 4)
		if decoded == nil {
			assets_fatal("{}: falha ao decodificar {}: {}", ctx, tex.path, stbi.failure_reason())
		}
		defer stbi.image_free(decoded)
		if w <= 0 || h <= 0 || w > c.int(MAX_ASSET_TEXTURE_DIM) || h > c.int(MAX_ASSET_TEXTURE_DIM) {
			assets_fatal("{}: dimensões inválidas em {} ({}x{})", ctx, tex.path, w, h)
		}
		voxel_assets.stats_textures_decoded += 1
		voxel_assets.stats_texture_bytes += u64(w * h * 4)
		layer_size := int(w) * int(h) * 4
		layer_pixels := make([]u8, layer_size, context.temp_allocator)
		mem.copy(raw_data(layer_pixels), decoded, layer_size)
		flip_rows(layer_pixels, int(w), int(h))
		if ref_width == 0 {
			ref_width, ref_height = int(w), int(h)
		}
		append(&dims, {name = tex.name, width = int(w), height = int(h)})

		if pixels == nil {
			pixels = make([]u8, layer_size * len(doc.textures), context.allocator)
		}
		dst := pixels[i * layer_size:]
		mem.copy(raw_data(dst), raw_data(layer_pixels), layer_size)
		layer_of[tex.name] = i
	}

	// dimensões uniformes entre todas as PNGs (erro listando as encontradas)
	divergent := false
	for d in dims {
		if d.width != ref_width || d.height != ref_height do divergent = true
	}
	if divergent {
		parts := make([dynamic]string, 0, len(dims), context.temp_allocator)
		for d in dims {
			append(&parts, fmt.tprintf("{} {}x{}", d.name, d.width, d.height))
		}
		assets_fatal("texturas com dimensões divergentes: {}", strings.join(parts[:], ", ", context.temp_allocator))
	}

	voxel_assets.texture_pixels = pixels
	voxel_assets.stats_decode_ms = time.duration_milliseconds(time.tick_since(decode_start))
	voxel_assets.texture_width = u32(ref_width)
	voxel_assets.texture_height = u32(ref_height)
	voxel_assets.texture_layers = u32(len(doc.textures))
	voxel_assets.layer_of = layer_of
}

@(private)
assets_build_blocks :: proc(doc: ^assets_json_doc) {
	// índice das malhas por nome (templates 1-based, na ordem de definição)
	mesh_index := make(map[string]u32, len(doc.meshes), context.temp_allocator)
	for mesh, i in doc.meshes {
		mesh_index[mesh.name] = u32(i + 1)
	}

	voxel_assets.block_names = make([]string, BLOCK_REGISTRY_CAPACITY, context.allocator)
	seen: map[i64]string
	defer delete(seen)
	for block, i in doc.blocks {
		ctx := fmt.tprintf("bloco[%v]", i)
		if block.name == "" {
			assets_fatal("{}: campo 'name' ausente ou vazio", ctx)
		}
		ctx = fmt.tprintf("bloco '%v'", block.name)
		if block.id == 0 {
			assets_fatal("{}: id 0 é reservado (AR) e não pode ser definido", ctx)
		}
		if block.id < 0 || block.id > 255 {
			assets_fatal("{}: id {} fora do intervalo 1..255", ctx, block.id)
		}
		if prev, ok := seen[block.id]; ok {
			assets_fatal("{}: id {} duplicado (já usado por '{}')", ctx, block.id, prev)
		}
		seen[block.id] = block.name
		if block.mesh == "" {
			assets_fatal("{}: campo 'mesh' ausente ou vazio", ctx)
		}
		mesh_index_value, ok := mesh_index[block.mesh]
		if !ok {
			assets_fatal("{}: malha '{}' não encontrada", ctx, block.mesh)
		}
		// VS-21 (REQ-TEX-04): string normalizada para o objeto de 6 faces
		// iguais — internamente só existe a representação de objeto.
		albedo_faces := assets_parse_texture_faces(ctx, block.texture, voxel_assets.layer_of)
		flags: u32 = block.transparent ? BLOCK_DEFINITION_FLAG_TRANSPARENT : 0
		if block.solid != nil && block.solid.? == false {
			flags |= BLOCK_DEFINITION_FLAG_NON_SOLID
		}
		voxel_assets.registry[block.id] = BlockDefinition {
			mesh_template_index = mesh_index_value,
			pbr_texture_index   = 0, // dummy PBR
			flags               = flags,
			albedo_faces        = albedo_faces,
		}
		voxel_assets.block_names[block.id] = strings.clone(block.name, context.allocator)
		// VS-19 (REQ-PHY-01): defaults do tipo (blocking = solidez, hittable =
		// true) + objeto opcional por bloco, validado citando o bloco.
		physics_default: u32 = PHYSICS_FLAG_HITTABLE
		if block.solid == nil || block.solid.? {
			physics_default |= PHYSICS_FLAG_BLOCKING
		}
		voxel_physics[block.id] = assets_parse_physics(ctx, block.physics, physics_default)
		if block.id == 1 {
			names := [6]string{face_names_face(voxel_assets.registry[1].albedo_faces[0]), face_names_face(voxel_assets.registry[1].albedo_faces[1]), face_names_face(voxel_assets.registry[1].albedo_faces[2]), face_names_face(voxel_assets.registry[1].albedo_faces[3]), face_names_face(voxel_assets.registry[1].albedo_faces[4]), face_names_face(voxel_assets.registry[1].albedo_faces[5])}
			log.infof("VS-21 grama albedo_faces FACE_NORMALS(+X,-X,+Y,-Y,+Z,-Z) = {} -> camadas {}", voxel_assets.registry[1].albedo_faces, names)
		}
	}

	// VS-14 (REQ-PLT-05): contrato do worldgen exige ids 1..4 (planta = 4).
	missing := make([dynamic]string, 0, 4, context.temp_allocator)
	for id in 1 ..= 4 {
		if voxel_assets.block_names[id] == "" {
			append(&missing, fmt.tprintf("{}", id))
		}
	}
	if len(missing) > 0 {
		assets_fatal("blocos obrigatórios do worldgen ausentes: ids {}", strings.join(missing[:], ", ", context.temp_allocator))
	}

	// VS-19 (REQ-PHY-01): invariantes da tabela física — ar (id 0) nunca
	// bloqueia nem é atingível; a planta padrão (4, NON_SOLID) é
	// não-bloqueante e atingível. BlockDefinition/std430 inalterado (48 B,
	// #assert em voxel_types.odin).
	log.assert(voxel_physics[0].flags == 0, "tabela física: id 0 (AR) deve ser não-bloqueante e não-atingível")
	if voxel_assets.registry[4].flags & BLOCK_DEFINITION_FLAG_NON_SOLID != 0 {
		log.assert(
			!block_is_blocking(4) && block_is_hittable(4),
			"tabela física: planta (id 4) deve ser não-bloqueante e atingível",
		)
	}
}


@(private)
TEXTURE_FACE_KEYS :: [6]string{"top", "bottom", "front", "back", "left", "right"}

@(private)
face_names_face :: proc(layer: u32) -> string {
	for name, index in voxel_assets.layer_of {
		if u32(index) == layer do return name
	}
	return "?"
}

// VS-21 (REQ-TEX-04): ordena as faces do objeto para albedo_faces[6] na
// ordem FACE_NORMALS (+X=right, -X=left, +Y=top, -Y=bottom, +Z=front,
// -Z=back). String vira o objeto com as 6 faces iguais.
TEXTURE_FACE_TO_SLOT :: [6]int{2, 3, 4, 5, 1, 0} // top,bottom,front,back,left,right -> slot FACE_NORMALS (+X=0,-X=1,+Y=2,-Y=3,+Z=4,-Z=5)

@(private)
assets_parse_texture_faces :: proc(ctx: string, value: json.Value, layer_of: map[string]int) -> [6]u32 {
	faces: [6]u32
	face_names: [6]string
	if string_value, is_string := value.(string); is_string {
		if string_value == "" {
			assets_fatal("{}: campo 'texture' ausente ou vazio", ctx)
		}
		for i in 0 ..< 6 do face_names[i] = string_value
	} else if object, is_object := value.(json.Object); is_object {
		if len(object) != 6 {
			assets_fatal("{}: objeto 'texture' deve ter exatamente as 6 faces top/bottom/front/back/left/right (recebido {} chaves)", ctx, len(object))
		}
		face_to_slot := TEXTURE_FACE_TO_SLOT
		for key, i in TEXTURE_FACE_KEYS {
			face_value, present := object[key]
			if !present {
				assets_fatal("{}: objeto 'texture' sem a face '{}'", ctx, key)
			}
			face_string, is_face_string := face_value.(string)
			if !is_face_string || face_string == "" {
				assets_fatal("{}: 'texture.{}' deve ser string não vazia", ctx, key)
			}
			face_names[face_to_slot[i]] = face_string
		}
	} else {
		assets_fatal("{}: campo 'texture' deve ser string ou objeto de 6 faces", ctx)
	}
	for i in 0 ..< 6 {
		layer, found := layer_of[face_names[i]]
		if !found {
			assets_fatal("{}: textura '{}' não encontrada (face {})", ctx, face_names[i], i)
		}
		faces[i] = u32(layer)
	}
	return faces
}

@(private)
assets_parse_physics :: proc(ctx: string, value: json.Value, default_flags: u32) -> PhysicsDefinition {
	definition := PhysicsDefinition {
		flags       = default_flags,
		friction    = PHYSICS_DEFAULT_FRICTION,
		restitution = PHYSICS_DEFAULT_RESTITUTION,
	}
	if value == nil do return definition
	object, is_object := value.(json.Object)
	if !is_object {
		assets_fatal("{}: campo 'physics' deve ser um objeto (recebido {})", ctx, variant_type_name(value))
	}
	for key, field in object {
		switch key {
		case "blocking":
			v, ok := field.(bool)
			if !ok do assets_fatal("{}: 'physics.blocking' deve ser booleano", ctx)
			if v do definition.flags |= PHYSICS_FLAG_BLOCKING
			else do definition.flags &= ~u32(PHYSICS_FLAG_BLOCKING)
		case "hittable":
			v, ok := field.(bool)
			if !ok do assets_fatal("{}: 'physics.hittable' deve ser booleano", ctx)
			if v do definition.flags |= PHYSICS_FLAG_HITTABLE
			else do definition.flags &= ~u32(PHYSICS_FLAG_HITTABLE)
		case "friction":
			v, ok := json_number(field)
			if !ok do assets_fatal("{}: 'physics.friction' deve ser número", ctx)
			if v < 0 do assets_fatal("{}: 'physics.friction' = {} fora do limite documentado (≥ 0)", ctx, v)
			definition.friction = f32(v)
		case "restitution":
			v, ok := json_number(field)
			if !ok do assets_fatal("{}: 'physics.restitution' deve ser número", ctx)
			if v < 0 || v > 1 do assets_fatal("{}: 'physics.restitution' = {} fora do limite documentado ([0,1])", ctx, v)
			definition.restitution = f32(v)
		case:
			assets_fatal("{}: flag física desconhecida 'physics.{}' (conhecidas: blocking, hittable, friction, restitution)", ctx, key)
		}
	}
	return definition
}

@(private)
json_number :: proc(value: json.Value) -> (f64, bool) {
	if f, ok := value.(f64); ok do return f, true
	if i, ok := value.(i64); ok do return f64(i), true
	return 0, false
}

@(private)
variant_type_name :: proc(value: json.Value) -> string {
	switch v in value {
	case json.Object:
		return "objeto"
	case json.Array:
		return "array"
	case string:
		return "string"
	case i64:
		return "inteiro"
	case f64:
		return "número"
	case bool:
		return "booleano"
	case json.Null:
		return "null"
	}
	return "?"
}

@(private)
fmt_mesh_where :: proc(name: string, i: int) -> string {
	if name == "" {
		return fmt.tprintf("malha[{}]", i)
	}
	return fmt.tprintf("malha '{}'", name)
}

@(private)
assets_fatal :: proc(format: string, args: ..any) -> ! {
	log.errorf(format, ..args)
	os.exit(1)
}
