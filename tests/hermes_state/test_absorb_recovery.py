"""An owner message in transfer to a running turn that the gateway loses is delivered exactly once: its text
is in the transcript (the steer row carries the admission id) or it runs as its own turn, never both."""
import pytest

from hermes_state import SessionDB
from hermes_state_runtime import (
    admit_session_input, begin_runtime_epoch, claim_session_input, find_session_admission, get_session_admission,
    recover_session_inputs, steer_session_input,
)


def _db_with_transfer(tmp_path, title="Bot Chat"):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s", source="gui")
    db.set_session_title("s", title)
    epoch = begin_runtime_epoch(db, instance_id="first")
    for request_id in ("running", "owner-follow-up"):
        admit_session_input(db, epoch=epoch, principal_id="human", session_id="s", request_id=request_id,
                            payload={"text": request_id})
    running = claim_session_input(db, epoch=epoch, session_id="s")
    follow_up = find_session_admission(db, principal_id="human", session_id="s", request_id="owner-follow-up")
    steer_session_input(db, epoch=epoch, admission_id=follow_up["admission_id"], generation=running["generation"])
    return db, follow_up["admission_id"]


def _restart(db):
    recover_session_inputs(db, epoch=begin_runtime_epoch(db, instance_id="second"))


def test_a_transfer_whose_text_never_reached_the_transcript_is_queued_again_exactly_once(tmp_path):
    db, admission_id = _db_with_transfer(tmp_path)
    _restart(db)
    row = get_session_admission(db, admission_id=admission_id)
    assert (row["status"], row["outcome"], row["generation"]) == ("queued", None, None)
    _restart(db)
    assert get_session_admission(db, admission_id=admission_id)["status"] == "queued"


def test_a_transfer_whose_text_reached_the_transcript_is_never_replayed(tmp_path):
    db, admission_id = _db_with_transfer(tmp_path)
    db.append_message("s", "user", "[steer marker] owner-follow-up", display_kind="steer",
                      display_metadata={"admission_ids": ["someone-else", admission_id]})
    _restart(db)
    row = get_session_admission(db, admission_id=admission_id)
    assert (row["status"], row["outcome"]) == ("terminal", "interrupted")


def test_a_transfer_in_a_chat_that_is_not_a_bot_chat_is_never_replayed(tmp_path):
    db, admission_id = _db_with_transfer(tmp_path, title="Plain chat")
    _restart(db)
    row = get_session_admission(db, admission_id=admission_id)
    assert (row["status"], row["outcome"]) == ("terminal", "interrupted")
