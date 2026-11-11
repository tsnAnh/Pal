from __future__ import annotations

import json
import logging
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from hermes_cli.profiles import get_profile_dir
from tests.tui_gateway import test_bot_settings_slack_rpc as base
from tui_gateway import server

_rpc, _env_of, two_bots, gateway_reload = base._rpc, base._env_of, base.two_bots, base.gateway_reload


def _ok(method: str, params: dict) -> dict:
    from tui_gateway.contracts import METHODS

    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def canary() -> str:
    return f"{uuid.uuid4().int % 10**9}:CANARY{uuid.uuid4().hex}"


@pytest.fixture
def telegram_says(monkeypatch):
    verdicts = {"value": "accepted", "seen": []}

    def probe(token):
        verdicts["seen"].append(token)
        return verdicts["value"]

    monkeypatch.setattr(server, "_telegram_probe", probe)
    return verdicts


def _env_text(profile: str) -> str:
    path = get_profile_dir(profile) / ".env"
    return path.read_text() if path.exists() else ""


def test_connect_stores_the_token_for_that_bot_only_and_never_echoes_it(two_bots, gateway_reload, telegram_says, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    token = canary()
    response = _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": token})
    out = capsys.readouterr()
    assert "error" not in response, response
    assert token not in json.dumps(response) + caplog.text + out.out + out.err
    result = response["result"]
    assert result["profile"] == "scout" and result["enabled"] and result["configured"] and result["bot_token_set"]
    assert result["allowed_users_set"] is False
    assert _env_of("scout")["TELEGRAM_BOT_TOKEN"] == token
    assert "TELEGRAM_" not in _env_text("pilot")
    assert _ok("messaging.telegram.status", {"profile": "pilot"})["bot_token_set"] is False
    status = _ok("messaging.telegram.status", {"profile": "scout"})
    assert status["bot_token_set"] and token not in json.dumps(status)
    assert gateway_reload["restart"] == ["scout"]


def test_malformed_tokens_are_refused_before_telegram_is_asked(two_bots, gateway_reload, telegram_says):
    for bad in ("", "  ", "not-a-token", "123:short", "«redacted:123…abcd»"):
        assert _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": bad})["error"]["code"] == 4101
    assert _rpc("messaging.telegram.connect", {"profile": "scout"})["error"]["code"] == 4101
    assert telegram_says["seen"] == [] and "TELEGRAM_" not in _env_text("scout")
    assert gateway_reload["hot"] == [] and gateway_reload["restart"] == []


def test_a_token_telegram_refuses_is_not_saved_and_the_old_one_stays(two_bots, gateway_reload, telegram_says):
    old, new = canary(), canary()
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": old})
    telegram_says["value"] = "refused"
    refused = _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": new})
    assert refused["error"]["code"] == 4101 and new not in json.dumps(refused)
    assert _env_of("scout")["TELEGRAM_BOT_TOKEN"] == old and new not in _env_text("scout")
    assert gateway_reload["restart"] == ["scout"]


def test_an_unreachable_telegram_is_its_own_error_and_saves_nothing(two_bots, gateway_reload, telegram_says):
    telegram_says["value"] = "unreachable"
    token = canary()
    response = _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": token})
    assert response["error"]["code"] == 5103 and token not in json.dumps(response)
    assert "TELEGRAM_" not in _env_text("scout") and gateway_reload["restart"] == []


def test_replacing_a_connected_token_never_touches_another_bot(two_bots, gateway_reload, telegram_says):
    first, other, replacement = canary(), canary(), canary()
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": first})
    _ok("messaging.telegram.connect", {"profile": "pilot", "bot_token": other})
    pilot_before = _env_text("pilot")
    result = _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": replacement})
    assert result["bot_token_set"] and _env_of("scout")["TELEGRAM_BOT_TOKEN"] == replacement
    assert first not in _env_text("scout") and _env_text("pilot") == pilot_before
    assert gateway_reload["restart"] == ["scout", "pilot", "scout"]


def test_a_failed_write_keeps_the_old_token_and_reports_no_secret(two_bots, gateway_reload, telegram_says, monkeypatch, caplog):
    from hermes_cli.web_routers import messaging

    old, new = canary(), canary()
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": old})
    before = _env_text("scout")

    def failing_write(key, value):
        raise OSError(f"disk full writing {value}")

    monkeypatch.setattr(messaging, "save_env_value", failing_write)
    caplog.set_level(logging.DEBUG)
    response = _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": new})
    assert response["error"]["code"] == 5102 and new not in json.dumps(response)
    assert _env_text("scout") == before and gateway_reload["restart"] == ["scout"]


def test_disconnect_removes_only_the_token_and_disables_the_adapter(two_bots, gateway_reload, telegram_says):
    token = canary()
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": token})
    (get_profile_dir("scout") / ".env").open("a").write("TELEGRAM_ALLOWED_USERS=12345\n")
    result = _ok("messaging.telegram.disconnect", {"profile": "scout"})
    assert result["bot_token_set"] is False and result["enabled"] is False and result["allowed_users_set"] is True
    assert "TELEGRAM_BOT_TOKEN" not in _env_of("scout") and token not in _env_text("scout")


def test_an_unknown_bot_is_a_typed_not_found_error_and_nothing_is_probed(two_bots, gateway_reload, telegram_says):
    for method, params in (("messaging.telegram.connect", {"bot_token": canary()}), ("messaging.telegram.status", {}),
                           ("messaging.telegram.disconnect", {})):
        assert _rpc(method, {"profile": "ghost", **params})["error"]["code"] == 4064
    assert telegram_says["seen"] == [] and gateway_reload["restart"] == []


def test_status_reports_why_the_connection_failed_without_the_token(two_bots, telegram_says, monkeypatch):
    from hermes_cli.web_routers import messaging

    token = canary()
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": token})
    real = messaging._platform_payloads

    def revoked(scope_dir, entries):
        payloads = real(scope_dir, entries)
        payloads[0].update(state="fatal", error_code="telegram_auth_error", error_message=f"rejected {token}")
        return payloads

    monkeypatch.setattr(messaging, "_platform_payloads", revoked)
    status = _ok("messaging.telegram.status", {"profile": "scout"})
    assert (status["state"], status["error_code"]) == ("fatal", "telegram_auth_error")


class _FakeTelegram(BaseHTTPRequestHandler):
    seen: list[str] = []

    def do_GET(self):
        type(self).seen.append(self.path)
        secret = self.path.split(":", 1)[1]
        code = next(c for m, c in (("ok", 200), ("revoked", 401), ("malformed", 404), ("limited", 429), ("down", 502))
                    if secret.startswith(m))
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *args):
        pass


@pytest.fixture
def fake_telegram(monkeypatch):
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("NO_PROXY", "127.0.0.1")
    _FakeTelegram.seen = []
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _FakeTelegram)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    monkeypatch.setattr(server, "_TELEGRAM_API", f"http://127.0.0.1:{httpd.server_address[1]}")
    yield httpd
    httpd.shutdown()
    httpd.server_close()


@pytest.mark.parametrize("marker,verdict", [
    ("ok", "accepted"), ("revoked", "refused"), ("malformed", "refused"), ("limited", "unreachable"), ("down", "unreachable")])
def test_getme_answers_map_to_plain_verdicts(two_bots, fake_telegram, marker, verdict):
    token = f"123456789:{marker}" + "A" * 30
    assert server._telegram_probe(token) == verdict
    assert _FakeTelegram.seen == [f"/bot{token}/getMe"]


def test_a_dead_network_is_unreachable_and_logs_no_token(two_bots, fake_telegram, monkeypatch, caplog):
    token = canary()
    fake_telegram.shutdown()
    fake_telegram.server_close()
    caplog.set_level(logging.DEBUG)
    assert server._telegram_probe(token) == "unreachable"
    assert token not in caplog.text


def test_the_whole_path_through_a_real_getme_request(two_bots, gateway_reload, fake_telegram):
    good = f"123456789:ok{'A' * 30}"
    revoked = f"123456789:revoked{'B' * 30}"
    _ok("messaging.telegram.connect", {"profile": "scout", "bot_token": good})
    response = _rpc("messaging.telegram.connect", {"profile": "scout", "bot_token": revoked})
    assert response["error"]["code"] == 4101 and revoked not in json.dumps(response)
    assert _env_of("scout")["TELEGRAM_BOT_TOKEN"] == good
