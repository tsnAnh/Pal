from __future__ import annotations

import base64
import hashlib

import pytest

from tests.tui_gateway import test_library_rpc as library

_call, _error, _ok, _seed = library._call, library._error, library._ok, library._seed
bots = library.bots


@pytest.fixture(autouse=True)
def delivery_root(bots, monkeypatch):
    from gateway.platforms import base
    monkeypatch.setattr(base, "_HERMES_ROOT", bots["launch"])

CSV = b"screen,flow\nhome,onboarding\n"
MARKDOWN = b"# Feature flows\n\n- sign in\n- save file\n"


def _ref(kind: str, path) -> str:
    return hashlib.sha256(f"{kind}\x00{path}".encode()).hexdigest()[:32]


def _produce(bots, name: str, data: bytes):
    path = bots["tmp"] / "research" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _asset(ref: str, profile: str = "alpha", **extra):
    return {"profile": profile, "asset_ref": ref, **extra}


def test_wire_ref_matches_the_swift_decoder_vector():
    assert _ref("file", "/home/tsnanh/smilewallpaper-research/app-audit.csv") == "ef6dab1fc086c186833781fbc205fe76"
    assert _ref("file", "/home/tsnanh/smilewallpaper-research/feature-flows-v0.1.md") == "39b685030d5b3d6681f60eb48f25528e"


def test_two_consecutive_media_lines_serve_their_exact_bytes(bots):
    csv = _produce(bots, "app-audit.csv", CSV)
    md = _produce(bots, "feature-flows-v0.1.md", MARKDOWN)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"Here you go.\nMEDIA:{csv}\nMEDIA:{md}")
    seed.close()
    for path, data in ((csv, CSV), (md, MARKDOWN)):
        result = _ok("library.asset", _asset(_ref("file", path), thumbnail=False))
        served = base64.b64decode(result["data_base64"])
        assert served == data
        assert hashlib.sha256(served).hexdigest() == hashlib.sha256(data).hexdigest()
        assert result["size"] == len(data)
    assert _ok("library.asset", _asset(_ref("file", csv)))["mime"] == "text/csv"


def test_a_file_sent_by_the_user_stays_inside_the_media_roots(bots):
    secret = _produce(bots, "notes.csv", CSV)
    seed = _seed(bots["alpha"])
    seed.message("s1", "user", f"@file:{secret}")
    seed.close()
    assert _error("library.asset", _asset(_ref("file", secret))) == 4154


def test_policy_refusals_share_one_code_and_message_and_a_missing_file_is_not_found(bots):
    alpha, beta = bots["alpha"], bots["beta"]
    (beta / ".env").write_text("TOKEN=other-profile-secret\n")
    (alpha / ".env").write_text("TOKEN=own-secret\n")
    outside = bots["tmp"] / "research"
    outside.mkdir()
    link = outside / "report.csv"
    link.symlink_to(beta / ".env")
    missing = outside / "missing.csv"
    traversal = "/".join([str(outside), *[".."] * 16, "etc", "passwd"])
    seed = _seed(alpha)
    seed.message("s1", "assistant", "\n".join(
        f"MEDIA:{path}" for path in (beta / ".env", alpha / ".env", alpha / "state.db", link, missing, traversal)))
    seed.close()
    paths = (beta / ".env", alpha / ".env", alpha / "state.db", link, missing, traversal)
    responses = {path: _call("library.asset", _asset(_ref("file", path))) for path in paths}
    denied = [response for path, response in responses.items() if path != missing]
    assert {r["error"]["code"] for r in denied} == {4154}, responses
    assert len({r["error"]["message"] for r in denied}) == 1
    assert responses[missing]["error"]["code"] == 4151
    for response in responses.values():
        assert "secret" not in str(response) and str(bots["tmp"]) not in str(response)


def test_canary_outside_the_allowed_roots_is_neither_readable_nor_revealed_in_strict_mode(bots):
    config = bots["alpha"] / "config.yaml"
    config.write_text("gateway:\n  strict: true\n  trust_recent_files: false\n")
    canary = _produce(bots, "canary.csv", b"CANARY-HOST-SECRET")
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{canary}")
    seed.close()
    response = _call("library.asset", _asset(_ref("file", canary)))
    assert response["error"]["code"] == 4154
    assert "CANARY" not in str(response) and str(canary) not in str(response)

    config.write_text(f"gateway:\n  strict: true\n  trust_recent_files: false\n  media_delivery_allow_dirs: [{canary.parent}]\n")
    assert base64.b64decode(_ok("library.asset", _asset(_ref("file", canary)))["data_base64"]) == b"CANARY-HOST-SECRET"


def test_another_profile_and_forged_refs_get_the_same_typed_refusal(bots):
    csv = _produce(bots, "app-audit.csv", CSV)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{csv}")
    seed.close()
    ref = _ref("file", csv)
    assert _error("library.asset", _asset(ref, profile="beta")) == 4151
    for forged in ("../../etc/passwd", "g" * 32, "", ref[:-1], ref.upper(), _ref("media", csv)):
        assert _error("library.asset", _asset(forged)) == 4151, forged


def test_directives_inside_code_fences_are_not_served(bots):
    csv = _produce(bots, "app-audit.csv", CSV)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"Example:\n```\nMEDIA:{csv}\n```")
    seed.close()
    assert _error("library.asset", _asset(_ref("file", csv))) == 4151


def test_oversize_file_is_a_typed_limit_and_deleted_history_stops_serving(bots):
    csv = _produce(bots, "app-audit.csv", CSV)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{csv}")
    ref = _ref("file", csv)
    assert _error("library.asset", _asset(ref, max_bytes=1)) == 4152
    assert _ok("library.asset", _asset(ref))["size"] == len(CSV)
    assert seed.db.delete_session("s1")
    seed.close()
    assert _error("library.asset", _asset(ref)) == 4151


def _strict(bots, *, trust_recent: bool, allow_dir=None, seconds: int | None = None):
    lines = ["gateway:", "  strict: true", f"  trust_recent_files: {str(trust_recent).lower()}"]
    if seconds is not None:
        lines.append(f"  trust_recent_files_seconds: {seconds}")
    if allow_dir is not None:
        lines.append(f"  media_delivery_allow_dirs: [{allow_dir}]")
    (bots["alpha"] / "config.yaml").write_text("\n".join(lines) + "\n")


def test_strict_mode_serves_an_allowed_directory_outside_every_profile_home(bots):
    page = _produce(bots, "mockup.html", b"<html>mockup</html>")
    _strict(bots, trust_recent=False, allow_dir=page.parent)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{page}")
    seed.close()
    result = _ok("library.asset", _asset(_ref("file", page), thumbnail=False))
    assert base64.b64decode(result["data_base64"]) == b"<html>mockup</html>"
    assert result["mime"] == "text/html" and result["size"] == len(b"<html>mockup</html>")


def test_strict_mode_trusts_a_fresh_file_only_inside_the_recency_window(bots):
    import os
    import time
    page = _produce(bots, "fresh.html", b"<p>fresh</p>")
    _strict(bots, trust_recent=True, seconds=600)
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{page}")
    seed.close()
    assert base64.b64decode(_ok("library.asset", _asset(_ref("file", page)))["data_base64"]) == b"<p>fresh</p>"
    old = time.time() - 3600
    os.utime(page, (old, old))
    assert _error("library.asset", _asset(_ref("file", page))) == 4154


def test_a_preview_directive_on_its_own_line_serves_the_same_bytes_as_a_media_tag(bots):
    page = _produce(bots, "widget.html", b"<div>widget</div>")
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f'Here is the widget.\n::preview{{file="{page}"}}\nDone.')
    seed.close()
    result = _ok("library.asset", _asset(_ref("file", page), thumbnail=False))
    assert base64.b64decode(result["data_base64"]) == b"<div>widget</div>"


def test_preview_lookalikes_do_not_index_a_file(bots):
    inline = _produce(bots, "inline.html", b"x")
    fenced = _produce(bots, "fenced.html", b"x")
    other = _produce(bots, "other.html", b"x")
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", "\n".join((
        f'see ::preview{{file="{inline}"}} here',
        f'```\n::preview{{file="{fenced}"}}\n```',
        f'::chart{{file="{other}"}}')))
    seed.close()
    for path in (inline, fenced, other):
        assert _error("library.asset", _asset(_ref("file", path))) == 4151


def test_a_missing_file_is_not_found_not_a_policy_refusal(bots):
    gone = bots["tmp"] / "research" / "gone.html"
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{gone}")
    seed.close()
    assert _error("library.asset", _asset(_ref("file", gone))) == 4151
