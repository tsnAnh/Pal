"""A bot's silent turns never become the roster's last-message preview or the picker's last reply."""
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
