"""The commitment ledger in a real per-profile state.db: the state machine as data, idempotent and
compare-and-set transitions, computed overdue and stuck facts, and an append-only event log."""

import dataclasses
import itertools
import sqlite3
import threading

import pytest

from gateway import commitments as cm
from gateway.commitments import Actor, Details, Refused, RefusalCode, Route, State
from hermes_state import SessionDB

NOW = 1_800_000_000.0
ROUTE = Route(platform="telegram", chat_id="42", thread_id=None, chat_type="dm", session_key="agent:main:telegram:dm:42",
              session_id="s1")
COMPLETE = Details(note="started", next_step="send the draft", blocker_what="waiting on the API key",
                   blocker_who="owner", evidence="PR #12 merged", reason="owner changed plans")
_keys = itertools.count()


@pytest.fixture
def home(tmp_path):
    SessionDB(db_path=tmp_path / "state.db").close()
    return tmp_path


def key() -> str:
    return f"k{next(_keys)}"


def promise(home, *, due_at=None, owner_requested=True, now=NOW, event_key=None):
    return cm.promise(home, event_key=event_key or key(), profile="main", text="Ship the report", owner_requested=owner_requested,
                      due_at=due_at, route=ROUTE, now=now)


def move(home, commitment_id, to, *, rev, details=COMPLETE, actor=Actor.BOT, now=NOW, event_key=None):
    return cm.transition(home, commitment_id, event_key=event_key or key(), expected_rev=rev, to=to, details=details,
                         actor=actor, now=now)


def reach(home, state: State):
    """A fresh commitment walked from open to ``state`` along legal edges."""
    created = promise(home)
    path = {State.OPEN: [], State.IN_PROGRESS: [State.IN_PROGRESS], State.BLOCKED: [State.BLOCKED],
            State.DONE: [State.DONE], State.ABANDONED: [State.ABANDONED]}[state]
    rev = created.rev
    for step in path:
        rev = move(home, created.commitment_id, step, rev=rev).rev
    return created.commitment_id, rev


ALL_PAIRS = [(a, b) for a in State for b in State]


def test_the_machine_has_five_states_and_two_are_terminal():
    assert {s.value for s in State} == {"open", "in_progress", "blocked", "done", "abandoned"}
    assert cm.TERMINAL_STATES == frozenset({State.DONE, State.ABANDONED})
    assert not any(src in cm.TERMINAL_STATES for src, _ in cm.EDGES)
    assert not any(dst is State.OPEN for _, dst in cm.EDGES)


@pytest.mark.parametrize("src,dst", sorted(cm.EDGES, key=lambda e: (e[0].value, e[1].value)))
def test_every_edge_is_accepted_and_logged(home, src, dst):
    cid, rev = reach(home, src)
    result = move(home, cid, dst, rev=rev)
    assert (result.from_state, result.to_state, result.rev, result.replayed) == (src, dst, rev + 1, False)
    row = cm.get(home, cid)
    assert (row.state, row.rev) == (dst, rev + 1)
    assert cm.events(home, cid)[-1].to_state is dst


@pytest.mark.parametrize("src,dst", [p for p in ALL_PAIRS if p not in cm.EDGES])
def test_every_other_edge_is_refused_without_a_trace(home, src, dst):
    cid, rev = reach(home, src)
    before = cm.events(home, cid)
    with pytest.raises(Refused) as refused:
        move(home, cid, dst, rev=rev)
    assert refused.value.code is RefusalCode.ILLEGAL_EDGE
    assert cm.get(home, cid).rev == rev
    assert cm.events(home, cid) == before


@pytest.mark.parametrize("missing", ["blocker_what", "blocker_who", "next_step"])
def test_a_blocker_needs_what_who_and_a_prepared_next_step(home, missing):
    cid, rev = reach(home, State.IN_PROGRESS)
    details = dataclasses.replace(COMPLETE, **{missing: "  "})
    with pytest.raises(Refused) as refused:
        move(home, cid, State.BLOCKED, rev=rev, details=details)
    assert refused.value.code is RefusalCode.MISSING_FIELDS
    assert missing in refused.value.message
    assert cm.get(home, cid).state is State.IN_PROGRESS


def test_done_needs_evidence(home):
    cid, rev = reach(home, State.IN_PROGRESS)
    with pytest.raises(Refused) as refused:
        move(home, cid, State.DONE, rev=rev, details=Details(note="finished"))
    assert refused.value.code is RefusalCode.MISSING_FIELDS
    assert "evidence" in refused.value.message


def test_abandoned_needs_a_reason_and_records_who(home):
    cid, rev = reach(home, State.OPEN)
    with pytest.raises(Refused) as refused:
        move(home, cid, State.ABANDONED, rev=rev, details=Details())
    assert refused.value.code is RefusalCode.MISSING_FIELDS
    move(home, cid, State.ABANDONED, rev=rev, details=Details(reason="owner cancelled"), actor=Actor.OWNER)
    row = cm.get(home, cid)
    assert (row.state, row.reason, row.abandoned_by) == (State.ABANDONED, "owner cancelled", Actor.OWNER)
    assert cm.events(home, cid)[-1].actor is Actor.OWNER


def test_the_row_carries_the_promise_route_and_blocker(home):
    created = promise(home, due_at=NOW + 60, owner_requested=False)
    move(home, created.commitment_id, State.BLOCKED, rev=created.rev)
    row = cm.get(home, created.commitment_id)
    assert (row.profile, row.promise, row.owner_requested, row.due_at, row.route) == (
        "main", "Ship the report", False, NOW + 60, ROUTE)
    assert (row.blocker_what, row.blocker_who, row.next_step) == (
        "waiting on the API key", "owner", "send the draft")
    assert (row.created_at, row.checks_since_progress) == (NOW, 0)


def test_a_repeated_event_key_returns_the_earlier_result(home):
    created = promise(home, event_key="promise-1")
    again = promise(home, event_key="promise-1", now=NOW + 5)
    assert (again.commitment_id, again.rev, again.replayed) == (created.commitment_id, created.rev, True)
    assert len(cm.list_active(home)) == 1
    first = move(home, created.commitment_id, State.IN_PROGRESS, rev=1, event_key="start-1")
    replay = move(home, created.commitment_id, State.IN_PROGRESS, rev=1, event_key="start-1", now=NOW + 9)
    assert (replay.from_state, replay.to_state, replay.rev, replay.replayed) == (
        first.from_state, first.to_state, first.rev, True)
    assert cm.get(home, created.commitment_id).rev == 2
    assert [e.event_key for e in cm.events(home, created.commitment_id)] == ["promise-1", "start-1"]


def test_an_event_key_cannot_move_another_commitment(home):
    a = promise(home)
    b = promise(home)
    move(home, a.commitment_id, State.IN_PROGRESS, rev=1, event_key="shared")
    with pytest.raises(Refused) as refused:
        move(home, b.commitment_id, State.IN_PROGRESS, rev=1, event_key="shared")
    assert refused.value.code is RefusalCode.KEY_REUSED
    assert cm.get(home, b.commitment_id).state is State.OPEN


def test_a_stale_expected_rev_is_refused(home):
    cid, rev = reach(home, State.IN_PROGRESS)
    with pytest.raises(Refused) as refused:
        move(home, cid, State.BLOCKED, rev=rev - 1)
    assert refused.value.code is RefusalCode.REV_CONFLICT
    assert cm.get(home, cid).state is State.IN_PROGRESS


def test_an_unknown_commitment_is_refused(home):
    with pytest.raises(Refused) as refused:
        move(home, "cm_missing", State.IN_PROGRESS, rev=1)
    assert refused.value.code is RefusalCode.UNKNOWN


def test_an_empty_promise_is_refused(home):
    with pytest.raises(Refused) as refused:
        cm.promise(home, event_key=key(), profile="main", text="   ", owner_requested=True, due_at=None, route=ROUTE,
                   now=NOW)
    assert refused.value.code is RefusalCode.INVALID


def test_overdue_is_computed_from_due_at_and_never_stored(home):
    cid = promise(home, due_at=NOW + 100).commitment_id
    row = cm.get(home, cid)
    assert not row.overdue(NOW + 100)
    assert row.overdue(NOW + 101)
    assert row.state is State.OPEN
    assert not cm.get(home, promise(home).commitment_id).overdue(NOW + 10**9)
    move(home, cid, State.DONE, rev=1)
    assert not cm.get(home, cid).overdue(NOW + 101)


@pytest.mark.parametrize("state", [State.IN_PROGRESS, State.BLOCKED])
def test_stuck_is_computed_from_the_last_event(home, state):
    cid, _ = reach(home, state)
    row = cm.get(home, cid)
    assert not row.stuck(NOW + cm.STUCK_AFTER_SECONDS - 1)
    assert row.stuck(NOW + cm.STUCK_AFTER_SECONDS)
    assert row.state is state


def test_an_open_or_closed_commitment_is_never_stuck_by_age(home):
    open_id, _ = reach(home, State.OPEN)
    done_id, _ = reach(home, State.DONE)
    later = NOW + cm.STUCK_AFTER_SECONDS * 10
    assert not cm.get(home, open_id).stuck(later)
    assert not cm.get(home, done_id).stuck(later)


def test_checks_without_progress_make_a_commitment_stuck_until_it_moves(home):
    cid, rev = reach(home, State.OPEN)
    counts = [cm.record_check(home, cid) for _ in range(cm.STUCK_AFTER_CHECKS)]
    assert counts == list(range(1, cm.STUCK_AFTER_CHECKS + 1))
    row = cm.get(home, cid)
    assert row.stuck(NOW)
    assert row.rev == rev
    assert len(cm.events(home, cid)) == 1
    move(home, cid, State.IN_PROGRESS, rev=rev)
    assert cm.get(home, cid).checks_since_progress == 0
    assert not cm.get(home, cid).stuck(NOW)


def test_a_check_on_a_closed_commitment_changes_nothing(home):
    cid, _ = reach(home, State.DONE)
    assert cm.record_check(home, cid) is None
    assert cm.get(home, cid).checks_since_progress == 0


def test_list_active_holds_only_open_work(home):
    open_id, _ = reach(home, State.OPEN)
    blocked_id, _ = reach(home, State.BLOCKED)
    reach(home, State.DONE)
    reach(home, State.ABANDONED)
    assert {row.id for row in cm.list_active(home)} == {open_id, blocked_id}


def test_the_event_log_is_append_only(home):
    cid, _ = reach(home, State.IN_PROGRESS)
    with sqlite3.connect(home / "state.db") as conn:
        for statement in ("UPDATE commitment_events SET actor = 'owner'", "DELETE FROM commitment_events"):
            with pytest.raises(sqlite3.DatabaseError, match="append-only"):
                conn.execute(statement)
    assert [(e.from_state, e.to_state, e.rev) for e in cm.events(home, cid)] == [
        (None, State.OPEN, 1), (State.OPEN, State.IN_PROGRESS, 2)]


def test_two_threads_moving_one_commitment_leave_one_winner(home):
    cid, rev = reach(home, State.IN_PROGRESS)
    barrier = threading.Barrier(2)
    outcomes = []

    def race(to):
        barrier.wait()
        try:
            outcomes.append(move(home, cid, to, rev=rev))
        except Refused as refused:
            outcomes.append(refused.code)

    threads = [threading.Thread(target=race, args=(to,)) for to in (State.DONE, State.BLOCKED)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=30)
    winners = [o for o in outcomes if not isinstance(o, RefusalCode)]
    assert len(winners) == 1
    assert [o for o in outcomes if isinstance(o, RefusalCode)] == [RefusalCode.REV_CONFLICT]
    log = cm.events(home, cid)
    assert [e.rev for e in log] == [1, 2, 3]
    assert log[-1].to_state is winners[0].to_state is cm.get(home, cid).state


def test_an_existing_state_db_gains_the_ledger_and_keeps_its_data(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s-old", "telegram")
    db.close()
    created = promise(tmp_path)
    reopened = SessionDB(db_path=tmp_path / "state.db")
    try:
        assert reopened.get_session("s-old") is not None
    finally:
        reopened.close()
    assert cm.get(tmp_path, created.commitment_id).state is State.OPEN
    assert promise(tmp_path).rev == 1
