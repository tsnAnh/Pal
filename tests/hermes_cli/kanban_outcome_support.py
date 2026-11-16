"""Shared fixtures and builders for coordinator-claim and outcome-gate tests."""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest

from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_connect as kbc
from hermes_cli import kanban_outcomes_store as store

BOARD = "coord"
PROFILE = "projbot"
SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
REPO = "acme/widget"
PR_URL = f"https://github.com/{REPO}/pull/7"


@pytest.fixture
def coord_env(tmp_path, monkeypatch):
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setenv("HERMES_KANBAN_HOME", str(root))
    monkeypatch.setenv("HERMES_KANBAN_BOARD", BOARD)
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    monkeypatch.delenv("HERMES_KANBAN_RUN_ID", raising=False)
    monkeypatch.delenv("HERMES_PROFILE", raising=False)
    monkeypatch.setenv("HERMES_PROFILE_NAME", PROFILE)
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    kb.init_db()
    kb.create_board(BOARD)
    kb.write_board_metadata(BOARD, dispatch_mode="external")
    return root


@pytest.fixture
def as_profile(monkeypatch):
    def bind(name):
        if name is None:
            monkeypatch.delenv("HERMES_PROFILE_NAME", raising=False)
        else:
            monkeypatch.setenv("HERMES_PROFILE_NAME", name)
    return bind


@pytest.fixture
def conn(coord_env):
    connection = kbc.connect(board=BOARD)
    yield connection
    connection.close()


@pytest.fixture
def fake_github(monkeypatch):
    state = {"state": "MERGED", "head_sha": SHA_A, "merge_commit": SHA_B, "calls": [], "raise": None}

    def fetch(repo, number, *, profile):
        state["calls"].append((repo, number, profile))
        if state["raise"]:
            raise state["raise"]
        return {k: state[k] for k in ("state", "head_sha", "merge_commit")}

    monkeypatch.setattr(store, "fetch_pull_request", fetch)
    return state


@pytest.fixture
def hooks(monkeypatch):
    fired = []
    real = kb._fire_task_hook

    def record(event, task, task_id, run_id, **fields):
        fired.append((event, task_id))
        return real(event, task, task_id, run_id, **fields)

    monkeypatch.setattr(kb, "_fire_task_hook", record)
    return fired


def governed(conn, contract, *, assignee=PROFILE, parents=(), title="governed"):
    return kb.create_task(conn, title=title, assignee=assignee, parents=parents, outcome_contract=contract)


def claim(conn, task_id, profile=PROFILE, session="sess-1"):
    from hermes_cli.kanban_external_claim import claim_external
    task = claim_external(conn, task_id, profile=profile, session_id=session, board=BOARD)
    return task.current_run_id


def add(conn, task_id, run_id, kind, payload, profile=PROFILE):
    return store.record_evidence(conn, task_id, run_id=run_id, kind=kind, payload=payload, profile=profile)


def merged_payload(pr_url=PR_URL, head=SHA_A, merge=SHA_B):
    return {"pr_url": pr_url, "head_sha": head, "merge_commit": merge}


def sha256_of(path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def attach_file(conn, task_id, tmp_path, name="app.zip", data=b"build-bytes"):
    path = tmp_path / name
    path.write_bytes(data)
    kb.add_attachment(conn, task_id, filename=name, stored_path=str(path), size=len(data))
    return sha256_of(path)


def event_kinds(conn, task_id):
    return [e.kind for e in kb.list_events(conn, task_id)]


def complete(conn, task_id, run_id, **kw):
    return kb.complete_task(conn, task_id, summary="done", expected_run_id=run_id, actor_profile=PROFILE, **kw)
