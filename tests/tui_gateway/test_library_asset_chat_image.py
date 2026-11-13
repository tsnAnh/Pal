"""A photo sent from a remote client loads in its chat before anyone opens the Library.

The client derives the asset ref from the ``[Image attached at: <host path>]`` hint in the stored row
(sha256 of ``media\\0<path>``, first 32 hex) and asks ``library.asset`` for the bytes; the gateway must
index the row on that first ask, through the same profile, live-row and media-root checks as ever.
"""
from __future__ import annotations

import base64
import hashlib

import pytest

from tests.tui_gateway import test_library_rpc as library

_error, _ok, _png, _seed = library._error, library._ok, library._png, library._seed
bots = library.bots


def _client_ref(host_path) -> str:
    return hashlib.sha256(f"media\x00{host_path}".encode()).hexdigest()[:32]


def _photo_turn(home, name="photo.png"):
    image = home / "cache" / "documents" / "native-inputs" / ("a" * 64) / name
    original = _png(image, (40, 30))
    seed = _seed(home)
    seed.message("s1", "user", f"Look at this\n\n[Image attached at: {image}]\n[screenshot]")
    seed.close()
    return image, original


@pytest.mark.parametrize("thumbnail", [True, False])
def test_first_ask_for_a_stored_chat_image_returns_its_bytes(bots, thumbnail):
    image, original = _photo_turn(bots["alpha"])
    result = _ok("library.asset", {"profile": "alpha", "asset_ref": _client_ref(image), "thumbnail": thumbnail})
    data = base64.b64decode(result["data_base64"])
    assert data.startswith(b"\x89PNG") if not thumbnail else data[:3] in (b"\x89PN", b"\xff\xd8\xff")
    if not thumbnail:
        assert data == original


def test_another_profile_or_a_forged_ref_is_still_refused(bots):
    image, _ = _photo_turn(bots["alpha"])
    ref = _client_ref(image)
    assert _error("library.asset", {"profile": "beta", "asset_ref": ref}) == 4151
    assert _error("library.asset", {"asset_ref": ref}) == 4151
    assert _error("library.asset", {"profile": "alpha", "asset_ref": _client_ref(bots["alpha"] / "state.db")}) == 4151


def test_an_image_outside_the_media_roots_is_refused_even_when_named_in_a_row(bots):
    outside = bots["tmp"] / "outside" / "secret.png"
    _png(outside, (10, 10))
    seed = _seed(bots["alpha"])
    seed.message("s1", "user", f"Look\n\n[Image attached at: {outside}]")
    seed.close()
    assert _error("library.asset", {"profile": "alpha", "asset_ref": _client_ref(outside)}) == 4151


def test_an_image_whose_file_is_gone_is_unavailable(bots):
    image, _ = _photo_turn(bots["alpha"])
    image.unlink()
    assert _error("library.asset", {"profile": "alpha", "asset_ref": _client_ref(image)}) == 4151
