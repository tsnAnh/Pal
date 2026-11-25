import threading
import types

import pytest

import hermes_cli.config as hc
from tools import approval
from tools.bot_mode_drafts import NOT_SENT_NOBODY_TO_ASK, review_outbound
from tui_gateway import server

TOOL = "mcp__fakeconn__fakeconn__send_message"
ARGS = {"to": "client-1", "message": "Hello from the fake connector"}
KEY = "other-chat-key"


class _InlineThread:
    def __init__(self, target=None, daemon=None, args=(), kwargs=None, name=None):
        self._target, self._args, self._kwargs = target, args, kwargs or {}

    def start(self):
        self._target(*self._args, **self._kwargs)

    def is_alive(self):
        return False

    def join(self, timeout=None):
        return None


@pytest.fixture
def turn(monkeypatch, tmp_path):
    home = tmp_path / "hermes"
    home.mkdir()
    (home / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    shape: cloud\n", encoding="utf-8")
    (home / "config.yaml").write_text("approvals:\n  mode: manual\n  timeout: 2\n", encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(home))
    for name in ("HERMES_CRON_SESSION", "HERMES_SINGLE_QUERY_SESSION"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HERMES_GATEWAY_SESSION", "1")
    monkeypatch.setenv("HERMES_EXEC_ASK", "1")
    monkeypatch.setattr("tools.terminal_tool._get_approval_callback", lambda: None, raising=False)
    hc._LOAD_CONFIG_CACHE.clear()
    monkeypatch.setattr(server, "_emit", lambda *a, **k: None)
    monkeypatch.setattr(server.threading, "Thread", _InlineThread)
    monkeypatch.setattr(server, "_wire_callbacks", lambda sid: None)
    monkeypatch.setattr(server, "_sync_agent_model_with_config", lambda sid, session: None)
    monkeypatch.setattr(server, "_session_cwd", lambda session: str(tmp_path))
    monkeypatch.setattr(server, "_register_session_cwd", lambda session: None)
    monkeypatch.setattr(server, "_tts_stream_begin", lambda: None)
    monkeypatch.setattr(server, "_sync_session_key_after_compress", lambda *a, **k: None)
    monkeypatch.setattr(server, "_get_usage", lambda agent: {})
    monkeypatch.setattr(server, "_hermes_home", home)
    yield home
    approval.unregister_gateway_notify(KEY)
    approval.clear_session(KEY)
    hc._LOAD_CONFIG_CACHE.clear()


def _run_turn(title, clients, monkeypatch):
    outcome = {}

    def run_conversation(message, **kwargs):
        outcome["review"] = review_outbound(TOOL, ARGS)
        return {"final_response": "done"}

    agent = types.SimpleNamespace(session_id=KEY, run_conversation=run_conversation, clear_interrupt=lambda: None,
                                  _session_title_hint=title)
    session = {"agent": agent, "session_key": KEY, "history": [], "history_lock": threading.Lock(),
               "history_version": 0, "running": True, "attached_images": [], "image_counter": 0, "cols": 80,
               "slash_worker": None, "show_reasoning": False, "tool_progress_mode": "all", "inflight_turn": None}
    monkeypatch.setattr(server, "_session_answering_clients", lambda sid: clients)
    server._run_prompt_submit("rid", "sid-other", session, "send it")
    return outcome


def test_a_turn_of_an_ordinary_chat_with_an_answering_client_asks_inline(turn, monkeypatch):
    cards = []

    def owner(data):
        cards.append(data)
        approval.resolve_gateway_approval(KEY, "once", request_id=data["request_id"])

    approval.register_gateway_notify(KEY, owner)
    outcome = _run_turn("Some other chat", [object()], monkeypatch)
    assert outcome["review"] == (None, None)
    assert len(cards) == 1 and cards[0]["draft"]["recipient"] == "client-1"
    assert cards[0]["command"] == ARGS["message"]
    assert not (turn / "bot_mode" / "drafts").exists()


def test_a_turn_with_no_answering_client_is_refused_and_stores_nothing(turn, monkeypatch):
    cards = []
    approval.register_gateway_notify(KEY, cards.append)
    outcome = _run_turn("Some other chat", [], monkeypatch)
    assert outcome["review"] == (NOT_SENT_NOBODY_TO_ASK, None)
    assert cards == [] and not (turn / "bot_mode" / "drafts").exists()


def test_the_canonical_bot_chat_turn_without_a_client_is_refused_too(turn, monkeypatch):
    approval.register_gateway_notify(KEY, lambda data: None)
    outcome = _run_turn("Bot Chat", [], monkeypatch)
    assert outcome["review"] == (NOT_SENT_NOBODY_TO_ASK, None)
    assert not (turn / "bot_mode" / "drafts").exists()
