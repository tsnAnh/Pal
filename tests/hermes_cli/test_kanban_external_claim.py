"""Coordinator-owned (external) boards: claim, heartbeat, run fence and reclaim."""
from __future__ import annotations

import json
import subprocess
import threading
import time

import pytest

from hermes_cli import kanban as kanban_cli
from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_connect as kbc
from hermes_cli import kanban_db_dispatch as kbd
from hermes_cli.kanban_external_claim import (
    ExternalClaimError, ExternalRunFenceError, claim_external, heartbeat_external,
)
from tests.hermes_cli.kanban_outcome_support import BOARD, PROFILE, add, claim, event_kinds, governed

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support"]

CONTRACT = {"kind": "other", "name": "report", "required_fields": ["url"]}


@pytest.fixture
def no_spawn(monkeypatch):
    calls = []
    monkeypatch.setattr(kbd, "_default_spawn", lambda *a, **k: calls.append("spawn"))

    def popen(*a, **k):
        calls.append("popen")
        raise AssertionError("no worker process may start on an external board")

    monkeypatch.setattr(subprocess, "Popen", popen)
    return calls


def test_claim_heartbeat_evidence_complete_with_zero_spawns(conn, no_spawn, hooks):
    task_id = governed(conn, CONTRACT)
    result = kbd.dispatch_once(conn, spawn_fn=lambda *a, **k: no_spawn.append("spawn"))
    assert not getattr(result, "spawned", None)
    run_id = claim(conn, task_id)
    assert heartbeat_external(conn, task_id, run_id, PROFILE, note="working")
    add(conn, task_id, run_id, "other_result", {"name": "report", "receipt": {"url": "https://x/y"}})
    assert kb.complete_task(conn, task_id, summary="done", expected_run_id=run_id, actor_profile=PROFILE)
    assert kb.get_task(conn, task_id).status == "done"
    assert no_spawn == []
    assert hooks.count(("kanban_task_completed", task_id)) == 1
    run = conn.execute("SELECT executor, executor_session, worker_pid, profile FROM task_runs WHERE id=?", (run_id,)).fetchone()
    assert tuple(run) == ("external", "sess-1", None, PROFILE)
    assert conn.execute("SELECT claim_lock FROM task_runs WHERE id=?", (run_id,)).fetchone()[0].startswith(f"external:{PROFILE}:")


@pytest.mark.parametrize("scenario, reason", [
    ("other_profile", "wrong_profile"),
    ("default_profile", "default_profile"),
    ("no_profile", "no_profile"),
    ("unassigned", "unassigned"),
    ("parents", "parents_unmet"),
])
def test_claim_refusals_leave_card_ready(conn, as_profile, scenario, reason):
    parent = governed(conn, CONTRACT, title="parent")
    task_id = governed(conn, CONTRACT, assignee=None if scenario == "unassigned" else PROFILE,
                       parents=(parent,) if scenario == "parents" else ())
    if scenario == "parents":
        conn.execute("UPDATE tasks SET status='ready' WHERE id=?", (task_id,))
        conn.commit()
    if scenario == "unassigned":
        conn.execute("UPDATE tasks SET status='ready' WHERE id=?", (task_id,))
        conn.commit()
    profile = {"other_profile": "intruder", "default_profile": "default", "no_profile": None}.get(scenario, PROFILE)
    before = kb.get_task(conn, task_id).status
    with pytest.raises(ExternalClaimError) as err:
        claim_external(conn, task_id, profile=profile, board=BOARD)
    assert err.value.reason == reason
    assert kb.get_task(conn, task_id).status == before
    assert conn.execute("SELECT COUNT(*) FROM task_runs WHERE task_id=?", (task_id,)).fetchone()[0] == 0


def test_claim_refused_on_worker_board(coord_env):
    kb.create_board("plain")
    with kbc.connect(board="plain") as plain:
        task_id = kb.create_task(plain, title="t", assignee=PROFILE)
        with pytest.raises(ExternalClaimError) as err:
            claim_external(plain, task_id, profile=PROFILE, board="plain")
        assert err.value.reason == "not_external_board"
        assert kb.get_task(plain, task_id).status == "ready"


def test_identity_comes_from_bound_profile_not_arguments(conn, as_profile):
    task_id = governed(conn, CONTRACT)
    as_profile("intruder")
    out = kanban_cli.run_slash(f"claim {task_id} --json")
    assert "assigned to 'projbot', not 'intruder'" in out
    assert kb.get_task(conn, task_id).status == "ready"
    as_profile(None)
    assert "default profile" in kanban_cli.run_slash(f"claim {task_id} --json")
    as_profile(PROFILE)
    claimed = json.loads(kanban_cli.run_slash(f"claim {task_id} --session s9 --json"))
    assert claimed["profile"] == PROFILE and claimed["run_id"]


def test_tool_payload_cannot_choose_identity(conn, as_profile):
    from tools import kanban_outcome_tools as kot
    task_id = governed(conn, CONTRACT)
    as_profile("intruder")
    out = json.loads(kot._handle_claim({"task_id": task_id, "profile": PROFILE}))
    assert "unknown parameter" in out["error"]
    out = json.loads(kot._handle_claim({"task_id": task_id}))
    assert "wrong_profile" in out["error"]
    assert kb.get_task(conn, task_id).status == "ready"


def test_concurrent_claims_have_exactly_one_winner(conn):
    task_id = governed(conn, CONTRACT)
    barrier, results = threading.Barrier(8), []

    def attempt():
        with kbc.connect(board=BOARD) as mine:
            barrier.wait()
            try:
                task = claim_external(mine, task_id, profile=PROFILE, board=BOARD)
                results.append(task.current_run_id if task else None)
            except Exception as exc:
                results.append(exc)

    threads = [threading.Thread(target=attempt) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    winners = [r for r in results if isinstance(r, int)]
    assert len(winners) == 1 and results.count(None) == 7
    assert conn.execute("SELECT COUNT(*) FROM task_runs WHERE task_id=?", (task_id,)).fetchone()[0] == 1
    assert event_kinds(conn, task_id).count("claimed") == 1


def _reclaim_and_reclaim_again(conn, task_id):
    assert kb.reclaim_task(conn, task_id, reason="test")
    return claim(conn, task_id, session="sess-2")


def test_stale_run_cannot_heartbeat_attach_or_complete(conn):
    task_id = governed(conn, CONTRACT)
    old = claim(conn, task_id)
    new = _reclaim_and_reclaim_again(conn, task_id)
    assert new != old
    assert not heartbeat_external(conn, task_id, old, PROFILE)
    from hermes_cli.kanban_outcomes import EvidenceError
    with pytest.raises(EvidenceError) as err:
        add(conn, task_id, old, "other_result", {"name": "report", "receipt": {"url": "u"}})
    assert err.value.code == "stale"
    with pytest.raises(ExternalRunFenceError):
        kb.complete_task(conn, task_id, summary="x", expected_run_id=old, actor_profile=PROFILE)
    assert kb.get_task(conn, task_id).status == "running"
    assert heartbeat_external(conn, task_id, new, PROFILE)


def test_heartbeat_requires_owning_profile(conn):
    task_id = governed(conn, CONTRACT)
    run_id = claim(conn, task_id)
    assert not heartbeat_external(conn, task_id, run_id, "intruder")
    assert not heartbeat_external(conn, task_id, run_id, None)


def test_external_completion_requires_run_fence_and_owner(conn):
    plain = kb.create_task(conn, title="no contract", assignee=PROFILE)
    run_id = claim(conn, plain)
    with pytest.raises(ExternalRunFenceError, match="pass the run id"):
        kb.complete_task(conn, plain, summary="x", actor_profile=PROFILE)
    with pytest.raises(ExternalRunFenceError, match="does not own"):
        kb.complete_task(conn, plain, summary="x", expected_run_id=run_id, actor_profile="intruder")
    assert kb.get_task(conn, plain).status == "running"
    assert kb.complete_task(conn, plain, summary="x", expected_run_id=run_id, actor_profile=PROFILE)


def test_ttl_reclaim_returns_external_run_to_ready_and_crash_sweep_ignores_it(conn):
    task_id = governed(conn, CONTRACT)
    run_id = claim(conn, task_id)
    assert kbd.detect_crashed_workers(conn, board=BOARD) == []
    assert kb.get_task(conn, task_id).status == "running"
    conn.execute("UPDATE tasks SET claim_expires=? WHERE id=?", (int(time.time()) - 5, task_id))
    conn.commit()
    assert kb.release_stale_claims(conn) == 1
    task = kb.get_task(conn, task_id)
    assert task.status == "ready" and task.current_run_id is None
    assert conn.execute("SELECT outcome FROM task_runs WHERE id=?", (run_id,)).fetchone()[0] == "reclaimed"
    assert "crashed" not in event_kinds(conn, task_id)
    assert not heartbeat_external(conn, task_id, run_id, PROFILE)
