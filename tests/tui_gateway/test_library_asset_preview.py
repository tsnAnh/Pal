"""``library.asset`` preview mode: the poster frame, first page or still image the chat bubble shows."""
from __future__ import annotations

import base64
import io
import json
import os
import shutil
import subprocess
import threading
from types import SimpleNamespace

import pytest

from tests.tui_gateway import test_library_rpc as library
from tui_gateway.library_media import PreviewResult, cache, image, tools
from tui_gateway.library_media import preview as preview_module

_call, _error, _ok, _png, _seed = library._call, library._error, library._ok, library._png, library._seed
bots = library.bots

MP4_HEAD = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"
PDF = b"%PDF-1.4\n%fixture\n"
HEIC_HEAD = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00heicmif1"
ELF = b"\x7fELF\x02\x01\x01" + b"\0" * 64


def _index(bots, path, *, profile="alpha"):
    seed = _seed(bots[profile])
    seed.message("s1", "assistant", f"here\nMEDIA:{path}")
    seed.close()
    items = _ok("library.list", {"profile": profile})["items"]
    return next(item["asset_ref"] for item in items if item["title"] == path.name)


def _media(bots, name, data, folder="documents", profile="alpha"):
    path = bots[profile] / "cache" / folder / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _preview(ref, **extra):
    return _ok("library.asset", {"profile": "alpha", "asset_ref": ref, "preview": True, **extra})


def _jpeg(size=(512, 288)) -> bytes:
    from PIL import Image
    buffer = io.BytesIO()
    Image.new("RGB", size, (10, 120, 200)).save(buffer, format="JPEG")
    return buffer.getvalue()


class FakeTools:
    """Stands in for ffprobe and ffmpeg: records argv and kwargs, writes the poster where ffmpeg is told to."""

    def __init__(self, monkeypatch, *, duration="3.000000", width=1920, height=1080, rotation=None,
                 ffmpeg_code=0, timeout=False):
        self.calls: list[tuple[list[str], dict]] = []
        self.duration, self.width, self.height, self.rotation = duration, width, height, rotation
        self.ffmpeg_code, self.timeout = ffmpeg_code, timeout
        monkeypatch.setattr(preview_module, "find_tool", lambda name: f"/opt/fake/{name}")
        monkeypatch.setattr(subprocess, "run", self._run)

    @property
    def ffmpeg_calls(self):
        return [call for call in self.calls if call[0][0].endswith("ffmpeg")]

    def _run(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        if argv[0].endswith("ffprobe"):
            stream = {"width": self.width, "height": self.height}
            if self.rotation is not None:
                stream["side_data_list"] = [{"rotation": self.rotation}]
            body = {"streams": [stream], "format": {"duration": self.duration}}
            return SimpleNamespace(returncode=0, stdout=json.dumps(body).encode())
        if self.timeout:
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
        if self.ffmpeg_code == 0:
            with open(argv[-1], "wb") as out:
                out.write(_jpeg())
        return SimpleNamespace(returncode=self.ffmpeg_code, stdout=b"")


def test_a_png_previews_as_a_bounded_image_with_its_true_size_and_kind(bots):
    from PIL import Image
    path = bots["alpha"] / "cache" / "images" / "big.png"
    original = _png(path)
    result = _preview(_index(bots, path))
    data = base64.b64decode(result["data_base64"])
    assert max(Image.open(io.BytesIO(data)).size) <= 512
    assert result["mime"] == "image/jpeg" and result["size"] == len(data)
    assert (result["kind"], result["sniffed_mime"], result["previewable"]) == ("image", "image/png", True)
    assert (result["total"], result["width"], result["height"]) == (len(original), 1200, 800)
    assert "preview_reason" not in result


def test_a_jpeg_and_a_transparent_png_keep_their_formats(bots):
    from PIL import Image
    jpeg = bots["alpha"] / "cache" / "images" / "photo.jpg"
    jpeg.parent.mkdir(parents=True)
    jpeg.write_bytes(_jpeg((900, 600)))
    clear = bots["alpha"] / "cache" / "images" / "clear.png"
    Image.new("RGBA", (700, 700), (0, 0, 0, 0)).save(clear)
    assert _preview(_index(bots, jpeg))["mime"] == "image/jpeg"
    assert _preview(_index(bots, clear))["mime"] == "image/png"


def test_a_preview_larger_than_max_bytes_is_reported_not_truncated(bots):
    path = bots["alpha"] / "cache" / "images" / "big.png"
    _png(path)
    result = _preview(_index(bots, path), max_bytes=100)
    assert result["data_base64"] == "" and result["size"] == 0
    assert result["preview_reason"] == "too_large" and result["kind"] == "image"


def test_heic_without_a_decoder_falls_back_to_the_device(bots, monkeypatch):
    monkeypatch.setattr(image, "heif_available", lambda: False)
    path = _media(bots, "IMG_1.HEIC", HEIC_HEAD + b"\0" * 64, folder="images")
    result = _preview(_index(bots, path))
    assert result["data_base64"] == "" and result["preview_reason"] == "heic_decoder_missing"
    assert (result["kind"], result["sniffed_mime"], result["previewable"]) == ("image", "image/heic", True)
    assert result["total"] == path.stat().st_size


def test_pdf_without_a_renderer_falls_back(bots, monkeypatch):
    monkeypatch.setattr(preview_module, "find_tool", lambda name: None)
    path = _media(bots, "paper.pdf", PDF)
    result = _preview(_index(bots, path))
    assert result["preview_reason"] == "pdf_renderer_missing" and result["kind"] == "pdf"


@pytest.mark.skipif(shutil.which("pdftoppm") is None, reason="pdftoppm is not installed")
def test_pdf_first_page_renders_with_pdftoppm(bots):
    from PIL import Image
    path = bots["alpha"] / "cache" / "documents" / "page.pdf"
    path.parent.mkdir(parents=True)
    Image.new("RGB", (612, 792), (255, 255, 255)).save(path, format="PDF")
    result = _preview(_index(bots, path))
    data = base64.b64decode(result["data_base64"])
    assert data.startswith(b"\xff\xd8") and result["mime"] == "image/jpeg"
    assert max(Image.open(io.BytesIO(data)).size) <= 512


def test_video_poster_uses_ffmpeg_with_a_safe_argv_and_returns_metadata(bots, monkeypatch):
    fake = FakeTools(monkeypatch)
    path = _media(bots, "clip.mp4", MP4_HEAD + b"\0" * 4096, folder="videos")
    result = _preview(_index(bots, path))
    assert (result["kind"], result["sniffed_mime"], result["previewable"]) == ("video", "video/mp4", True)
    assert (result["duration_seconds"], result["width"], result["height"]) == (3.0, 1920, 1080)
    assert result["mime"] == "image/jpeg" and base64.b64decode(result["data_base64"]).startswith(b"\xff\xd8")
    assert result["total"] == path.stat().st_size

    (probe, probe_kwargs), (poster, _) = fake.calls
    for argv, kwargs in fake.calls:
        assert argv[0].startswith("/opt/fake/") and isinstance(argv, list)
        assert kwargs["shell"] is False and kwargs["timeout"] == tools.TOOL_TIMEOUT_SECONDS == 10
        assert kwargs["stdin"] == subprocess.DEVNULL
        assert str(path) not in argv
        source = argv[argv.index("-i") + 1]
        assert source.startswith("file:/dev/fd/")
        assert kwargs["pass_fds"] == (int(source.rsplit("/", 1)[1]),)
    assert "-nostdin" in poster
    assert poster[poster.index("-ss") + 1] == "0.300"
    assert poster[poster.index("-frames:v") + 1] == "1"
    assert "scale=w=512:h=512" in poster[poster.index("-vf") + 1]
    assert poster[poster.index("-fs") + 1] == str(8_000_000)
    assert not os.path.exists(os.path.dirname(poster[-1]))
    assert "-show_entries" in probe and probe_kwargs["timeout"] == 10


def test_the_poster_frame_is_at_one_second_for_long_videos(bots, monkeypatch):
    fake = FakeTools(monkeypatch, duration="600.0")
    path = _media(bots, "long.mov", b"\x00\x00\x00\x14ftypqt  \0\0\0\0qt  " + b"\0" * 64, folder="videos")
    _preview(_index(bots, path))
    poster = fake.ffmpeg_calls[0][0]
    assert poster[poster.index("-ss") + 1] == "1.000"


def test_a_rotated_phone_video_reports_its_displayed_size(bots, monkeypatch):
    FakeTools(monkeypatch, width=1920, height=1080, rotation=-90)
    path = _media(bots, "phone.mov", b"\x00\x00\x00\x14ftypqt  \0\0\0\0qt  " + b"\0" * 64, folder="videos")
    result = _preview(_index(bots, path))
    assert (result["width"], result["height"]) == (1080, 1920)


def test_unknown_duration_takes_the_first_frame(bots, monkeypatch):
    fake = FakeTools(monkeypatch, duration="N/A")
    path = _media(bots, "live.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    result = _preview(_index(bots, path))
    assert "duration_seconds" not in result
    assert fake.ffmpeg_calls[0][0][fake.ffmpeg_calls[0][0].index("-ss") + 1] == "0.000"


def test_video_without_ffmpeg_falls_back_to_the_device(bots, monkeypatch):
    monkeypatch.setattr(preview_module, "find_tool", lambda name: None)
    path = _media(bots, "clip.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    result = _preview(_index(bots, path))
    assert result["preview_reason"] == "ffmpeg_missing" and result["data_base64"] == ""
    assert (result["kind"], result["previewable"]) == ("video", True)


def test_a_failed_poster_keeps_the_probed_metadata_and_is_remembered(bots, monkeypatch):
    fake = FakeTools(monkeypatch, ffmpeg_code=1)
    path = _media(bots, "broken.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    ref = _index(bots, path)
    result = _preview(ref)
    assert result["preview_reason"] == "render_failed" and result["data_base64"] == ""
    assert (result["width"], result["height"], result["duration_seconds"]) == (1920, 1080, 3.0)
    calls = len(fake.calls)
    assert _preview(ref)["preview_reason"] == "render_failed" and len(fake.calls) == calls


def test_a_timeout_is_reported_and_not_remembered(bots, monkeypatch):
    fake = FakeTools(monkeypatch, timeout=True)
    path = _media(bots, "stuck.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    ref = _index(bots, path)
    assert _preview(ref)["preview_reason"] == "timed_out"
    before = len(fake.ffmpeg_calls)
    assert _preview(ref)["preview_reason"] == "timed_out" and len(fake.ffmpeg_calls) == before + 1


def test_a_cached_preview_skips_ffmpeg_until_the_file_changes(bots, monkeypatch):
    fake = FakeTools(monkeypatch)
    path = _media(bots, "clip.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    ref = _index(bots, path)
    first = _preview(ref)
    assert len(fake.ffmpeg_calls) == 1
    assert _preview(ref) == first and len(fake.ffmpeg_calls) == 1
    stat = path.stat()
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000))
    _preview(ref)
    assert len(fake.ffmpeg_calls) == 2


def test_a_cached_preview_obeys_a_smaller_max_bytes(bots, monkeypatch):
    FakeTools(monkeypatch)
    path = _media(bots, "clip.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    ref = _index(bots, path)
    assert _preview(ref)["size"] > 0
    small = _preview(ref, max_bytes=100)
    assert small["data_base64"] == "" and small["preview_reason"] == "too_large"


def test_the_cache_stays_inside_its_size_bound(tmp_path):
    store = cache.PreviewCache(tmp_path, max_bytes=2_500)
    for index in range(5):
        store.put(f"{index:032x}", 1, 1, PreviewResult(b"x" * 600, "image/jpeg"))
        os.utime(tmp_path / f"{index:032x}-1-1.json", (index, index))
    names = sorted(p.name for p in tmp_path.glob("*.json"))
    assert sum((tmp_path / name).stat().st_size for name in names) <= 2_500
    assert f"{4:032x}-1-1.json" in names and f"{0:032x}-1-1.json" not in names


def test_the_preview_cache_is_not_a_servable_media_root(bots):
    from tui_gateway.library_assets import PREVIEW_CACHE_DIR, serve_roots
    cache_dir = (bots["alpha"] / PREVIEW_CACHE_DIR).resolve()
    assert all(root != cache_dir and root not in cache_dir.parents for root in serve_roots(bots["alpha"]))


def test_a_video_over_the_source_cap_is_not_probed(bots, monkeypatch):
    fake = FakeTools(monkeypatch)
    path = _media(bots, "huge.mp4", MP4_HEAD, folder="videos")
    os.truncate(path, 200_000_001)
    result = _preview(_index(bots, path))
    assert result["preview_reason"] == "too_large" and result["total"] == 200_000_001 and not fake.calls


@pytest.mark.parametrize(("name", "data", "kind", "reason"), [
    ("track.mp3", b"ID3\x04" + b"\0" * 64, "audio", "unsupported_kind"),
    ("notes.txt", b"plain words\n", "document", "unsupported_kind"),
    ("archive.zip", b"PK\x03\x04" + b"\0" * 64, "archive", "not_previewable"),
    ("page.html", b"<!doctype html><p>x</p>", "document", "not_previewable"),
    ("vector.svg", b'<svg xmlns="http://www.w3.org/2000/svg"/>', "image", "not_previewable"),
    ("photo.png", ELF, "other", "not_previewable"),
    ("run.txt", b"#!/bin/sh\nid\n", "other", "not_previewable"),
    ("blob.bin", b"\0\1\2\3\xff", "other", "not_previewable"),
])
def test_everything_else_says_why_there_is_no_preview(bots, monkeypatch, name, data, kind, reason):
    fake = FakeTools(monkeypatch)
    path = _media(bots, name, data)
    result = _preview(_index(bots, path))
    assert result["data_base64"] == "" and result["size"] == 0
    assert (result["kind"], result["preview_reason"]) == (kind, reason)
    assert result["total"] == len(data) and not fake.calls


def test_a_busy_gateway_answers_busy_instead_of_queueing_forever(bots, monkeypatch):
    FakeTools(monkeypatch)
    monkeypatch.setattr(tools, "PREVIEW_QUEUE_SECONDS", 0.05)
    path = _media(bots, "clip.mp4", MP4_HEAD + b"\0" * 64, folder="videos")
    ref = _index(bots, path)
    with tools.preview_slot(), tools.preview_slot():
        assert _preview(ref)["preview_reason"] == "busy"
    assert _preview(ref)["data_base64"] != ""


def test_no_more_previews_run_at_once_than_the_limit(monkeypatch):
    monkeypatch.setattr(tools, "PREVIEW_QUEUE_SECONDS", 0.05)
    entered = []
    held = threading.Event()
    done = threading.Event()

    def hold():
        with tools.preview_slot():
            entered.append(1)
            if len(entered) == tools.PREVIEW_CONCURRENCY:
                held.set()
            done.wait(10)

    threads = [threading.Thread(target=hold) for _ in range(tools.PREVIEW_CONCURRENCY)]
    for thread in threads:
        thread.start()
    assert held.wait(10)
    with pytest.raises(tools.PreviewStopped) as stopped, tools.preview_slot():
        pass
    assert stopped.value.reason.value == "busy"
    done.set()
    for thread in threads:
        thread.join(10)


@pytest.mark.skipif(shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None, reason="ffmpeg is not installed")
def test_a_real_video_gets_a_real_poster(bots):
    from PIL import Image
    path = bots["alpha"] / "cache" / "videos" / "real.mp4"
    path.parent.mkdir(parents=True)
    subprocess.run(
        [shutil.which("ffmpeg"), "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
         "testsrc=size=640x360:rate=10:duration=3", "-pix_fmt", "yuv420p", str(path)],
        check=True, timeout=60)
    result = _preview(_index(bots, path))
    data = base64.b64decode(result["data_base64"])
    assert Image.open(io.BytesIO(data)).size == (512, 288)
    assert (result["width"], result["height"]) == (640, 360)
    assert result["duration_seconds"] == pytest.approx(3.0, abs=0.2)
    assert (result["kind"], result["mime"]) == ("video", "image/jpeg")
