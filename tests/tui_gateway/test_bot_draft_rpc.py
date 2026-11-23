import json
import textwrap
import threading
from types import SimpleNamespace

import pytest

import hermes_cli.config as hc
import tui_gateway.server as srv
from tools import bot_mode_draft_store
from tools.bot_mode_drafts import classify_outbound

EMAIL = "connectors__gmail__SEND_EMAIL"
ARGS = {"to": "ada@example.com", "subject": "Lunch", "body": "Lunch at noon?"}


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / "hermes"
    path.mkdir()
    (path / "profile.yaml").write_text(
        textwrap.dedent("""\
            ui_meta:
              hermes-bots:
                shape: cloud
        """), encoding="utf-8")
    (path / "config.yaml").write_text("approvals:\n  mode: manual\n", encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(path))
    hc._LOAD_CONFIG_CACHE.clear()
    yield path
    hc._LOAD_CONFIG_CACHE.clear()
    srv._sessions.pop("ui-bot", None)


def _session(title):
    session = {"session_key": "bot-key", "history": [], "pending_title": title,
               "agent": SimpleNamespace(_session_title_hint=title)}
    srv._sessions["ui-bot"] = session
    return session


def _rpc(method, **params):
    return srv.handle_request({"id": "r", "method": method, "params": {"session_id": "ui-bot", **params}})


def _hold():
    return bot_mode_draft_store.hold(classify_outbound(EMAIL, ARGS), ARGS, origin="unattended")


def test_held_drafts_come_back_with_the_bot_chats_pending_approvals(home):
    _session("Bot Chat")
    record = _hold()
    (card,) = _rpc("approval.pending")["result"]["approvals"]
    assert card["request_id"] == f"draft:{record['id']}"
    assert card["draft"]["text"] == "Lunch at noon?" and card["draft"]["held"] is True


def test_any_chat_of_the_bot_lists_and_answers_its_held_drafts(home, monkeypatch):
    sent = []
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda tool, args, **kw: sent.append((tool, args)) or json.dumps({"response": "ok"}))
    _session("Some other chat")
    record, other = _hold(), _hold()
    cards = _rpc("approval.pending")["result"]["approvals"]
    assert {card["request_id"] for card in cards} == {f"draft:{record['id']}", f"draft:{other['id']}"}
    assert {card["draft"]["state"] for card in cards} == {"pending"}
    assert _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="once")["result"] == {
        "resolved": 1, "status": "sent", "state": "sent"}
    assert _rpc("approval.respond", request_id=f"draft:{other['id']}", choice="deny")["result"] == {
        "resolved": 1, "state": "cancelled"}
    assert len(sent) == 1 and bot_mode_draft_store.list_pending() == []


def test_a_second_answer_names_the_true_state_and_never_resends(home, monkeypatch):
    sent = []
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda tool, args, **kw: sent.append((tool, args)) or json.dumps({"response": "ok"}))
    _session("Some other chat")
    record = _hold()
    assert _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="once")["result"]["state"] == "sent"
    again = _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="once")
    assert again["error"]["code"] == 4134 and again["error"]["data"] == {"reason": "already_sent", "state": "sent"}
    assert len(sent) == 1


def test_a_failed_send_comes_back_with_its_reason_and_state(home, monkeypatch):
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda *a, **k: json.dumps({"error": {"message": "provider down"}}))
    _session("Some other chat")
    record = _hold()
    reply = _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="once")
    assert reply["error"]["code"] == 4134 and reply["error"]["data"] == {"reason": "send_failed", "state": "failed"}
    assert "provider down" in reply["error"]["message"]
    (card,) = _rpc("approval.pending")["result"]["approvals"]
    assert card["draft"]["state"] == "failed" and card["draft"]["error"] == "provider down"


def test_a_draft_of_another_profile_is_not_reachable_from_this_one(home, tmp_path):
    secondary = tmp_path / "secondary"
    secondary.mkdir()
    (secondary / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    shape: cloud\n", encoding="utf-8")
    (secondary / "config.yaml").write_text("approvals:\n  mode: manual\n", encoding="utf-8")
    foreign = bot_mode_draft_store.hold(classify_outbound(EMAIL, ARGS), ARGS, origin="elsewhere", home=secondary)
    _session("Some other chat")
    assert _rpc("approval.pending")["result"]["approvals"] == []
    reply = _rpc("approval.respond", request_id=f"draft:{foreign['id']}", choice="once")
    assert reply["error"]["code"] == 4134 and reply["error"]["data"]["reason"] == "not_found"
    assert len(bot_mode_draft_store.list_pending(secondary)) == 1


def test_a_profile_that_is_not_bot_managed_lists_and_answers_nothing(home):
    _session("Some other chat")
    record = _hold()
    (home / "profile.yaml").unlink()
    assert _rpc("approval.pending")["result"]["approvals"] == []
    assert _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="deny")["error"]["code"] == 4132


def test_send_delivers_once_and_discard_is_final(home, monkeypatch):
    sent = []
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda tool, args, **kw: sent.append((tool, args)) or json.dumps({"response": "ok"}))
    _session("Bot Chat")
    first, second = _hold(), _hold()
    ok = _rpc("approval.respond", request_id=f"draft:{first['id']}", choice="once", edited_text="Lunch at one?")
    assert ok["result"] == {"resolved": 1, "status": "sent", "state": "sent"}
    assert sent == [(EMAIL, {**ARGS, "body": "Lunch at one?"})]
    again = _rpc("approval.respond", request_id=f"draft:{first['id']}", choice="once")
    assert again["error"]["code"] == 4134 and again["error"]["data"]["reason"] == "already_sent"
    assert _rpc("approval.respond", request_id=f"draft:{second['id']}", choice="deny")["result"] == {
        "resolved": 1, "state": "cancelled"}
    assert len(sent) == 1 and bot_mode_draft_store.list_pending() == []


def test_a_draft_is_sent_or_discarded_never_given_a_scope(home):
    _session("Bot Chat")
    record = _hold()
    reply = _rpc("approval.respond", request_id=f"draft:{record['id']}", choice="always")
    assert reply["error"]["code"] == 4133
    assert len(bot_mode_draft_store.list_pending()) == 1


def test_a_profile_that_is_not_bot_managed_cannot_send_or_discard_drafts(home, monkeypatch):
    sent = []
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda tool, args, **kw: sent.append((tool, args)) or json.dumps({"response": "ok"}))
    _session("Bot Chat")
    record = _hold()
    (home / "profile.yaml").unlink()
    for choice in ("once", "deny"):
        reply = _rpc("approval.respond", request_id=f"draft:{record['id']}", choice=choice)
        assert reply["error"]["code"] == 4132
    assert sent == [] and len(bot_mode_draft_store.list_pending()) == 1


def test_resolve_all_with_an_edit_and_no_request_id_is_refused(home):
    _session("Bot Chat")
    reply = _rpc("approval.respond", choice="once", all=True, edited_text="HIJACK")
    assert reply["error"]["code"] == 4135


class _Wire:
    def __init__(self):
        self.frames = []
        self.arrived = threading.Event()

    def write(self, obj):
        self.frames.append(obj)
        self.arrived.set()
        return True

    def close(self):
        pass


def _dispatch(wire, **params):
    return srv.dispatch(
        {"id": "r", "method": "approval.respond", "params": {"session_id": "ui-bot", **params}}, wire)


def test_a_send_runs_off_the_rpc_reader_and_answers_through_the_transport(home, monkeypatch):
    ran_on = []
    monkeypatch.setattr("model_tools.handle_function_call",
                        lambda tool, args, **kw: ran_on.append(threading.current_thread()) or json.dumps({"response": "ok"}))
    _session("Bot Chat")
    record = _hold()
    wire = _Wire()
    assert _dispatch(wire, request_id=f"draft:{record['id']}", choice="once") is None
    assert wire.arrived.wait(10)
    assert wire.frames[0]["result"] == {"resolved": 1, "status": "sent", "state": "sent"}
    assert ran_on and ran_on[0] is not threading.current_thread()


def test_the_send_uses_the_sessions_profile_not_the_launch_profile(home, tmp_path, monkeypatch):
    import os

    from hermes_constants import get_hermes_home, get_hermes_home_override, set_hermes_home_override
    from tools.mcp_tool import _mcp_registry_scope

    secondary = tmp_path / "secondary"
    secondary.mkdir()
    (secondary / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    shape: cloud\n", encoding="utf-8")
    (secondary / "config.yaml").write_text("approvals:\n  mode: manual\n", encoding="utf-8")
    seen = {}

    def deliver(tool, args, **kw):
        seen["home"] = get_hermes_home()
        seen["mcp_scope"] = _mcp_registry_scope()
        return json.dumps({"response": "ok"})

    monkeypatch.setattr("model_tools.handle_function_call", deliver)
    token = set_hermes_home_override(str(secondary))
    try:
        expected_scope = _mcp_registry_scope()
    finally:
        from hermes_constants import reset_hermes_home_override
        reset_hermes_home_override(token)
    session = _session("Bot Chat")
    session["profile_home"] = str(secondary)
    record = bot_mode_draft_store.hold(classify_outbound(EMAIL, ARGS), ARGS, origin="unattended", home=secondary)
    before = dict(os.environ)
    wire = _Wire()
    assert _dispatch(wire, request_id=f"draft:{record['id']}", choice="once") is None
    assert wire.arrived.wait(10)
    assert wire.frames[0]["result"] == {"resolved": 1, "status": "sent", "state": "sent"}
    assert seen["home"] == secondary
    assert seen["mcp_scope"] is not None and seen["mcp_scope"] == expected_scope
    assert seen["mcp_scope"] != _mcp_registry_scope()
    assert get_hermes_home_override() is None and dict(os.environ) == before
    assert bot_mode_draft_store.list_pending(secondary) == []
