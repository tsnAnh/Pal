"""Standing duties in the commitment ledger: the kind column and its migration, the mandate lifecycle as data, the
owner-only acceptance, and promise queries that never see a mandate."""

import itertools
import sqlite3

import pytest

from gateway import commitments as cm
from gateway.autonomy import ActionClass
from gateway.commitments import Actor, Kind, MandateState, Refused, RefusalCode, Route, Standing, State, Trigger
from hermes_state import SessionDB

NOW = 1_800_000_000.0
ROUTE = Route(platform="telegram", chat_id="42", thread_id=None, chat_type="dm", session_key="k", session_id="s1")
_keys = itertools.count()

PREVIOUS_SCHEMA = """
CREATE TABLE commitments (
    id TEXT PRIMARY KEY, profile TEXT NOT NULL, promise TEXT NOT NULL,
    owner_requested INTEGER NOT NULL CHECK (owner_requested IN (0, 1)), due_at REAL,
    state TEXT NOT NULL CHECK (state IN ('open', 'in_progress', 'blocked', 'done', 'abandoned')),
    rev INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, route_json TEXT NOT NULL,
    next_step TEXT, blocker_what TEXT, blocker_who TEXT, evidence TEXT, reason TEXT,
    abandoned_by TEXT CHECK (abandoned_by IN ('bot', 'owner', 'auto')),
    checks_since_progress INTEGER NOT NULL DEFAULT 0);
CREATE TABLE commitment_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT NOT NULL UNIQUE, commitment_id TEXT NOT NULL,
    from_state TEXT, to_state TEXT NOT NULL, rev INTEGER NOT NULL,
    actor TEXT NOT NULL CHECK (actor IN ('bot', 'owner', 'auto')), at REAL NOT NULL,
    detail_json TEXT NOT NULL DEFAULT '{}', UNIQUE (commitment_id, rev));
INSERT INTO commitments (id, profile, promise, owner_requested, due_at, state, rev, created_at, updated_at, route_json)
VALUES ('cm_old', 'main', 'Send the report', 1, NULL, 'open', 1, 1.0, 1.0, '{}');
INSERT INTO commitment_events (event_key, commitment_id, from_state, to_state, rev, actor, at)
VALUES ('old-key', 'cm_old', NULL, 'open', 1, 'bot', 1.0);
"""


@pytest.fixture
def home(tmp_path):
    SessionDB(db_path=tmp_path / "state.db").close()
    return tmp_path


def key() -> str:
    return f"m{next(_keys)}"


def propose(home, *, trigger=Trigger.PR_MERGED, action_class=ActionClass.RUN_TOOLS, text="Build the app on merge",
            done_when="the app is installed", event_key=None, now=NOW):
    return cm.propose_mandate(home, event_key=event_key or key(), profile="main", text=text, trigger=trigger,
                              action_class=action_class, done_when=done_when, owner_requested=False, route=ROUTE,
                              now=now)


def promise(home):
    return cm.promise(home, event_key=key(), profile="main", text="Ship the report", owner_requested=True,
                      due_at=None, route=ROUTE, now=NOW)


def accepted(home, **kw):
    made = propose(home, **kw)
    return made.commitment_id, cm.accept(home, made.commitment_id, event_key=key(), expected_rev=made.rev,
                                         actor=Actor.OWNER, now=NOW).rev


def test_a_ledger_from_the_previous_schema_keeps_its_promises_and_gains_the_kind(tmp_path):
    with sqlite3.connect(tmp_path / "state.db") as conn:
        conn.executescript(PREVIOUS_SCHEMA)
    [old] = cm.list_active(tmp_path)
    assert (old.id, old.kind, old.state, old.hits, old.dismissed) == ("cm_old", Kind.PROMISE, State.OPEN, 0, 0)
    assert [event.event_key for event in cm.events(tmp_path, "cm_old")] == ["old-key"]
    made = propose(tmp_path)
    assert cm.get(tmp_path, made.commitment_id).kind is Kind.PROPOSAL
    assert [c.id for c in cm.list_active(tmp_path)] == ["cm_old"]


def test_reading_a_ledger_from_the_previous_schema_read_only_needs_no_migration(tmp_path):
    with sqlite3.connect(tmp_path / "state.db") as conn:
        conn.executescript(PREVIOUS_SCHEMA)
    with sqlite3.connect(f"{(tmp_path / 'state.db').as_uri()}?mode=ro", uri=True) as conn:
        [outcome] = cm.outcomes(conn, as_of=NOW)
    assert outcome.commitment_id == "cm_old"
    assert cm.find_by_event_key(tmp_path, "old-key").kind is Kind.PROMISE


def test_a_proposal_starts_unaccepted_and_is_logged(home):
    made = propose(home)
    row = cm.get(home, made.commitment_id)
    assert (row.kind, row.mandate_state, row.trigger, row.action_class) == (
        Kind.PROPOSAL, None, Trigger.PR_MERGED, ActionClass.RUN_TOOLS)
    assert (row.promise, row.done_when, row.hits, row.dismissed, row.last_fired) == (
        "Build the app on merge", "the app is installed", 0, 0, None)
    assert row.standing is Standing.PROPOSED
    [event] = cm.events(home, made.commitment_id)
    assert (event.from_state, event.to_state, event.rev, event.actor) == (None, State.OPEN, 1, Actor.BOT)
    assert event.detail["verb"] == "propose"


def test_the_owner_accepts_a_proposal_into_an_active_mandate(home):
    cid, rev = accepted(home)
    row = cm.get(home, cid)
    assert (row.kind, row.mandate_state, row.standing, row.rev, rev) == (Kind.MANDATE, MandateState.ACTIVE,
                                                                        Standing.ACTIVE, 2, 2)
    assert [e.detail["verb"] for e in cm.events(home, cid)] == ["propose", "accept"]


@pytest.mark.parametrize("actor", [Actor.BOT, Actor.AUTO])
def test_only_the_owner_accepts(home, actor):
    made = propose(home)
    with pytest.raises(Refused) as refused:
        cm.accept(home, made.commitment_id, event_key=key(), expected_rev=made.rev, actor=actor, now=NOW)
    assert refused.value.code is RefusalCode.OWNER_ONLY
    assert cm.get(home, made.commitment_id).kind is Kind.PROPOSAL


def test_accepting_twice_with_one_event_key_is_one_acceptance(home):
    made = propose(home)
    once = cm.accept(home, made.commitment_id, event_key="tap-1", expected_rev=made.rev, actor=Actor.OWNER, now=NOW)
    again = cm.accept(home, made.commitment_id, event_key="tap-1", expected_rev=made.rev, actor=Actor.OWNER, now=NOW)
    assert (once.replayed, again.replayed, again.rev) == (False, True, once.rev)
    assert len(cm.events(home, made.commitment_id)) == 2


def test_accepting_an_active_mandate_again_under_a_new_key_is_refused(home):
    cid, rev = accepted(home)
    with pytest.raises(Refused) as refused:
        cm.accept(home, cid, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW)
    assert refused.value.code is RefusalCode.ILLEGAL_EDGE


def test_a_stale_revision_is_refused(home):
    made = propose(home)
    with pytest.raises(Refused) as refused:
        cm.accept(home, made.commitment_id, event_key=key(), expected_rev=7, actor=Actor.OWNER, now=NOW)
    assert refused.value.code is RefusalCode.REV_CONFLICT


def test_pause_and_resume_flip_the_mandate_state(home):
    cid, rev = accepted(home)
    paused = cm.pause(home, cid, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW)
    assert cm.get(home, cid).standing is Standing.PAUSED
    resumed = cm.resume(home, cid, event_key=key(), expected_rev=paused.rev, actor=Actor.OWNER, now=NOW)
    assert cm.get(home, cid).standing is Standing.ACTIVE
    assert [e.detail["verb"] for e in cm.events(home, cid)] == ["propose", "accept", "pause", "resume"]
    assert resumed.rev == 4


@pytest.mark.parametrize("verb", ["pause", "resume"])
def test_a_proposal_can_be_neither_paused_nor_resumed(home, verb):
    made = propose(home)
    with pytest.raises(Refused) as refused:
        getattr(cm, verb)(home, made.commitment_id, event_key=key(), expected_rev=made.rev, actor=Actor.OWNER,
                          now=NOW)
    assert refused.value.code is RefusalCode.ILLEGAL_EDGE


def test_pausing_a_paused_mandate_and_resuming_an_active_one_are_refused(home):
    cid, rev = accepted(home)
    with pytest.raises(Refused):
        cm.resume(home, cid, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW)
    paused = cm.pause(home, cid, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW)
    with pytest.raises(Refused):
        cm.pause(home, cid, event_key=key(), expected_rev=paused.rev, actor=Actor.OWNER, now=NOW)


@pytest.mark.parametrize("path", ["proposal", "active", "paused"])
def test_dismiss_counts_keeps_the_row_and_ends_the_duty(home, path):
    made = propose(home)
    rev = made.rev
    if path != "proposal":
        rev = cm.accept(home, made.commitment_id, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW).rev
    if path == "paused":
        rev = cm.pause(home, made.commitment_id, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW).rev
    cm.dismiss(home, made.commitment_id, event_key=key(), expected_rev=rev, actor=Actor.OWNER, now=NOW,
               reason="not useful")
    row = cm.get(home, made.commitment_id)
    assert (row.dismissed, row.standing, row.state, row.abandoned_by, row.reason) == (
        1, Standing.DISMISSED, State.ABANDONED, Actor.OWNER, "not useful")
    assert cm.events(home, made.commitment_id)[-1].detail == {"verb": "dismiss", "reason": "not useful"}
    assert cm.list_mandates(home) == []
    assert [c.id for c in cm.list_mandates(home, include_dismissed=True)] == [made.commitment_id]


def test_a_dismissed_duty_cannot_move_again(home):
    made = propose(home)
    done = cm.dismiss(home, made.commitment_id, event_key=key(), expected_rev=made.rev, actor=Actor.OWNER, now=NOW)
    for verb in ("accept", "pause", "resume", "dismiss"):
        with pytest.raises(Refused) as refused:
            getattr(cm, verb)(home, made.commitment_id, event_key=key(), expected_rev=done.rev, actor=Actor.OWNER,
                              now=NOW)
        assert refused.value.code is RefusalCode.ILLEGAL_EDGE
    assert cm.get(home, made.commitment_id).dismissed == 1


def test_an_unknown_trigger_or_action_class_is_refused(home):
    for bad in ({"trigger": "sunrise"}, {"action_class": "launch_missiles"}, {"trigger": None}, {"action_class": ""}):
        with pytest.raises(Refused) as refused:
            propose(home, **bad)
        assert refused.value.code is RefusalCode.INVALID
    assert cm.list_mandates(home) == []


def test_the_raw_enum_values_are_accepted_and_every_member_round_trips(home):
    for trigger in Trigger:
        for action_class in ActionClass:
            made = propose(home, trigger=trigger.value, action_class=action_class.value)
            row = cm.get(home, made.commitment_id)
            assert (row.trigger, row.action_class) == (trigger, action_class)


@pytest.mark.parametrize("missing", ["text", "done_when"])
def test_a_proposal_needs_text_and_done_when(home, missing):
    with pytest.raises(Refused) as refused:
        propose(home, **{missing: "  "})
    assert refused.value.code is RefusalCode.INVALID


def test_the_same_event_key_proposes_once(home):
    first = propose(home, event_key="p-1")
    second = propose(home, event_key="p-1")
    assert (first.commitment_id, second.replayed) == (second.commitment_id, True)
    assert len(cm.list_mandates(home)) == 1


def test_an_event_key_that_moved_a_promise_cannot_propose(home):
    created = promise(home)
    cm.transition(home, created.commitment_id, event_key="moved", expected_rev=1, to=State.DONE,
                  details=cm.Details(evidence="e"), actor=Actor.BOT, now=NOW)
    with pytest.raises(Refused) as refused:
        propose(home, event_key="moved")
    assert refused.value.code is RefusalCode.KEY_REUSED


def test_a_promise_and_a_mandate_never_take_each_others_moves(home):
    made = propose(home)
    kept = promise(home)
    with pytest.raises(Refused) as refused:
        cm.transition(home, made.commitment_id, event_key=key(), expected_rev=made.rev, to=State.DONE,
                      details=cm.Details(evidence="e"), actor=Actor.BOT, now=NOW)
    assert refused.value.code is RefusalCode.ILLEGAL_EDGE
    with pytest.raises(Refused) as refused:
        cm.accept(home, kept.commitment_id, event_key=key(), expected_rev=kept.rev, actor=Actor.OWNER, now=NOW)
    assert refused.value.code is RefusalCode.ILLEGAL_EDGE
    assert cm.record_check(home, made.commitment_id) is None


def test_promise_queries_return_promises_only(home):
    kept = promise(home)
    cid, _ = accepted(home)
    propose(home)
    assert [c.id for c in cm.list_active(home)] == [kept.commitment_id]
    assert [c.id for c in cm.list_for_follow_up(home, closed_since=0)] == [kept.commitment_id]
    assert cm.open_with_subject(home, "") == []
    assert {c.id for c in cm.list_active(home, kind=Kind.MANDATE)} == {cid}
    assert len(cm.list_mandates(home)) == 2
    assert [o.commitment_id for o in _outcomes(home)] == [kept.commitment_id]


def test_a_dismissed_mandate_is_not_a_dropped_promise_in_the_outcomes(home):
    made = propose(home)
    cm.dismiss(home, made.commitment_id, event_key=key(), expected_rev=made.rev, actor=Actor.OWNER, now=NOW)
    assert _outcomes(home) == []


def test_overdue_and_stuck_are_facts_of_promises_only(home):
    cid, _ = accepted(home)
    row = cm.get(home, cid)
    later = NOW + 10 * 24 * 3600
    assert (row.overdue(later), row.stuck(later)) == (False, False)


def test_the_primary_guard_names_the_refusal(home, monkeypatch):
    monkeypatch.setattr("hermes_cli.primary_profile.primary_profile_name", lambda: "main")
    cm.require_primary("main")
    with pytest.raises(Refused) as refused:
        cm.require_primary("sage")
    assert refused.value.code is RefusalCode.NOT_PRIMARY


def _outcomes(home):
    conn = sqlite3.connect(home / "state.db")
    try:
        return cm.outcomes(conn, as_of=NOW + 1)
    finally:
        conn.close()
