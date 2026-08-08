#!/usr/bin/env python3
"""
Generate the app icons.

Drawn here rather than checked in as opaque binaries, for the same reason the
sounds are synthesised: reproducible from the repo, no licensing question, and
changing the design is a code change rather than a binary blob swap.

    python build/make-icons.py

Writes PNGs, a Windows .ico and a macOS .icns to app/src-tauri/icons/. Tauri
needs specific sizes and, on Windows and macOS, those container formats.

No third-party imaging library: PNG is a handful of chunks around zlib-compressed
scanlines, and both .ico and .icns are small headers wrapping PNGs, so they are
cheaper to write than to depend on.
"""

import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'app', 'src-tauri', 'icons')

# Sizes Tauri expects, plus the ones the .ico wants.
PNG_SIZES = [32, 128, 256, 512]
ICO_SIZES = [16, 32, 48, 64, 256]
ICNS_SIZES = [32, 64, 128, 256, 512]

BG_TOP = (99, 91, 255)      # indigo
BG_BOTTOM = (56, 48, 190)
FG = (255, 255, 255)


def blend(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def draw(size):
    """A speaker with two arcs. Returns RGBA rows, top to bottom.

    Everything is computed in units of the canvas size, so the glyph is the same
    shape at 16px and 512px, and supersampled 3x3 so the curves are not jagged.
    """
    px = [[(0, 0, 0, 0)] * size for _ in range(size)]
    ss = 3
    cx, cy = size / 2.0, size / 2.0
    radius = size * 0.22          # corner radius of the rounded square

    # Speaker body, in canvas units.
    box_l, box_r = size * 0.24, size * 0.38
    box_t, box_b = size * 0.40, size * 0.60
    cone_tip_x = size * 0.56
    cone_half = size * 0.20

    for y in range(size):
        for x in range(size):
            inside_bg = 0
            inside_fg = 0
            for sy in range(ss):
                for sx in range(ss):
                    fx = x + (sx + 0.5) / ss
                    fy = y + (sy + 0.5) / ss

                    # Rounded square background.
                    dx = max(abs(fx - cx) - (size / 2.0 - radius), 0.0)
                    dy = max(abs(fy - cy) - (size / 2.0 - radius), 0.0)
                    if math.hypot(dx, dy) <= radius:
                        inside_bg += 1
                    else:
                        continue

                    # Speaker box.
                    if box_l <= fx <= box_r and box_t <= fy <= box_b:
                        inside_fg += 1
                        continue

                    # Triangular cone: widens from the box to the tip.
                    if box_r <= fx <= cone_tip_x:
                        t = (fx - box_r) / (cone_tip_x - box_r)
                        half = (box_b - box_t) / 2.0 + t * (cone_half - (box_b - box_t) / 2.0)
                        if abs(fy - cy) <= half:
                            inside_fg += 1
                            continue

                    # Two sound arcs to the right of the cone.
                    d = math.hypot(fx - cone_tip_x, fy - cy)
                    if fx > cone_tip_x:
                        # Only the part of each ring within a wedge, so they read
                        # as arcs rather than full circles.
                        ang = abs(math.atan2(fy - cy, fx - cone_tip_x))
                        if ang < math.radians(55):
                            for r in (size * 0.10, size * 0.17):
                                if abs(d - r) <= size * 0.028:
                                    inside_fg += 1
                                    break

            total = ss * ss
            if inside_bg == 0:
                continue
            bg = blend(BG_TOP, BG_BOTTOM, y / float(size - 1))
            alpha = int(round(255 * inside_bg / total))
            fg_cov = inside_fg / float(total)
            colour = blend(bg, FG, min(1.0, fg_cov * (total / max(inside_bg, 1))))
            px[y][x] = (colour[0], colour[1], colour[2], alpha)
    return px


def png_bytes(px):
    size = len(px)
    raw = b''
    for row in px:
        raw += b'\x00' + b''.join(struct.pack('BBBB', *p) for p in row)

    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)

    return (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw, 9))
        + chunk(b'IEND', b'')
    )


def ico_bytes(pngs):
    """A .ico wrapping PNG entries, which Windows Vista onward accepts."""
    count = len(pngs)
    header = struct.pack('<HHH', 0, 1, count)
    offset = 6 + 16 * count
    entries, blobs = b'', b''
    for size, data in pngs:
        entries += struct.pack(
            '<BBBBHHII',
            0 if size >= 256 else size,   # 0 means 256
            0 if size >= 256 else size,
            0, 0, 1, 32, len(data), offset,
        )
        blobs += data
        offset += len(data)
    return header + entries + blobs


def icns_bytes(pngs):
    """An .icns wrapping PNG entries, which macOS 10.7 onward accepts.

    The format is a magic, a total length, then typed chunks. Each type name
    implies a size, so they have to agree with the PNG that follows.
    """
    types = {32: b'ic11', 64: b'ic12', 128: b'ic07', 256: b'ic08', 512: b'ic09'}
    body = b''
    for size, data in pngs:
        tag = types[size]
        body += tag + struct.pack('>I', len(data) + 8) + data
    return b'icns' + struct.pack('>I', len(body) + 8) + body


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    cache = {}

    def render(size):
        if size not in cache:
            cache[size] = png_bytes(draw(size))
        return cache[size]

    for size in PNG_SIZES:
        name = '128x128@2x.png' if size == 256 else '%dx%d.png' % (size, size)
        path = os.path.join(OUT, name)
        with open(path, 'wb') as f:
            f.write(render(size))
        print('  %-18s %6d bytes' % (name, os.path.getsize(path)))

    # Tauri also looks for a plain icon.png.
    with open(os.path.join(OUT, 'icon.png'), 'wb') as f:
        f.write(render(512))
    print('  %-18s %6d bytes' % ('icon.png', os.path.getsize(os.path.join(OUT, 'icon.png'))))

    ico = ico_bytes([(s, render(s)) for s in ICO_SIZES])
    with open(os.path.join(OUT, 'icon.ico'), 'wb') as f:
        f.write(ico)
    print('  %-18s %6d bytes' % ('icon.ico', len(ico)))

    icns = icns_bytes([(s, render(s)) for s in ICNS_SIZES])
    with open(os.path.join(OUT, 'icon.icns'), 'wb') as f:
        f.write(icns)
    print('  %-18s %6d bytes' % ('icon.icns', len(icns)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
