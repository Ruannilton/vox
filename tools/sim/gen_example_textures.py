#!/usr/bin/env python3
# VS-12 (IMPL-04) — gera as PNGs de exemplo 16x16 (grama/terra/pedra) em
# assets/textures/. Padrões procedurais determinísticos com variação de tom
# por pixel (textura visível no smoke) e cores base casando com a paleta
# procedural antiga (grama 89,191,64 / terra 128,89,51 / pedra 140,140,148).

import os

from png_min import encode_png

SIZE = 16
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "textures")


def clamp(v):
    return max(0, min(255, int(v)))


def gen(base, fn):
    px = bytearray()
    for y in range(SIZE):
        for x in range(SIZE):
            r, g, b = base
            # variação determinística tipo valor de ruído leve
            n = ((x * 37 + y * 91 + x * y * 13) % 21) - 10
            # borda levemente mais escura (leitura de contorno no voxel)
            if x in (0, SIZE - 1) or y in (0, SIZE - 1):
                n -= 12
            px += bytes((clamp(r + n), clamp(g + n), clamp(b + n), 255))
    return encode_png(SIZE, SIZE, bytes(px))


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, base in (
        ("grama", (89, 191, 64)),
        ("terra", (128, 89, 51)),
        ("pedra", (140, 140, 148)),
    ):
        path = os.path.join(OUT, f"{name}.png")
        with open(path, "wb") as fh:
            fh.write(gen(base, None))
        print(f"gerado {path}")


if __name__ == "__main__":
    main()
