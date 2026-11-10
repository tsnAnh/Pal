from hermes_state import SessionDB
from hermes_state_runtime import (
    admit_session_input, begin_runtime_epoch, claim_session_input, list_session_admissions,
)
from tui_gateway import server

from tests.tui_gateway.test_legacy_submit_forwards_to_owner import _legacy, _owner

NOTE = '[@mentions resolved from the Bot Mode roster: @faker-kit = agent profile "faker-kit"]'


def test_the_forwarded_admission_commits_the_note_beside_the_untouched_typed_text(monkeypatch, tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    sid, key, turns, _emitted = _legacy(monkeypatch, db)
    try:
        db.create_session(key, "test")
        epoch = begin_runtime_epoch(db, instance_id="gateway")
        admit_session_input(db, epoch=epoch, principal_id="bot", session_id=key, request_id="dm-1",
                            payload={"text": "a message_agent DM"})
        claim_session_input(db, epoch=epoch, session_id=key)
        _owner(monkeypatch, db, key, epoch)

        reply = server.handle_request({"id": "p", "method": "prompt.submit", "params": {
            "session_id": sid, "text": "ask @faker-kit to say hi", "turn_context": f"  {NOTE}\n"}})

        assert reply["result"]["status"] == "queued" and reply["result"]["forwarded"] is True, reply
        assert turns == []
        mine = next(r for r in list_session_admissions(db, session_id=key) if r["principal_id"] != "bot")
        assert mine["payload"]["text"] == "ask @faker-kit to say hi"
        assert mine["payload"]["cli_turn_v1"] == {"turn_context": NOTE}
    finally:
        db.close()
