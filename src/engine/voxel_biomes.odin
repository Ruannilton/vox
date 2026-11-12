package engine

// VS-22 (REQ-BIO-01): biomas procedurais data-driven via assets/biomes.json.
// Mesmo padrão de rejeição da VS-12: parse + validação rodam no boot, DEPOIS
// de assets_load (o registry de blocos precisa estar carregado para resolver
// nomes → ids). Erro → log fatal, sem fallback silencioso. Os dados parseados
// espelham as structs std430 de common.slang e alimentam os bindings 22–24
// (upload em voxel_gpu_init, upload_biome_tables).

import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"

BIOMES_DEFAULT_PATH :: "assets/biomes.json"

// Limites fixos de buffer (REQ-BIO-01): ≤16 biomas, ≤8 camadas por bioma e
// ≤64 camadas no total (stride dos StructuredBuffers).
MAX_BIOMES :: 16
MAX_BIOME_LAYERS_PER_BIOME :: 8
MAX_BIOME_LAYERS_TOTAL :: 64

// Defaults documentados (REQ-BIO-01).
BIOME_DEFAULT_SEED :: 1337
BIOME_DEFAULT_DISTORTION :: f32(24)
BIOME_DEFAULT_TRANSITION_THRESHOLD :: f32(0.15)
BIOME_DEFAULT_TEMPERATURE_FREQUENCY :: f32(0.001)
BIOME_DEFAULT_HUMIDITY_FREQUENCY :: f32(0.002)
BIOME_DEFAULT_SUBSURFACE_DEPTH :: 8

// Tipo de ruído (espelha o FastNoiseLite usado pelo kernel).
// u32 explícito: biomes_parse_enum asserção .(u32) nos argumentos variádicos.
BIOME_NOISE_TYPE_SIMPLEX :: u32(0)
BIOME_NOISE_TYPE_PERLIN :: u32(1)
BIOME_NOISE_TYPE_CELLULAR :: u32(2)

// Operação da camada: +amplitude (vales preservados) ou −amplitude (ravinas).
BIOME_NOISE_OP_ADD :: u32(0)
BIOME_NOISE_OP_SUBTRACT :: u32(1)

// BiomeDefinition.flags: bit 0 — o bioma permite spawn de plantas (VS-14).
BIOME_FLAG_PERMITE_PLANTAS :: 1

// Clamps documentados (REQ-BIO-01/03).
BIOME_MIN_HEIGHT :: 1
BIOME_MAX_HEIGHT :: 32767

// 48 B std430 — espelha o Slang (float2 alinhado a 8, stride múltiplo de 16).
BiomeGlobals :: struct {
	offset_mundial:         [2]f32, // 0..8
	semente:                u32,    // 8
	num_biomas:             u32,    // 12
	num_camadas_total:      u32,    // 16
	forca_distorcao:        f32,    // 20
	limiar_transicao:       f32,    // 24
	frequencia_temperatura: f32,    // 28
	frequencia_umidade:     f32,    // 32
	padding:                [3]u32, // 36..48
}

// 48 B std430 — espelha o Slang. Os blocos são ids do registry global (VS-12).
BiomeDefinition :: struct {
	centro_climatico:              [2]f32, // 0..8 (T, H)
	altura_base:                   f32,    // 8
	bloco_superficie:              u32,    // 12
	bloco_subsuperficie:           u32,    // 16
	bloco_profundo:                u32,    // 20
	profundidade_subsuperficie:    u32,    // 24
	layer_start:                   u32,    // 28
	layer_count:                   u32,    // 32
	flags:                         u32,    // 36 (bit 0 = permitePlantas)
	padding:                       [2]u32, // 40..48
}

// 32 B std430 — espelha o Slang (stride múltiplo de 16).
BiomeNoiseLayer :: struct {
	amplitude: f32,     // 0
	frequencia: f32,    // 4
	oitavas:     u32,    // 8
	tipo:        u32,    // 12 (0=simplex, 1=perlin, 2=cellular)
	operacao:    u32,    // 16 (0=adicao, 1=subtracao)
	padding:     [3]u32, // 20..32
}

// Tabelas parseadas: arrays de capacidade fixa para o upload direto aos
// StructuredBuffers (bindings 22/23/24); as contagens vêm de BiomeGlobals.
VoxelBiomes :: struct {
	loaded:  bool,
	globals: BiomeGlobals,
	biomes:  [MAX_BIOMES]BiomeDefinition,
	layers:  [MAX_BIOME_LAYERS_TOTAL]BiomeNoiseLayer,
}

voxel_biomes: VoxelBiomes

#assert(size_of(BiomeGlobals) == 48)
#assert(size_of(BiomeDefinition) == 48)
#assert(size_of(BiomeNoiseLayer) == 32)

biomes_json_layer :: struct {
	amplitude: Maybe(f64) `json:"amplitude"`,
	frequencia: Maybe(f64) `json:"frequencia"`,
	oitavas: Maybe(i64) `json:"oitavas"`,
	tipo: Maybe(string) `json:"tipo"`,
	operacao: Maybe(string) `json:"operacao"`,
}

biomes_json_biome :: struct {
	nome: Maybe(string) `json:"nome"`,
	centro_temperatura: Maybe(f64) `json:"centroTemperatura"`,
	centro_umidade: Maybe(f64) `json:"centroUmidade"`,
	altura_base: Maybe(f64) `json:"alturaBase"`,
	bloco_superficie: Maybe(string) `json:"blocoSuperficie"`,
	bloco_subsuperficie: Maybe(string) `json:"blocoSubsuperficie"`,
	bloco_profundo: Maybe(string) `json:"blocoProfundo"`,
	profundidade_subsuperficie: Maybe(i64) `json:"profundidadeSubsuperficie"`,
	permite_plantas: Maybe(bool) `json:"permitePlantas"`,
	camadas: []biomes_json_layer `json:"camadas"`,
}

biomes_json_global :: struct {
	semente: Maybe(i64) `json:"semente"`,
	forca_distorcao: Maybe(f64) `json:"forcaDistorcao"`,
	limiar_transicao: Maybe(f64) `json:"limiarTransicao"`,
	frequencia_temperatura: Maybe(f64) `json:"frequenciaTemperatura"`,
	frequencia_umidade: Maybe(f64) `json:"frequenciaUmidade"`,
	offset_mundial: Maybe([2]f64) `json:"offsetMundial"`,
}

biomes_json_doc :: struct {
	global: Maybe(biomes_json_global) `json:"global"`,
	biomas: []biomes_json_biome `json:"biomas"`,
}

// Carga + validação (REQ-BIO-01). Ausente ou inválido → fatal (sem fallback:
// o kernel de geração data-driven (VS-22-IMPL-03) passa a exigir as tabelas).
biomes_load :: proc() {
	ZoneN("biomes_load")
	path := BIOMES_DEFAULT_PATH
	data, ferr := os.read_entire_file_from_path(path, context.allocator)
	if ferr != nil {
		biomes_fatal("{}: arquivo não encontrado", path)
	}

	doc: biomes_json_doc
	unmarshal_err := json.unmarshal(data, &doc, allocator = context.allocator)
	if unmarshal_err != nil {
		biomes_fatal("{}: JSON inválido: {}", path, unmarshal_err)
	}

	biomes_parse_globals(doc.global, path)
	block_ids := biomes_block_id_index()
	total_layers := biomes_parse_biomes(doc.biomas, block_ids)

	voxel_biomes.globals.num_camadas_total = u32(total_layers)
	voxel_biomes.loaded = true
	log.infof(
		"VS-22: biomas carregados de {} — {} biomas, {} camadas de ruído | globais: semente {}, forcaDistorcao {}, limiarTransicao {}",
		path,
		voxel_biomes.globals.num_biomas,
		voxel_biomes.globals.num_camadas_total,
		voxel_biomes.globals.semente,
		voxel_biomes.globals.forca_distorcao,
		voxel_biomes.globals.limiar_transicao,
	)
}

// Globais: campos ausentes usam os defaults documentados da spec.
@(private)
biomes_parse_globals :: proc(global: Maybe(biomes_json_global), path: string) {
	g := BiomeGlobals {
		semente = BIOME_DEFAULT_SEED,
		forca_distorcao = BIOME_DEFAULT_DISTORTION,
		limiar_transicao = BIOME_DEFAULT_TRANSITION_THRESHOLD,
		frequencia_temperatura = BIOME_DEFAULT_TEMPERATURE_FREQUENCY,
		frequencia_umidade = BIOME_DEFAULT_HUMIDITY_FREQUENCY,
	}
	if global != nil {
		gvalue := global.?
		if gvalue.semente != nil {
			seed := gvalue.semente.?
			if seed < 0 || seed > i64(max(u32)) {
				biomes_fatal("{}: global.semente = {} fora do intervalo 0..{}", path, seed, max(u32))
			}
			g.semente = u32(seed)
		}
		if gvalue.forca_distorcao != nil {
			g.forca_distorcao = f32(gvalue.forca_distorcao.?)
			if g.forca_distorcao < 0 {
				biomes_fatal("{}: global.forcaDistorcao = {} fora do limite documentado (≥ 0)", path, g.forca_distorcao)
			}
		}
		if gvalue.limiar_transicao != nil {
			g.limiar_transicao = f32(gvalue.limiar_transicao.?)
			if g.limiar_transicao <= 0 {
				biomes_fatal("{}: global.limiarTransicao = {} fora do limite documentado (> 0)", path, g.limiar_transicao)
			}
		}
		if gvalue.frequencia_temperatura != nil {
			g.frequencia_temperatura = f32(gvalue.frequencia_temperatura.?)
			if g.frequencia_temperatura <= 0 {
				biomes_fatal("{}: global.frequenciaTemperatura = {} fora do limite documentado (> 0)", path, g.frequencia_temperatura)
			}
		}
		if gvalue.frequencia_umidade != nil {
			g.frequencia_umidade = f32(gvalue.frequencia_umidade.?)
			if g.frequencia_umidade <= 0 {
				biomes_fatal("{}: global.frequenciaUmidade = {} fora do limite documentado (> 0)", path, g.frequencia_umidade)
			}
		}
		if gvalue.offset_mundial != nil {
			g.offset_mundial = [2]f32{f32(gvalue.offset_mundial.?[0]), f32(gvalue.offset_mundial.?[1])}
		}
	}
	voxel_biomes.globals = g
}

// Índice nome → id a partir do registry global (VS-12). Requer assets_load
// executado antes (biomes_load roda depois dele no boot).
@(private)
biomes_block_id_index :: proc() -> map[string]u32 {
	index := make(map[string]u32, BLOCK_REGISTRY_CAPACITY, context.temp_allocator)
	for id in 1 ..< BLOCK_REGISTRY_CAPACITY {
		name := voxel_assets.block_names[id]
		if name != "" do index[name] = u32(id)
	}
	return index
}

// Biomas: valida limites e referências, aplica defaults e preenche as tabelas
// std430 (layer_start/layer_count apontam no pool global de camadas).
@(private)
biomes_parse_biomes :: proc(json_biomes: []biomes_json_biome, block_ids: map[string]u32) -> (total_layers: int) {
	if len(json_biomes) == 0 || len(json_biomes) > MAX_BIOMES {
		biomes_fatal("biomas: {} biomas (esperado 1..{})", len(json_biomes), MAX_BIOMES)
	}

	for json_biome, i in json_biomes {
		ctx := biomes_where(json_biome.nome, i)
		if json_biome.nome == nil || json_biome.nome.? == "" {
			biomes_fatal("bioma[{}]: campo 'nome' ausente ou vazio", i)
		}
		if json_biome.centro_temperatura == nil || json_biome.centro_umidade == nil {
			biomes_fatal("{}: campos 'centroTemperatura'/'centroUmidade' ausentes", ctx)
		}
		center := [2]f32 {
			f32(json_biome.centro_temperatura.?),
			f32(json_biome.centro_umidade.?),
		}
		for component, axis in center {
			if component < -1 || component > 1 {
				biomes_fatal("{}: centro climático ({}, {}) fora de [-1,1]²", ctx, center[0], center[1])
			}
		}
		if json_biome.altura_base == nil {
			biomes_fatal("{}: campo 'alturaBase' ausente", ctx)
		}
		base_height := f32(json_biome.altura_base.?)
		if json_biome.bloco_superficie == nil || json_biome.bloco_superficie.? == "" {
			biomes_fatal("{}: campo 'blocoSuperficie' ausente ou vazio", ctx)
		}
		if json_biome.bloco_subsuperficie == nil || json_biome.bloco_subsuperficie.? == "" {
			biomes_fatal("{}: campo 'blocoSubsuperficie' ausente ou vazio", ctx)
		}
		surface_id := biomes_resolve_block(ctx, "blocoSuperficie", json_biome.bloco_superficie.?, block_ids)
		subsurface_id := biomes_resolve_block(ctx, "blocoSubsuperficie", json_biome.bloco_subsuperficie.?, block_ids)
		deep_id := subsurface_id // default documentado: blocoProfundo = blocoSubsuperficie
		if json_biome.bloco_profundo != nil && json_biome.bloco_profundo.? != "" {
			deep_id = biomes_resolve_block(ctx, "blocoProfundo", json_biome.bloco_profundo.?, block_ids)
		}
		subsurface_depth := i64(BIOME_DEFAULT_SUBSURFACE_DEPTH)
		if json_biome.profundidade_subsuperficie != nil {
			subsurface_depth = json_biome.profundidade_subsuperficie.?
			if subsurface_depth < 0 || subsurface_depth > i64(max(u32)) {
				biomes_fatal("{}: profundidadeSubsuperficie = {} fora do intervalo 0..{}", ctx, subsurface_depth, max(u32))
			}
		}
		flags := u32(0)
		if json_biome.permite_plantas != nil && json_biome.permite_plantas.? {
			flags |= BIOME_FLAG_PERMITE_PLANTAS
		}
		if len(json_biome.camadas) > MAX_BIOME_LAYERS_PER_BIOME {
			biomes_fatal("{}: {} camadas excede o máximo de {} por bioma", ctx, len(json_biome.camadas), MAX_BIOME_LAYERS_PER_BIOME)
		}
		if total_layers + len(json_biome.camadas) > MAX_BIOME_LAYERS_TOTAL {
			biomes_fatal("{}: {} camadas no total excede o máximo de {}", ctx, total_layers + len(json_biome.camadas), MAX_BIOME_LAYERS_TOTAL)
		}

		definition := BiomeDefinition {
			centro_climatico = center,
			// alturaBase é clampada a [1, 32767] (documentado; não é rejeição).
			altura_base = clamp(base_height, BIOME_MIN_HEIGHT, BIOME_MAX_HEIGHT),
			bloco_superficie = surface_id,
			bloco_subsuperficie = subsurface_id,
			bloco_profundo = deep_id,
			profundidade_subsuperficie = u32(subsurface_depth),
			layer_start = u32(total_layers),
			layer_count = u32(len(json_biome.camadas)),
			flags = flags,
		}
		for json_layer, j in json_biome.camadas {
			voxel_biomes.layers[total_layers + j] = biomes_parse_layer(ctx, json_layer, j)
		}
		total_layers += len(json_biome.camadas)
		voxel_biomes.biomes[i] = definition
	}
	voxel_biomes.globals.num_biomas = u32(len(json_biomes))
	return total_layers
}

@(private)
biomes_parse_layer :: proc(ctx: string, json_layer: biomes_json_layer, index: int) -> BiomeNoiseLayer {
	layer_ctx := fmt.tprintf("{}: camada[{}]", ctx, index)
	if json_layer.amplitude == nil || json_layer.frequencia == nil {
		biomes_fatal("{}: campos 'amplitude'/'frequencia' ausentes", layer_ctx)
	}
	if json_layer.oitavas == nil {
		biomes_fatal("{}: campo 'oitavas' ausente", layer_ctx)
	}
	octaves := json_layer.oitavas.?
	if octaves < 1 || octaves > 8 {
		biomes_fatal("{}: oitavas = {} fora do intervalo 1..8", layer_ctx, octaves)
	}
	noise_type := biomes_parse_enum(layer_ctx, "tipo", json_layer.tipo, "simplex", BIOME_NOISE_TYPE_SIMPLEX, "perlin", BIOME_NOISE_TYPE_PERLIN, "cellular", BIOME_NOISE_TYPE_CELLULAR)
	operation := biomes_parse_enum(layer_ctx, "operacao", json_layer.operacao, "adicao", BIOME_NOISE_OP_ADD, "subtracao", BIOME_NOISE_OP_SUBTRACT)
	return BiomeNoiseLayer {
		amplitude = f32(json_layer.amplitude.?),
		frequencia = f32(json_layer.frequencia.?),
		oitavas = u32(octaves),
		tipo = noise_type,
		operacao = operation,
	}
}

// Enumerações por nome — valor desconhecido é rejeição fatal (sem fallback).
@(private)
biomes_parse_enum :: proc(ctx: string, field: string, value: Maybe(string), args: ..any) -> u32 {
	if value == nil || value.? == "" {
		biomes_fatal("{}: campo '{}' ausente ou vazio", ctx, field)
	}
	name := value.?
	known := make([dynamic]string, 0, len(args) / 2, context.temp_allocator)
	for i := 0; i + 1 < len(args); i += 2 {
		key, key_ok := args[i].(string)
		mapped, value_ok := args[i + 1].(u32)
		if !key_ok || !value_ok {
			biomes_fatal("biomes_parse_enum: argumentos inválidos para '{}'", field)
		}
		append(&known, key)
		if key == name do return mapped
	}
	biomes_fatal("{}: '{}' desconhecido: '{}' (conhecidos: {})", ctx, field, name, known)
}

// Nome de bloco → id do registry global (VS-12). Inexistente → fatal.
@(private)
biomes_resolve_block :: proc(ctx: string, field: string, name: string, block_ids: map[string]u32) -> u32 {
	id, ok := block_ids[name]
	if !ok {
		biomes_fatal("{}: bloco '{}' não encontrado no registry (campo '{}')", ctx, name, field)
	}
	return id
}

@(private)
biomes_where :: proc(name: Maybe(string), i: int) -> string {
	if name == nil || name.? == "" {
		return fmt.tprintf("bioma[{}]", i)
	}
	return fmt.tprintf("bioma '{}'", name.?)
}

@(private)
biomes_fatal :: proc(format: string, args: ..any) -> ! {
	log.errorf(format, ..args)
	os.exit(1)
}
