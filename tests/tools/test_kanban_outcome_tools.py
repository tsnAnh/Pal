"""Tool surface for coordinator profiles: kanban_claim, kanban_evidence, run-fenced complete/heartbeat."""
from __future__ import annotations

import json

import pytest

from hermes_cli import kanban_db as kb
from hermes_cli import kanban_db_workspace as kbw
from tests.hermes_cli.kanban_outcome_support import BOARD, PROFILE, REPO, event_kinds, merged_payload
from tools import kanban_outcome_tools as kot
from tools import kanban_tools as kt

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support"]

MERGED = {"kind": "merged_pr", "repo": REPO}


def _create(conn, contract=MERGED, parents=()):
    return kb.create_task(conn, title="g", assignee=PROFILE, outcome_contract=contract, parents=parents)


def _claimed(conn):
    parent = _create(conn)
    child = kb.create_task(conn, title="child", assignee=PROFILE, parents=(parent,))
    out = json.loads(kot._handle_claim({"task_id": parent, "session_id": "s1"}))
    assert out["ok"] and out["profile"] == PROFILE
    workspace = kbw.resolve_workspace(kb.get_task(conn, parent), board=BOARD)
    kbw.set_workspace_path(conn, parent, str(workspace))
    return parent, child, out["run_id"], workspace


def test_claim_evidence_complete_through_tools(conn, fake_github, hooks):
    parent, child, run_id, _workspace = _claimed(conn)
    assert json.loads(kt._handle_heartbeat({"task_id": parent, "run_id": run_id, "note": "alive"}))["ok"]
    added = json.loads(kot._handle_evidence({"action": "add", "task_id": parent, "run_id": run_id,
                                             "kind": "pr_merged", "payload": merged_payload()}))
    assert added["ok"] and added["created"]
    repeated = json.loads(kot._handle_evidence({"action": "add", "task_id": parent, "run_id": run_id,
                                                "kind": "pr_merged", "payload": merged_payload()}))
    assert repeated["created"] is False and repeated["evidence_id"] == added["evidence_id"]
    listed = json.loads(kot._handle_evidence({"action": "list", "task_id": parent}))
    assert [e["kind"] for e in listed["evidence"]] == ["pr_merged"]
    done = json.loads(kt._handle_complete({"task_id": parent, "run_id": run_id, "summary": "merged"}))
    assert done["ok"], done
    assert kb.get_task(conn, child).status == "ready"
    assert hooks.count(("kanban_task_completed", parent)) == 1
    again = json.loads(kt._handle_complete({"task_id": parent, "run_id": run_id, "summary": "merged"}))
    assert again.get("error")
    assert hooks.count(("kanban_task_completed", parent)) == 1


def test_complete_tool_refuses_without_evidence_and_changes_nothing(conn, hooks):
    parent, child, run_id, workspace = _claimed(conn)
    out = json.loads(kt._handle_complete({"task_id": parent, "run_id": run_id, "summary": "prose says done"}))
    assert "outcome refused (missing)" in out["error"]
    assert kb.get_task(conn, parent).status == "running"
    assert kb.get_task(conn, child).status == "todo" and workspace.exists()
    assert ("kanban_task_completed", parent) not in hooks
    assert "outcome_refused" in event_kinds(conn, parent)


def test_complete_tool_needs_run_id_for_external_run(conn):
    parent, _, _run_id, _ = _claimed(conn)
    out = json.loads(kt._handle_complete({"task_id": parent, "summary": "x"}))
    assert "pass the run id" in out["error"]
    assert kb.get_task(conn, parent).status == "running"


def test_tool_identity_is_the_bound_profile(conn, as_profile, fake_github):
    parent, _, run_id, _ = _claimed(conn)
    as_profile("intruder")
    for out in (
        kot._handle_evidence({"action": "add", "task_id": parent, "run_id": run_id,
                              "kind": "pr_merged", "payload": merged_payload()}),
        kt._handle_heartbeat({"task_id": parent, "run_id": run_id}),
        kt._handle_complete({"task_id": parent, "run_id": run_id, "summary": "x"}),
    ):
        assert json.loads(out).get("error")
    assert kb.get_task(conn, parent).status == "running"
    assert kb.get_task(conn, parent).current_run_id == run_id


def test_evidence_tool_rejects_forged_producer_and_bad_shapes(conn):
    parent, _, run_id, _ = _claimed(conn)
    forged = {**merged_payload(), "producer_profile": "someone-else"}
    out = json.loads(kot._handle_evidence({"action": "add", "task_id": parent, "run_id": run_id,
                                           "kind": "pr_merged", "payload": forged}))
    assert "malformed" in out["error"]
    assert "unknown parameter" in json.loads(kot._handle_evidence({"action": "list", "task_id": parent, "producer": "x"}))["error"]
    assert json.loads(kot._handle_evidence({"action": "add", "task_id": parent, "kind": "pr_merged",
                                            "payload": merged_payload()}))["error"]


def test_create_tool_declares_contract_and_rejects_bad_one(conn):
    ok = json.loads(kt._handle_create({"title": "t", "assignee": PROFILE, "outcome_contract": MERGED}))
    assert ok["ok"]
    assert json.loads(kb.get_task(conn, ok["task_id"]).outcome_contract) == MERGED
    bad = json.loads(kt._handle_create({"title": "t", "assignee": PROFILE, "outcome_contract": {"kind": "other"}}))
    assert "outcome_contract" in bad["error"]


def test_claim_tool_hidden_from_dispatcher_workers(conn, monkeypatch):
    task_id = _create(conn)
    monkeypatch.setenv("HERMES_KANBAN_TASK", task_id)
    out = json.loads(kot._handle_claim({"task_id": task_id}))
    assert "orchestrator-only" in out["error"]
