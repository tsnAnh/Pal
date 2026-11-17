from __future__ import annotations

import io

from PIL import Image

from tui_gateway.chat_install import SLACK_IDENTITY_POLICY

AVATAR_MAX_PX = 2000
AVATAR_TARGET_PX = 1024
AVATAR_BACKGROUND = (255, 255, 255)


def prepare_avatar(source: bytes) -> bytes:
    with Image.open(io.BytesIO(source)) as image:
        image.load()
        rgba = image.convert("RGBA")
    side = min(rgba.size)
    left, top = (rgba.width - side) // 2, (rgba.height - side) // 2
    square = rgba.crop((left, top, left + side, top + side))
    target = min(max(side, SLACK_IDENTITY_POLICY.avatar_min_px), AVATAR_MAX_PX)
    for size in (target, AVATAR_TARGET_PX, SLACK_IDENTITY_POLICY.avatar_min_px):
        opaque = Image.new("RGB", (size, size), AVATAR_BACKGROUND)
        resized = square.resize((size, size), Image.LANCZOS)
        opaque.paste(resized, mask=resized.getchannel("A"))
        out = io.BytesIO()
        opaque.save(out, format="PNG", optimize=True)
        if out.tell() <= SLACK_IDENTITY_POLICY.avatar_max_bytes:
            return out.getvalue()
    raise ValueError("avatar cannot fit the Slack size limit")
