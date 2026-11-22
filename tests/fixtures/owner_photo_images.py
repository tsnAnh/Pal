from __future__ import annotations

import base64
import struct
import zlib


def png(seed: int = 0, size: int = 8) -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    rows = b"".join(b"\x00" + bytes((seed + x + y) % 256 for x in range(size) for _ in range(3)) for y in range(size))
    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def jpeg(seed: int = 0) -> bytes:
    return b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" + bytes([seed % 256]) * 64 + b"\xff\xd9"


def webp() -> bytes:
    return b"RIFF" + struct.pack("<I", 12) + b"WEBPVP8 " + b"\x00" * 16


def gif() -> bytes:
    return b"GIF89a\x01\x00\x01\x00\x00\x00\x00;"


def b64(blob: bytes) -> str:
    return base64.b64encode(blob).decode("ascii")


def png_of_size(total_bytes: int) -> bytes:
    return png() + b"\x00" * (total_bytes - len(png()))
