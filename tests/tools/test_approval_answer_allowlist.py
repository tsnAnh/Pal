"""Only "once" counts as consent.

The owner-decision gate used to be a deny-list: it refused "deny", ``None`` and "timeout" and treated
every other value as a yes. The gateway round-trip (``_await_gateway_decision``) hands its answer
straight through to ``grant``, so a client that starts sending ``{"choice": "approve"}`` after an
upgrade, or a truncated payload, read as consent and the draft went out.

This test pins the allow-list in ``tools.approval._human_decision.grant``.
"""

from __future__ import annotations

import pytest

import tools.approval as approval_module
from tools.approval import request_draft_approval
from tools.terminal_tool import set_approval_callback
from tests.waiting import wait_until


DRAFT = "Dinner at 7?"


def ask_owner():
    return request_draft_approval(text=DRAFT, description="Send a message", pattern_key="draft:allowlist",
                                  draft={"kind": "message"})


# Values a gateway client or transport plugin could plausibly send that are NOT consent. Every one
# of these executed the command while the gate was a deny-list.
NOT_CONSENT = [
    "yes",
    "ok",
    "true",
    "accept",
    "",             # empty payload
    "null",
    "1",
    "denied",       # near-miss on the refusal word
    # ``approval.respond`` accepts any JSON value: a non-string answer is no decision either.
    ["once"],
    {"choice": "once"},
]

@pytest.fixture(autouse=True)
def _clean_approval_env(monkeypatch):
    """Neutral approval environment."""
    for key in ("HERMES_EXEC_ASK", "HERMES_GATEWAY_SESSION", "HERMES_SESSION_PLATFORM", "HERMES_CRON_SESSION"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setenv("HERMES_INTERACTIVE", "1")
    monkeypatch.setattr("tools.details_bubble.post_details", lambda *a, **k: None)
    set_approval_callback(None)
    yield
    set_approval_callback(None)


def _drive_gateway(monkeypatch, answer):
    """Run the owner gate through the gateway branch with ``answer`` as the user's reply."""
    monkeypatch.setenv("HERMES_EXEC_ASK", "1")
    monkeypatch.setattr(approval_module, "_gateway_notify_cb", lambda _sk: (lambda *a, **k: True))
    monkeypatch.setattr(
        approval_module, "_await_gateway_decision",
        lambda *a, **k: {"resolved": True, "choice": answer, "reason": None},
    )
    return ask_owner()


class TestGatewayAnswersMustBeConsentWords:
    @pytest.mark.parametrize("answer", NOT_CONSENT)
    def test_unrecognized_gateway_answer_is_refused(self, monkeypatch, answer):
        result = _drive_gateway(monkeypatch, answer)

        assert result.get("approved") is False, f"{answer!r} was treated as consent"
        assert result.get("outcome") == "unrecognized_answer"
        assert result.get("user_consent") is False
        assert "not a recognized decision" in (result.get("message") or "")

    @pytest.mark.parametrize("answer", ["ONCE", " once\n", "Approve", "session", "always"])
    def test_spelling_variants_of_once_approve_this_call_only(self, monkeypatch, answer):
        assert _drive_gateway(monkeypatch, answer).get("approved") is True


# --- The answer is canonical where it is stored, not only in ``grant`` ---------------------------
# Real round-trip (register_gateway_notify -> resolve_gateway_approval), no mocked wait: the
# coalescing rule reads ``entry.result`` before ``grant`` runs.

def _gateway_guard(session_key):
    import contextvars
    from gateway.session_context import set_session_vars
    from tools.approval_context import set_current_session_key

    def run():
        set_session_vars(session_key=session_key, platform="whatsapp")
        set_current_session_key(session_key)
        return ask_owner()

    return contextvars.Context().run(run)


def test_alias_of_once_does_not_approve_an_identical_coalesced_call(monkeypatch):
    """ "once" covers only the prompt it answered; an alias of it must not approve a follower."""
    import threading
    import tools.approval_gateway_wait as wait_mod

    key = "alias-coalesce"
    follower_waiting = threading.Event()
    real_follow = wait_mod._await_coalesced_leader

    def follow(*args, **kwargs):
        follower_waiting.set()
        return real_follow(*args, **kwargs)

    monkeypatch.setattr(wait_mod, "_await_coalesced_leader", follow)
    prompts = []

    def notify(data):
        prompts.append(data)
        if len(prompts) == 1:
            def answer():
                follower_waiting.wait(10)
                approval_module.resolve_gateway_approval(key, "approve", request_id=data["request_id"])
        else:
            def answer():
                approval_module.resolve_gateway_approval(key, "deny", request_id=data["request_id"])
        threading.Thread(target=answer, daemon=True).start()

    approval_module.register_gateway_notify(key, notify)
    results = {}
    try:
        leader = threading.Thread(target=lambda: results.update(leader=_gateway_guard(key)))
        leader.start()
        wait_until(lambda: prompts, timeout=10, what="the leader's prompt")
        follower = threading.Thread(target=lambda: results.update(follower=_gateway_guard(key)))
        follower.start()
        leader.join(20)
        follower.join(20)
    finally:
        approval_module.unregister_gateway_notify(key)

    assert results["leader"]["approved"] is True
    assert results["follower"]["approved"] is False
    assert len(prompts) == 2
