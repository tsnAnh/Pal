from __future__ import annotations

import base64
import hashlib
import os
import stat
import sys
import threading
from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile
from tests.fixtures.owner_photo_images import b64, gif, jpeg, png, png_of_size, webp
from tools import bot_mode_about_you as about
from tui_gateway import server
from tui_gateway.contracts import METHODS


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    return home


def _rpc(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _version(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()[:16]


def _photo_files(home: Path) -> list[str]:
    return sorted(p.name for p in (home / "bot-mode").glob("owner-photo.*"))


def test_a_photo_round_trips_through_set_version_photo_and_remove(two_bots):
    assert _ok("bot_mode.about_you.get", {})["photo_version"] == ""
    assert _ok("bot_mode.about_you.photo", {}) == {"data": "", "mime": "", "photo_version": ""}

    image = png(1)
    saved = _ok("bot_mode.about_you.set_photo", {"data": b64(image)})
    assert saved == {"name": "", "timezone": "", "timezone_auto": False, "photo_version": _version(image)}
    assert _ok("bot_mode.about_you.get", {})["photo_version"] == _version(image)
    assert _ok("bot_mode.about_you.photo", {}) == {
        "data": b64(image), "mime": "image/png", "photo_version": _version(image)}

    assert _ok("bot_mode.about_you.set_photo", {"data": None})["photo_version"] == ""
    assert _ok("bot_mode.about_you.photo", {})["data"] == "" and _photo_files(two_bots) == []
    assert _ok("bot_mode.about_you.set_photo", {"data": ""})["photo_version"] == ""
    assert _ok("bot_mode.about_you.set_photo", {})["photo_version"] == ""


def test_replacing_a_photo_changes_the_version_and_keeps_exactly_one_file(two_bots):
    first, second = png(1), jpeg(2)
    _ok("bot_mode.about_you.set_photo", {"data": b64(first)})
    assert _photo_files(two_bots) == ["owner-photo.png"]

    saved = _ok("bot_mode.about_you.set_photo", {"data": b64(second)})

    assert saved["photo_version"] == _version(second) != _version(first)
    assert _ok("bot_mode.about_you.photo", {})["mime"] == "image/jpeg"
    assert _photo_files(two_bots) == ["owner-photo.jpg"]
    assert _ok("bot_mode.about_you.set_photo", {"data": b64(first)})["photo_version"] == _version(first)
    assert _photo_files(two_bots) == ["owner-photo.png"]


def test_a_data_url_is_accepted_like_the_avatar_upload(two_bots):
    image = png(3)
    saved = _ok("bot_mode.about_you.set_photo", {"data": "data:image/png;base64," + b64(image)})
    assert saved["photo_version"] == _version(image)


@pytest.mark.parametrize("data,code", [
    ("not base64 %%%", 4068),
    (b64(b"just some text, not an image"), 4070),
    (b64(webp()), 4070),
    (b64(gif()), 4070),
    (b64(png_of_size(2_000_001)), 4069),
    ("A" * 3_000_000, 4069),
], ids=["not-base64", "text", "webp", "gif", "just-over-2MB", "huge-payload"])
def test_a_bad_image_is_refused_and_the_current_photo_survives(two_bots, data, code):
    current = png(4)
    _ok("bot_mode.about_you.set_photo", {"data": b64(current)})

    response = _rpc("bot_mode.about_you.set_photo", {"data": data})

    assert response["error"]["code"] == code
    assert _ok("bot_mode.about_you.photo", {})["photo_version"] == _version(current)
    assert _photo_files(two_bots) == ["owner-photo.png"]


def test_exactly_two_megabytes_is_accepted(two_bots):
    image = png_of_size(2_000_000)
    assert _ok("bot_mode.about_you.set_photo", {"data": b64(image)})["photo_version"] == _version(image)


def test_a_refused_first_upload_creates_nothing(two_bots):
    assert _rpc("bot_mode.about_you.set_photo", {"data": b64(gif())})["error"]["code"] == 4070
    assert not (two_bots / "bot-mode").exists()


def test_a_mistyped_or_unknown_param_is_refused_before_the_handler_runs(two_bots):
    assert _rpc("bot_mode.about_you.set_photo", {"bogus": 1})["error"]["code"] == 4000
    with pytest.raises(ValueError):
        METHODS["bot_mode.about_you.set_photo"].params.model_validate({"data": 5})
    assert _rpc("bot_mode.about_you.set_photo", {"data": 5})["error"]["code"] == 4067
    assert _photo_files(two_bots) == []


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX modes")
def test_the_photo_is_stored_privately_beside_the_facts(two_bots):
    _ok("bot_mode.about_you.set", {"name": "Ann"})
    _ok("bot_mode.about_you.set_photo", {"data": b64(png(5))})

    directory = two_bots / "bot-mode"
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700
    assert stat.S_IMODE((directory / "owner-photo.png").stat().st_mode) == 0o600
    assert (directory / "about-you.yaml").is_file()


def test_the_photo_is_install_wide_and_binds_no_profile(two_bots):
    environment_before = dict(os.environ)
    image = png(6)
    _ok("bot_mode.about_you.set_photo", {"data": b64(image), "profile": "scout"})

    for profile in ("scout", "pilot", None):
        params = {} if profile is None else {"profile": profile}
        assert _ok("bot_mode.about_you.photo", params)["photo_version"] == _version(image)
        assert _ok("bot_mode.about_you.get", params)["photo_version"] == _version(image)
    assert not list((two_bots / "profiles").glob("*/bot-mode"))
    assert dict(os.environ) == environment_before


def test_the_photo_never_reaches_a_bots_prompt_or_the_shared_facts(two_bots):
    _ok("bot_mode.about_you.set", {"name": "Ann", "timezone": "Europe/Paris"})
    section_before = about.about_you_section(two_bots)

    saved = _ok("bot_mode.about_you.set_photo", {"data": b64(png(7))})

    assert about.read_about_you(two_bots) == {"name": "Ann", "timezone": "Europe/Paris"}
    assert about.about_you_section(two_bots) == section_before
    assert saved["photo_version"] not in section_before


def test_other_fact_writes_keep_the_photo_and_a_photo_write_keeps_the_facts(two_bots):
    image = png(8)
    _ok("bot_mode.about_you.set", {"name": "Ann", "timezone": "Asia/Tokyo", "timezone_auto": True})
    _ok("bot_mode.about_you.set_photo", {"data": b64(image)})

    after_facts = _ok("bot_mode.about_you.set", {"name": "Bea"})

    assert after_facts == {"name": "Bea", "timezone": "Asia/Tokyo", "timezone_auto": True, "photo_version": _version(image)}
    assert _ok("bot_mode.about_you.set_photo", {"data": None}) == {
        "name": "Bea", "timezone": "Asia/Tokyo", "timezone_auto": True, "photo_version": ""}


def test_concurrent_uploads_never_tear_the_photo(two_bots):
    images = [png(10), jpeg(11), png(12), jpeg(13)] * 3
    failures: list[BaseException] = []

    def upload(blob: bytes) -> None:
        try:
            _ok("bot_mode.about_you.set_photo", {"data": b64(blob)})
        except BaseException as exc:
            failures.append(exc)

    threads = [threading.Thread(target=upload, args=(blob,)) for blob in images]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert not failures
    photo = _ok("bot_mode.about_you.photo", {})
    stored = base64.b64decode(photo["data"])
    assert stored in images and photo["photo_version"] == _version(stored)
    assert len(_photo_files(two_bots)) == 1
