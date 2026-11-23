from __future__ import annotations

import json
import math
import os
import tempfile
from dataclasses import dataclass

from tui_gateway.contracts.library import LibraryPreviewReason as Reason

from .tools import PreviewStopped, ToolInput, run_tool

POSTER_MAX_SECONDS = 1.0
POSTER_FRACTION = 0.1
_JPEG_MAGIC = b"\xff\xd8"
_QUARTER_TURNS = frozenset({90, 270})


@dataclass(frozen=True, slots=True)
class VideoInfo:
    duration_seconds: float | None = None
    width: int | None = None
    height: int | None = None


def _positive_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _duration(value: object) -> float | None:
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if math.isfinite(seconds) and seconds >= 0 else None


def _rotation(stream: dict) -> int:
    for side in stream.get("side_data_list") or ():
        if isinstance(side, dict) and "rotation" in side:
            return _rotation_degrees(side["rotation"])
    return _rotation_degrees((stream.get("tags") or {}).get("rotate"))


def _rotation_degrees(value: object) -> int:
    try:
        return int(float(value)) % 360
    except (TypeError, ValueError):
        return 0


def probe(ffprobe: str, source: ToolInput) -> VideoInfo | None:
    argv = [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height:stream_tags=rotate:stream_side_data=rotation:format=duration",
        "-of", "json", "-i", f"file:{source.arg}"]
    try:
        document = json.loads(run_tool(argv, source))
        streams = document.get("streams") or [{}]
        stream = streams[0] if isinstance(streams[0], dict) else {}
        width, height = _positive_int(stream.get("width")), _positive_int(stream.get("height"))
        if _rotation(stream) in _QUARTER_TURNS:
            width, height = height, width
        return VideoInfo(_duration((document.get("format") or {}).get("duration")), width, height)
    except (PreviewStopped, ValueError, AttributeError):
        return None


def poster_offset(info: VideoInfo | None) -> float:
    if info is None or info.duration_seconds is None:
        return 0.0
    return min(POSTER_MAX_SECONDS, info.duration_seconds * POSTER_FRACTION)


def poster(ffmpeg: str, source: ToolInput, offset: float, *, max_side: int, max_bytes: int) -> bytes:
    with tempfile.TemporaryDirectory(prefix="hermes-poster-") as scratch:
        out = os.path.join(scratch, "poster.jpg")
        scale = f"scale=w={max_side}:h={max_side}:force_original_aspect_ratio=decrease:force_divisible_by=2"
        argv = [
            ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-threads", "1",
            "-ss", f"{offset:.3f}", "-i", f"file:{source.arg}",
            "-frames:v", "1", "-an", "-sn", "-vf", scale,
            "-c:v", "mjpeg", "-q:v", "5", "-fs", str(max_bytes), "-update", "1", "-f", "image2", out]
        run_tool(argv, source)
        try:
            size = os.path.getsize(out)
            if size >= max_bytes:
                raise PreviewStopped(Reason.TOO_LARGE)
            with open(out, "rb") as handle:
                data = handle.read()
        except OSError as exc:
            raise PreviewStopped(Reason.RENDER_FAILED) from exc
    if not data.startswith(_JPEG_MAGIC):
        raise PreviewStopped(Reason.RENDER_FAILED)
    return data
