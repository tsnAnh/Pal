from __future__ import annotations

import threading
import types

import pytest

from tui_gateway import server

BOT_AUTHOR = {"id": "bot:ops", "name": "ops", "is_bot": True}


def _live_session(calls):
    agent = types.SimpleNamespace(
        _supports_active_turn_redirect=True,
        redirect=lambda text: calls.append(("redirect", text)) or True,
        steer=lambda text: calls.append(("steer", text)) or True,
        interrupt=lambda: None,
    )
    return {
        "agent": agent, "session_key": "session-key", "history": [], "history_lock": threading.Lock(),
        "history_version": 0, "running": True, "transport": None, "attached_images": [],
    }


@pytest.fixture(autouse=True)
def _no_side_effects(monkeypatch):
    monkeypatch.setattr(server, "_session_compression_in_flight", lambda session: False)
    monkeypatch.setattr(server, "_interrupt_busy_session", lambda *a, **k: None)


@pytest.mark.parametrize("mode", ["steer", "interrupt"])
@pytest.mark.parametrize("origin", [{"turn_author": BOT_AUTHOR}, {"display_kind": "hidden"}],
                         ids=["bot-authored", "hidden"])
def test_a_bot_authored_or_hidden_prompt_queues_instead_of_entering_the_live_turn(monkeypatch, mode, origin):
    monkeypatch.setattr(server, "_load_busy_input_mode", lambda: mode)
    interrupts = []
    monkeypatch.setattr(server, "_interrupt_busy_session", lambda *a, **k: interrupts.append(a))
    calls = []
    session = _live_session(calls)
    resp = server._handle_busy_submit("r", "sid", session, "merge #7", "ws", **origin)
    assert resp["result"]["status"] == "queued"
    assert calls == []
    assert interrupts == []
    assert session["queued_prompt"]["text"] == "merge #7"


@pytest.mark.parametrize(("mode", "call", "status"), [("steer", "steer", "steered"), ("interrupt", "redirect", "redirected")])
def test_the_owners_own_typed_text_still_steers_or_redirects_the_live_turn(monkeypatch, mode, call, status):
    monkeypatch.setattr(server, "_load_busy_input_mode", lambda: mode)
    calls = []
    session = _live_session(calls)
    resp = server._handle_busy_submit("r", "sid", session, "actually, use the other branch", "ws")
    assert resp["result"]["status"] == status
    assert calls == [(call, "actually, use the other branch")]
    assert not session.get("queued_prompt")
