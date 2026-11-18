// vox2vmesh.cpp (v2)
// Compilador offline: .vox (MagicaVoxel) -> greedy meshing por cor -> welding
// -> cadeia de LODs (meshopt_simplify) -> meshlets com bounds -> .vmesh v2
//
// Mudanças em relação à v1:
//  - Sem atlas PNG. Cor RGBA8 por vértice em pool próprio (template_colors).
//  - Greedy só junta quads da MESMA cor, então cada quad tem cor constante.
//  - Welding por posição + cor (na v1 não fundia nas bordas de patch por causa do atlas).
//  - Simplificação sem atributos, com bordas travadas.
//  - Cull de faces por geometria com tolerância, recalculado em cada LOD.
//  - Bounds (esfera + cone) por meshlet, prontos para o task shader (Fase 2).
//  - lod_error armazenado e lod_info com índice e total de LODs.
//  - Flag TEMPLATE_FLAG_FULL_CUBE para a solidez do bloco.
//  - Parser endurecido: limites de leitura, uint32 explícito, só o primeiro modelo.
//
// Uso: vox2vmesh <entrada.vox> <saida_prefixo> [lod_levels]
// Ex.: vox2vmesh grass_tuft.vox assets/models/grass_tuft 3
//
// Dependência: meshoptimizer (headers e fonte em meshoptimizer.h / meshoptimizer.cpp).
// Compilar com C++17 ou superior.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <numeric>
#include <string>
#include <vector>

#include "./meshoptimizer/meshoptimizer.h"

// ============================================================================
// Constantes espelhadas de common.slang
// ============================================================================
static constexpr uint32_t CULL_FACE_NEVER               = 7u;
static constexpr uint32_t CULL_MASK_NEVER_BIT           = 0x40u;
static constexpr uint32_t NO_TEMPLATE_UV_OFFSET         = 0xFFFFFFFFu;
static constexpr uint32_t TEMPLATE_FLAG_HAS_FLUSH_FACES = 1u;
static constexpr uint32_t TEMPLATE_FLAG_HEAVY           = 2u;
static constexpr uint32_t TEMPLATE_FLAG_FULL_CUBE       = 4u; // NOVO: geometria preenche a célula

static constexpr size_t   MESHLET_MAX_VERTICES  = 64;
static constexpr size_t   MESHLET_MAX_TRIANGLES = 124; // múltiplo de 4 (exigido pelo meshopt); HW aceita 126
static constexpr int      LOD_MAX               = 4;
static constexpr uint32_t VMESH_VERSION         = 2;

// Ordem de faces da engine: +X=0, -X=1, +Y=2, -Y=3, +Z=4, -Z=5
static constexpr int FACE_NORMALS[6][3] = {
    { 1, 0, 0 }, {-1, 0, 0 },
    { 0, 1, 0 }, { 0,-1, 0 },
    { 0, 0, 1 }, { 0, 0,-1 }
};

// ============================================================================
// Estruturas binárias (layout std430 da GPU, todos os campos de 4 bytes)
// ============================================================================
#pragma pack(push, 1)
struct VmeshHeader {
    char     magic[4];        // "VMSH"
    uint32_t version;         // 2
    uint32_t lod_count;       // total de LODs gravados
    uint32_t meshlet_count;   // total de TemplateMeshlet
    uint32_t vertex_count;    // total de vértices locais
    uint32_t triangle_count;  // total de triângulos empacotados
    uint32_t flags;           // TEMPLATE_FLAG_*
    uint32_t reserved;        // 0 (era atlas_dim na v1)
};
#pragma pack(pop)

struct HeavyTemplate {            // 16 B (binding 29)
    uint32_t meshlet_base;        // índice em template_meshlets
    uint32_t meshlet_count;
    uint32_t lod_info;            // lo16 = índice do LOD, hi16 = total de LODs
    float    lod_error;           // erro de simplificação do LOD (ver nota em build_lod_chain)
};

struct TemplateMeshlet {          // 48 B (binding 30)
    uint32_t vertex_offset;       // em template_vertices (locais ao meshlet)
    uint32_t vertex_count;        // <= 64
    uint32_t triangle_offset;     // em template_triangles
    uint32_t triangle_count;      // <= 126
    uint32_t uv_offset;           // NO_TEMPLATE_UV_OFFSET (cor vem de template_colors)
    uint32_t cull_mask;           // bits 0..5 = faces; bit 6 = nunca cull
    float    center[3];           // esfera envolvente, espaço local do voxel
    float    radius;
    uint32_t cone_axis_s8;        // bytes 0..2 = eixo do cone em snorm8 (x, y, z)
    float    cone_cutoff;         // >= 1.0 desativa o teste de cone
};

static_assert(sizeof(VmeshHeader)   == 32, "VmeshHeader deve ter 32 bytes");
static_assert(sizeof(HeavyTemplate) == 16, "HeavyTemplate deve ter 16 bytes");
static_assert(sizeof(TemplateMeshlet) == 48, "TemplateMeshlet deve ter 48 bytes");
static_assert(sizeof(unsigned int) == 4, "meshopt usa unsigned int de 32 bits");

// Vértice intermediário (só CPU). Stride 16 B: a posição é lida pelo meshopt via &v.x.
struct Vertex {
    float    x, y, z;
    uint32_t rgba;                // cor RGBA8 do quad (A = 255)
};

// ============================================================================
// 1. Parser de .vox (MagicaVoxel RIFF)
// ============================================================================
struct VoxModel {
    int size[3] = {0, 0, 0};      // X, Y (altura), Z — já em Y-up
    std::vector<uint8_t> grid;    // índices de cor (0 = vazio)
    uint8_t palette[256][4];      // entradas do chunk RGBA; cor do índice i = palette[i-1]

    uint8_t get(int x, int y, int z) const {
        if (x < 0 || x >= size[0] || y < 0 || y >= size[1] || z < 0 || z >= size[2]) return 0;
        return grid[x + size[0] * (z + size[2] * y)];
    }
    size_t cell_count() const {
        return size_t(size[0]) * size_t(size[1]) * size_t(size[2]);
    }
};

static bool read_u32_at(const std::vector<uint8_t>& d, size_t off, uint32_t& out) {
    if (off + 4 > d.size()) return false;
    out = uint32_t(d[off])
        | (uint32_t(d[off + 1]) << 8)
        | (uint32_t(d[off + 2]) << 16)
        | (uint32_t(d[off + 3]) << 24);
    return true;
}

static bool parse_vox(const std::string& path, VoxModel& out, std::string& err) {
    std::ifstream file(path, std::ios::binary);
    if (!file) { err = "não foi possível abrir o arquivo"; return false; }
    std::vector<uint8_t> data((std::istreambuf_iterator<char>(file)),
                               std::istreambuf_iterator<char>());

    if (data.size() < 8 || std::memcmp(data.data(), "VOX ", 4) != 0) {
        err = "cabeçalho VOX inválido";
        return false;
    }

    for (auto& c : out.palette) { c[0] = c[1] = c[2] = c[3] = 255; }

    size_t off = 8;
    int model_count = 0;          // quantos chunks SIZE apareceram
    bool voxels_read = false;

    while (off + 12 <= data.size()) {
        char id[5] = {0};
        std::memcpy(id, data.data() + off, 4);

        uint32_t content_size = 0, children_size = 0;
        if (!read_u32_at(data, off + 4, content_size) ||
            !read_u32_at(data, off + 8, children_size)) break;
        (void)children_size;

        const size_t content     = off + 12;
        const size_t content_end = content + content_size;
        if (content_end > data.size()) { err = "chunk excede o tamanho do arquivo"; return false; }

        if (std::strcmp(id, "SIZE") == 0) {
            if (model_count == 0) {
                uint32_t mx = 0, my = 0, mz = 0;
                if (!read_u32_at(data, content, mx) ||
                    !read_u32_at(data, content + 4, my) ||
                    !read_u32_at(data, content + 8, mz)) {
                    err = "chunk SIZE truncado";
                    return false;
                }
                if (mx == 0 || my == 0 || mz == 0 || size_t(mx) * my * mz > (1u << 24)) {
                    err = "dimensões inválidas";
                    return false;
                }
                out.size[0] = int(mx);
                out.size[1] = int(mz);   // Z-up -> Y-up (altura vem do Z do arquivo)
                out.size[2] = int(my);
                out.grid.assign(out.cell_count(), 0);
            }
            ++model_count;
        } else if (std::strcmp(id, "XYZI") == 0) {
            // Só o primeiro modelo é convertido
            if (model_count == 1 && !voxels_read) {
                uint32_t n = 0;
                if (!read_u32_at(data, content, n) ||
                    content + 4 + size_t(n) * 4 > content_end) {
                    err = "chunk XYZI inválido";
                    return false;
                }
                for (uint32_t i = 0; i < n; ++i) {
                    const size_t p = content + 4 + size_t(i) * 4;
                    const int x = data[p + 0];
                    const int y = data[p + 2];   // Z -> Y
                    const int z = data[p + 1];   // Y -> Z
                    const uint8_t c = data[p + 3];
                    if (c == 0) continue;
                    if (x < out.size[0] && y < out.size[1] && z < out.size[2]) {
                        out.grid[x + out.size[0] * (z + out.size[2] * y)] = c;
                    }
                }
                voxels_read = true;
            }
        } else if (std::strcmp(id, "RGBA") == 0) {
            if (content_size >= 256u * 4u) {
                std::memcpy(out.palette, data.data() + content, 256 * 4);
            }
        }

        off = content_end;   // MAIN tem content 0: os filhos são lidos na sequência
    }

    if (model_count == 0 || !voxels_read) {
        err = "arquivo sem chunk SIZE/XYZI";
        return false;
    }
    if (model_count > 1) {
        std::fprintf(stderr, "[AVISO] %d modelos no arquivo; só o primeiro é convertido\n",
                     model_count);
    }
    return true;
}

// ============================================================================
// 2. Greedy meshing por cor (sem atlas)
// ============================================================================
struct RawMesh {
    std::vector<Vertex>   vertices;
    std::vector<uint32_t> indices;
};

static uint32_t palette_rgba(const VoxModel& m, uint8_t color_index) {
    const uint8_t* c = m.palette[color_index - 1];
    return uint32_t(c[0]) | (uint32_t(c[1]) << 8) | (uint32_t(c[2]) << 16) | (0xFFu << 24);
}

static RawMesh build_greedy_mesh(const VoxModel& m) {
    RawMesh out;

    const int    max_dim = std::max({ m.size[0], m.size[1], m.size[2] });
    const double scale   = 1.0 / double(max_dim);
    const double off_x   = (1.0 - m.size[0] * scale) * 0.5;   // centraliza X e Z na célula
    const double off_z   = (1.0 - m.size[2] * scale) * 0.5;

    auto make_vertex = [&](const int p[3], uint32_t rgba) {
        Vertex v;
        v.x = float(off_x + p[0] * scale);
        v.y = float(p[1] * scale);           // Y não é centralizado: base em y = 0
        v.z = float(off_z + p[2] * scale);
        v.rgba = rgba;
        return v;
    };

    for (int face = 0; face < 6; ++face) {
        const int  axis    = face / 2;
        const bool is_pos  = (face % 2) == 0;
        const int  u_axis  = (axis + 1) % 3;
        const int  v_axis  = (axis + 2) % 3;
        const int  dim_d   = m.size[axis];
        const int  dim_u   = m.size[u_axis];
        const int  dim_v   = m.size[v_axis];

        // Máscara: índice da cor da face exposta nesta fatia (0 = sem face)
        std::vector<uint8_t> mask(size_t(dim_u) * size_t(dim_v), 0);

        for (int d = 0; d < dim_d; ++d) {
            for (int v = 0; v < dim_v; ++v) {
                for (int u = 0; u < dim_u; ++u) {
                    int pos[3];
                    pos[axis] = d; pos[u_axis] = u; pos[v_axis] = v;
                    const uint8_t c = m.get(pos[0], pos[1], pos[2]);
                    const int np[3] = {
                        pos[0] + FACE_NORMALS[face][0],
                        pos[1] + FACE_NORMALS[face][1],
                        pos[2] + FACE_NORMALS[face][2]
                    };
                    mask[u + v * dim_u] = (c != 0 && m.get(np[0], np[1], np[2]) == 0) ? c : 0;
                }
            }

            for (int v = 0; v < dim_v; ++v) {
                for (int u = 0; u < dim_u; ) {
                    const uint8_t c = mask[u + v * dim_u];
                    if (c == 0) { ++u; continue; }

                    // Expande em largura: só junta células da MESMA cor
                    int w = 1;
                    while (u + w < dim_u && mask[(u + w) + v * dim_u] == c) ++w;

                    // Expande em altura: a linha inteira precisa ter a mesma cor
                    int h = 1;
                    bool done = false;
                    while (v + h < dim_v && !done) {
                        for (int k = 0; k < w; ++k) {
                            if (mask[(u + k) + (v + h) * dim_u] != c) { done = true; break; }
                        }
                        if (!done) ++h;
                    }

                    for (int dv = 0; dv < h; ++dv)
                        for (int du = 0; du < w; ++du)
                            mask[(u + du) + (v + dv) * dim_u] = 0;

                    const int slice = is_pos ? (d + 1) : d;

                    // Cantos em (u, v): 0=(u,v) 1=(u+w,v) 2=(u+w,v+h) 3=(u,v+h)
                    const int corner[4][2] = { {u, v}, {u + w, v}, {u + w, v + h}, {u, v + h} };
                    // Ordem que mantém o enrolamento para fora (+ e -)
                    int ord[4] = { 0, 1, 2, 3 };
                    if (!is_pos) { ord[1] = 3; ord[3] = 1; }

                    const uint32_t rgba = palette_rgba(m, c);
                    const uint32_t base = uint32_t(out.vertices.size());
                    for (int k = 0; k < 4; ++k) {
                        int pos[3];
                        pos[axis]   = slice;
                        pos[u_axis] = corner[ord[k]][0];
                        pos[v_axis] = corner[ord[k]][1];
                        out.vertices.push_back(make_vertex(pos, rgba));
                    }
                    out.indices.insert(out.indices.end(),
                        { base + 0, base + 1, base + 2, base + 0, base + 2, base + 3 });

                    u += w;
                }
            }
        }
    }
    return out;
}

// ============================================================================
// 3. Welding por posição + cor e otimização de cache/fetch
// ============================================================================
struct Welded {
    std::vector<Vertex>   vertices;
    std::vector<uint32_t> indices;
};

static Welded weld_and_optimize(const RawMesh& raw) {
    std::vector<unsigned int> remap(raw.indices.size());
    const size_t unique = meshopt_generateVertexRemap(
        remap.data(), raw.indices.data(), raw.indices.size(),
        raw.vertices.data(), raw.vertices.size(), sizeof(Vertex));

    std::vector<Vertex>   v1(unique);
    std::vector<uint32_t> i1(raw.indices.size());
    meshopt_remapVertexBuffer(v1.data(), raw.vertices.data(), raw.vertices.size(),
                              sizeof(Vertex), remap.data());
    meshopt_remapIndexBuffer(i1.data(), raw.indices.data(), raw.indices.size(), remap.data());

    std::vector<uint32_t> i2(i1.size());
    meshopt_optimizeVertexCache(i2.data(), i1.data(), i1.size(), v1.size());

    // Destino e origem em buffers separados (não compartilhar o mesmo buffer)
    std::vector<Vertex> v2(v1.size());
    const size_t used = meshopt_optimizeVertexFetch(
        v2.data(), i2.data(), i2.size(), v1.data(), v1.size(), sizeof(Vertex));
    v2.resize(used);

    return { std::move(v2), std::move(i2) };
}

// Cull de face por geometria: a face só é "flush" se o triângulo estiver no plano
// da borda da célula com a normal apontando para fora. Tolerância em vez de igualdade exata.
static uint32_t infer_cull_face(const Vertex& a, const Vertex& b, const Vertex& c) {
    constexpr float EPS = 1e-4f;
    const float ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z;
    const float vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
    float nx = uy * vz - uz * vy;
    float ny = uz * vx - ux * vz;
    float nz = ux * vy - uy * vx;
    const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
    if (len < 1e-8f) return CULL_FACE_NEVER;
    nx /= len; ny /= len; nz /= len;

    auto on = [](float value, float target) { return std::fabs(value - target) < EPS; };

    if (nx >  0.99f && on(a.x, 1.f) && on(b.x, 1.f) && on(c.x, 1.f)) return 0; // +X
    if (nx < -0.99f && on(a.x, 0.f) && on(b.x, 0.f) && on(c.x, 0.f)) return 1; // -X
    if (ny >  0.99f && on(a.y, 1.f) && on(b.y, 1.f) && on(c.y, 1.f)) return 2; // +Y
    if (ny < -0.99f && on(a.y, 0.f) && on(b.y, 0.f) && on(c.y, 0.f)) return 3; // -Y
    if (nz >  0.99f && on(a.z, 1.f) && on(b.z, 1.f) && on(c.z, 1.f)) return 4; // +Z
    if (nz < -0.99f && on(a.z, 0.f) && on(b.z, 0.f) && on(c.z, 0.f)) return 5; // -Z
    return CULL_FACE_NEVER;
}

static std::vector<uint32_t> cull_faces_for(const std::vector<Vertex>& verts,
                                            const std::vector<uint32_t>& indices) {
    std::vector<uint32_t> out(indices.size() / 3);
    for (size_t t = 0; t < out.size(); ++t) {
        out[t] = infer_cull_face(verts[indices[t * 3 + 0]],
                                 verts[indices[t * 3 + 1]],
                                 verts[indices[t * 3 + 2]]);
    }
    return out;
}

// ============================================================================
// 4. Cadeia de LODs
// ============================================================================
struct LodLevel {
    std::vector<uint32_t> indices;
    float error = 0.0f;
};

// NOTA: `error` é o result_error do meshopt_simplify. Confira na documentação da sua
// versão a unidade (costuma ser absoluta em unidades de posição). A engine usa esse
// valor para escolher a distância de troca de LOD.
static std::vector<LodLevel> build_lod_chain(const Welded& base, int requested) {
    std::vector<LodLevel> levels;
    levels.push_back({ base.indices, 0.0f });

    const size_t full = base.indices.size();
    for (int lod = 1; lod < requested; ++lod) {
        size_t target = size_t(double(full) * std::pow(0.5, double(lod)));
        target = (target / 3) * 3;
        if (target < 12) target = 12;
        if (target >= full) break;

        std::vector<uint32_t> dst(full);
        float err = 0.0f;
        const size_t n = meshopt_simplify(
            dst.data(),
            base.indices.data(), full,
            &base.vertices[0].x, base.vertices.size(), sizeof(Vertex),
            target,
            0.05f,                         // erro relativo máximo (5% da extensão do mesh)
            meshopt_SimplifyLockBorder,    // bordas e cores preservadas
            &err);

        if (n < 3) break;
        dst.resize(n);
        levels.push_back({ std::move(dst), err });
    }
    return levels;
}

// ============================================================================
// 5. Meshlets com bounds, merge de pequenos e validação
// ============================================================================
struct Meshlet {
    std::vector<Vertex>   vertices;   // locais ao meshlet
    std::vector<uint32_t> packed;     // i0 | i1<<8 | i2<<16 | cull_face<<24
    uint32_t              cull_mask = 0;
    meshopt_Bounds        bounds{};
};

static meshopt_Bounds bounds_of(const std::vector<Vertex>& verts,
                                const std::vector<uint32_t>& packed) {
    std::vector<unsigned int>  local(verts.size());
    std::iota(local.begin(), local.end(), 0u);

    std::vector<unsigned char> tris(packed.size() * 3);
    for (size_t t = 0; t < packed.size(); ++t) {
        const uint32_t pt = packed[t];
        tris[t * 3 + 0] = static_cast<unsigned char>(pt & 0xFFu);
        tris[t * 3 + 1] = static_cast<unsigned char>((pt >> 8) & 0xFFu);
        tris[t * 3 + 2] = static_cast<unsigned char>((pt >> 16) & 0xFFu);
    }
    return meshopt_computeMeshletBounds(local.data(), tris.data(), packed.size(),
                                        &verts[0].x, verts.size(), sizeof(Vertex));
}

static std::vector<Meshlet> build_meshlets(const std::vector<Vertex>& verts,
                                           const std::vector<uint32_t>& indices,
                                           const std::vector<uint32_t>& cull) {
    // Separa triângulos em 7 classes: faces 0..5 e "nunca cull" (6)
    std::vector<uint32_t> cls_idx[7];
    for (size_t t = 0; t < cull.size(); ++t) {
        const uint32_t cf  = cull[t];
        const int      cls = (cf <= 5) ? int(cf) : 6;
        cls_idx[cls].push_back(indices[t * 3 + 0]);
        cls_idx[cls].push_back(indices[t * 3 + 1]);
        cls_idx[cls].push_back(indices[t * 3 + 2]);
    }

    std::vector<Meshlet> out;
    for (int cls = 0; cls < 7; ++cls) {
        const auto& ci = cls_idx[cls];
        if (ci.empty()) continue;

        const uint32_t cf       = (cls < 6) ? uint32_t(cls) : CULL_FACE_NEVER;
        const uint32_t mask_bit = (cls < 6) ? (1u << cls) : CULL_MASK_NEVER_BIT;

        const size_t max_m = meshopt_buildMeshletsBound(ci.size(),
                                MESHLET_MAX_VERTICES, MESHLET_MAX_TRIANGLES);
        std::vector<meshopt_Meshlet> ms(max_m);
        std::vector<unsigned int>    mv(max_m * MESHLET_MAX_VERTICES);
        std::vector<unsigned char>   mt(max_m * MESHLET_MAX_TRIANGLES * 3);

        const size_t count = meshopt_buildMeshlets(
            ms.data(), mv.data(), mt.data(),
            ci.data(), ci.size(),
            &verts[0].x, verts.size(), sizeof(Vertex),
            MESHLET_MAX_VERTICES, MESHLET_MAX_TRIANGLES,
            0.0f);   // cone_weight 0: a forma do meshlet fica por conta do meshopt

        for (size_t i = 0; i < count; ++i) {
            const meshopt_Meshlet& m = ms[i];

            meshopt_optimizeMeshlet(&mv[m.vertex_offset], &mt[m.triangle_offset],
                                    m.triangle_count, m.vertex_count);

            Meshlet ml;
            ml.cull_mask = mask_bit;

            ml.vertices.resize(m.vertex_count);
            for (uint32_t v = 0; v < m.vertex_count; ++v) {
                ml.vertices[v] = verts[mv[m.vertex_offset + v]];
            }

            ml.packed.resize(m.triangle_count);
            for (uint32_t t = 0; t < m.triangle_count; ++t) {
                const uint32_t i0 = mt[m.triangle_offset + t * 3 + 0];
                const uint32_t i1 = mt[m.triangle_offset + t * 3 + 1];
                const uint32_t i2 = mt[m.triangle_offset + t * 3 + 2];
                ml.packed[t] = (i0 & 0xFFu) | ((i1 & 0xFFu) << 8) |
                               ((i2 & 0xFFu) << 16) | ((cf & 7u) << 24);
            }

            ml.bounds = meshopt_computeMeshletBounds(
                &mv[m.vertex_offset], &mt[m.triangle_offset], m.triangle_count,
                &verts[0].x, verts.size(), sizeof(Vertex));

            out.push_back(std::move(ml));
        }
    }
    return out;
}

// Junta meshlets pequenos (de classes diferentes) em bin-packing guloso.
// Como o conjunto mudou, os bounds são recalculados sobre a geometria mesclada.
static std::vector<Meshlet> merge_small(std::vector<Meshlet> in) {
    std::stable_sort(in.begin(), in.end(), [](const Meshlet& a, const Meshlet& b) {
        return a.packed.size() > b.packed.size();
    });

    std::vector<Meshlet> out;
    for (auto& cand : in) {
        bool placed = false;
        for (auto& dst : out) {
            if (dst.vertices.size() + cand.vertices.size() > MESHLET_MAX_VERTICES) continue;
            if (dst.packed.size()   + cand.packed.size()   > MESHLET_MAX_TRIANGLES) continue;

            const uint32_t base = uint32_t(dst.vertices.size());
            dst.vertices.insert(dst.vertices.end(), cand.vertices.begin(), cand.vertices.end());
            for (uint32_t pt : cand.packed) {
                const uint32_t i0 = (pt & 0xFFu) + base;
                const uint32_t i1 = ((pt >> 8) & 0xFFu) + base;
                const uint32_t i2 = ((pt >> 16) & 0xFFu) + base;
                const uint32_t cf = (pt >> 24) & 7u;
                dst.packed.push_back(i0 | (i1 << 8) | (i2 << 16) | (cf << 24));
            }
            dst.cull_mask |= cand.cull_mask;
            dst.bounds = bounds_of(dst.vertices, dst.packed);
            placed = true;
            break;
        }
        if (!placed) out.push_back(std::move(cand));
    }
    return out;
}

static bool validate_meshlet(const Meshlet& m) {
    if (m.vertices.empty() || m.vertices.size() > MESHLET_MAX_VERTICES) return false;
    if (m.packed.empty() || m.packed.size() > 126) return false;
    const uint32_t n = uint32_t(m.vertices.size());
    for (uint32_t pt : m.packed) {
        if ((pt & 0xFFu) >= n || ((pt >> 8) & 0xFFu) >= n || ((pt >> 16) & 0xFFu) >= n)
            return false;
    }
    return true;
}

static uint32_t pack_s8x3(const signed char a[3]) {
    return uint32_t(uint8_t(a[0])) |
           (uint32_t(uint8_t(a[1])) << 8) |
           (uint32_t(uint8_t(a[2])) << 16);
}

// ============================================================================
// 6. Main: parsing -> greedy -> welding -> LODs -> meshlets -> .vmesh
// ============================================================================
struct LodBuild {
    std::vector<Meshlet> meshlets;
    float error;
};

int main(int argc, char** argv) {
    std::printf("Uso: vox2vmesh <entrada.vox> <saida_prefixo> [lod_levels]\n");
    if (argc < 3) {
        std::printf("Ex:  vox2vmesh grass_tuft.vox assets/models/grass_tuft 3\n");
        return 1;
    }

    const std::string vox_path   = argv[1];
    const std::string out_prefix = argv[2];
    const int requested = (argc >= 4)
        ? std::clamp(std::atoi(argv[3]), 1, LOD_MAX)
        : 3;

    VoxModel model;
    std::string err;
    if (!parse_vox(vox_path, model, err)) {
        std::fprintf(stderr, "[ERRO] '%s': %s\n", vox_path.c_str(), err.c_str());
        return 1;
    }

    // Bloco cheio: cubo com todas as células preenchidas (solidez total)
    bool full_cube = model.size[0] == model.size[1] && model.size[1] == model.size[2];
    if (full_cube) {
        for (uint8_t c : model.grid) {
            if (c == 0) { full_cube = false; break; }
        }
    }

    // 1. Greedy meshing por cor
    RawMesh raw = build_greedy_mesh(model);
    if (raw.indices.empty()) {
        std::fprintf(stderr, "[ERRO] modelo sem faces visíveis\n");
        return 1;
    }

    // 2. Welding + otimização
    Welded welded = weld_and_optimize(raw);

    // 3. Cadeia de LODs
    auto levels = build_lod_chain(welded, requested);

    // 4. Meshlets por LOD (descarta LODs que não reduzem a contagem)
    std::vector<LodBuild> lods;
    for (const auto& level : levels) {
        const auto cull     = cull_faces_for(welded.vertices, level.indices);
        auto meshlets       = build_meshlets(welded.vertices, level.indices, cull);
        meshlets            = merge_small(std::move(meshlets));
        if (meshlets.empty()) break;
        if (!lods.empty() && meshlets.size() >= lods.back().meshlets.size()) break;
        lods.push_back({ std::move(meshlets), level.error });
    }
    if (lods.empty()) {
        std::fprintf(stderr, "[ERRO] nenhum LOD gerado\n");
        return 1;
    }

    // 5. Validação antes de gravar
    for (const auto& lod : lods) {
        for (const auto& m : lod.meshlets) {
            if (!validate_meshlet(m)) {
                std::fprintf(stderr, "[ERRO] meshlet inválido na validação\n");
                return 1;
            }
        }
    }

    // 6. Empacota os pools
    std::vector<HeavyTemplate>   out_lods;
    std::vector<TemplateMeshlet> out_meshlets;
    std::vector<float>           out_pos;   // float4 (x, y, z, 0)
    std::vector<uint32_t>        out_col;   // RGBA8 por vértice (mesmo índice de out_pos)
    std::vector<uint32_t>        out_tri;   // empacotado

    uint32_t flags = TEMPLATE_FLAG_HEAVY;
    if (full_cube) flags |= TEMPLATE_FLAG_FULL_CUBE;

    const uint32_t lod_total = uint32_t(lods.size());
    for (uint32_t l = 0; l < lod_total; ++l) {
        const LodBuild& lb = lods[l];

        HeavyTemplate ht{};
        ht.meshlet_base  = uint32_t(out_meshlets.size());
        ht.meshlet_count = uint32_t(lb.meshlets.size());
        ht.lod_info      = (l & 0xFFFFu) | (lod_total << 16);
        ht.lod_error     = lb.error;
        out_lods.push_back(ht);

        for (const auto& ml : lb.meshlets) {
            if ((ml.cull_mask & 0x3Fu) != 0u) flags |= TEMPLATE_FLAG_HAS_FLUSH_FACES;

            TemplateMeshlet tm{};
            tm.vertex_offset   = uint32_t(out_pos.size() / 4);
            tm.vertex_count    = uint32_t(ml.vertices.size());
            tm.triangle_offset = uint32_t(out_tri.size());
            tm.triangle_count  = uint32_t(ml.packed.size());
            tm.uv_offset       = NO_TEMPLATE_UV_OFFSET;
            tm.cull_mask       = ml.cull_mask;
            tm.center[0]       = ml.bounds.center[0];
            tm.center[1]       = ml.bounds.center[1];
            tm.center[2]       = ml.bounds.center[2];
            tm.radius          = ml.bounds.radius;
            tm.cone_axis_s8    = pack_s8x3(ml.bounds.cone_axis_s8);
            tm.cone_cutoff     = ml.bounds.cone_cutoff;
            out_meshlets.push_back(tm);

            for (const auto& v : ml.vertices) {
                out_pos.push_back(v.x);
                out_pos.push_back(v.y);
                out_pos.push_back(v.z);
                out_pos.push_back(0.0f);
                out_col.push_back(v.rgba);
            }
            out_tri.insert(out_tri.end(), ml.packed.begin(), ml.packed.end());
        }
    }

    // 7. Grava o .vmesh v2
    VmeshHeader header{};
    std::memcpy(header.magic, "VMSH", 4);
    header.version        = VMESH_VERSION;
    header.lod_count      = uint32_t(out_lods.size());
    header.meshlet_count  = uint32_t(out_meshlets.size());
    header.vertex_count   = uint32_t(out_pos.size() / 4);
    header.triangle_count = uint32_t(out_tri.size());
    header.flags          = flags;
    header.reserved       = 0;

    const std::string vmesh_path = out_prefix + ".vmesh";
    std::ofstream out(vmesh_path, std::ios::binary);
    if (!out) {
        std::fprintf(stderr, "[ERRO] não foi possível gravar '%s'\n", vmesh_path.c_str());
        return 1;
    }
    out.write(reinterpret_cast<const char*>(&header), sizeof(header));
    out.write(reinterpret_cast<const char*>(out_lods.data()),
              out_lods.size() * sizeof(HeavyTemplate));
    out.write(reinterpret_cast<const char*>(out_meshlets.data()),
              out_meshlets.size() * sizeof(TemplateMeshlet));
    out.write(reinterpret_cast<const char*>(out_pos.data()),
              out_pos.size() * sizeof(float));
    out.write(reinterpret_cast<const char*>(out_col.data()),
              out_col.size() * sizeof(uint32_t));
    out.write(reinterpret_cast<const char*>(out_tri.data()),
              out_tri.size() * sizeof(uint32_t));
    out.close();
    if (!out) {
        std::fprintf(stderr, "[ERRO] falha ao escrever '%s'\n", vmesh_path.c_str());
        return 1;
    }

    for (uint32_t l = 0; l < lod_total; ++l) {
        std::printf("  LOD %u: %u meshlets | erro %.5f\n",
                    l, out_lods[l].meshlet_count, out_lods[l].lod_error);
    }
    std::printf("[OK] '%s' (%dx%dx%d)%s -> %u LODs | %u meshlets | %u vértices | %u triângulos\n",
                vox_path.c_str(), model.size[0], model.size[1], model.size[2],
                full_cube ? " [cubo cheio]" : "",
                header.lod_count, header.meshlet_count, header.vertex_count, header.triangle_count);
    std::printf("     Binário: %s\n", vmesh_path.c_str());
    return 0;
}