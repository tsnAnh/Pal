import json

import pytest

from tools import bot_mode_dm
from tools.approval import check_all_command_guards, register_gateway_notify, unregister_gateway_notify
from tools.approval_context import reset_current_session_key, set_current_session_key

# _fresh_probe_cache is the autouse probe-cache reset; importing it applies it here too.
from tests.tools.test_bot_mode_dm import (
    _FakeAgent, _canonical_target, _capture_spawn, _fresh_probe_cache, _managed_home,
)


@pytest.fixture
def delivery_command(tmp_path, monkeypatch):
    calls = _capture_spawn(monkeypatch)
    monkeypatch.setattr(bot_mode_dm, "_dm_dir", lambda: tmp_path)
    home = _managed_home(tmp_path, teammates=("researcher",))
    _canonical_target(monkeypatch, home / "profiles" / "researcher")
    result = json.loads(bot_mode_dm.message_agent_tool(
        target="@researcher", message="status?", agent=_FakeAgent(home, title="Bot Chat")))
    assert result["status"] == "queued"
    return calls[0]["command"]


@pytest.mark.parametrize("client_attached", [False, True], ids=["no-client-in-bot-chat", "client-attached-in-bot-chat"])
def test_delivery_runner_command_raises_no_approval_event(delivery_command, client_attached):
    events = []
    session_key = "bot-chat-session"
    token = set_current_session_key(session_key)
    if client_attached:
        register_gateway_notify(session_key, events.append)
    try:
        decision = check_all_command_guards(delivery_command, "local")
    finally:
        unregister_gateway_notify(session_key)
        reset_current_session_key(token)

    assert decision["approved"] is True
    assert events == []
