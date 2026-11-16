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
    assert _error("library.asset", _asset(_ref("file", secret))) == 4151


def test_refusals_are_identical_so_nothing_reveals_which_paths_exist(bots):
    alpha, beta = bots["alpha"], bots["beta"]
    (beta / ".env").write_text("TOKEN=other-profile-secret\n")
    (alpha / ".env").write_text("TOKEN=own-secret\n")
    outside = bots["tmp"] / "research"
    outside.mkdir()
    link = outside / "report.csv"
    link.symlink_to(beta / ".env")
    missing = outside / "missing.csv"
    traversal = f"{outside}/../../../../etc/passwd"
    seed = _seed(alpha)
    seed.message("s1", "assistant", "\n".join(
        f"MEDIA:{path}" for path in (beta / ".env", alpha / ".env", alpha / "state.db", link, missing, traversal)))
    seed.close()
    paths = (beta / ".env", alpha / ".env", alpha / "state.db", link, missing, traversal)
    responses = [_call("library.asset", _asset(_ref("file", path))) for path in paths]
    assert [r.get("error", {}).get("code") for r in responses] == [4151] * len(paths), responses
    assert len({response["error"]["message"] for response in responses}) == 1
    for response in responses:
        assert "secret" not in str(response) and str(bots["tmp"]) not in str(response)


def test_canary_outside_the_allowed_roots_is_neither_readable_nor_revealed_in_strict_mode(bots):
    config = bots["alpha"] / "config.yaml"
    config.write_text("gateway:\n  strict: true\n  trust_recent_files: false\n")
    canary = _produce(bots, "canary.csv", b"CANARY-HOST-SECRET")
    seed = _seed(bots["alpha"])
    seed.message("s1", "assistant", f"MEDIA:{canary}")
    seed.close()
    response = _call("library.asset", _asset(_ref("file", canary)))
    assert response["error"]["code"] == 4151
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
