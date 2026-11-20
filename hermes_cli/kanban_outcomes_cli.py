"""``hermes kanban claim|evidence|heartbeat --run-id`` for coordinator-owned boards.

The acting profile is always the bound profile (``-p``/``HERMES_HOME``), never an argument.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import asdict

from hermes_cli import kanban_db_connect as kbc
from hermes_cli.kanban_external_claim import (
    ExternalClaimError, bound_profile, claim_external, heartbeat_external,
)
from hermes_cli.kanban_output import _err, _print_json
from hermes_cli.kanban_outcomes import EvidenceError
from hermes_cli.kanban_outcomes_store import list_evidence, record_evidence
from hermes_cli.kanban_pr_acceptance_store import merged_already_done


def _claim_refusal(existing) -> str:
    if existing is None:
        return "no such task"
    if existing.status == "done":
        return "status=done, and no merged pull request is bound to it, so there is nothing to accept again"
    holder = f"held by {existing.claim_lock.split(':')[1]}" if (existing.claim_lock or "").startswith("external:") else (
        "held by a dispatcher worker" if existing.claim_lock else "not claimed")
    return f"status={existing.status}; {holder}, so it is not ready to claim"


def claim(args: argparse.Namespace) -> int:
    from hermes_cli import kanban_db as kb
    with kbc.connect_closing() as conn:
        try:
            task = claim_external(conn, args.task_id, profile=bound_profile(),
                                  session_id=getattr(args, "session", None), ttl_seconds=args.ttl)
        except ExternalClaimError as exc:
            return _err(f"kanban: {exc}")
        if task is None:
            existing = kb.get_task(conn, args.task_id)
            if merged_already_done(conn, args.task_id):
                if getattr(args, "json", False):
                    _print_json({"task_id": args.task_id, "status": "done", "already_done": True, "run_id": None})
                else:
                    print(f"{args.task_id} is already done and its pull request is merged; nothing to claim")
                return 0
            return _err(f"cannot claim {args.task_id}: {_claim_refusal(existing)}")
    if getattr(args, "json", False):
        _print_json({"task_id": task.id, "run_id": task.current_run_id, "profile": task.assignee,
                     "claim_expires": task.claim_expires})
    else:
        print(f"Claimed {task.id} run_id={task.current_run_id} profile={task.assignee}")
    return 0


def heartbeat(args: argparse.Namespace) -> int:
    with kbc.connect_closing() as conn:
        ok = heartbeat_external(conn, args.task_id, args.run_id, bound_profile(), note=getattr(args, "note", None))
    if not ok:
        return _err(f"cannot heartbeat {args.task_id}: run {args.run_id} is not your live coordinator run")
    print(f"Heartbeat recorded for {args.task_id}")
    return 0


def evidence(args: argparse.Namespace) -> int:
    action = getattr(args, "evidence_action", None)
    with kbc.connect_closing() as conn:
        if action == "list":
            rows = [asdict(e) for e in list_evidence(conn, args.task_id)]
            if getattr(args, "json", False):
                _print_json(rows)
            else:
                for row in rows:
                    print(f"#{row['id']} run={row['run_id']} {row['kind']} by {row['producer_profile']} "
                          f"{row['digest'][:12]}")
            return 0
        try:
            payload = json.loads(args.json_payload)
        except ValueError:
            return _err("kanban: evidence --json must be a JSON object", 2)
        try:
            item, created = record_evidence(conn, args.task_id, run_id=args.run_id, kind=args.kind,
                                            payload=payload, profile=bound_profile())
        except EvidenceError as exc:
            return _err(f"kanban: {exc}")
    print(f"{'Recorded' if created else 'Already recorded'} {item.kind} evidence #{item.id} for {args.task_id}")
    return 0
