"""Evidence persistence and the completion gate for governed Kanban cards.

``complete_task`` calls :func:`prepare_outcome` before its write transaction (GitHub and file
reads happen there, never under the SQLite lock) and :func:`record_outcome` inside it, which
re-reads the same snapshot so a run, status, contract or evidence change in between aborts the
completion. Evidence rows are append-only (triggers), so a verdict can only ever rest on rows
that still exist unchanged.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import subprocess
import time
from pathlib import Path
from typing import Optional

from hermes_cli.kanban_db_connect import write_txn
from hermes_cli.kanban_external_claim import (
    EXECUTOR, ExternalRunFenceError, current_external_run,
)
from hermes_cli.kanban_outcomes import (
    EVIDENCE_SOURCE, LEGAL_EVIDENCE, Evidence, EvidenceError, OutcomeContract, Unverifiable,
    Verdict, evaluate, parse_contract, payload_digest, pr_parts, validate_evidence,
)

OPEN_STATUSES = ("running", "ready", "blocked", "review")

_SCHEMA = (
    "CREATE TABLE IF NOT EXISTS task_evidence ("
    " id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL, run_id INTEGER NOT NULL,"
    " kind TEXT NOT NULL, digest TEXT NOT NULL, payload TEXT NOT NULL,"
    " producer_profile TEXT NOT NULL, producer_session TEXT, source TEXT NOT NULL,"
    " observed_at INTEGER NOT NULL, UNIQUE(task_id, run_id, kind, digest))",
    "CREATE INDEX IF NOT EXISTS idx_evidence_task ON task_evidence(task_id, run_id, id)",
    "CREATE TRIGGER IF NOT EXISTS task_evidence_no_update BEFORE UPDATE ON task_evidence "
    "BEGIN SELECT RAISE(ABORT, 'task_evidence is append-only'); END",
    "CREATE TRIGGER IF NOT EXISTS task_evidence_no_delete BEFORE DELETE ON task_evidence "
    "BEGIN SELECT RAISE(ABORT, 'task_evidence is append-only'); END",
)


def ensure_schema(conn: sqlite3.Connection) -> None:
    for statement in _SCHEMA:
        conn.execute(statement)


class OutcomeRefusedError(ValueError):
    """The governed card's outcome is not proven; ``code`` is missing, malformed, mismatch or unverifiable."""

    def __init__(self, task_id: str, code: str, detail: str):
        self.task_id, self.code, self.detail = task_id, code, detail
        super().__init__(f"outcome refused ({code}): {detail}")


def fetch_pull_request(repo: str, number: int, *, profile: str) -> dict:
    """Default GitHub seam: read the PR as the claimant profile's own login."""
    from hermes_cli.kanban_pr_acceptance import _GateAuthError, _api, _assignee_profile_home
    owner, name = repo.split("/")
    query = (f'{{repository(owner:{json.dumps(owner)},name:{json.dumps(name)}){{'
             f'pullRequest(number:{number:d}){{state headRefOid mergeCommit{{oid}}}}}}}}')
    try:
        repository = _api("graphql", query=query, profile_home=_assignee_profile_home(profile))["data"]["repository"]
    except _GateAuthError as exc:
        raise Unverifiable(str(exc)) from None
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, IndexError) as exc:
        raise Unverifiable(f"GitHub read failed ({type(exc).__name__})") from None
    pr = (repository or {}).get("pullRequest")
    if pr is None:
        raise Unverifiable(f"{repo}#{number} is not visible to profile {profile!r}")
    return {"state": pr["state"], "head_sha": pr["headRefOid"],
            "merge_commit": (pr.get("mergeCommit") or {}).get("oid")}


def _row_evidence(row) -> Evidence:
    return Evidence(id=row["id"], run_id=row["run_id"], kind=row["kind"], digest=row["digest"],
                    payload=json.loads(row["payload"]), producer_profile=row["producer_profile"],
                    producer_session=row["producer_session"], source=row["source"],
                    observed_at=row["observed_at"])


def list_evidence(conn, task_id: str, run_id: Optional[int] = None) -> list[Evidence]:
    sql, params = "SELECT * FROM task_evidence WHERE task_id = ?", [task_id]
    if run_id is not None:
        sql, params = sql + " AND run_id = ?", [*params, int(run_id)]
    return [_row_evidence(r) for r in conn.execute(sql + " ORDER BY id", params).fetchall()]


def record_evidence(conn, task_id: str, *, run_id: int, kind: str, payload, profile: Optional[str]):
    """Append evidence for the live external run ``run_id`` owned by ``profile``.

    Returns ``(Evidence, created)``; an identical retry returns the stored row with ``created=False``.
    Producer identity and session come from the run, never from the payload.
    """
    from hermes_cli import kanban_db as kb
    clean = validate_evidence(kind, payload)
    digest = payload_digest(clean)
    with write_txn(conn):
        task = conn.execute("SELECT outcome_contract FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if task is None:
            raise EvidenceError("stale", f"no such task: {task_id}")
        contract = parse_contract(task["outcome_contract"])
        if contract is None:
            raise EvidenceError("mismatch", "this card has no outcome contract, so it takes no evidence")
        run = current_external_run(conn, task_id, run_id, profile)
        if run is None:
            raise EvidenceError("stale", f"run {run_id} is not this card's live coordinator run for the bound profile; "
                                "claim the card again and use the run id it returns")
        if kind not in LEGAL_EVIDENCE[contract.kind]:
            raise EvidenceError("mismatch", f"{kind} evidence does not belong to a {contract.kind} contract; "
                                f"use one of {', '.join(sorted(LEGAL_EVIDENCE[contract.kind]))}")
        if kind in ("pr_published", "pr_merged"):
            _check_pr_binding(conn, task_id, contract, clean["pr_url"])
        cur = conn.execute(
            "INSERT OR IGNORE INTO task_evidence (task_id, run_id, kind, digest, payload, producer_profile,"
            " producer_session, source, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (task_id, int(run_id), kind, digest, json.dumps(clean, sort_keys=True), run["profile"],
             run["executor_session"], EVIDENCE_SOURCE.get(kind, "attestation"), int(time.time())))
        created = cur.rowcount == 1
        row = conn.execute("SELECT * FROM task_evidence WHERE task_id = ? AND run_id = ? AND kind = ? AND digest = ?",
                           (task_id, int(run_id), kind, digest)).fetchone()
        if created:
            kb._append_event(conn, task_id, "evidence_recorded",
                             {"kind": kind, "digest": digest, "evidence_id": row["id"], "producer": run["profile"]},
                             run_id=int(run_id))
    return _row_evidence(row), created


def _check_pr_binding(conn, task_id: str, contract: OutcomeContract, pr_url: str) -> None:
    repo, _ = pr_parts(pr_url)
    if contract.kind == "merged_pr" and repo != contract.repo:
        raise EvidenceError("mismatch", f"the PR is in {repo}; the contract requires {contract.repo}")
    from hermes_cli.kanban_pr_acceptance import _PR, split_contract
    accepted = conn.execute("SELECT completion_contract FROM tasks WHERE id = ?", (task_id,)).fetchone()[0]
    target = split_contract(accepted)[1] if accepted else ""
    if _PR.fullmatch(target) and target != pr_url:
        raise EvidenceError("mismatch", f"CI acceptance is bound to {target}; evidence for a different PR cannot be recorded")
    for row in conn.execute("SELECT payload FROM task_evidence WHERE task_id = ? AND kind IN ('pr_published','pr_merged')",
                            (task_id,)).fetchall():
        bound = json.loads(row["payload"])["pr_url"]
        if bound != pr_url:
            raise EvidenceError("mismatch", f"this card is already bound to {bound}; a different PR cannot replace it")


def _attachments(conn, task_id: str):
    from hermes_cli import kanban_db as kb

    def read() -> list[dict]:
        found = []
        for att in kb.list_attachments(conn, task_id):
            try:
                digest = hashlib.sha256()
                with Path(att.stored_path).open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1 << 20), b""):
                        digest.update(chunk)
            except OSError:
                continue
            found.append({"id": att.id, "filename": att.filename, "sha256": digest.hexdigest()})
        return found
    cache: list[list[dict]] = []

    def once() -> list[dict]:
        if not cache:
            cache.append(read())
        return cache[0]
    return once


def _subject_run(conn, task_id: str, row) -> Optional[int]:
    if row["current_run_id"] is not None:
        return int(row["current_run_id"]) if row["executor"] == EXECUTOR else None
    if row["status"] != "review":
        return None
    found = conn.execute(
        "SELECT id FROM task_runs WHERE task_id = ? AND executor = ? AND outcome = 'review_requested' "
        "ORDER BY id DESC LIMIT 1", (task_id, EXECUTOR)).fetchone()
    return int(found["id"]) if found else None


def _state(conn, task_id: str):
    return conn.execute(
        "SELECT t.status, t.current_run_id, t.outcome_contract, t.assignee, r.executor, r.profile AS run_profile "
        "FROM tasks t LEFT JOIN task_runs r ON r.id = t.current_run_id WHERE t.id = ?", (task_id,)).fetchone()


def _snapshot(conn, task_id: str, subject: Optional[int]):
    row = _state(conn, task_id)
    if row is None:
        return None
    ids = tuple((e.id, e.digest) for e in list_evidence(conn, task_id, subject)) if subject is not None else ()
    return (row["status"], row["current_run_id"], row["outcome_contract"], subject, ids)


def _check_fence(row, expected_run_id: Optional[int], actor_profile: Optional[str]) -> None:
    from hermes_cli.profiles import normalize_profile_name
    if expected_run_id is None:
        raise ExternalRunFenceError(
            "this card is running under a coordinator claim; pass the run id the claim returned "
            "(--run-id) so a stale attempt cannot complete it")
    if int(expected_run_id) != int(row["current_run_id"]):
        raise ExternalRunFenceError(f"run {expected_run_id} is not the card's current run ({row['current_run_id']}); the attempt is stale")
    actor = normalize_profile_name(actor_profile) if isinstance(actor_profile, str) and actor_profile.strip() else None
    if actor != row["run_profile"]:
        raise ExternalRunFenceError(f"the bound profile {actor!r} does not own run {row['current_run_id']} ({row['run_profile']!r})")


def prepare_outcome(conn, task_id: str, expected_run_id: Optional[int], *, actor_profile: Optional[str] = None,
                    force: bool = False):
    """``None`` for an ungoverned card with no coordinator run, ``False`` for a no-op, else the verified snapshot.

    Raises :class:`ExternalRunFenceError` for an unfenced or foreign completion of a coordinator
    run and :class:`OutcomeRefusedError` (after one auditable event) when the outcome is not proven.
    ``force`` waives only the run fence, never the evidence.
    """
    row = _state(conn, task_id)
    if row is None:
        return None
    contract = parse_contract(row["outcome_contract"])
    external = row["executor"] == EXECUTOR
    if contract is None and not external:
        return None
    if row["status"] not in OPEN_STATUSES:
        return False if contract is not None else None
    if external and not force:
        _check_fence(row, expected_run_id, actor_profile)
    if contract is None:
        return None
    if expected_run_id is not None and row["current_run_id"] is not None and int(expected_run_id) != int(row["current_run_id"]):
        raise ExternalRunFenceError(f"run {expected_run_id} is not the card's current run; the attempt is stale")
    subject = _subject_run(conn, task_id, row)
    snapshot = _snapshot(conn, task_id, subject)
    if subject is None:
        verdict = Verdict(False, "missing", "no coordinator run holds evidence for this card; claim it with "
                          "`hermes kanban claim` as the project profile, attach evidence, then complete with --run-id")
    else:
        run_profile = row["run_profile"] or conn.execute("SELECT profile FROM task_runs WHERE id = ?", (subject,)).fetchone()["profile"]
        verdict = evaluate(
            contract, list_evidence(conn, task_id, subject),
            fetch_pr=lambda repo, number: fetch_pull_request(repo, number, profile=run_profile),
            attachments=_attachments(conn, task_id))
    if not verdict.ok:
        _record_refusal(conn, task_id, contract, subject, snapshot[4], verdict)
        raise OutcomeRefusedError(task_id, verdict.code, verdict.detail)
    return snapshot, {"kind": contract.kind, "run_id": subject, "evidence": [e[0] for e in snapshot[4]],
                      "verified": verdict.receipt}


def _record_refusal(conn, task_id, contract, subject, evidence_ids, verdict) -> None:
    from hermes_cli import kanban_db as kb
    payload = {"code": verdict.code, "detail": verdict.detail, "kind": contract.kind, "run_id": subject,
               "evidence": [e[0] for e in evidence_ids]}
    payload["digest"] = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
    with write_txn(conn):
        last = conn.execute("SELECT payload FROM task_events WHERE task_id = ? AND kind = 'outcome_refused' "
                            "ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
        if last is not None and (json.loads(last["payload"] or "{}")).get("digest") == payload["digest"]:
            return
        kb._append_event(conn, task_id, "outcome_refused", payload, run_id=subject)


def record_outcome(conn, task_id: str, prepared) -> bool:
    """Under ``complete_task``'s write txn: same snapshot or the completion is abandoned."""
    return _snapshot(conn, task_id, prepared[0][3]) == prepared[0]


def append_outcome_verified(conn, task_id: str, prepared, run_id: Optional[int]) -> None:
    from hermes_cli import kanban_db as kb
    kb._append_event(conn, task_id, "outcome_verified", prepared[1], run_id=run_id)


def create_time_contract(value, board: Optional[str]) -> Optional[str]:
    """Canonical contract JSON; a governed card is accepted only on a board whose coordinators can attach its evidence."""
    from hermes_cli.kanban_board_mode import board_dispatch_mode
    from hermes_cli.kanban_outcomes import contract_json

    canonical = contract_json(value)
    if canonical is not None and board_dispatch_mode(board) != "external":
        raise ValueError(
            "outcome_contract requires a coordinator-owned board (dispatch_mode=external): "
            "only an external coordinator run can attach the evidence it demands"
        )
    return canonical
