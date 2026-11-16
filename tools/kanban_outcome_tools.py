"""Coordinator tools for external Kanban boards: claim a card, attach outcome evidence.

Orchestrator-visible only. The acting profile is the bound profile, never an argument.
"""
from __future__ import annotations

from dataclasses import asdict

from tools.kanban_tools import (
    _Reject, _board, _check, _check_kanban_orchestrator_mode, _kanban_handler, _ok,
    _persisted_identity, _reject_delegated_child_mutation, _require_orchestrator_tool, _require_text,
)
from tools.kanban_tools_schemas import _prop, _schema
from tools.registry import registry

KANBAN_CLAIM_SCHEMA = _schema(
    "kanban_claim",
    (
        "Claim a ready card on a coordinator-owned (external) board as your own profile and get the run_id "
        "that fences every later heartbeat, evidence and completion call. Nothing is spawned. Refused for "
        "other profiles, the default profile, ordinary boards, unassigned cards and unmet parents."
    ),
    {
        "task_id": _prop("string", "Card id to claim."),
        "session_id": _prop("string", "Your coordinator session label, recorded on the run."),
        "ttl_seconds": _prop("integer", "Claim lifetime; refresh it with kanban_heartbeat and run_id."),
    },
    ["task_id"],
)

KANBAN_EVIDENCE_SCHEMA = _schema(
    "kanban_evidence",
    (
        "Append or list outcome evidence for a governed card (action add|list). Evidence is immutable and the "
        "producer is stamped from your bound profile. Kinds: execution_ref{session_id,runtime}; "
        "pr_published{pr_url,head_sha}; pr_merged{pr_url,head_sha,merge_commit}; artifact_built{sha256,name}; "
        "app_installed{app_id,artifact_sha256,readback_sha256,host}; other_result{name,receipt}. "
        "kanban_complete then verifies the outcome (a merged PR is read from GitHub)."
    ),
    {
        "action": _prop("string", "add or list."),
        "task_id": _prop("string", "Governed card id."),
        "run_id": _prop("integer", "Run id returned by kanban_claim (add)."),
        "kind": _prop("string", "Evidence kind (add)."),
        "payload": _prop("object", "Evidence fields for the kind (add)."),
    },
    ["action", "task_id"],
)


@_kanban_handler("kanban_claim")
def _handle_claim(args: dict, **kw) -> str:
    _reject_delegated_child_mutation("kanban_claim")
    _require_orchestrator_tool("kanban_claim")
    from hermes_cli.kanban_external_claim import ExternalClaimError, claim_external
    tid = _require_text(args, "task_id")
    with _board(args.get("board")) as (_kb, conn):
        try:
            task = claim_external(conn, tid, profile=_bound_profile(), session_id=args.get("session_id"),
                                  ttl_seconds=args.get("ttl_seconds"), board=args.get("board"))
        except ExternalClaimError as exc:
            raise _Reject(f"kanban_claim: {exc}") from None
        _check(task is not None, f"could not claim {tid}: another claimant holds it or it is not ready")
        return _ok(task_id=tid, run_id=task.current_run_id, profile=task.assignee, claim_expires=task.claim_expires)


@_kanban_handler("kanban_evidence")
def _handle_evidence(args: dict, **kw) -> str:
    _reject_delegated_child_mutation("kanban_evidence")
    _require_orchestrator_tool("kanban_evidence")
    from hermes_cli.kanban_outcomes import EvidenceError
    from hermes_cli.kanban_outcomes_store import list_evidence, record_evidence
    tid, action = _require_text(args, "task_id"), args.get("action")
    _check(action in ("add", "list"), "action must be add or list")
    with _board(args.get("board")) as (_kb, conn):
        if action == "list":
            return _ok(task_id=tid, evidence=[asdict(e) for e in list_evidence(conn, tid)])
        run_id = args.get("run_id")
        _check(isinstance(run_id, int) and not isinstance(run_id, bool), "run_id (integer) is required for add")
        try:
            item, created = record_evidence(conn, tid, run_id=run_id, kind=str(args.get("kind") or ""),
                                            payload=args.get("payload"), profile=_persisted_identity())
        except EvidenceError as exc:
            raise _Reject(f"kanban_evidence: {exc}") from None
        return _ok(task_id=tid, evidence_id=item.id, kind=item.kind, digest=item.digest, created=created)


def _bound_profile():
    from hermes_cli.kanban_external_claim import bound_profile
    return bound_profile()


for _name, _sch, _handler in (("kanban_claim", KANBAN_CLAIM_SCHEMA, _handle_claim),
                              ("kanban_evidence", KANBAN_EVIDENCE_SCHEMA, _handle_evidence)):
    registry.register(name=_name, toolset="kanban", schema=_sch, handler=_handler, emoji="🔖",
                      check_fn=_check_kanban_orchestrator_mode)
