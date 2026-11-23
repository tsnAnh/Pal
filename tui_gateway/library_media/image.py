from __future__ import annotations

import functools
from dataclasses import dataclass
from io import BytesIO
from typing import BinaryIO


@dataclass(frozen=True, slots=True)
class Thumbnail:
    data: bytes
    mime: str
    width: int
    height: int


@functools.cache
def heif_available() -> bool:
    try:
        import pillow_heif
        pillow_heif.register_heif_opener()
    except (ImportError, OSError, RuntimeError):
        return False
    return True


def thumbnail(source: BinaryIO, max_side: int) -> Thumbnail | None:
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        with Image.open(source) as image:
            image.load()
            width, height = image.size
            image.thumbnail((max_side, max_side))
            has_alpha = image.mode in ("RGBA", "LA") or (image.mode == "P" and "transparency" in image.info)
            out = BytesIO()
            if has_alpha:
                image.convert("RGBA").save(out, format="PNG", optimize=True)
                return Thumbnail(out.getvalue(), "image/png", width, height)
            image.convert("RGB").save(out, format="JPEG", quality=82, optimize=True)
            return Thumbnail(out.getvalue(), "image/jpeg", width, height)
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError):
        return None
