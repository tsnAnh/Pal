"""Promises that outlive a turn reach the commitment ledger from the turn's structured tool calls: which calls count,
who the promise is attributed to, one commitment per subject however often a turn is replayed, settlement on the
evidence the runtime itself produces, a ledger written before the `auto` actor existed, and a gateway start that
puts the wake job on every served profile."""

import json
import logging
import sqlite3
import time
from types import SimpleNamespace

import pytest

from agent import turn_finalizer
from gateway import commitments as cm
from gateway import commitments_capture as capture
from gateway import commitments_wake as wake
from gateway.commitments import Actor, State
from gateway.session_context import clear_session_vars, set_session_vars
from tests.gateway.reach_harness import make_home
from tools import commitment_tool

NOW = time.time()
GOAL = "migrate the billing tables and tell nobody"


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = make_home(tmp_path, "profile")
    monkeypatch.setenv("HERMES_HOME", str(path))
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", session_id="s1", profile="main")
    yield path
    clear_session_vars(tokens)


def call(call_id, name, **arguments):
    return {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}


def turn(*pairs, user="please do it"):
    messages = [{"role": "user", "content": user}, {"role": "assistant", "content": "", "tool_calls": [c for c, _ in pairs]}]
    messages += [{"role": "tool", "tool_call_id": c["id"], "content": json.dumps(result)} for c, result in pairs]
    return messages


LAUNCH = (call("c1", "delegate_task", background=True, goal=GOAL),
          {"status": "dispatched", "mode": "background", "delegation_id": "d1", "goals": [GOAL]})
SCHEDULE = (call("c2", "cronjob_manage", action="create", prompt=GOAL, schedule="every 2h"),
            {"success": True, "job_id": "j1", "name": "digest"})
MESSAGE = (call("c3", "message_agent", target="researcher", message=GOAL),
           {"status": "queued", "delivery_id": "x", "to": "@researcher", "process_id": "proc_1"})


def agent(**fields):
    return SimpleNamespace(**{"platform": "telegram", "_synthetic_turn": False, "_turn_author": None, **fields})


def run_turn(messages, **fields):
    turn_finalizer._capture_promises(agent(**fields), messages, logging.getLogger("test"))
    capture._executor.submit(lambda: None).result(timeout=10)


def open_promises(home):
    return {c.promise: c for c in cm.list_active(home)}


def test_a_turn_that_launches_schedules_and_messages_leaves_three_open_promises_the_owner_asked_for(home):
    run_turn(turn(LAUNCH, SCHEDULE, MESSAGE))
    promises = open_promises(home)
    assert set(promises) == {"Delegated task d1", "Scheduled job digest", "Message to @researcher"}
    assert all(c.owner_requested and c.state is State.OPEN and c.route.chat_id == "42" and c.profile == "main"
               for c in promises.values())
    assert {e.actor for c in promises.values() for e in cm.events(home, c.id)} == {Actor.AUTO}


def test_replaying_a_turn_records_each_launch_once(home):
    run_turn(turn(LAUNCH))
    run_turn(turn(LAUNCH))
    assert list(open_promises(home)) == ["Delegated task d1"]


@pytest.mark.parametrize("fields, owner_requested", [
    ({}, True),
    ({"_synthetic_turn": True}, False),
    ({"_turn_author": {"id": "bot:other", "name": "other", "is_bot": True}}, False),
])
def test_only_a_turn_the_owner_typed_is_owner_requested(home, fields, owner_requested):
    run_turn(turn(SCHEDULE), **fields)
    assert [c.owner_requested for c in cm.list_active(home)] == [owner_requested]


@pytest.mark.parametrize("fields", [{"platform": "cron"}, {"platform": "webhook"}])
def test_an_autonomous_run_promises_nothing(home, fields):
    run_turn(turn(SCHEDULE), **fields)
    assert cm.list_active(home) == []


def test_calls_that_leave_nothing_running_are_not_promises(home):
    run_turn(turn(
        (call("a", "delegate_task", goal=GOAL), {"results": [{"status": "completed"}]}),
        (call("b", "cronjob_manage", action="list"), {"success": True, "jobs": []}),
        (call("c", "cronjob_manage", action="create", paused=True), {"success": True, "job_id": "j9", "name": "x"}),
        (call("d", "message_agent", target="r", message="fyi", expects_reply=False),
         {"status": "queued", "to": "@r", "process_id": "p9", "expects_reply": False}),
        (call("e", "message_agent", target="r", message="hi"), {"error": "no such teammate"}),
        (call("f", "terminal", command="faker-kit launch"), {"output": "started"})))
    assert cm.list_active(home) == []


def test_a_commitment_the_model_recorded_in_the_turn_is_left_alone(home):
    made = (call("m", "commitment", action="promise", text="Migrate billing", owner_requested=True), {"id": "cm_x"})
    run_turn(turn(made, LAUNCH))
    assert cm.list_active(home) == []


def test_a_failed_commitment_call_does_not_stand_the_capture_down(home):
    refused = (call("m", "commitment", action="promise", text=""), {"error": "text is required", "code": "invalid_input"})
    run_turn(turn(refused, LAUNCH))
    assert list(open_promises(home)) == ["Delegated task d1"]


def test_the_stored_promise_carries_no_message_text(home):
    run_turn(turn(LAUNCH, SCHEDULE, MESSAGE))
    conn = sqlite3.connect(home / "state.db")
    dump = json.dumps([conn.execute(f"SELECT * FROM {table}").fetchall() for table in ("commitments", "commitment_events")])
    assert "Delegated task d1" in dump
    assert "billing" not in dump and "nobody" not in dump


def test_a_ledger_error_never_fails_the_turn_and_is_logged(home, monkeypatch, caplog):
    monkeypatch.setattr(cm, "promise", lambda *a, **k: (_ for _ in ()).throw(sqlite3.OperationalError("locked")))
    with caplog.at_level(logging.WARNING):
        run_turn(turn(LAUNCH))
    assert "Promise capture failed (OperationalError)" in caplog.text


def test_a_planning_error_never_fails_the_turn_and_is_logged(home, monkeypatch, caplog):
    monkeypatch.setattr(capture, "plan", lambda *a, **k: 1 / 0)
    with caplog.at_level(logging.WARNING):
        turn_finalizer._capture_promises(agent(), turn(LAUNCH), logging.getLogger("test"))
    assert "Promise capture skipped (ZeroDivisionError)" in caplog.text


def settle_event(home, **event):
    capture.settle_from_event(event)
    return {c.promise: c.state for c in cm.list_for_follow_up(home, closed_since=0)}


def test_a_finished_delegation_closes_its_promise_with_the_runtime_as_actor(home):
    run_turn(turn(LAUNCH))
    assert settle_event(home, type="async_delegation", delegation_id="d1", results=[{"status": "completed"}]) == {
        "Delegated task d1": State.DONE}
    done = cm.list_for_follow_up(home, closed_since=0)[0]
    assert done.evidence == "The delegated task finished." and cm.events(home, done.id)[-1].actor is Actor.AUTO
    assert settle_event(home, type="async_delegation", delegation_id="d1", results=[{"status": "completed"}]) == {
        "Delegated task d1": State.DONE}


@pytest.mark.parametrize("event", [
    {"type": "async_delegation", "delegation_id": "d1", "results": [{"status": "failed", "error": "boom"}]},
    {"type": "async_delegation", "delegation_id": "d1", "task_failure_notice": True},
    {"type": "async_delegation", "delegation_id": "other", "results": [{"status": "completed"}]},
])
def test_a_failed_or_foreign_delegation_event_leaves_the_promise_open(home, event):
    run_turn(turn(LAUNCH))
    assert settle_event(home, **event) == {"Delegated task d1": State.OPEN}


def test_a_reply_closes_the_message_promise_but_an_empty_exit_does_not(home):
    run_turn(turn(MESSAGE))
    assert settle_event(home, type="completion", session_id="proc_1", exit_code=0, output="  ") == {
        "Message to @researcher": State.OPEN}
    assert settle_event(home, type="completion", session_id="proc_1", exit_code=1, output="no") == {
        "Message to @researcher": State.OPEN}
    assert settle_event(home, type="completion", session_id="proc_1", exit_code=0, output="done") == {
        "Message to @researcher": State.DONE}


def test_a_completion_in_a_profile_that_never_promised_does_not_create_a_ledger(home):
    assert not (home / "state.db").exists() or "commitments" not in [
        r[0] for r in sqlite3.connect(home / "state.db").execute("SELECT name FROM sqlite_master")]
    capture.settle_from_event({"type": "completion", "session_id": "p", "exit_code": 0, "output": "x"})
    assert "commitments" not in [r[0] for r in sqlite3.connect(home / "state.db").execute("SELECT name FROM sqlite_master")]


def test_a_scheduled_job_promise_closes_when_the_job_has_run(home):
    from cron.jobs import create_job, mark_job_run
    run_turn(turn(SCHEDULE))
    assert capture.settle_cron_runs(home, NOW) == 0
    job = create_job(prompt="p", schedule="every 2h", name="digest")
    run_turn(turn((call("c2", "cronjob_manage", action="create"), {"success": True, "job_id": job["id"], "name": "digest"})))
    assert capture.settle_cron_runs(home, NOW) == 0
    mark_job_run(job["id"], True)
    assert capture.settle_cron_runs(home, NOW) == 1
    states = {c.promise: c.state for c in cm.list_for_follow_up(home, closed_since=0)}
    assert states == {"Scheduled job digest": State.DONE}


def test_an_auto_promise_is_silent_while_open_and_reported_once_when_done(home):
    run_turn(turn(LAUNCH))
    assert wake.pending_reports(home, NOW + 3 * 24 * 3600) == []
    assert json.loads(wake.gate(home, NOW + 3 * 24 * 3600)) == {"wakeAgent": False}
    capture.settle_from_event({"type": "async_delegation", "delegation_id": "d1", "results": [{"status": "completed"}]})
    [report] = wake.pending_reports(home, time.time())
    assert report.kind is wake.ReportKind.DONE and report.offer().title == "Done: Delegated task d1"


def test_the_model_cannot_name_the_runtime_as_an_actor(home):
    assert "auto" not in commitment_tool.COMMITMENT_SCHEMA["parameters"]["properties"]["by"]["enum"]
    made = json.loads(commitment_tool.commitment_tool({"action": "promise", "text": "x", "owner_requested": True}))
    refused = json.loads(commitment_tool.commitment_tool(
        {"action": "close", "id": made["id"], "state": "abandoned", "by": "auto", "reason": "r"}))
    assert refused["code"] == "invalid_input"


LEGACY_DDL = """
CREATE TABLE commitments (
    id TEXT PRIMARY KEY, profile TEXT NOT NULL, promise TEXT NOT NULL,
    owner_requested INTEGER NOT NULL CHECK (owner_requested IN (0, 1)), due_at REAL,
    state TEXT NOT NULL CHECK (state IN ('open', 'in_progress', 'blocked', 'done', 'abandoned')),
    rev INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, route_json TEXT NOT NULL,
    next_step TEXT, blocker_what TEXT, blocker_who TEXT, evidence TEXT, reason TEXT,
    abandoned_by TEXT CHECK (abandoned_by IN ('bot', 'owner')), checks_since_progress INTEGER NOT NULL DEFAULT 0);
CREATE TABLE commitment_events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT NOT NULL UNIQUE, commitment_id TEXT NOT NULL,
    from_state TEXT, to_state TEXT NOT NULL, rev INTEGER NOT NULL,
    actor TEXT NOT NULL CHECK (actor IN ('bot', 'owner')), at REAL NOT NULL,
    detail_json TEXT NOT NULL DEFAULT '{}', UNIQUE (commitment_id, rev));
CREATE TRIGGER commitment_events_no_update BEFORE UPDATE ON commitment_events
BEGIN SELECT RAISE(ABORT, 'commitment_events is append-only'); END;
CREATE TRIGGER commitment_events_no_delete BEFORE DELETE ON commitment_events
BEGIN SELECT RAISE(ABORT, 'commitment_events is append-only'); END;
"""


def test_a_ledger_written_before_the_auto_actor_keeps_its_history_and_accepts_auto(home):
    conn = sqlite3.connect(home / "state.db")
    conn.executescript(LEGACY_DDL)
    conn.execute("INSERT INTO commitments VALUES ('cm_old', 'main', 'Old promise', 1, NULL, 'open', 1, 1, 1, "
                 "'{\"platform\":null,\"chat_id\":null,\"thread_id\":null,\"chat_type\":null,\"session_key\":null,"
                 "\"session_id\":null}', NULL, NULL, NULL, NULL, NULL, NULL, 0)")
    conn.execute("INSERT INTO commitment_events (event_key, commitment_id, from_state, to_state, rev, actor, at, "
                 "detail_json) VALUES ('k-old', 'cm_old', NULL, 'open', 1, 'bot', 1, '{\"promise\":\"Old promise\"}')")
    conn.commit()
    conn.close()
    run_turn(turn(LAUNCH))
    assert set(open_promises(home)) == {"Old promise", "Delegated task d1"}
    assert [e.actor for e in cm.events(home, "cm_old")] == [Actor.BOT]
    conn = cm._connect(home)
    try:
        with pytest.raises(sqlite3.DatabaseError, match="append-only"):
            conn.execute("DELETE FROM commitment_events")
    finally:
        conn.close()


@pytest.fixture
def two_profiles(tmp_path, monkeypatch):
    homes = [(name, make_home(tmp_path, name)) for name in ("chief", "fren")]
    monkeypatch.setenv("HERMES_HOME", str(homes[0][1]))
    return homes


def jobs_of(home):
    return [job for job in json.loads((home / "cron" / "jobs.json").read_text())["jobs"] if job.get("script") == wake.SCRIPT_NAME]


def test_gateway_start_puts_one_wake_job_on_every_profile_and_a_restart_adds_none(two_profiles, caplog):
    with caplog.at_level(logging.INFO, logger=wake.logger.name):
        first = wake.register_for_profiles(two_profiles)
        again = wake.register_for_profiles(two_profiles)
    assert set(first.values()) == {wake.Registration.REGISTERED} and set(again.values()) == {wake.Registration.PRESENT}
    for _name, path in two_profiles:
        assert len(jobs_of(path)) == 1 and (path / "scripts" / wake.SCRIPT_NAME).is_file()
    assert [r.getMessage() for r in caplog.records if "chief" in r.getMessage()] == [
        "Promise follow-through job for profile chief: registered",
        "Promise follow-through job for profile chief: already present"]


def test_one_profile_failing_to_register_is_logged_and_does_not_stop_the_others(two_profiles, monkeypatch, caplog):
    real = wake.register_job
    monkeypatch.setattr(wake, "register_job", lambda: (_ for _ in ()).throw(OSError("disk")) if "chief" in str(
        wake.get_hermes_home()) else real())
    with caplog.at_level(logging.INFO, logger=wake.logger.name):
        outcomes = wake.register_for_profiles(two_profiles)
    assert outcomes == {"chief": wake.Registration.FAILED, "fren": wake.Registration.REGISTERED}
    assert any(r.levelno == logging.WARNING and "chief" in r.getMessage() for r in caplog.records)
