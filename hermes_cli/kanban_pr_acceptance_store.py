"""Persist acceptance with the same ownership snapshot as the terminal write."""
from __future__ import annotations

import json

from hermes_cli.kanban_db_connect import write_txn
from hermes_cli.kanban_pr_acceptance import _PR, collect_acceptance, refusal_detail, split_contract


def _snapshot(conn, task_id):
    row = conn.execute("SELECT current_run_id, status, completion_contract FROM tasks WHERE id=?", (task_id,)).fetchone()
    return tuple(row) if row else None


def prepare_acceptance(conn, task_id, expected_run_id, metadata, outcome=None):
    snapshot = _snapshot(conn, task_id)
    if snapshot is None:
        return False
    run_id, status, contract = snapshot
    if not contract or contract == "local-only":
        return None
    if status not in {"running", "ready", "blocked", "review"} or (expected_run_id is not None and run_id != expected_run_id):
        return False
    published_pr = metadata.get("published_pr") if isinstance(metadata, dict) else None
    match = _PR.fullmatch(published_pr) if isinstance(published_pr, str) else None
    # Publication binds once. Retrying cannot replace the task's PR with a green sibling.
    policy, target = split_contract(contract)
    if match and target == match[1]:
        bound = published_pr if policy == "required-checks" else f"fleet-ci:{published_pr}"
        with write_txn(conn):
            if _snapshot(conn, task_id) != snapshot:
                return False
            conn.execute("UPDATE tasks SET completion_contract=? WHERE id=?", (bound, task_id))
        snapshot = (run_id, status, bound)
        contract = bound
    # The assignee profile's gh login owns the repo: acceptance must not run as
    # the ambient login of whichever process completes the card (#122689).
    assignee = conn.execute("SELECT assignee FROM tasks WHERE id=?", (task_id,)).fetchone()["assignee"]
    receipt = collect_acceptance(contract, published_pr, assignee=assignee)
    verified = outcome[1]["verified"] if outcome and outcome[1]["kind"] == "merged_pr" else None
    if receipt["ok"] and verified and (verified["pr_url"], verified["head_sha"]) != (receipt["pr_url"], receipt["head_sha"]):
        receipt.update(ok=False, classification="mismatch",
                       detail=f"The merged outcome names {verified['pr_url']} at {verified['head_sha']}; "
                              f"the CI acceptance names {receipt['pr_url']} at {receipt['head_sha']}.")
    if not receipt["ok"]:
        receipt["detail"] = refusal_detail(receipt)
    return snapshot, receipt


def merged_already_done(conn, task_id, metadata=None) -> bool:
    row = conn.execute("SELECT status, completion_contract, assignee FROM tasks WHERE id=?", (task_id,)).fetchone()
    if row is None or row["status"] != "done" or not row["completion_contract"] or row["completion_contract"] == "local-only":
        return False
    published_pr = metadata.get("published_pr") if isinstance(metadata, dict) else None
    receipt = collect_acceptance(row["completion_contract"], published_pr if isinstance(published_pr, str) else None,
                                 assignee=row["assignee"])
    return receipt["ok"] and receipt.get("merged", False)


def acceptance_warning(conn, task_id) -> str | None:
    row = conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='pr_acceptance' ORDER BY id DESC LIMIT 1",
                       (task_id,)).fetchone()
    return (json.loads(row["payload"]) if row else {}).get("warning")


def record_acceptance(conn, task_id, acceptance):
    """Called under complete_task's write_txn, before its terminal UPDATE."""
    from hermes_cli.kanban_db import _append_event
    snapshot, receipt = acceptance
    if _snapshot(conn, task_id) != snapshot:
        return False
    _append_event(conn, task_id, "pr_acceptance", receipt, run_id=snapshot[0])
    if not receipt["ok"]:
        detail = f"PR acceptance {receipt['classification']}: {receipt['detail']} {receipt['recovery']}"
        conn.execute("UPDATE tasks SET last_failure_error=? WHERE id=?", (detail, task_id))
    return receipt["ok"]
