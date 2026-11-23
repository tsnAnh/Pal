from __future__ import annotations

import base64
import io
import logging
import re
from pathlib import Path

from PIL import Image

from tui_gateway.chat_install import DISCORD_IDENTITY_POLICY

logger = logging.getLogger(__name__)

FORBIDDEN_NAMES = re.compile(r"discord|clyde", re.IGNORECASE)
CHANNEL_NAME_MAX = 100
CATEGORY_NAME = "Pal"
FALLBACK_NAME = "pal"
AVATAR_TARGET_PX = 1024


def webhook_name(display_name: str) -> str:
    cleaned = " ".join(FORBIDDEN_NAMES.sub("", display_name).split())
    return (cleaned or FALLBACK_NAME)[: DISCORD_IDENTITY_POLICY.username_max].strip() or FALLBACK_NAME


def channel_slug(display_name: str) -> str:
    slug = re.sub(r"[^a-z0-9_]+", "-", display_name.lower()).strip("-")
    return (slug or FALLBACK_NAME)[:CHANNEL_NAME_MAX].strip("-") or FALLBACK_NAME


def unique_channel_name(display_name: str, taken: set[str]) -> str:
    base = channel_slug(display_name)
    name, suffix = base, 1
    while name in taken:
        suffix += 1
        tail = f"-{suffix}"
        name = f"{base[: CHANNEL_NAME_MAX - len(tail)]}{tail}"
    return name


def avatar_data_uri(path: str | None) -> str | None:
    if not path or not Path(path).is_file():
        return None
    try:
        with Image.open(path) as image:
            image.load()
            rgba = image.convert("RGBA")
    except (OSError, Image.DecompressionBombError):
        logger.warning("discord avatar unreadable, webhook keeps its default picture")
        return None
    side = min(rgba.size)
    left, top = (rgba.width - side) // 2, (rgba.height - side) // 2
    square = rgba.crop((left, top, left + side, top + side))
    if side > AVATAR_TARGET_PX:
        square = square.resize((AVATAR_TARGET_PX, AVATAR_TARGET_PX), Image.LANCZOS)
    out = io.BytesIO()
    square.save(out, format="PNG", optimize=True)
    if out.tell() > DISCORD_IDENTITY_POLICY.avatar_max_bytes:
        logger.warning("discord avatar too large, webhook keeps its default picture")
        return None
    return "data:image/png;base64," + base64.b64encode(out.getvalue()).decode("ascii")
