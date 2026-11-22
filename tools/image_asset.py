from __future__ import annotations

import base64
import binascii
import re
from typing import Literal

MAX_ASSET_BYTES = 2_000_000
ASSET_EXTS = {"png": "image/png", "jpg": "image/jpeg", "webp": "image/webp"}
ASSET_MAGIC = {
    "png": [(0, 8, b"\x89PNG\r\n\x1a\n")],
    "jpg": [(0, 3, b"\xff\xd8\xff")],
    "webp": [(0, 4, b"RIFF"), (8, 12, b"WEBP")],
}
_DATA_URL = re.compile(r"^data:(image/(?:png|jpeg|webp));base64,(.*)$", re.DOTALL)
_MAX_ENCODED_CHARS = (MAX_ASSET_BYTES + 2) // 3 * 4

Kind = Literal["encoding", "size", "format"]


class ImageAssetError(ValueError):
    def __init__(self, kind: Kind, message: str) -> None:
        super().__init__(message)
        self.kind = kind


def sniff_image_ext(blob: bytes, allowed: tuple[str, ...] = tuple(ASSET_EXTS)) -> str | None:
    return next((ext for ext in allowed if all(blob[a:b] == m for a, b, m in ASSET_MAGIC[ext])), None)


def decode_image(data: str, allowed: tuple[str, ...] = tuple(ASSET_EXTS)) -> tuple[bytes, str]:
    match = _DATA_URL.match(data)
    payload = match.group(2) if match else data
    if len(payload) > _MAX_ENCODED_CHARS:
        raise ImageAssetError("size", f"asset too large (max {MAX_ASSET_BYTES // 1_000_000}MB)")
    try:
        blob = base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ImageAssetError("encoding", "data is not valid base64") from exc
    if len(blob) > MAX_ASSET_BYTES:
        raise ImageAssetError("size", f"asset too large ({len(blob)} bytes; max {MAX_ASSET_BYTES // 1_000_000}MB)")
    ext = sniff_image_ext(blob, allowed)
    if ext is None:
        raise ImageAssetError("format", f"unsupported image format ({'/'.join(e.upper() for e in allowed)} only)")
    return blob, ext
