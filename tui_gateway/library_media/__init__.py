"""What ``library.asset`` needs beyond reading bytes: kind detection, preview images, a preview cache.

- ``sniff``: classify a file from its first 4 KB (kind, real MIME, whether the app may preview it).
- ``preview``: render one preview image (still image, video poster, first PDF page) or say why not.
- ``image`` / ``video`` / ``pdf``: the Pillow, ffmpeg + ffprobe and pdftoppm renderers.
- ``tools``: external-tool lookup, the bounded subprocess call and the concurrent-preview limit.
- ``cache``: the size-bounded on-disk cache of rendered previews.
- ``result``: the outcome of one preview attempt.
"""

from .cache import PreviewCache
from .image import Thumbnail, thumbnail
from .preview import (
    IMAGE_SOURCE_MAX_BYTES,
    PREVIEW_MAX_SIDE,
    VIDEO_SOURCE_MAX_BYTES,
    render,
)
from .result import PreviewResult
from .sniff import HEAD_BYTES, Sniffed, sniff

__all__ = [
    "HEAD_BYTES",
    "IMAGE_SOURCE_MAX_BYTES",
    "PREVIEW_MAX_SIDE",
    "VIDEO_SOURCE_MAX_BYTES",
    "PreviewCache",
    "PreviewResult",
    "Sniffed",
    "Thumbnail",
    "render",
    "sniff",
    "thumbnail",
]
