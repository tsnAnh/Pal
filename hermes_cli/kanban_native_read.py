"""Read-only projections of the one Kanban lifecycle database for native clients: boards open mode=ro, nothing is created, claim locks and paths never leave."""
from __future__ import annotations

import base64
import contextlib
import dataclasses
import hashlib
import json
import re
import sqlite3
from typing import Any, Iterator, Optional

DEFAULT_PAGE = 100
MAX_PAGE = 500
_CURSOR_PREFIX = "kc2"
_PAGE_PREFIX = "kp1"

# Event kinds whose payload carries cross-profile facts; every other kind projects to ``{}``.
# ``claimed`` deliberately omits ``lock`` and ``expires`` (the claim lock is a bearer secret).
_EVENT_FIELDS = {
    "claimed": ("executor", "profile", "session", "run_id"),
    "evidence_recorded": ("kind", "digest", "evidence_id", "producer"),
    "outcome_verified": ("verification", "pr_url", "head_sha", "merge_commit", "state", "sha256", "name",
                         "attachment_id", "app_id", "host", "fields", "kind", "evidence"),
    "outcome_refused": ("code", "detail"),
    "pr_acceptance": ("ok", "classification"),
    "blocked": ("reason",),
    "completed": ("summary",),
}
_RECEIPT_FIELDS = tuple(f for f in _EVENT_FIELDS["outcome_verified"] if f not in ("kind", "evidence"))
_PATH = re.compile(r"(?<![\w:/.\-])/(?:[\w.@+\-]+/)+[\w.@+\-]*|[A-Za-z]:\\[^\s\"']*|~/[^\s\"']*")


class BoardUnavailable(Exception):

    def __init__(self, state: str):
        super().__init__(state)
        self.state = state


class SnapshotRequired(Exception):

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def scrub(value: Any) -> Any:
    if isinstance(value, str):
        return _PATH.sub("[path]", value)
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, dict):
        return {str(key): scrub(item) for key, item in value.items()}
    return value


def clamp_limit(limit: Optional[int]) -> int:
    return DEFAULT_PAGE if limit is None else max(1, min(int(limit), MAX_PAGE))


def _kb():
    from hermes_cli import kanban_db
    return kanban_db


def _generation(path, meta: dict) -> str:
    stat = path.stat()
    return hashlib.sha256(f"{stat.st_dev}:{stat.st_ino}:{meta.get('created_at')}".encode()).hexdigest()[:12]


@contextlib.contextmanager
def open_board(slug: str) -> Iterator[tuple[sqlite3.Connection, dict, str]]:
    kb = _kb()
    slug = kb._require_slug(slug)
    meta = kb.read_board_metadata(slug)
    if slug != kb.DEFAULT_BOARD and not kb.board_metadata_path(slug).exists():
        raise BoardUnavailable("absent")
    if meta.get("archived"):
        raise BoardUnavailable("archived")
    path = kb.kanban_db_path(slug)
    if not path.is_file():
        raise BoardUnavailable("absent")
    conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, isolation_level=None)
    try:
        conn.row_factory = sqlite3.Row
        conn.text_factory = kb._lossy_text
        conn.execute("PRAGMA query_only = ON")
        conn.execute("BEGIN")
        if not _has_table(conn, "tasks"):
            raise BoardUnavailable("absent")
        yield conn, meta, _generation(path, meta)
    finally:
        conn.close()


def _has_table(conn, name: str) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _columns(conn, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def board_id(gateway_id: str, slug: str) -> str:
    return f"{gateway_id}/{slug}"


def card_id(gateway_id: str, slug: str, task_id: str) -> str:
    return f"{gateway_id}/{slug}/{task_id}"


def scope(gateway_id: str, slug: str) -> dict:
    return {"gateway_id": gateway_id, "board": slug, "board_id": board_id(gateway_id, slug)}


def board_row(gateway_id: str, meta: dict, counts: Optional[dict]) -> dict:
    return {
        "scope": scope(gateway_id, meta["slug"]), "name": meta.get("name") or meta["slug"],
        "description": meta.get("description") or "", "icon": meta.get("icon") or "",
        "color": meta.get("color") or "", "archived": bool(meta.get("archived")),
        "dispatch_mode": meta.get("dispatch_mode") or "workers", "project_id": meta.get("project_id"),
        "created_at": meta.get("created_at"), "task_counts": counts,
    }


def status_counts(conn) -> dict:
    return {row[0]: row[1] for row in conn.execute("SELECT status, COUNT(*) FROM tasks GROUP BY status")}


def list_boards(gateway_id: str) -> list[dict]:
    kb = _kb()
    rows = []
    for meta in kb.list_boards(include_archived=True):
        slug = meta["slug"]
        if meta.get("archived"):
            rows.append(board_row(gateway_id, meta, None))
            continue
        try:
            with open_board(slug) as (conn, fresh, _generation_id):
                rows.append(board_row(gateway_id, fresh, status_counts(conn)))
        except BoardUnavailable:
            continue
    return rows


def encode_cursor(gateway_id: str, slug: str, generation: str, event_id: int, count: int) -> str:
    return _pack(_CURSOR_PREFIX, gateway_id, slug, generation, event_id, count)


def _pack(*parts) -> str:
    return base64.urlsafe_b64encode(json.dumps(list(parts), separators=(",", ":")).encode()).decode().rstrip("=")


def _unpack(token: str, prefix: str, strings: int, ints: int) -> tuple:
    """The fields of a token this module issued; anything else, whatever JSON it decodes to, is ``invalid_cursor``."""
    try:
        parts = json.loads(base64.urlsafe_b64decode(token + "=" * (-len(token) % 4)))
    except ValueError:
        raise SnapshotRequired("invalid_cursor") from None
    if not isinstance(parts, list) or len(parts) != 1 + strings + ints or parts[0] != prefix:
        raise SnapshotRequired("invalid_cursor")
    rest = parts[1:]
    if (not all(isinstance(p, str) for p in rest[:strings])
            or not all(type(p) is int and p >= 0 for p in rest[strings:])):
        raise SnapshotRequired("invalid_cursor")
    return tuple(rest)


def _decode_cursor(cursor: str) -> tuple[str, str, str, int, int]:
    return _unpack(cursor, _CURSOR_PREFIX, 3, 2)


def log_position(conn) -> tuple[int, int]:
    """``(highest event id, number of events)``: appends move the first, a purge moves only the second."""
    return tuple(conn.execute("SELECT COALESCE(MAX(id), 0), COUNT(*) FROM task_events").fetchone())


def head_event_id(conn) -> int:
    return log_position(conn)[0]


def _check_scope(found: tuple, gateway_id: str, slug: str, generation: str) -> None:
    if found[0] != gateway_id:
        raise SnapshotRequired("wrong_gateway")
    if found[1] != slug:
        raise SnapshotRequired("wrong_board")
    if found[2] != generation:
        raise SnapshotRequired("stale_generation")


def resolve_cursor(conn, cursor: str, gateway_id: str, slug: str, generation: str) -> tuple[int, int]:
    """``(event id, events up to it)`` a cursor continues from, or ``SnapshotRequired`` naming why it cannot.

    Appends only add ids above the cursor, so the number of events at or below it can change only by a
    deletion (task purge, event retention): the cursor then no longer describes the log the client holds.
    """
    found = _decode_cursor(cursor)
    _check_scope(found, gateway_id, slug, generation)
    event_id, count = found[3], found[4]
    if event_id > head_event_id(conn):
        raise SnapshotRequired("ahead_of_log")
    if conn.execute("SELECT COUNT(*) FROM task_events WHERE id <= ?", (event_id,)).fetchone()[0] != count:
        raise SnapshotRequired("history_changed")
    return event_id, count


def event_row(gateway_id: str, slug: str, event) -> dict:
    payload = event.payload if isinstance(event.payload, dict) else {}
    if event.kind == "outcome_verified" and isinstance(payload.get("verified"), dict):
        payload = {**payload["verified"], "kind": payload.get("kind"), "evidence": payload.get("evidence")}
    keep = _EVENT_FIELDS.get(event.kind, ())
    return {
        "event_id": event.id, "card_id": card_id(gateway_id, slug, event.task_id), "task_id": event.task_id,
        "run_id": event.run_id, "kind": event.kind, "created_at": event.created_at,
        "data": scrub({key: payload[key] for key in keep if key in payload}),
    }


def events_page(conn, gateway_id: str, slug: str, after: int, count: int, limit: int, task_id: Optional[str]) -> dict:
    """Events after ``after`` plus the next ``(event_id, count)`` position; ``SnapshotRequired('gap')`` when an
    event between the cursor and that position was deleted (a client would never learn of it)."""
    kb = _kb()
    sql, args = "SELECT * FROM task_events WHERE id > ?", [after]
    if task_id is not None:
        sql, args = sql + " AND task_id = ?", [*args, task_id]
    rows = conn.execute(sql + " ORDER BY id LIMIT ?", [*args, limit + 1]).fetchall()
    has_more = len(rows) > limit
    shown = rows[:limit]
    position = shown[-1]["id"] if has_more else head_event_id(conn)
    if conn.execute("SELECT COUNT(*) FROM task_events WHERE id > ? AND id <= ?", (after, position)).fetchone()[0] != position - after:
        raise SnapshotRequired("gap")
    return {"events": [event_row(gateway_id, slug, kb.Event.from_row(row)) for row in shown], "has_more": has_more,
            "position": position, "count": count + position - after}


def card_summary(gateway_id: str, slug: str, task, *, governed: bool) -> dict:
    return {
        "card_id": card_id(gateway_id, slug, task.id), "task_id": task.id, "title": task.title,
        "status": task.status, "assignee": task.assignee, "priority": task.priority,
        "created_at": task.created_at, "started_at": task.started_at, "completed_at": task.completed_at,
        "block_kind": task.block_kind, "governed": governed,
    }


def snapshot(conn, gateway_id: str, slug: str, generation: str, limit: int, page_token: Optional[str]) -> dict:
    """One page of the complete card set, keyed by task id.

    Every page pins the event position (head id and count) of the first page; a page taken after the log
    moved or lost events raises ``SnapshotRequired`` instead of mixing two states. Only the final page
    carries the replay ``cursor`` (that position), so a client cannot adopt a cursor for an incomplete set.
    """
    kb = _kb()
    head, count = log_position(conn)
    after = ""
    if page_token:
        found = _unpack(page_token, _PAGE_PREFIX, 4, 2)
        _check_scope(found, gateway_id, slug, generation)
        pinned = (int(found[4]), int(found[5]))
        if pinned != (head, count):
            raise SnapshotRequired("changed_during_snapshot")
        after = found[3]
    rows = conn.execute("SELECT * FROM tasks WHERE id > ? ORDER BY id LIMIT ?", (after, limit + 1)).fetchall()
    shown = rows[:limit]
    ids = [row["id"] for row in shown]
    marks = ",".join("?" * len(ids))
    edges = [{"task_id": row["child_id"], "requires_task_id": row["parent_id"]} for row in conn.execute(
        f"SELECT parent_id, child_id FROM task_links WHERE child_id IN ({marks}) ORDER BY child_id, parent_id", ids)]
    more = len(rows) > limit
    return {"cards": [card_summary(gateway_id, slug, kb.Task.from_row(row), governed=bool(row["outcome_contract"]))
                      for row in shown],
            "prerequisites": edges,
            "next_page_token": _pack(_PAGE_PREFIX, gateway_id, slug, generation, ids[-1], head, count) if more else None,
            "cursor": None if more else encode_cursor(gateway_id, slug, generation, head, count)}


def _contract(task) -> Optional[dict]:
    from hermes_cli.kanban_outcomes import OutcomeContractError, parse_contract
    try:
        contract = parse_contract(task.outcome_contract)
    except OutcomeContractError:
        return None
    if contract is None:
        return None
    return {"kind": contract.kind, "repo": contract.repo, "name": contract.name,
            "required_fields": list(contract.required_fields)}


def _runs(conn, task_id: str) -> list[dict]:
    columns = _columns(conn, "task_runs")
    runs = []
    for row in conn.execute("SELECT * FROM task_runs WHERE task_id = ? ORDER BY id", (task_id,)):
        runs.append({
            "run_id": row["id"], "profile": row["profile"],
            "executor": row["executor"] if "executor" in columns else None,
            "executor_session": row["executor_session"] if "executor_session" in columns else None,
            "status": row["status"], "outcome": row["outcome"], "started_at": row["started_at"],
            "ended_at": row["ended_at"], "claim_expires": row["claim_expires"],
            "last_heartbeat_at": row["last_heartbeat_at"],
            "summary": scrub(row["summary"]), "error": scrub(row["error"]),
        })
    return runs


def evidence_rows(conn, task_id: str, run_id: Optional[int]) -> list[dict]:
    if not _has_table(conn, "task_evidence"):
        return []
    from hermes_cli.kanban_outcomes_store import list_evidence
    return [{
        "evidence_id": ev.id, "run_id": ev.run_id, "kind": ev.kind, "digest": ev.digest,
        "payload": scrub(ev.payload), "producer_profile": ev.producer_profile,
        "producer_session": ev.producer_session, "source": ev.source, "observed_at": ev.observed_at,
    } for ev in list_evidence(conn, task_id, run_id)]


_PROOF_KINDS = ("pr_acceptance", "outcome_verified", "outcome_refused")
_HISTORY_LIMIT = 20


def subject_run(conn, task) -> Optional[int]:
    """The run proofs are judged for: the live run, else the card's latest."""
    if task.current_run_id is not None:
        return task.current_run_id
    return conn.execute("SELECT MAX(id) FROM task_runs WHERE task_id = ?", (task.id,)).fetchone()[0]


def _ci_entry(event) -> dict:
    payload = event.payload if isinstance(event.payload, dict) else {}
    ok, classification = payload.get("ok"), payload.get("classification")
    state = "unknown" if not isinstance(ok, bool) else "accepted" if ok else "pending" if classification == "pending" else "rejected"
    return {"state": state,
            "classification": scrub(payload.get("classification")), "run_id": event.run_id,
            "observed_at": event.created_at, "event_id": event.id}


def _outcome_entry(event) -> dict:
    """``verification`` is copied from the stored receipt: an attestation is never relabelled independent."""
    blank = {"verification": None, "receipt": None, "run_id": event.run_id, "observed_at": event.created_at,
             "event_id": event.id}
    stored = event.payload if isinstance(event.payload, dict) else {}
    receipt = stored.get("verified") if isinstance(stored.get("verified"), dict) else None
    if event.kind != "outcome_verified" or receipt is None:
        return {**blank, "state": "refused" if event.kind == "outcome_refused" else "unknown"}
    label = receipt.get("verification")
    return {**blank, "state": "verified", "verification": label if label in ("independent", "attested") else "unknown",
            "receipt": scrub({key: receipt[key] for key in _RECEIPT_FIELDS if key in receipt})}


def _attributed(conn, event):
    """A proof recorded before any run was live (the exact-head CI check of a first completion) belongs to the
    run the card opens next; with none, it stays run-less."""
    nxt = conn.execute("SELECT run_id FROM task_events WHERE task_id = ? AND id > ? AND run_id IS NOT NULL ORDER BY id LIMIT 1",
                       (event.task_id, event.id)).fetchone()
    return dataclasses.replace(event, run_id=nxt[0]) if nxt else event


def proofs(conn, task, contract: Optional[dict]) -> dict:
    """CI acceptance and outcome verification for the subject run only; other runs' proofs are history."""
    run_id = subject_run(conn, task)
    marks = ",".join("?" * len(_PROOF_KINDS))
    events = [_kb().Event.from_row(r) for r in conn.execute(
        f"SELECT * FROM task_events WHERE task_id = ? AND kind IN ({marks}) ORDER BY id", (task.id, *_PROOF_KINDS))]
    ci = {"state": "unknown", "classification": None, "run_id": None, "observed_at": None, "event_id": None}
    outcome = {"state": "not_governed" if contract is None else "unknown", "verification": None, "receipt": None,
               "run_id": None, "observed_at": None, "event_id": None}
    history = []
    for event in events:
        if event.run_id is None:
            event = _attributed(conn, event)
        current = event.run_id == run_id
        if event.kind == "pr_acceptance":
            entry = _ci_entry(event)
            if current:
                ci = entry
        else:
            entry = _outcome_entry(event)
            if current and contract is not None:
                outcome = entry
        if not current:
            history.append({"kind": event.kind, **{k: entry[k] for k in ("state", "run_id", "observed_at", "event_id")},
                            "verification": entry.get("verification")})
    return {"proof_run_id": run_id, "ci_acceptance": ci, "outcome_verification": outcome,
            "proof_history": history[-_HISTORY_LIMIT:]}


def card_detail(conn, gateway_id: str, slug: str, generation: str, task_id: str) -> Optional[dict]:
    kb = _kb()
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        return None
    task = kb.Task.from_row(row)
    contract = _contract(task)
    parents = [r[0] for r in conn.execute("SELECT parent_id FROM task_links WHERE child_id = ? ORDER BY parent_id", (task_id,))]
    children = [r[0] for r in conn.execute("SELECT child_id FROM task_links WHERE parent_id = ? ORDER BY child_id", (task_id,))]
    head, count = log_position(conn)
    return {
        "card": card_summary(gateway_id, slug, task, governed=contract is not None),
        "body": scrub(task.body), "result": scrub(task.result), "branch_name": task.branch_name,
        "lifecycle": {"status": task.status, "assignee": task.assignee, "block_kind": task.block_kind,
                      "created_at": task.created_at, "started_at": task.started_at,
                      "completed_at": task.completed_at},
        "execution": {"current_run_id": task.current_run_id, "claim_expires": task.claim_expires,
                      "runs": _runs(conn, task_id)},
        "outcome_contract": contract,
        **proofs(conn, task, contract),
        "evidence": evidence_rows(conn, task_id, None),
        "prerequisites": parents, "dependents": children,
        "cursor": encode_cursor(gateway_id, slug, generation, head, count),
    }


def task_exists(conn, task_id: str) -> bool:
    return conn.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,)).fetchone() is not None
