from __future__ import annotations

import os
import tempfile

from tui_gateway.contracts.library import LibraryPreviewReason as Reason

from .tools import PreviewStopped, ToolInput, run_tool

_JPEG_MAGIC = b"\xff\xd8"


def first_page(pdftoppm: str, source: ToolInput, *, max_side: int, max_bytes: int) -> bytes:
    with tempfile.TemporaryDirectory(prefix="hermes-pdf-") as scratch:
        root = os.path.join(scratch, "page")
        argv = [
            pdftoppm, "-jpeg", "-jpegopt", "quality=82", "-f", "1", "-l", "1",
            "-scale-to", str(max_side), "-singlefile", source.arg, root]
        run_tool(argv, source)
        try:
            with open(f"{root}.jpg", "rb") as handle:
                data = handle.read(max_bytes + 1)
        except OSError as exc:
            raise PreviewStopped(Reason.RENDER_FAILED) from exc
    if len(data) > max_bytes:
        raise PreviewStopped(Reason.TOO_LARGE)
    if not data.startswith(_JPEG_MAGIC):
        raise PreviewStopped(Reason.RENDER_FAILED)
    return data
