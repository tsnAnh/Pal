from __future__ import annotations

import json
import shutil
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_cli import webapp_sign_in
from hermes_cli.dashboard_auth import clear_providers, register_provider
from hermes_cli.profiles import create_profile, get_profile_dir
from tests.hermes_cli.conftest_dashboard_auth import StubAuthProvider
from tools.bot_desktop import disk, lease
from tui_gateway import server

REFRESH = "refresh-token-SECRET-0123456789abcdef"
ACCESS = "access-token-SECRET-0123456789abcdef"


@pytest.fixture
def two_bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    lease._reset_for_tests()
    yield home
    lease._reset_for_tests()


def _rpc(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _desktop_state(profile: str) -> Path:
    state = get_profile_dir(profile) / "bot-desktop"
    (state / "xdg" / "xfce4").mkdir(parents=True, exist_ok=True)
    (state / "xdg" / "xfce4" / "panel.xml").write_text("layout", encoding="utf-8")
    (state / "browser-profile" / "Default").mkdir(parents=True, exist_ok=True)
    (state / "browser-profile" / "Default" / "Cookies").write_text("session", encoding="utf-8")
    (state / "launcher.log").write_text("log", encoding="utf-8")
    return state


@pytest.mark.parametrize("free_mb, used_pct, level", [
    (50_000, 40, "normal"), (2048, 89, "normal"), (2047, 50, "low"), (10_000, 90, "low"),
    (511, 50, "critical"), (10_000, 97, "critical"), (0, 100, "critical")])
def test_disk_level_follows_free_space_and_fill(free_mb, used_pct, level):
    assert disk.level_for(free_mb, used_pct) == level


def test_display_status_reports_the_disk_level_of_the_bots_screen(two_bots, monkeypatch):
    usage = shutil._ntuple_diskusage(total=100 * 1024**3, used=95 * 1024**3, free=5 * 1024**3)
    monkeypatch.setattr(disk.shutil, "disk_usage", lambda path: usage)
    result = _ok("display.status", {"profile": "scout"})
    assert result["disk"] == {"level": "low", "free_mb": 5120, "total_mb": 102400, "used_pct": 95}


def test_display_status_has_no_disk_when_the_filesystem_cannot_be_read(two_bots, monkeypatch):
    def broken(path):
        raise OSError("gone")

    monkeypatch.setattr(disk.shutil, "disk_usage", broken)
    assert _ok("display.status", {"profile": "scout"})["disk"] is None


def test_reset_wipes_that_bots_desktop_settings_and_browser_data_only(two_bots):
    scout, pilot = _desktop_state("scout"), _desktop_state("pilot")
    result = _ok("display.reset", {"profile": "scout"})
    assert result["reset"] == ["xdg", "browser-profile"] and result["running"] is False
    assert not (scout / "xdg").exists() and not (scout / "browser-profile").exists()
    assert (scout / "launcher.log").exists()
    assert (pilot / "xdg" / "xfce4" / "panel.xml").exists() and (pilot / "browser-profile" / "Default" / "Cookies").exists()
    assert _ok("display.reset", {"profile": "scout"})["reset"] == []


def test_reset_is_refused_while_a_human_holds_the_screen_unless_forced(two_bots):
    state = _desktop_state("scout")
    from hermes_constants import hermes_home_key

    lease.acquire("viewer-1", profile_key=hermes_home_key(get_profile_dir("scout")))
    refused = _rpc("display.reset", {"profile": "scout"})
    assert refused["error"]["code"] == 5300 and refused["error"]["data"]["code"] == "viewer_mismatch"
    assert (state / "browser-profile" / "Default" / "Cookies").exists()
    forced = _ok("display.reset", {"profile": "scout", "force": True})
    assert forced["reset"] == ["xdg", "browser-profile"]


def test_reset_is_refused_for_a_screen_that_runs_in_a_sandbox(two_bots, monkeypatch):
    state = _desktop_state("scout")
    from tools.bot_desktop import sandbox_host

    monkeypatch.setattr(sandbox_host, "_read_marker", lambda: {"sandbox": "docker"})
    refused = _rpc("display.reset", {"profile": "scout"})
    assert refused["error"]["code"] == 5300 and "sandbox" in refused["error"]["message"]
    assert (state / "xdg").exists()


class RecordingProvider(StubAuthProvider):
    revoked: list[str]

    def __init__(self, fail: bool = False):
        super().__init__()
        self.revoked = []
        self.fail = fail

    def revoke_session(self, *, refresh_token: str) -> None:
        if self.fail:
            raise RuntimeError("idp unreachable")
        self.revoked.append(refresh_token)


@pytest.fixture
def providers():
    clear_providers()
    webapp_sign_in._reset_for_tests()
    yield
    clear_providers()
    webapp_sign_in._reset_for_tests()


@pytest.fixture
def webapp_home(tmp_path, monkeypatch) -> Path:
    home = tmp_path / "gateway-home"
    home.mkdir()
    monkeypatch.setattr(server, "_account_session_webapp_home", lambda: home)
    return home


def _gated_request(home: Path):
    state = SimpleNamespace(ui_surface="webapp", auth_required=True, webapp_home=home)
    return SimpleNamespace(app=SimpleNamespace(state=state))


def _signed_in(home: Path):
    request = _gated_request(home)
    webapp_sign_in.gave_native_app(request, SimpleNamespace(access_token=ACCESS, refresh_token=REFRESH, expires_at=0))
    assert webapp_sign_in.token_works_alone(request, REFRESH) and webapp_sign_in.token_works_alone(request, ACCESS)
    return request


def test_revoke_self_needs_a_refresh_token_and_rejects_junk(providers):
    assert _rpc("auth.revoke_self", {})["error"]["code"] == 4101
    assert _rpc("auth.revoke_self", {"refresh_token": "   "})["error"]["code"] == 4101
    assert _rpc("auth.revoke_self", {"refresh_token": 5})["error"]["code"] == 4101
    assert _rpc("auth.revoke_self", {"refresh_token": "x" * 9000})["error"]["code"] == 4101
    assert _rpc("auth.revoke_self", {"refresh_token": REFRESH, "access_token": ["a"]})["error"]["code"] == 4101
    assert _rpc("auth.revoke_self", {"refresh_token": REFRESH, "device": "x"})["error"]["code"] == 4000


def test_revoke_self_revokes_at_the_provider_and_stops_honouring_the_tokens(providers, webapp_home):
    provider = RecordingProvider()
    register_provider(provider)
    request = _signed_in(webapp_home)

    response = _rpc("auth.revoke_self", {"refresh_token": REFRESH, "access_token": ACCESS})
    assert "error" not in response, response
    result = response["result"]
    assert result == {"ok": True, "providers_revoked": 1, "forgotten": 2}
    assert provider.revoked == [REFRESH]
    assert REFRESH not in json.dumps(response) and ACCESS not in json.dumps(response)
    assert not webapp_sign_in.token_works_alone(request, REFRESH)
    assert not webapp_sign_in.token_works_alone(request, ACCESS)

    webapp_sign_in._reset_for_tests()
    assert not webapp_sign_in.token_works_alone(request, REFRESH)


def test_revoke_self_leaves_another_devices_tokens_alone(providers, webapp_home):
    register_provider(RecordingProvider())
    request = _signed_in(webapp_home)
    other = SimpleNamespace(access_token="other-access-0123456789", refresh_token="other-refresh-0123456789", expires_at=0)
    webapp_sign_in.gave_native_app(request, other)
    _ok("auth.revoke_self", {"refresh_token": REFRESH, "access_token": ACCESS})
    assert webapp_sign_in.token_works_alone(request, other.refresh_token)
    assert webapp_sign_in.token_works_alone(request, other.access_token)


def test_an_unreachable_provider_does_not_stop_the_local_sign_out(providers, webapp_home):
    register_provider(RecordingProvider(fail=True))
    request = _signed_in(webapp_home)
    result = _ok("auth.revoke_self", {"refresh_token": REFRESH})
    assert result["providers_revoked"] == 0 and result["forgotten"] == 1
    assert not webapp_sign_in.token_works_alone(request, REFRESH)
