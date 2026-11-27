#!/usr/bin/env python3
"""Converts the TrueColor screen dump `xwd -root` writes to a PNG.

    xwd2png.py <in.xwd> <out.png>

smoke_test.sh runs it so the screenshot needs no ImageMagick, which CI used
to install on every linux-smoke job from a mirror that could stall
(KAP-316). Only the standard library is used.
"""
import struct
import sys
import zlib


def convert(xwd: bytes) -> bytes:
    header = struct.unpack(">25I", xwd[:100])
    (size, version, fmt, _, width, height, _, byte_order, _, _, _, bpp,
     stride, _, red, green, blue) = header[:17]
    colors = header[19]
    if version != 7 or fmt != 2 or bpp not in (24, 32):
        raise ValueError(f"not a TrueColor ZPixmap dump: version {version}, "
                         f"format {fmt}, {bpp} bits per pixel")
    order = "little" if byte_order == 0 else "big"
    step = bpp // 8
    start = size + colors * 12

    def shift(mask):
        return (mask & -mask).bit_length() - 1

    channels = [(mask, shift(mask)) for mask in (red, green, blue)]
    rows = bytearray()
    for y in range(height):
        line = xwd[start + y * stride:start + y * stride + width * step]
        rows.append(0)
        for x in range(0, width * step, step):
            pixel = int.from_bytes(line[x:x + step], order)
            rows.extend((pixel & mask) >> s for mask, s in channels)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(
            ">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))


if __name__ == "__main__":
    with open(sys.argv[1], "rb") as source:
        png = convert(source.read())
    with open(sys.argv[2], "wb") as target:
        target.write(png)
