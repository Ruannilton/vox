package engine

// VS-12 (REQ-AST-01..06, REQ-VAL-07): assets data-driven via JSON.
// `assets/blocks.json` define meshes reaproveitáveis, texturas (PNG única) e
// blocos por nome. Parse + validação rodam ANTES de CreateEngine; o resultado
// é consumido no init do motor de voxels. Ausente → warning + built-ins (paridade).

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import png "core:image/png"

ASSETS_DEFAULT_PATH :: "assets/blocks.json"

// Pools de templates têm capacidade fixa (buffers criados em voxel_gpu_init).
VERTEX_POOL_CAPACITY   :: 1024
TRIANGLE_POOL_CAPACITY :: 1024
UV_POOL_CAPACITY       :: 1024
MAX_ASSET_TEXTURE_DIM  :: 256

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
}

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
	id:      i64 `json:"id"`,
	name:    string `json:"name"`,
	mesh:    string `json:"mesh"`,
	texture: string `json:"texture"`,
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
	log.infof(
		"VS-12: assets carregados de {} — {} malhas, {} texturas ({}x{}x{}), {} blocos",
		path,
		len(voxel_assets.templates) - 1,
		voxel_assets.texture_layers,
		voxel_assets.texture_width,
		voxel_assets.texture_height,
		voxel_assets.texture_layers,
		len(doc.blocks),
	)
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
		img, perr := png.load_from_bytes(data, allocator = context.temp_allocator)
		if perr != nil {
			assets_fatal("{}: falha ao decodificar PNG {}: {}", ctx, tex.path, perr)
		}
		if img.depth != 8 || (img.channels != 4 && img.channels != 3) {
			assets_fatal("{}: formato não suportado em {} (esperado RGB/RGBA 8-bit)", ctx, tex.path)
		}
		w, h := img.width, img.height
		if w > MAX_ASSET_TEXTURE_DIM || h > MAX_ASSET_TEXTURE_DIM {
			assets_fatal("textura '{}' {}x{}: dimensão excede o máximo de {}x{}", tex.name, w, h, MAX_ASSET_TEXTURE_DIM, MAX_ASSET_TEXTURE_DIM)
		}
		if ref_width == 0 {
			ref_width, ref_height = w, h
		}
		append(&dims, {name = tex.name, width = w, height = h})

		layer_size := w * h * 4
		if pixels == nil {
			pixels = make([]u8, layer_size * len(doc.textures), context.allocator)
		}
		dst := pixels[i * layer_size:]
		src := img.pixels.buf[:]
		if img.channels == 4 {
			mem.copy(raw_data(dst), raw_data(src), layer_size)
		} else {
			for p in 0 ..< w * h {
				dst[p * 4 + 0] = src[p * 3 + 0]
				dst[p * 4 + 1] = src[p * 3 + 1]
				dst[p * 4 + 2] = src[p * 3 + 2]
				dst[p * 4 + 3] = 255
			}
		}
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
		if block.texture == "" {
			assets_fatal("{}: campo 'texture' ausente ou vazio", ctx)
		}
		texture_index, texture_ok := voxel_assets.layer_of[block.texture]
		if !texture_ok {
			assets_fatal("{}: textura '{}' não encontrada", ctx, block.texture)
		}
		voxel_assets.registry[block.id] = BlockDefinition {
			mesh_template_index  = mesh_index_value,
			albedo_texture_index = u32(texture_index),
			pbr_texture_index    = 0, // dummy PBR
		}
		voxel_assets.block_names[block.id] = strings.clone(block.name, context.allocator)
	}

	missing := make([dynamic]string, 0, 3, context.temp_allocator)
	for id in 1 ..= 3 {
		if voxel_assets.block_names[id] == "" {
			append(&missing, fmt.tprintf("{}", id))
		}
	}
	if len(missing) > 0 {
		assets_fatal("blocos obrigatórios do worldgen ausentes: ids {}", strings.join(missing[:], ", ", context.temp_allocator))
	}
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
