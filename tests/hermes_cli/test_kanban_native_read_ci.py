"""Native projection of the merged fleet CI acceptance: real collector (gh shim against a local GitHub contract),
real ``complete_task`` recorder, real ``kanban_native_read`` projection and the canonical result model."""
import pytest

from hermes_cli import kanban_db as kb
from hermes_cli import kanban_native_read as read
from hermes_cli.kanban_db_connect import connect
from tests.hermes_cli.kanban_outcome_support import BOARD, PROFILE
from tests.hermes_cli.test_kanban_pr_acceptance_fleet import PR, REPO, add_check, attempt
from tui_gateway.contracts.canonical_kanban import KanbanCardResult

pytest_plugins = ["tests.hermes_cli.kanban_outcome_support", "tests.hermes_cli.test_kanban_pr_acceptance_fleet"]


def project(task_id):
    with read.open_board(BOARD) as (conn, _meta, generation):
        detail = read.card_detail(conn, "gw", BOARD, generation, task_id)
        events = read.events_page(conn, "gw", BOARD, 0, 0, 500, task_id)["events"]
    KanbanCardResult.model_validate({"state": "present", "scope": read.scope("gw", BOARD), "detail": detail})
    return detail, events


def test_accepted_ci_receipt_projects_as_accepted_and_nothing_else(github):
    with connect(board=BOARD) as conn:
        tid, done = attempt(conn)
    assert done is True
    detail, events = project(tid)
    assert detail["ci_acceptance"]["state"] == "accepted" and detail["ci_acceptance"]["classification"] == "success"
    assert detail["lifecycle"]["status"] == "done"
    assert detail["outcome_verification"]["state"] == "not_governed" and detail["evidence"] == []
    accepted = next(e for e in events if e["kind"] == "pr_acceptance")
    assert accepted["data"] == {"ok": True, "classification": "success"}


def test_pending_and_failing_receipts_are_never_accepted_and_a_later_success_replaces_them(github):
    add_check(github, status="in_progress", conclusion=None)
    with connect(board=BOARD) as conn:
        tid, done = attempt(conn)
        assert done is False
        pending, _ = project(tid), None
        assert pending[0]["ci_acceptance"]["state"] == "pending" and pending[0]["lifecycle"]["status"] != "done"
        github["check_runs"].pop()
        github["check_runs"][0]["conclusion"] = "failure"
        assert kb.complete_task(conn, tid, result="again", metadata={"published_pr": PR}) is False
    failing = project(tid)[0]
    assert failing["ci_acceptance"]["state"] == "rejected" and failing["ci_acceptance"]["classification"] == "failure"
    github["check_runs"][0]["conclusion"] = "success"
    with connect(board=BOARD) as conn:
        assert kb.complete_task(conn, tid, result="third", metadata={"published_pr": PR}) is True
    final, events = project(tid)
    assert final["ci_acceptance"]["state"] == "accepted"
    assert [e["data"]["classification"] for e in events if e["kind"] == "pr_acceptance"] == ["pending", "failure", "success"]


def test_ci_acceptance_does_not_imply_outcome_verification_or_completion(github):
    from hermes_cli.kanban_outcomes_store import OutcomeRefusedError
    with connect(board=BOARD) as conn:
        tid = kb.create_task(conn, title="governed", assignee=PROFILE, completion_contract=f"fleet-ci:{REPO}",
                             outcome_contract={"kind": "built_artifact"}, board=BOARD)
        with pytest.raises(OutcomeRefusedError):
            kb.complete_task(conn, tid, result="x", metadata={"published_pr": PR})
    detail, _events = project(tid)
    assert detail["outcome_verification"]["state"] == "refused" and detail["lifecycle"]["status"] != "done"
    assert detail["ci_acceptance"]["state"] != "accepted" or detail["outcome_verification"]["state"] != "verified"
