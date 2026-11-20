import json

import pytest

from gateway.session_bot_thread_links import project_links
from hermes_state import SessionDB
from tools import bot_thread_identity as identity
from tools import bot_thread_ledger as ledger

DELIVERY = "a" * 64
BETA = identity.CounterpartRef(
    lane=identity.Lane.local, origin="", profile="beta", handle="beta", display_name="Beta")


@pytest.fixture
def home(tmp_path):
    return tmp_path


def _send(db, session_id, home, *, process_id):
    call = f"call_{process_id}"
    db.append_message(session_id, "assistant", content="", tool_calls=[{
        "id": call, "type": "function",
        "function": {"name": "message_agent", "arguments": json.dumps({"target": "beta", "message": "hi"})}}])
    db.append_message(session_id, "tool", tool_call_id=call, content=json.dumps({
        "status": "queued", "delivery_id": DELIVERY, "to": "@beta", "process_id": process_id}))
    key = ledger.ExchangeKey.of(ledger.Direction.outbound, DELIVERY)
    ledger.record_message(home, key, BETA, "hi", status=ledger.Status.delivered, anchor_session_id=session_id)


def _links(db, home, session_id):
    return project_links(db, [session_id], ledger.anchored_exchanges(home, [session_id]))


def test_an_exchange_stays_linked_after_compaction_archives_its_rows(home):
    db = SessionDB(db_path=home / "state.db")
    try:
        db.create_session("chat", source="cli")
        _send(db, "chat", home, process_id="proc_1")
        [live] = _links(db, home, "chat")
        db._execute_write(lambda conn: conn.execute(
            "UPDATE messages SET active = 0, compacted = 1 WHERE session_id = 'chat'"))
        db.append_message("chat", "assistant", content="Summary of the earlier conversation.")
        [archived] = _links(db, home, "chat")
        assert (archived.anchor_uid, [row.uid for row in archived.covered]) == (
            live.anchor_uid, [row.uid for row in live.covered])
    finally:
        db.close()


def test_an_undone_exchange_is_not_linked(home):
    db = SessionDB(db_path=home / "state.db")
    try:
        db.create_session("chat", source="cli")
        _send(db, "chat", home, process_id="proc_1")
        db._execute_write(lambda conn: conn.execute(
            "UPDATE messages SET active = 0, compacted = 0 WHERE session_id = 'chat'"))
        assert _links(db, home, "chat") == []
    finally:
        db.close()
