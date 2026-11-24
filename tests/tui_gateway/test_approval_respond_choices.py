import threading

import pytest

from tools.approval import _gateway_queues
from tools.approval_gateway_wait import _ApprovalEntry
from tui_gateway import server

SESSION_KEY = "20260909_120000_bbbbbb"
SID = "live-choices"
REQUEST_ID = "req-choices-1"


@pytest.fixture()
def pending_entry():
    server._sessions[SID] = {"_sid": SID, "session_key": SESSION_KEY, "history": [],
                             "history_lock": threading.Lock(), "running": False, "agent": None}
    entry = _ApprovalEntry({"description": "Send the held message", "request_id": REQUEST_ID})
    _gateway_queues.setdefault(SESSION_KEY, []).append(entry)
    yield entry
    _gateway_queues.pop(SESSION_KEY, None)
    server._sessions.pop(SID, None)


def _respond(**params):
    return server.handle_request({"id": "r", "method": "approval.respond",
                                  "params": {"session_id": SID, "request_id": REQUEST_ID, **params}})


@pytest.mark.parametrize("choice", ["session", "always", "approve", ""])
def test_a_scoped_or_unknown_choice_is_refused_and_leaves_the_request_pending(pending_entry, choice):
    reply = _respond(choice=choice)

    assert reply["error"]["code"] == 4133
    assert pending_entry.result is None and not pending_entry.event.is_set()


@pytest.mark.parametrize("choice", ["once", "deny"])
def test_once_and_deny_resolve_the_request(pending_entry, choice):
    reply = _respond(choice=choice)

    assert reply["result"]["resolved"] == 1
    assert pending_entry.result == choice and pending_entry.event.is_set()


def test_an_edit_applies_only_when_the_draft_is_sent(pending_entry):
    reply = _respond(choice="deny", edited_text="changed")

    assert reply["error"]["code"] == 4135
    assert not pending_entry.event.is_set()


def test_the_request_payload_offers_once_or_deny_whatever_the_queue_entry_says():
    payload = server._approval_request_payload(
        {"request_id": REQUEST_ID, "description": "Pay", "allow_session": True, "allow_permanent": True,
         "choices": ["once", "session", "always", "deny"]})

    assert payload["choices"] == ["once", "deny"]
