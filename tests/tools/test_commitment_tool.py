"""The `commitment` tool: a schema generated from the ledger's states and edges, the four actions on a
real per-profile state.db, the route of the chat a promise was made in, and nothing that asks the owner."""

import json

import pytest

import tools.commitment_tool as tool
from gateway import commitments as cm
from gateway.commitments import State
from gateway.session_context import clear_session_vars, set_session_vars
from tools.approval_context import reset_current_observability_context, set_current_observability_context
from tools.registry import registry


@pytest.fixture
def bound(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", thread_id="7",
                              session_key="agent:main:telegram:dm:42", session_id="s1", profile="main")
    yield tmp_path
    clear_session_vars(tokens)


def call(args: dict, *, tool_call_id: str = "") -> dict:
    tokens = set_current_observability_context(turn_id="t1" if tool_call_id else "", tool_call_id=tool_call_id,
                                               session_id="s1" if tool_call_id else "")
    try:
        return json.loads(registry.dispatch("commitment", args))
    finally:
        reset_current_observability_context(tokens)


def promise(*, tool_call_id: str = "", **extra) -> dict:
    return call({"action": "promise", "text": "Send the weekly report", "owner_requested": True, **extra},
                tool_call_id=tool_call_id)


def schema_states(schema: dict) -> set[str]:
    found = set()

    def walk(node):
        if isinstance(node, dict):
            found.update(v for v in node.get("enum", ()) if isinstance(v, str))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(schema)
    return found


def test_the_registered_schema_is_the_generated_one():
    assert registry.get_schema("commitment") == tool.build_schema()
    assert tool.COMMITMENT_SCHEMA == tool.build_schema()


def test_the_schema_covers_every_state_and_action():
    schema = tool.build_schema()
    enums = schema_states(schema)
    assert {s.value for s in State} - {State.OPEN.value} <= enums
    assert {"promise", "update", "close", "list"} <= enums
    text = json.dumps(schema)
    for state, fields in cm.REQUIRED_FIELDS.items():
        assert state.value in text
        for field in fields:
            assert field in schema["parameters"]["properties"] or field in text


def test_a_promise_records_the_chat_it_was_made_in(bound):
    made = promise(due="2030-01-02T03:04:05+00:00")
    assert made["state"] == "open"
    row = cm.get(bound, made["id"])
    assert (row.route.platform, row.route.chat_id, row.route.thread_id, row.route.session_key) == (
        "telegram", "42", "7", "agent:main:telegram:dm:42")
    assert (row.profile, row.owner_requested, row.due_at) == ("main", True, 1893553445.0)


def test_a_replayed_tool_call_does_not_promise_twice(bound):
    first = promise(tool_call_id="call-1")
    again = promise(tool_call_id="call-1")
    assert again["id"] == first["id"]
    assert again.get("replayed") is True
    assert len(call({"action": "list"})["commitments"]) == 1


def test_update_and_close_walk_the_ledger(bound):
    cid = promise()["id"]
    started = call({"action": "update", "id": cid, "state": "in_progress", "note": "drafting"})
    assert (started["from"], started["to"], started["rev"]) == ("open", "in_progress", 2)
    blocked = call({"action": "update", "id": cid, "state": "blocked", "blocker_what": "no sales numbers",
                    "blocker_who": "owner", "next_step": "send the draft without them"})
    assert blocked["to"] == "blocked"
    closed = call({"action": "close", "id": cid, "state": "done", "evidence": "sent at 09:00", "expected_rev": 3})
    assert (closed["to"], closed["rev"]) == ("done", 4)
    assert call({"action": "list"})["commitments"] == []


def test_the_tool_refuses_what_the_ledger_refuses(bound):
    cid = promise()["id"]
    missing = call({"action": "update", "id": cid, "state": "blocked", "blocker_what": "no key"})
    assert missing["code"] == "missing_fields"
    assert call({"action": "close", "id": cid, "state": "done"})["code"] == "missing_fields"
    assert call({"action": "update", "id": cid, "state": "done", "evidence": "x"})["code"] == "invalid_input"
    assert call({"action": "close", "id": cid, "state": "in_progress"})["code"] == "invalid_input"
    assert call({"action": "update", "id": cid, "state": "in_progress", "expected_rev": 9})["code"] == "rev_conflict"
    assert call({"action": "close", "id": cid, "state": "abandoned", "reason": "dropped"})["code"] == "missing_fields"
    assert call({"action": "promise", "text": "x"})["code"] == "invalid_input"
    assert call({"action": "promise", "text": "x", "owner_requested": True, "due": "soon"})["code"] == "invalid_input"


def test_abandon_records_who_dropped_it(bound):
    cid = promise()["id"]
    closed = call({"action": "close", "id": cid, "state": "abandoned", "reason": "owner cancelled", "by": "owner"})
    assert closed["to"] == "abandoned"
    assert cm.get(bound, cid).abandoned_by is cm.Actor.OWNER


def test_list_reports_computed_overdue(bound):
    promise(due="2001-01-01T00:00:00+00:00")
    [item] = call({"action": "list"})["commitments"]
    assert (item["state"], item["overdue"], item["stuck"]) == ("open", True, False)


def test_an_unattended_cron_turn_can_use_it_and_nothing_asks_the_owner(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    tokens = set_session_vars(platform="cron", session_id="cron-1", cron_session="1")
    asked = []
    monkeypatch.setattr("tools.clarify_tool.clarify_tool", lambda *a, **k: asked.append(a) or "{}")
    try:
        cid = promise()["id"]
        assert call({"action": "close", "id": cid, "state": "done", "evidence": "report sent"})["to"] == "done"
    finally:
        clear_session_vars(tokens)
    assert asked == []
