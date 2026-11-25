import pytest

from gateway.run_turn_runner import TurnRunner
from tools import approval
from tools.approval_context import reset_current_session_key, set_current_session_key
from tools.approval_prompt import request_elicitation_consent

SESSION_KEY = "agent:main:telegram:dm:42"


@pytest.fixture
def plain_chat_turn(monkeypatch):
    monkeypatch.setenv("HERMES_GATEWAY_SESSION", "1")
    runner = object.__new__(TurnRunner)
    token = set_current_session_key(SESSION_KEY)
    approval.register_gateway_notify(SESSION_KEY, runner._approval_notify_sync)
    yield runner
    approval.unregister_gateway_notify(SESSION_KEY)
    approval.clear_session(SESSION_KEY)
    reset_current_session_key(token)


def test_plain_chat_turn_has_no_authority_owner_to_notify(plain_chat_turn):
    with pytest.raises(RuntimeError, match="no client can answer"):
        plain_chat_turn._approval_notify_sync({"request_id": "r1", "command": "x"})


def test_outbound_draft_in_a_plain_chat_turn_is_blocked_without_waiting(plain_chat_turn):
    result = approval.request_draft_approval(
        text="Hello", description="Send to Ana", pattern_key="draft:1",
        draft={"kind": "outbound_message", "text": "Hello"})

    assert result["approved"] is False
    assert result["outcome"] == "notify_failed"
    assert result["user_consent"] is False
    assert result["message"].startswith("BLOCKED")
    assert approval.pending_gateway_approval_count() == 0


def test_elicitation_consent_in_a_plain_chat_turn_is_declined_without_waiting(plain_chat_turn):
    assert request_elicitation_consent("Share your email?", "A server asks for your email") == "decline"
    assert approval.pending_gateway_approval_count() == 0
