from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server

CANARY_QR = "CANARY-NOT-A-REAL-QR-7f3a-0000"
CANARY_CLOUD_TOKEN = "CANARY-NOT-A-REAL-TOKEN-9b2c-0000"
CREDS = '{"me":{"id":"15550001111:1@s.whatsapp.net","name":"Scout Phone"},"registered":true}'


class FakeBridge:
    """Stands in for ``node bridge.js --pair-only --pair-json``: replays the JSON lines it would print."""

    def __init__(self, lines, returncode=0):
        self.stdout = iter(lines)
        self.pid = 0
        self._returncode = returncode

    def wait(self, timeout=None):
        return self._returncode

    def poll(self):
        return self._returncode


def _event(**payload) -> str:
    return json.dumps(payload) + "\n"


@pytest.fixture
def bots(tmp_path, monkeypatch):
    from hermes_cli.web_routers import messaging

    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setenv("HERMES_GATEWAY_LOCK_DIR", str(tmp_path / "locks"))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in ("WHATSAPP_ENABLED", "WHATSAPP_MODE", "WHATSAPP_ALLOWED_USERS", "WHATSAPP_CLOUD_ACCESS_TOKEN"):
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    messaging._whatsapp_onboarding_sessions.clear()
    reloads = []
    monkeypatch.setattr(messaging, "_notify_multiplexer_hot_serve", lambda profile: reloads.append(profile) or True)
    monkeypatch.setattr(messaging, "_restart_gateway_after_whatsapp_onboarding",
                        lambda profile: reloads.append(profile) or {"restart_started": True})
    monkeypatch.setattr(messaging, "_launch_whatsapp_pairing", lambda *a, **k: None)
    monkeypatch.setattr(messaging, "release_process_group_once_empty", lambda *a, **k: None)
    yield SimpleNamespace(home=home, messaging=messaging, reloads=reloads)
    from gateway.status_scoped_locks import release_scoped_lock

    for record in messaging._whatsapp_onboarding_sessions.values():
        release_scoped_lock("whatsapp-session", record.session_path)
    messaging._whatsapp_onboarding_sessions.clear()


def _rpc(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _session_dir(profile: str) -> Path:
    return get_profile_dir(profile) / "platforms" / "whatsapp" / "session"


def _start(profile="scout", **extra) -> dict:
    return _ok("messaging.whatsapp.pair.start", {"profile": profile, "mode": "bot", "allowed_users": "15550002222", **extra})


def _bridge_says(bots, pairing_id, *lines, returncode=0):
    record = bots.messaging._whatsapp_onboarding_sessions[pairing_id]
    bridge = FakeBridge(lines, returncode)
    record.proc = bridge
    bots.messaging._watch_whatsapp_pairing(pairing_id, bridge)
    return record


def _bridge_live(bots, pairing_id, **payload):
    record = bots.messaging._whatsapp_onboarding_sessions[pairing_id]
    with bots.messaging._whatsapp_onboarding_lock:
        bots.messaging._apply_pairing_event(record, payload)
    return record


def _poll(pairing_id, profile="scout") -> dict:
    return _ok("messaging.whatsapp.pair.status", {"profile": profile, "pairing_id": pairing_id})


def test_pairing_shows_the_qr_while_waiting_and_clears_it_once_connected(bots):
    started = _start()
    assert started["status"] == "starting" and started["qr_payload"] is None
    pairing_id = started["pairing_id"]

    _bridge_live(bots, pairing_id, event="qr", qr=CANARY_QR)
    waiting = _poll(pairing_id)
    assert waiting["status"] == "waiting" and waiting["qr_payload"] == CANARY_QR

    (_session_dir("scout")).mkdir(parents=True, exist_ok=True)
    (_session_dir("scout") / "creds.json").write_text(CREDS, encoding="utf-8")
    _bridge_says(bots, pairing_id, _event(event="connected", user={"id": "15550001111:1@s.whatsapp.net", "name": "Scout Phone"}))
    connected = _poll(pairing_id)
    assert connected["status"] == "connected" and connected["qr_payload"] is None
    assert connected["account_phone"] == "15550001111" and connected["account_name"] == "Scout Phone"

    applied = _ok("messaging.whatsapp.pair.apply", {"profile": "scout", "pairing_id": pairing_id})
    assert applied["ok"] is True and applied["restart_started"] is True
    scout_env = (get_profile_dir("scout") / ".env").read_text()
    assert "WHATSAPP_ENABLED=true" in scout_env and "WHATSAPP_ALLOWED_USERS=15550002222" in scout_env
    pilot_env = get_profile_dir("pilot") / ".env"
    assert "WHATSAPP" not in (pilot_env.read_text() if pilot_env.exists() else "")

    status = _ok("messaging.whatsapp.status", {"profile": "scout"})
    assert status["paired"] is True and status["enabled"] is True and status["mode"] == "bot"
    assert status["allowed_users"] == "15550002222" and status["account_phone"] == "15550001111"
    assert _ok("messaging.whatsapp.status", {"profile": "pilot"})["paired"] is False


def test_a_bridge_failure_is_a_plain_reason_and_never_carries_a_qr(bots):
    pairing_id = _start()["pairing_id"]
    _bridge_says(bots, pairing_id, _event(event="qr", qr=CANARY_QR), _event(event="error", error="passkey_required"))
    failed = _poll(pairing_id)
    assert failed["status"] == "error" and failed["qr_payload"] is None
    assert "passkey" in failed["error"].lower() and "terminal" in failed["error"].lower()


def test_a_bridge_that_dies_silently_reports_it_stopped(bots):
    pairing_id = _start()["pairing_id"]
    _bridge_says(bots, pairing_id, returncode=1)
    failed = _poll(pairing_id)
    assert failed["status"] == "error" and "exited" in failed["error"]


def test_an_old_pairing_reports_expired_with_no_qr(bots):
    pairing_id = _start()["pairing_id"]
    record = _bridge_live(bots, pairing_id, event="qr", qr=CANARY_QR)
    record.expires_at_ts = time.time() - 1
    expired = _poll(pairing_id)
    assert expired["status"] == "expired" and expired["qr_payload"] is None


def test_cancelling_ends_the_pairing_and_frees_the_slot(bots):
    first = _start()["pairing_id"]
    assert _ok("messaging.whatsapp.pair.cancel", {"profile": "scout", "pairing_id": first})["ok"] is True
    assert _rpc("messaging.whatsapp.pair.status", {"profile": "scout", "pairing_id": first})["error"]["code"] == 4113
    assert _start()["status"] == "starting"


def test_a_second_start_while_one_is_active_is_refused(bots):
    first = _start()["pairing_id"]
    second = _rpc("messaging.whatsapp.pair.start", {"profile": "scout", "mode": "bot"})
    assert second["error"]["code"] == 4119
    assert _poll(first)["status"] == "starting"
    assert _start("pilot")["status"] == "starting"


def test_another_bots_request_cannot_read_cancel_or_apply_a_pairing(bots):
    pairing_id = _start()["pairing_id"]
    _bridge_live(bots, pairing_id, event="qr", qr=CANARY_QR)
    for method in ("pair.status", "pair.cancel", "pair.apply"):
        refused = _rpc(f"messaging.whatsapp.{method}", {"profile": "pilot", "pairing_id": pairing_id})
        assert refused["error"]["code"] == 4113, method
        assert CANARY_QR not in json.dumps(refused)
    assert _poll(pairing_id)["status"] == "waiting"
    assert _rpc("messaging.whatsapp.pair.status", {"profile": "ghost", "pairing_id": pairing_id})["error"]["code"] == 4064


def test_unpair_disables_the_bot_and_moves_the_session_aside(bots):
    _session_dir("scout").mkdir(parents=True)
    (_session_dir("scout") / "creds.json").write_text(CREDS, encoding="utf-8")
    assert _ok("messaging.whatsapp.status", {"profile": "scout"})["paired"] is True

    result = _ok("messaging.whatsapp.unpair", {"profile": "scout"})
    assert result["paired"] is False and result["enabled"] is False and result["hot_served"] is True
    assert "WHATSAPP_ENABLED=false" in (get_profile_dir("scout") / ".env").read_text()
    backups = list(_session_dir("scout").parent.glob("session-backup-*/session/creds.json"))
    assert len(backups) == 1 and backups[0].read_text(encoding="utf-8") == CREDS
    assert _ok("messaging.whatsapp.unpair", {"profile": "scout"})["paired"] is False


def test_unpair_is_refused_while_a_pairing_is_active(bots):
    _start()
    assert _rpc("messaging.whatsapp.unpair", {"profile": "scout"})["error"]["code"] == 4119


def test_configure_changes_mode_and_allowlist_for_that_bot_only(bots):
    result = _ok("messaging.whatsapp.configure", {"profile": "scout", "mode": "self-chat", "allowed_users": "1555 000 3333"})
    assert result["mode"] == "self-chat" and result["allowed_users"] == "1555000 3333".replace(" ", "")
    assert _rpc("messaging.whatsapp.configure", {"profile": "scout", "mode": "nonsense"})["error"]["code"] == 4111
    assert _ok("messaging.whatsapp.status", {"profile": "pilot"})["mode"] == ""


def test_cloud_credentials_are_saved_for_that_bot_only_and_never_echoed(bots, caplog):
    caplog.set_level(logging.DEBUG)
    params = {"profile": "scout", "phone_number_id": "100200300", "access_token": CANARY_CLOUD_TOKEN}
    response = _rpc("messaging.whatsapp_cloud.connect", params)
    assert "error" not in response, response
    assert CANARY_CLOUD_TOKEN not in json.dumps(response) and CANARY_CLOUD_TOKEN not in caplog.text
    assert response["result"]["access_token_set"] is True and response["result"]["configured"] is True
    assert f"WHATSAPP_CLOUD_ACCESS_TOKEN={CANARY_CLOUD_TOKEN}" in (get_profile_dir("scout") / ".env").read_text()
    pilot_env = get_profile_dir("pilot") / ".env"
    assert "WHATSAPP_CLOUD" not in (pilot_env.read_text() if pilot_env.exists() else "")
    assert _rpc("messaging.whatsapp_cloud.connect", {"profile": "scout", "phone_number_id": "1"})["error"]["code"] == 4111


def test_the_qr_appears_only_in_the_pairing_frame(bots, caplog):
    caplog.set_level(logging.DEBUG)
    frames = {}
    started = _rpc("messaging.whatsapp.pair.start", {"profile": "scout", "mode": "bot"})
    frames["start"] = started
    pairing_id = started["result"]["pairing_id"]
    record = _bridge_live(bots, pairing_id, event="qr", qr=CANARY_QR)
    waiting = _rpc("messaging.whatsapp.pair.status", {"profile": "scout", "pairing_id": pairing_id})
    assert waiting["result"]["qr_payload"] == CANARY_QR

    frames["status"] = _rpc("messaging.whatsapp.status", {"profile": "scout"})
    frames["other_bot_poll"] = _rpc("messaging.whatsapp.pair.status", {"profile": "pilot", "pairing_id": pairing_id})
    frames["configure"] = _rpc("messaging.whatsapp.configure", {"profile": "scout", "mode": "bot"})
    frames["bad_start"] = _rpc("messaging.whatsapp.pair.start", {"profile": "scout", "mode": "bot"})
    frames["cancel"] = _rpc("messaging.whatsapp.pair.cancel", {"profile": "scout", "pairing_id": pairing_id})
    frames["after_cancel"] = _rpc("messaging.whatsapp.pair.status", {"profile": "scout", "pairing_id": pairing_id})

    for name, frame in frames.items():
        assert CANARY_QR not in json.dumps(frame), name
    assert CANARY_QR not in caplog.text
    assert CANARY_QR not in repr(record) and CANARY_QR not in str(record)
    on_disk = [p for p in bots.home.rglob("*") if p.is_file() and CANARY_QR.encode() in p.read_bytes()]
    assert on_disk == []
