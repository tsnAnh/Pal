from __future__ import annotations

import io
from pathlib import Path

from PIL import Image

from tools.image_asset import ImageAssetError
from utils.files import atomic_write_bytes

ICON_FILE = "icon.png"
ICON_MIN_PX = 256
ICON_MAX_PX = 4096


def icon_path(bot: str) -> Path:
    from hermes_cli.profiles import get_profile_dir
    return Path(get_profile_dir(bot)) / "chat_slack" / ICON_FILE


def store_icon(bot: str, png: bytes) -> None:
    try:
        with Image.open(io.BytesIO(png)) as image:
            width, height = image.size
            image.verify()
    except (OSError, SyntaxError, Image.DecompressionBombError):
        raise ImageAssetError("format", "the picture could not be read") from None
    if not (ICON_MIN_PX <= min(width, height) and max(width, height) <= ICON_MAX_PX):
        raise ImageAssetError("size", f"the picture must be between {ICON_MIN_PX} and {ICON_MAX_PX} pixels")
    path = icon_path(bot)
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_bytes(path, png)
