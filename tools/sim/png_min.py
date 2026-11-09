#!/usr/bin/env python3
# VS-12 — mini codec PNG (stdlib apenas): decode/encode de PNGs 8-bit
# não entrelaçados (color types 0, 2, 4, 6). Usado por assets_check.py
# (validação) e gen_example_textures.py (geração das PNGs de exemplo).

import struct
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


class PngError(Exception):
    pass


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(data):
    """Retorna (width, height, pixels) com pixels RGBA8 (list de bytes).
    VS-21: gray/palette de 1/2/4/8 bits acompanham o domínio do loader
    (stb_image normaliza tudo para RGBA8); demais color types seguem 8-bit."""
    if not data.startswith(PNG_SIG):
        raise PngError("assinatura PNG inválida")
    pos = len(PNG_SIG)
    width = height = None
    bit_depth = color_type = interlace = None
    idat = bytearray()
    palette = None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if len(body) != length:
            raise PngError("chunk truncado")
        pos += 12 + length
        if ctype == b"IHDR":
            width, height, bit_depth, color_type, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", body
            )
        elif ctype == b"PLTE":
            palette = body
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
    if width is None:
        raise PngError("IHDR ausente")
    if interlace != 0:
        raise PngError("PNG entrelaçado não suportado")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if channels is None:
        raise PngError(f"color type {color_type} não suportado")
    packed = color_type in (0, 3) and bit_depth in (1, 2, 4)
    if bit_depth != 8 and not packed:
        raise PngError(f"bit depth {bit_depth} não suportado para o color type {color_type}")
    if color_type == 3 and palette is None:
        raise PngError("PLTE ausente em PNG paletizado")
    try:
        raw = zlib.decompress(bytes(idat))
    except zlib.error as e:
        raise PngError(f"IDAT corrompido: {e}")
    if packed:
        stride = (width * channels * bit_depth + 7) // 8
        filter_bpp = max(1, (channels * bit_depth + 7) // 8)
    else:
        stride = width * channels
        filter_bpp = channels
    expected = (stride + 1) * height
    if len(raw) != expected:
        raise PngError(f"dados de pixel insuficientes: {len(raw)} != {expected}")
    # unfilter (bpp = bytes por pixel para o filtro)
    out = bytearray()
    prev = bytearray(stride)
    off = 0
    for _y in range(height):
        f = raw[off]
        line = bytearray(raw[off + 1 : off + 1 + stride])
        off += stride + 1
        if f == 1:  # Sub
            for i in range(filter_bpp, stride):
                line[i] = (line[i] + line[i - filter_bpp]) & 0xFF
        elif f == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:  # Average
            for i in range(stride):
                a = line[i - filter_bpp] if i >= filter_bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:  # Paeth
            for i in range(stride):
                a = line[i - filter_bpp] if i >= filter_bpp else 0
                c = prev[i - filter_bpp] if i >= filter_bpp else 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 0xFF
        elif f != 0:
            raise PngError(f"filtro desconhecido {f}")
        out += line
        prev = line

    def unpack_sample(line, pixel_index):
        """Extrai gray/índice de paleta de uma linha compactada por bit depth."""
        bitpos = pixel_index * channels * bit_depth
        if bit_depth == 8:
            return line[bitpos // 8]
        shift = 8 - bit_depth - (bitpos % 8)
        mask = (1 << bit_depth) - 1
        return (line[bitpos // 8] >> shift) & mask

    pixels = bytearray(width * height * 4)
    scale = 255 // ((1 << bit_depth) - 1) if packed else 0
    for y in range(height):
        line = out[y * stride : (y + 1) * stride]
        for x in range(width):
            d = (y * width + x) * 4
            if packed:
                v = unpack_sample(line, x)
                if color_type == 3:
                    idx = v * 3
                    if idx + 3 > len(palette):
                        raise PngError("índice de paleta fora do range")
                    pixels[d : d + 4] = palette[idx : idx + 3] + b"\xff"
                else:
                    g = v * scale
                    pixels[d : d + 4] = bytes((g, g, g, 255))
                continue
            s = (y * width + x) * channels
            if color_type == 0:
                g = out[s]
                pixels[d : d + 4] = bytes((g, g, g, 255))
            elif color_type == 2:
                pixels[d : d + 4] = out[s : s + 3] + b"\xff"
            elif color_type == 3:
                idx = out[s] * 3
                if idx + 3 > len(palette):
                    raise PngError("índice de paleta fora do range")
                pixels[d : d + 4] = palette[idx : idx + 3] + b"\xff"
            elif color_type == 4:
                pixels[d : d + 4] = out[s : s + 2] + out[s : s + 1] + b"\xff"
            else:  # 6
                pixels[d : d + 4] = out[s : s + 4]
    return width, height, bytes(pixels)


def encode_png(width, height, pixels):
    """pixels: bytes RGBA8 (width*height*4). Gera PNG color type 6, filter 0."""

    def chunk(ctype, body):
        c = struct.pack(">I", len(body)) + ctype + body
        return c + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * width * 4 : (y + 1) * width * 4]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return PNG_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")
