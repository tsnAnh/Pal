"""``library.asset`` ranges: a big file streams into the app a couple of megabytes per call."""
from __future__ import annotations

import base64
import hashlib
import os

import pytest

from tests.tui_gateway import test_library_rpc as library
from tui_gateway.library_assets import CHUNK_MAX_BYTES, DOWNLOAD_MAX_BYTES, AssetUnavailable, _open_regular

_call, _error, _ok, _png, _seed = library._call, library._error, library._ok, library._png, library._seed
bots = library.bots

MP4_HEAD = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2"


def _index(bots, path):
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"here\nMEDIA:{path}")
    seed.close()
    items = _ok("library.list", {"profile": "alpha"})["items"]
    return next(item["asset_ref"] for item in items if item["title"] == path.name)


@pytest.fixture
def big(bots):
    data = MP4_HEAD + os.urandom(5_000_000)
    path = bots["alpha"] / "cache" / "videos" / "big.mp4"
    path.parent.mkdir(parents=True)
    path.write_bytes(data)
    return _index(bots, path), data


def _range(ref, **extra):
    return _ok("library.asset", {"profile": "alpha", "asset_ref": ref, **extra})


def _bytes(result):
    return base64.b64decode(result["data_base64"])


def test_first_middle_and_last_ranges(big):
    ref, data = big
    first = _range(ref, offset=0, length=1000)
    assert _bytes(first) == data[:1000]
    assert (first["offset"], first["length"], first["total"], first["size"]) == (0, 1000, len(data), 1000)
    assert (first["kind"], first["sniffed_mime"], first["mime"]) == ("video", "video/mp4", "video/mp4")
    middle = _range(ref, offset=2_000_000, length=777)
    assert _bytes(middle) == data[2_000_000:2_000_777] and middle["offset"] == 2_000_000
    last = _range(ref, offset=len(data) - 10, length=100)
    assert _bytes(last) == data[-10:] and last["length"] == 10 and last["total"] == len(data)


def test_a_range_past_the_end_is_empty_and_still_reports_the_total(big):
    ref, data = big
    for offset in (len(data), len(data) + 1, 10**30):
        empty = _range(ref, offset=offset, length=10)
        assert empty["data_base64"] == "" and empty["length"] == 0 and empty["total"] == len(data)
        assert empty["offset"] == offset


def test_one_call_never_returns_more_than_the_chunk_limit(big):
    ref, data = big
    wide = _range(ref, offset=0, length=50_000_000)
    assert wide["length"] == CHUNK_MAX_BYTES and _bytes(wide) == data[:CHUNK_MAX_BYTES]
    unbounded = _range(ref, offset=0)
    assert unbounded["length"] == CHUNK_MAX_BYTES


def test_chunks_reassemble_the_exact_file(big):
    ref, data = big
    out, offset = bytearray(), 0
    while offset < len(data):
        part = _range(ref, offset=offset)
        out += _bytes(part)
        offset += part["length"]
    assert hashlib.sha256(out).digest() == hashlib.sha256(data).digest()


def test_a_length_alone_starts_at_the_beginning(big):
    ref, data = big
    assert _bytes(_range(ref, length=64)) == data[:64]


@pytest.mark.parametrize("extra", [
    {"offset": -1}, {"offset": 0, "length": 0}, {"offset": 0, "length": -5}, {"offset": "x"},
    {"preview": True, "offset": 0}, {"preview": True, "length": 10}])
def test_an_invalid_range_is_a_clear_error(big, extra):
    ref, _ = big
    assert _error("library.asset", {"profile": "alpha", "asset_ref": ref, **extra}) == 4153


def test_a_file_over_the_download_limit_answers_4152_with_its_size(bots):
    path = bots["alpha"] / "cache" / "videos" / "huge.mp4"
    path.parent.mkdir(parents=True)
    path.write_bytes(MP4_HEAD)
    os.truncate(path, DOWNLOAD_MAX_BYTES + 1)
    ref = _index(bots, path)
    response = _call("library.asset", {"profile": "alpha", "asset_ref": ref, "offset": 0})
    assert response["error"]["code"] == 4152
    assert response["error"]["data"] == {"size": DOWNLOAD_MAX_BYTES + 1, "limit": DOWNLOAD_MAX_BYTES}
    assert "200 MB" in response["error"]["message"]


def test_a_file_exactly_at_the_download_limit_can_be_read(bots):
    path = bots["alpha"] / "cache" / "videos" / "edge.mp4"
    path.parent.mkdir(parents=True)
    path.write_bytes(MP4_HEAD)
    os.truncate(path, DOWNLOAD_MAX_BYTES)
    result = _range(_index(bots, path), offset=DOWNLOAD_MAX_BYTES - 5, length=5)
    assert result["length"] == 5 and result["total"] == DOWNLOAD_MAX_BYTES


def test_the_whole_file_call_old_apps_make_is_unchanged(bots):
    path = bots["alpha"] / "cache" / "images" / "pic.png"
    original = _png(path)
    ref = _index(bots, path)
    whole = _ok("library.asset", {"profile": "alpha", "asset_ref": ref, "thumbnail": False, "max_bytes": 16_000_000})
    assert _bytes(whole) == original
    assert (whole["mime"], whole["size"], whole["total"]) == ("image/png", len(original), len(original))
    assert "offset" not in whole and "length" not in whole and "preview_reason" not in whole
    over = _call("library.asset", {"profile": "alpha", "asset_ref": ref, "thumbnail": False, "max_bytes": 100})
    assert over["error"]["code"] == 4152 and over["error"]["data"]["size"] == len(original)


def test_the_old_call_still_stops_at_sixteen_megabytes(bots):
    path = bots["alpha"] / "cache" / "videos" / "wide.mp4"
    path.parent.mkdir(parents=True)
    path.write_bytes(MP4_HEAD)
    os.truncate(path, 16_000_001)
    ref = _index(bots, path)
    response = _call("library.asset", {"profile": "alpha", "asset_ref": ref, "thumbnail": False, "max_bytes": 10**9})
    assert response["error"]["code"] == 4152 and response["error"]["data"]["limit"] == 16_000_000


def test_a_symlink_to_a_protected_file_is_refused_in_every_mode(bots):
    (bots["beta"] / ".env").write_text("TOKEN=other-profile-secret\n")
    link = bots["alpha"] / "cache" / "images" / "link.png"
    link.parent.mkdir(parents=True)
    link.symlink_to(bots["beta"] / ".env")
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"look\nMEDIA:{link}")
    seed.close()
    ref = _ok("library.list", {"profile": "alpha"})["items"][0]["id"]
    for extra in ({}, {"preview": True}, {"offset": 0}):
        assert _error("library.asset", {"profile": "alpha", "asset_ref": ref, **extra}) in (4151, 4154), extra


def test_a_file_swapped_for_a_symlink_after_the_root_check_is_not_followed(tmp_path):
    target = tmp_path / "target.bin"
    target.write_bytes(b"secret")
    link = tmp_path / "link.bin"
    link.symlink_to(target)
    with pytest.raises(AssetUnavailable), _open_regular(link):
        pass
    with pytest.raises(AssetUnavailable), _open_regular(tmp_path):
        pass
