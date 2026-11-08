#!/usr/bin/env python3
"""Puts the app icon on the canvas ios 6 expects for a prerendered icon (118x120 @2x, 59x60 @1x)
with a soft shadow in the margin. Without it springboard stretches the icon over the whole canvas."""
import struct
import sys
import zlib


def load(path):
    data = open(path, "rb").read()
    i, idat = 8, b""
    while i < len(data):
        size, kind = struct.unpack(">I4s", data[i : i + 8])
        chunk = data[i + 8 : i + 8 + size]
        i += 12 + size
        if kind == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
    assert depth == 8 and color == 6, path
    raw, pos, stride = zlib.decompress(idat), 0, w * 4
    prev, rows = bytearray(stride), []
    for _ in range(h):
        kind, row = raw[pos], bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = row[x - 4] if x >= 4 else 0
            b = prev[x]
            c = prev[x - 4] if x >= 4 else 0
            if kind == 1:
                row[x] = (row[x] + a) & 255
            elif kind == 2:
                row[x] = (row[x] + b) & 255
            elif kind == 3:
                row[x] = (row[x] + (a + b) // 2) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                row[x] = (row[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(row)
        prev = row
    return w, h, rows


def save(path, w, h, rows):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    raw = b"".join(b"\0" + bytes(r) for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def blur(alpha, w, h, radius):
    out = [[0.0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            near = [alpha[j][i] for j in range(max(0, y - radius), min(h, y + radius + 1))
                    for i in range(max(0, x - radius), min(w, x + radius + 1))]
            out[y][x] = sum(near) / ((2 * radius + 1) ** 2)
    return out


def pad(src, dst, cw, ch, ox, oy, drop, radius):
    w, h, rows = load(src)
    shape = [[0.0] * cw for _ in range(ch)]
    for y in range(h):
        for x in range(w):
            if oy + y + drop < ch:
                shape[oy + y + drop][ox + x] = rows[y][x * 4 + 3] / 255
    shadow = blur(shape, cw, ch, radius)
    out = [bytearray(cw * 4) for _ in range(ch)]
    for y in range(ch):
        for x in range(cw):
            out[y][x * 4 + 3] = int(shadow[y][x] * 0.5 * 255)
    for y in range(h):
        for x in range(w):
            r, g, b, a = rows[y][x * 4 : x * 4 + 4]
            under = out[oy + y][(ox + x) * 4 + 3] / 255
            top = a / 255
            total = top + under * (1 - top)
            px = [int(c * top / total) if total else 0 for c in (r, g, b)]
            out[oy + y][(ox + x) * 4 : (ox + x) * 4 + 4] = bytes(px + [int(total * 255)])
    save(dst, cw, ch, out)


src, dst = sys.argv[1], sys.argv[2]
pad(src + "/Icon@2x.png", dst + "/Icon@2x.png", 118, 120, 2, 1, 2, 2)
pad(src + "/Icon.png", dst + "/Icon.png", 59, 60, 1, 1, 1, 1)
