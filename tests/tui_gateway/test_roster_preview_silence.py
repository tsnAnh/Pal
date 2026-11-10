"""What the owner's transcript hides (silent replies, cron and process-completion turns) never becomes the roster's last-message preview, the picker's preview, or its last reply."""
from __future__ import annotations

import pytest

from tests.tui_gateway.test_profiles_list_canonical_session import _add_session, _db, _profiles, _row


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = tmp_path / ".hermes"
    (h / "profiles" / "ops").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(h))
    return h


def _chat(db, sid, *replies):
    _add_session(db, sid, title="Bot Chat", ts=1000, text="question", hidden=True)
    for offset, reply in enumerate(replies, start=1):
        db.append_message(sid, "assistant", reply, timestamp=1000 + offset)


@pytest.mark.parametrize("silent", ["[SILENT]", "  [SILENT]\n", "NO_REPLY"])
def test_profiles_list_previews_the_last_real_message_not_a_silent_reply(home, silent):
    db = _db(home)
    _chat(db, "chat", "Real answer.", silent)
    db.close()
    canonical = _row(_profiles({}), "default")["canonical_session"]
    assert canonical["preview"] == "Real answer."


def test_profiles_list_falls_back_to_the_prompt_when_the_only_reply_is_silent(home):
    db = _db(home)
    _chat(db, "chat", "[SILENT]")
    db.close()
    canonical = _row(_profiles({}), "default")["canonical_session"]
    assert canonical["preview"] == "question"


def test_a_prose_reply_that_quotes_the_marker_stays_the_preview(home):
    db = _db(home)
    _chat(db, "chat", "Real answer.", "I answered [SILENT] only because nothing changed.")
    db.close()
    canonical = _row(_profiles({}), "default")["canonical_session"]
    assert canonical["preview"].startswith("I answered [SILENT]")


def test_the_picker_last_reply_skips_a_silent_reply():
    from gateway.session_picker_fields import _last_reply
    assert _last_reply([("[SILENT]", False), ("Real answer.", False)]) == "Real answer."
    assert _last_reply([("[SILENT]", False)]) is None


def test_the_authority_roster_preview_skips_a_silent_reply(home):
    from gateway.session_group_controls import _read_bot_sessions
    db = _db(home)
    _chat(db, "chat", "Real answer.", "[SILENT]")
    with db._lock:
        db._conn.execute("UPDATE sessions SET chat_id = 'local-chat', user_id = 'owner' WHERE id = 'chat'")
    try:
        fields = _read_bot_sessions(db, "owner", True)
    finally:
        db.close()
    assert fields["canonical_session"]["preview"] == "Real answer."


CRON_TURN = '[Cronjob "faker-kit-babysit" output — scheduled job, not the user. Review it.]\n\nbody'
PROCESS_TURN = "[IMPORTANT: Background process proc_1 exited (exit code 0).\nOutput: done]"


def _authority_fields(db, sid):
    from gateway.session_group_controls import _read_bot_sessions
    with db._lock:
        db._conn.execute("UPDATE sessions SET chat_id = 'local-chat', user_id = 'owner', hidden = 0 WHERE id = ?", (sid,))
    try:
        return _read_bot_sessions(db, "owner", True)
    finally:
        db.close()


def _cron_chat(db, sid):
    _add_session(db, sid, title="Bot Chat", ts=1000, text=CRON_TURN, hidden=True)
    db.append_message(sid, "assistant", "[SILENT]", timestamp=1001)
    return sid


def _answered_then_cron(db, sid):
    _chat(db, sid, "Real answer.")
    db.append_message(sid, "user", CRON_TURN, timestamp=1500)
    db.append_message(sid, "assistant", "[SILENT]", timestamp=1501)


def test_profiles_list_previews_the_message_before_a_cron_turn_and_its_silent_reply(home):
    db = _db(home)
    _answered_then_cron(db, "chat")
    db.close()
    assert _row(_profiles({}), "default")["canonical_session"]["preview"] == "Real answer."


def test_authority_roster_previews_the_message_before_a_cron_turn_and_its_silent_reply(home):
    db = _db(home)
    _answered_then_cron(db, "chat")
    assert _authority_fields(db, "chat")["canonical_session"]["preview"] == "Real answer."


@pytest.mark.parametrize("turn,kind", [(PROCESS_TURN, None), ("finished", "process_complete"),
                                       ("finished", "async_delegation_complete")])
def test_a_process_completion_turn_is_never_the_preview(home, turn, kind):
    db = _db(home)
    _chat(db, "chat", "Real answer.")
    db.append_message("chat", "user", turn, timestamp=1500, display_kind=kind)
    db.close()
    assert _row(_profiles({}), "default")["canonical_session"]["preview"] == "Real answer."


def test_a_session_of_only_cron_turns_has_no_preview_on_every_roster_path(home):
    db = _db(home)
    _cron_chat(db, "chat")
    _add_session(db, "scratch", title="Scratch", ts=2000, text=CRON_TURN)
    db.append_message("scratch", "assistant", "[SILENT]", timestamp=2001)
    db.close()
    row = _row(_profiles({}), "default")
    assert row["canonical_session"]["preview"] == ""
    assert row["last_session"]["preview"] == ""


def test_authority_roster_of_only_cron_turns_has_no_preview(home):
    db = _db(home)
    _cron_chat(db, "chat")
    fields = _authority_fields(db, "chat")
    assert fields["canonical_session"]["preview"] == ""
    assert fields["last_session"]["preview"] == ""


def test_a_user_message_that_quotes_the_cron_prefix_mid_text_still_previews(home):
    db = _db(home)
    _chat(db, "chat", "Real answer.")
    db.append_message("chat", "user", 'why did [Cronjob "x" output] appear?', timestamp=1500)
    db.close()
    assert _row(_profiles({}), "default")["canonical_session"]["preview"].startswith("why did [Cronjob")


def test_the_picker_preview_hides_a_cron_first_prompt_and_keeps_a_quoting_one(home):
    from gateway.session_picker_fields import fill_picker_fields
    db = _db(home)
    _add_session(db, "cron-born", title="Cron born", ts=1000, text=CRON_TURN)
    _add_session(db, "quoting", title="Quoting", ts=1000, text='see [Cronjob "x"] in the log')
    rows = {sid: {} for sid in ("cron-born", "quoting")}
    try:
        fill_picker_fields(db, [(row, sid, sid, None) for sid, row in rows.items()])
    finally:
        db.close()
    assert rows["cron-born"]["preview"] is None
    assert rows["quoting"]["preview"].startswith("see [Cronjob")


def test_the_cron_prefix_is_the_one_cron_writes():
    from cron.scheduler_delivery import bot_chat_message
    from gateway.response_filters import is_hidden_from_owner_row
    assert is_hidden_from_owner_row("user", bot_chat_message({"name": "faker-kit-babysit"}, "output"))
