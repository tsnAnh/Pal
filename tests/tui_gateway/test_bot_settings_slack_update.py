from __future__ import annotations

import json
import logging
import uuid

import pytest

from hermes_cli.profiles import get_profile_dir
from tests.tui_gateway import test_bot_settings_slack_rpc as base

APP_TOKEN, BOT_TOKEN, _env_of, _ok, _rpc = base.APP_TOKEN, base.BOT_TOKEN, base._env_of, base._ok, base._rpc
two_bots, gateway_reload = base.two_bots, base.gateway_reload


def _canary_tokens():
    tag = uuid.uuid4().hex
    return f"xoxb-CANARY-{tag}", f"xapp-1-CANARY-{tag}"


def test_either_token_alone_replaces_just_that_token(two_bots, gateway_reload):
    _ok("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    new_app = f"xapp-1-CANARY-{uuid.uuid4().hex}"
    result = _ok("messaging.slack.connect", {"profile": "scout", "app_token": new_app})
    assert result["app_token_set"] and result["bot_token_set"]
    assert _env_of("scout")["SLACK_APP_TOKEN"] == new_app and _env_of("scout")["SLACK_BOT_TOKEN"] == BOT_TOKEN
    new_bot = f"xoxb-CANARY-{uuid.uuid4().hex}"
    _ok("messaging.slack.connect", {"profile": "scout", "bot_token": new_bot})
    assert _env_of("scout")["SLACK_BOT_TOKEN"] == new_bot and _env_of("scout")["SLACK_APP_TOKEN"] == new_app
    assert gateway_reload["hot"] == ["scout"] * 3


def test_a_single_token_cannot_start_a_first_connection_and_an_empty_call_is_refused(two_bots, gateway_reload):
    assert _rpc("messaging.slack.connect", {"profile": "scout", "app_token": APP_TOKEN})["error"]["code"] == 4101
    assert _rpc("messaging.slack.connect", {"profile": "scout"})["error"]["code"] == 4101
    assert _rpc("messaging.slack.connect", {"profile": "scout", "bot_token": "  ", "app_token": ""})["error"]["code"] == 4101
    env_file = get_profile_dir("scout") / ".env"
    assert "SLACK_" not in (env_file.read_text() if env_file.exists() else "")
    assert gateway_reload["hot"] == [] and gateway_reload["restart"] == []


def test_replacing_one_bots_token_never_touches_another_bot(two_bots, gateway_reload):
    other_bot, other_app = _canary_tokens()
    _ok("messaging.slack.connect", {"profile": "scout", "bot_token": BOT_TOKEN, "app_token": APP_TOKEN})
    _ok("messaging.slack.connect", {"profile": "pilot", "bot_token": other_bot, "app_token": other_app})
    pilot_before = (get_profile_dir("pilot") / ".env").read_text()
    _ok("messaging.slack.connect", {"profile": "scout", "app_token": f"xapp-1-CANARY-{uuid.uuid4().hex}"})
    assert (get_profile_dir("pilot") / ".env").read_text() == pilot_before
    assert _env_of("pilot")["SLACK_APP_TOKEN"] == other_app
    assert gateway_reload["hot"][-1] == "scout" and "pilot" not in gateway_reload["hot"][-1:]


def test_token_canaries_reach_only_the_profile_env_file(two_bots, gateway_reload, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    bot, app = _canary_tokens()
    connect = _rpc("messaging.slack.connect", {"profile": "scout", "bot_token": bot, "app_token": app})
    rotated = f"xapp-1-CANARY-{uuid.uuid4().hex}"
    update = _rpc("messaging.slack.connect", {"profile": "scout", "app_token": rotated})
    status = _rpc("messaging.slack.status", {"profile": "scout"})
    swapped = _rpc("messaging.slack.connect", {"profile": "scout", "bot_token": app})
    out = capsys.readouterr()
    outside = json.dumps([connect, update, status, swapped]) + caplog.text + out.out + out.err
    for secret in (bot, app, rotated):
        assert secret not in outside
    assert bot in (get_profile_dir("scout") / ".env").read_text()
    assert _env_of("scout")["SLACK_APP_TOKEN"] == rotated


def test_status_carries_slacks_refusal_reason_and_no_token(two_bots, monkeypatch):
    from hermes_cli.web_routers import messaging

    real = messaging._platform_payloads

    def with_refusal(scope_dir, entries):
        payloads = real(scope_dir, entries)
        payloads[0].update(state="retrying", error_code="missing_scope", needed_scope="connections:write",
                           provided_scope="authorizations:read")
        return payloads

    monkeypatch.setattr(messaging, "_platform_payloads", with_refusal)
    status = _ok("messaging.slack.status", {"profile": "scout"})
    assert (status["state"], status["error_code"]) == ("retrying", "missing_scope")
    assert status["needed_scope"] == "connections:write" and status["provided_scope"] == "authorizations:read"


def test_status_without_a_refusal_has_no_scopes(two_bots):
    status = _ok("messaging.slack.status", {"profile": "scout"})
    assert status["needed_scope"] is None and status["provided_scope"] is None
