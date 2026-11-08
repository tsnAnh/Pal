import sqlite3

import pytest

from hermes_state import SessionDB
from hermes_state_common import SCHEMA_VERSION
from tools import bot_thread_identity as identity
from tools import bot_thread_ledger as ledger
from tools.bot_thread_ledger import Direction, ExchangeKey, Outcome, PageRequest, Status

BETA = identity.outbound_local("beta", "beta", "Beta")


@pytest.fixture
def home(tmp_path):
    SessionDB(db_path=tmp_path / "state.db").close()
    return tmp_path


def _key(n: int, direction=Direction.outbound) -> ExchangeKey:
    return ExchangeKey.of(direction, f"{n:064x}")


def _page(home, **request):
    return ledger.read_page(home, BETA.thread_id, PageRequest(limit=request.pop("limit", 50), **request))


def _shape(page):
    return [(m.exchange_id[:3], m.part.value, m.body, m.status.value, m.from_self) for m in page.messages]


def test_replays_and_late_statuses_never_duplicate_or_regress(home):
    key = _key(1)
    ledger.record_message(home, key, BETA, "hi", status=Status.delivered, anchor_session_id="s1")
    ledger.record_message(home, key, BETA, "hi again", status=Status.delivered)
    ledger.record_outcome(home, key, Outcome.answered("yo"))
    ledger.record_outcome(home, key, Outcome.answered("yo"))
    ledger.record_message(home, key, BETA, "hi", status=Status.pending)
    ledger.record_outcome(home, key, Outcome.failed("runtime_offline"))
    assert _shape(_page(home)) == [("out", "message", "hi", "answered", True), ("out", "reply", "yo", "answered", False)]


def test_an_unknown_admission_still_learns_its_late_reply(home):
    key = _key(2)
    ledger.record_message(home, key, BETA, "ping", status=Status.pending)
    ledger.record_outcome(home, key, Outcome.unknown())
    ledger.record_outcome(home, key, Outcome.answered("pong"))
    assert _shape(_page(home)) == [("out", "message", "ping", "answered", True), ("out", "reply", "pong", "answered", False)]


def test_silence_answers_without_an_empty_bubble(home):
    key = _key(3, Direction.inbound)
    ledger.record_message(home, key, BETA, "fyi", status=Status.delivered)
    ledger.record_outcome(home, key, Outcome.answered(""))
    assert _shape(_page(home)) == [("in:", "message", "fyi", "answered", False)]


def test_an_outcome_for_an_exchange_this_profile_never_sent_is_dropped(home):
    assert ledger.record_outcome(home, _key(4), Outcome.answered("stray")) is False
    assert ledger.read_page(home, BETA.thread_id, PageRequest(limit=10)) is None


def test_failure_reasons_are_closed_codes(home):
    key = _key(5)
    ledger.record_message(home, key, BETA, "x", status=Status.pending)
    ledger.record_outcome(home, key, Outcome.failed("Traceback: /Users/secret/path"))
    [message] = _page(home).messages
    assert (message.status, message.reason) == (Status.failed, "unknown")


def test_a_reply_never_sorts_before_its_message_even_with_a_skewed_clock(home):
    key = _key(6)
    ledger.record_message(home, key, BETA, "first", status=Status.delivered, occurred_at=1000.0)
    ledger.record_outcome(home, key, Outcome.answered("second"), occurred_at=10.0)
    assert [m.body for m in _page(home).messages] == ["first", "second"]


def test_both_directions_and_many_days_are_one_thread(home):
    ledger.record_message(home, _key(7), BETA, "day one", status=Status.delivered, occurred_at=1_000.0)
    ledger.record_message(home, _key(8, Direction.inbound), identity.inbound(
        {"id": "bot:beta", "name": "beta", "is_bot": True}, None, []), "day three", status=Status.delivered,
        occurred_at=200_000.0)
    assert [m.body for m in _page(home).messages] == ["day one", "day three"]
    [summary] = ledger.thread_summaries(home)
    assert (summary.thread_id, summary.message_count, summary.last.body) == (BETA.thread_id, 2, "day three")


def test_pages_focus_and_since_rev(home):
    for n in range(1, 11):
        ledger.record_message(home, _key(100 + n), BETA, f"m{n}", status=Status.pending, occurred_at=float(n))
    newest = _page(home, limit=4)
    assert [m.body for m in newest.messages] == ["m7", "m8", "m9", "m10"] and newest.has_older and not newest.has_newer
    older = _page(home, limit=4, before_seq=newest.messages[0].seq)
    assert [m.body for m in older.messages] == ["m3", "m4", "m5", "m6"]
    focused = _page(home, limit=4, focus_exchange_id=_key(105).exchange_id)
    assert [m.body for m in focused.messages] == ["m3", "m4", "m5", "m6"]
    assert focused.focus_seq == focused.messages[2].seq and focused.has_older and focused.has_newer
    rev = newest.rev
    ledger.record_outcome(home, _key(101), Outcome.answered("late"))
    changed = _page(home, since_rev=rev)
    assert [(m.body, m.status.value) for m in changed.messages] == [("m1", "answered"), ("late", "answered")]


def test_peer_threads_rekey_once_the_peer_names_its_origin(home):
    provisional = identity.outbound_peer("spark", "researcher", None)
    ledger.record_message(home, _key(20), provisional, "hello peer", status=Status.pending)
    ledger.record_outcome(home, _key(20), Outcome.answered("hi"), learned_origin="spark-host")
    learned = identity.outbound_peer("spark", "researcher", ledger.peer_origin(home, "spark"))
    inbound = identity.inbound({"id": "bot:spark-host/researcher", "name": "researcher", "is_bot": True}, None, [])
    assert learned.key == inbound.key == "remote:spark-host/researcher"
    assert ledger.read_page(home, provisional.thread_id, PageRequest(limit=5)) is None
    assert [m.body for m in ledger.read_page(home, learned.thread_id, PageRequest(limit=5)).messages] == ["hello peer", "hi"]


def test_pruning_removes_whole_exchanges(home, monkeypatch):
    monkeypatch.setattr(ledger, "MAX_EVENTS", 6)
    monkeypatch.setattr(ledger, "PRUNE_EVERY_SEQ", 1)
    for n in range(1, 7):
        ledger.record_message(home, _key(200 + n), BETA, f"m{n}", status=Status.pending, occurred_at=float(n))
        ledger.record_outcome(home, _key(200 + n), Outcome.answered(f"r{n}"))
    conn = sqlite3.connect(home / "state.db")
    try:
        parts = conn.execute("SELECT exchange_id, COUNT(*) FROM bot_thread_events GROUP BY exchange_id").fetchall()
    finally:
        conn.close()
    assert parts and all(count == 2 for _exchange, count in parts) and len(parts) <= 4


def test_an_unusable_store_never_raises_into_a_delivery(tmp_path, caplog):
    (tmp_path / "state.db").mkdir()
    assert ledger.record_message(tmp_path, _key(30), BETA, "x", status=Status.pending) is False
    assert ledger.record_outcome(tmp_path, _key(30), Outcome.answered("y")) is False
    assert "bot thread ledger" in caplog.text


def test_ledger_tables_are_additive_on_an_existing_store_and_keep_its_data(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("keep", source="cli")
    db.close()
    conn = sqlite3.connect(tmp_path / "state.db")
    conn.executescript("DROP TABLE bot_thread_events; DROP TABLE bot_thread_peer_origins;")
    conn.close()
    SessionDB(db_path=tmp_path / "state.db").close()
    ledger.record_message(tmp_path, _key(40), BETA, "x", status=Status.pending)
    conn = sqlite3.connect(tmp_path / "state.db")
    try:
        assert conn.execute("SELECT id FROM sessions").fetchall() == [("keep",)]
        assert conn.execute("SELECT COUNT(*) FROM bot_thread_events").fetchone() == (1,)
        assert conn.execute("SELECT MAX(version) FROM schema_version").fetchone()[0] == SCHEMA_VERSION
    finally:
        conn.close()
    SessionDB(db_path=tmp_path / "state.db").close()
    assert ledger.thread_summaries(tmp_path)[0].last.body == "x"
