package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// ============================================================================
// Estruturas binárias idênticas ao vox2vmesh.cpp (v2) e ao layout std430 da GPU
// ============================================================================
VMESH_MAGIC   :: "VMSH"
VMESH_VERSION :: 2

TEMPLATE_FLAG_HAS_FLUSH_FACES :: u32(1)
TEMPLATE_FLAG_HEAVY           :: u32(2)
TEMPLATE_FLAG_FULL_CUBE       :: u32(4)

VmeshHeader :: struct #packed {
	magic:          [4]u8,
	version:        u32,
	lod_count:      u32,
	meshlet_count:  u32,
	vertex_count:   u32,
	triangle_count: u32,
	flags:          u32,
	reserved:       u32,
}

HeavyTemplate :: struct #packed {
	meshlet_base:  u32,
	meshlet_count: u32,
	lod_info:      u32, // lo16 = índice do LOD, hi16 = total de LODs
	lod_error:     f32,
}

TemplateMeshlet :: struct #packed {
	vertex_offset:   u32,
	vertex_count:    u32,
	triangle_offset: u32,
	triangle_count:  u32,
	uv_offset:       u32,
	cull_mask:       u32,
	center:          [3]f32,
	radius:          f32,
	cone_axis_s8:    u32,
	cone_cutoff:     f32,
}

#assert(size_of(VmeshHeader) == 32)
#assert(size_of(HeavyTemplate) == 16)
#assert(size_of(TemplateMeshlet) == 48)

// ============================================================================
// Estruturas para serialização JSON / Inspeção
// ============================================================================
JsonVertex :: struct {
	pos:   [3]f32,
	color: [4]u8, // R, G, B, A
}

JsonTriangle :: struct {
	indices:   [3]u8,
	cull_face: u8,
}

JsonMeshlet :: struct {
	index:           u32,
	vertex_offset:   u32,
	vertex_count:    u32,
	triangle_offset: u32,
	triangle_count:  u32,
	uv_offset:       u32,
	cull_mask:       u32,
	cull_faces:      []string,
	bounds_center:   [3]f32,
	bounds_radius:   f32,
	cone_axis:       [3]f32,
	cone_cutoff:     f32,
	vertices:        []JsonVertex,
	triangles:       []JsonTriangle,
}

JsonLod :: struct {
	lod_index:     u16,
	lod_total:     u16,
	lod_error:     f32,
	meshlet_base:  u32,
	meshlet_count: u32,
	meshlets:      []JsonMeshlet,
}

JsonVmeshReport :: struct {
	file:           string,
	file_size:      int,
	version:        u32,
	flags_raw:      u32,
	flags:          []string,
	lod_count:      u32,
	meshlet_count:  u32,
	vertex_count:   u32,
	triangle_count: u32,
	lods:           []JsonLod,
}

// ============================================================================
// Helpers de decodificação
// ============================================================================
decode_flags :: proc(flags: u32, allocator := context.allocator) -> []string {
	list := make([dynamic]string, allocator)
	if (flags & TEMPLATE_FLAG_HAS_FLUSH_FACES) != 0 do append(&list, "HAS_FLUSH_FACES")
	if (flags & TEMPLATE_FLAG_HEAVY) != 0           do append(&list, "HEAVY")
	if (flags & TEMPLATE_FLAG_FULL_CUBE) != 0       do append(&list, "FULL_CUBE")
	return list[:]
}

decode_cull_mask :: proc(mask: u32, allocator := context.allocator) -> []string {
	FACE_NAMES := [6]string{"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
	list := make([dynamic]string, allocator)
	for i in 0..<6 {
		if (mask & (u32(1) << u32(i))) != 0 {
			append(&list, FACE_NAMES[i])
		}
	}
	if (mask & 0x40) != 0 {
		append(&list, "NEVER")
	}
	return list[:]
}

unpack_s8x3 :: proc(packed: u32) -> [3]f32 {
	sx := i8(packed & 0xFF)
	sy := i8((packed >> 8) & 0xFF)
	sz := i8((packed >> 16) & 0xFF)
	return {f32(sx) / 127.0, f32(sy) / 127.0, f32(sz) / 127.0}
}

unpack_rgba :: proc(rgba: u32) -> [4]u8 {
	return {
		u8(rgba & 0xFF),
		u8((rgba >> 8) & 0xFF),
		u8((rgba >> 16) & 0xFF),
		u8((rgba >> 24) & 0xFF),
	}
}

read_slice :: proc($T: typeid, data: []u8, offset: ^int, count: u32) -> (res: []T, ok: bool) {
	bytes := int(count) * size_of(T)
	if offset^ + bytes > len(data) {
		return nil, false
	}
	if count == 0 {
		return nil, true
	}
	res = slice.from_ptr((^T)(&data[offset^]), int(count))
	offset^ += bytes
	return res, true
}

// ============================================================================
// Main
// ============================================================================
main :: proc() {
	as_json   := false
	verbose   := false
	file_path := ""

	for arg in os.args[1:] {
		if arg == "--json" {
			as_json = true
		} else if arg == "--verbose" || arg == "-v" {
			verbose = true
		} else if !strings.has_prefix(arg, "-") {
			file_path = arg
		}
	}

	if file_path == "" {
		fmt.eprintln("Uso: vmesh_inspect <arquivo.vmesh> [--json] [--verbose]")
		os.exit(1)
	}

	data, err := os.read_entire_file_from_path(file_path, context.allocator)
	if err != nil {
		fmt.eprintf("[ERRO] Falha ao ler '%s': %v\n", file_path, err)
		os.exit(1)
	}

	if len(data) < size_of(VmeshHeader) {
		fmt.eprintln("[ERRO] Arquivo menor que o cabeçalho VmeshHeader (32 bytes)")
		os.exit(1)
	}

	hdr := (^VmeshHeader)(raw_data(data))^
	if string(hdr.magic[:]) != VMESH_MAGIC {
		fmt.eprintf("[ERRO] Magic inválido: '%s' (esperado 'VMSH')\n", string(hdr.magic[:]))
		os.exit(1)
	}
	if hdr.version != VMESH_VERSION {
		fmt.eprintf("[ERRO] Versão não suportada: %d (esperado %d)\n", hdr.version, VMESH_VERSION)
		os.exit(1)
	}

	offset := size_of(VmeshHeader)
	raw_lods, ok1      := read_slice(HeavyTemplate,   data, &offset, hdr.lod_count)
	raw_meshlets, ok2  := read_slice(TemplateMeshlet, data, &offset, hdr.meshlet_count)
	raw_positions, ok3 := read_slice([4]f32,          data, &offset, hdr.vertex_count)
	raw_colors, ok4    := read_slice(u32,             data, &offset, hdr.vertex_count)
	raw_triangles, ok5 := read_slice(u32,             data, &offset, hdr.triangle_count)

	if !(ok1 && ok2 && ok3 && ok4 && ok5) {
		fmt.eprintln("[ERRO] Arquivo .vmesh truncado ou corrompido")
		os.exit(1)
	}

	// Monta a estrutura unificada do relatório
	report := JsonVmeshReport{
		file           = file_path,
		file_size      = len(data),
		version        = hdr.version,
		flags_raw      = hdr.flags,
		flags          = decode_flags(hdr.flags),
		lod_count      = hdr.lod_count,
		meshlet_count  = hdr.meshlet_count,
		vertex_count   = hdr.vertex_count,
		triangle_count = hdr.triangle_count,
		lods           = make([]JsonLod, hdr.lod_count),
	}

	for l in 0..<hdr.lod_count {
		hl := raw_lods[l]
		lod_idx   := u16(hl.lod_info & 0xFFFF)
		lod_total := u16((hl.lod_info >> 16) & 0xFFFF)

		jlod := JsonLod{
			lod_index     = lod_idx,
			lod_total     = lod_total,
			lod_error     = hl.lod_error,
			meshlet_base  = hl.meshlet_base,
			meshlet_count = hl.meshlet_count,
			meshlets      = make([]JsonMeshlet, hl.meshlet_count),
		}

		for m in 0..<hl.meshlet_count {
			global_m_idx := hl.meshlet_base + m
			tm := raw_meshlets[global_m_idx]

			jverts := make([]JsonVertex, tm.vertex_count)
			for v in 0..<tm.vertex_count {
				p := raw_positions[tm.vertex_offset + v]
				c := raw_colors[tm.vertex_offset + v]
				jverts[v] = JsonVertex{
					pos   = {p[0], p[1], p[2]},
					color = unpack_rgba(c),
				}
			}

			jtris := make([]JsonTriangle, tm.triangle_count)
			for t in 0..<tm.triangle_count {
				pt := raw_triangles[tm.triangle_offset + t]
				jtris[t] = JsonTriangle{
					indices   = {u8(pt & 0xFF), u8((pt >> 8) & 0xFF), u8((pt >> 16) & 0xFF)},
					cull_face = u8((pt >> 24) & 0x7),
				}
			}

			jlod.meshlets[m] = JsonMeshlet{
				index           = global_m_idx,
				vertex_offset   = tm.vertex_offset,
				vertex_count    = tm.vertex_count,
				triangle_offset = tm.triangle_offset,
				triangle_count  = tm.triangle_count,
				uv_offset       = tm.uv_offset,
				cull_mask       = tm.cull_mask,
				cull_faces      = decode_cull_mask(tm.cull_mask),
				bounds_center   = tm.center,
				bounds_radius   = tm.radius,
				cone_axis       = unpack_s8x3(tm.cone_axis_s8),
				cone_cutoff     = tm.cone_cutoff,
				vertices        = jverts,
				triangles       = jtris,
			}
		}
		report.lods[l] = jlod
	}

	// Saída em JSON
	if as_json {
		opt := json.Marshal_Options{
			pretty     = true,
			use_spaces = true,
			spaces     = 2,
		}
		json_bytes, jerr := json.marshal(report, opt)
		if jerr != nil {
			fmt.eprintf("[ERRO] Falha ao serializar JSON: %v\n", jerr)
			os.exit(1)
		}
		fmt.println(string(json_bytes))
		return
	}

	// Saída legível no console
	fmt.printf("=== VMESH INSPECTOR: %s (%d bytes) ===\n", report.file, report.file_size)
	fmt.printf("Versão:     %d\n", report.version)
	fmt.printf("Flags:      0x%02X %v\n", report.flags_raw, report.flags)
	fmt.printf("Totais:     %d LODs | %d Meshlets | %d Vértices | %d Triângulos\n",
		report.lod_count, report.meshlet_count, report.vertex_count, report.triangle_count)
	fmt.printf("Bytes lidos: %d / %d\n\n", offset, len(data))

	for lod in report.lods {
		fmt.printf("--- LOD %d/%d (erro: %.6f | meshlets: %d..%d) ---\n",
			lod.lod_index, lod.lod_total - 1, lod.lod_error,
			lod.meshlet_base, lod.meshlet_base + lod.meshlet_count - 1)

		for m in lod.meshlets {
			fmt.printf("  [Meshlet #%d] verts: %d (off %d) | tris: %d (off %d) | cull: %v\n",
				m.index, m.vertex_count, m.vertex_offset,
				m.triangle_count, m.triangle_offset, m.cull_faces)
			fmt.printf("    Bounds: center=(%.3f, %.3f, %.3f) r=%.3f | cone_axis=(%.2f, %.2f, %.2f) cutoff=%.3f\n",
				m.bounds_center[0], m.bounds_center[1], m.bounds_center[2], m.bounds_radius,
				m.cone_axis[0], m.cone_axis[1], m.cone_axis[2], m.cone_cutoff)

			if verbose {
				for v, vi in m.vertices {
					fmt.printf("      v[%02d]: pos=(%.4f, %.4f, %.4f) rgba=(%d, %d, %d, %d)\n",
						vi, v.pos[0], v.pos[1], v.pos[2], v.color[0], v.color[1], v.color[2], v.color[3])
				}
				for t, ti in m.triangles {
					fmt.printf("      t[%03d]: (%d, %d, %d) cull_face=%d\n",
						ti, t.indices[0], t.indices[1], t.indices[2], t.cull_face)
				}
			}
		}
		fmt.println()
	}
}