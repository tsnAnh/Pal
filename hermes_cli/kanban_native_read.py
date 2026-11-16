"""Read-only projections of the one Kanban lifecycle database for native clients: boards open mode=ro, nothing is created, claim locks and paths never leave."""
from __future__ import annotations

import base64
import contextlib
import hashlib
import json
import re
import sqlite3
from typing import Any, Iterator, Optional

DEFAULT_PAGE = 100
MAX_PAGE = 500
_CURSOR_PREFIX = "kc1"

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


def encode_cursor(gateway_id: str, slug: str, generation: str, event_id: int) -> str:
    raw = json.dumps([_CURSOR_PREFIX, gateway_id, slug, generation, event_id], separators=(",", ":"))
    return base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[str, str, str, int]:
    try:
        parts = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
        prefix, gateway_id, slug, generation, event_id = parts
        if (prefix != _CURSOR_PREFIX or not all(isinstance(p, str) for p in (gateway_id, slug, generation))
                or type(event_id) is not int or event_id < 0):
            raise ValueError
    except (ValueError, TypeError):
        raise SnapshotRequired("invalid_cursor") from None
    return gateway_id, slug, generation, event_id


def head_event_id(conn) -> int:
    return conn.execute("SELECT COALESCE(MAX(id), 0) FROM task_events").fetchone()[0]


def resolve_cursor(conn, cursor: str, gateway_id: str, slug: str, generation: str) -> int:
    cursor_gateway, cursor_slug, cursor_generation, event_id = _decode_cursor(cursor)
    if cursor_gateway != gateway_id:
        raise SnapshotRequired("wrong_gateway")
    if cursor_slug != slug:
        raise SnapshotRequired("wrong_board")
    if cursor_generation != generation:
        raise SnapshotRequired("stale_generation")
    if event_id > head_event_id(conn):
        raise SnapshotRequired("ahead_of_log")
    oldest = conn.execute("SELECT MIN(id) FROM task_events").fetchone()[0]
    if oldest is not None and event_id + 1 < oldest:
        raise SnapshotRequired("expired")
    return event_id


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


def events_after(conn, gateway_id: str, slug: str, after: int, limit: int, task_id: Optional[str]) -> tuple[list[dict], bool]:
    kb = _kb()
    sql, args = "SELECT * FROM task_events WHERE id > ?", [after]
    if task_id is not None:
        sql, args = sql + " AND task_id = ?", [*args, task_id]
    rows = conn.execute(sql + " ORDER BY id LIMIT ?", [*args, limit + 1]).fetchall()
    return [event_row(gateway_id, slug, kb.Event.from_row(row)) for row in rows[:limit]], len(rows) > limit


def card_summary(gateway_id: str, slug: str, task, *, governed: bool) -> dict:
    return {
        "card_id": card_id(gateway_id, slug, task.id), "task_id": task.id, "title": task.title,
        "status": task.status, "assignee": task.assignee, "priority": task.priority,
        "created_at": task.created_at, "started_at": task.started_at, "completed_at": task.completed_at,
        "block_kind": task.block_kind, "governed": governed,
    }


def snapshot(conn, gateway_id: str, slug: str, generation: str, limit: int) -> dict:
    kb = _kb()
    rows = conn.execute("SELECT * FROM tasks ORDER BY created_at, id LIMIT ?", (limit + 1,)).fetchall()
    shown = rows[:limit]
    ids = {row["id"] for row in shown}
    edges = [{"task_id": row["child_id"], "requires_task_id": row["parent_id"]}
             for row in conn.execute("SELECT parent_id, child_id FROM task_links ORDER BY parent_id, child_id")
             if row["child_id"] in ids and row["parent_id"] in ids]
    cards = [card_summary(gateway_id, slug, kb.Task.from_row(row), governed=bool(row["outcome_contract"]))
             for row in shown]
    return {"cards": cards, "prerequisites": edges, "truncated": len(rows) > limit,
            "cursor": encode_cursor(gateway_id, slug, generation, head_event_id(conn))}


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


def _latest_event(conn, task_id: str, kind: str):
    row = conn.execute("SELECT * FROM task_events WHERE task_id = ? AND kind = ? ORDER BY id DESC LIMIT 1",
                       (task_id, kind)).fetchone()
    return _kb().Event.from_row(row) if row else None


def ci_acceptance(conn, task_id: str) -> dict:
    event = _latest_event(conn, task_id, "pr_acceptance")
    payload = event.payload if event and isinstance(event.payload, dict) else None
    if payload is None or not isinstance(payload.get("ok"), bool):
        return {"state": "unknown", "classification": None, "run_id": None, "observed_at": None, "event_id": None}
    return {"state": "accepted" if payload["ok"] else "rejected", "classification": scrub(payload.get("classification")),
            "run_id": event.run_id, "observed_at": event.created_at, "event_id": event.id}


def outcome_verification(conn, task_id: str, contract: Optional[dict]) -> dict:
    blank = {"verification": None, "receipt": None, "run_id": None, "observed_at": None, "event_id": None}
    if contract is None:
        return {"state": "not_governed", **blank}
    event = _latest_event(conn, task_id, "outcome_verified")
    stored = event.payload if event and isinstance(event.payload, dict) else {}
    receipt = stored.get("verified") if isinstance(stored.get("verified"), dict) else None
    if receipt is None:
        refused = _latest_event(conn, task_id, "outcome_refused")
        return {**blank, "state": "refused" if refused else "unknown"}
    label = receipt.get("verification")
    return {"state": "verified", "verification": label if label in ("independent", "attested") else "unknown",
            "receipt": scrub({key: receipt[key] for key in _RECEIPT_FIELDS if key in receipt}),
            "run_id": event.run_id, "observed_at": event.created_at, "event_id": event.id}


def card_detail(conn, gateway_id: str, slug: str, generation: str, task_id: str) -> Optional[dict]:
    kb = _kb()
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        return None
    task = kb.Task.from_row(row)
    contract = _contract(task)
    parents = [r[0] for r in conn.execute("SELECT parent_id FROM task_links WHERE child_id = ? ORDER BY parent_id", (task_id,))]
    children = [r[0] for r in conn.execute("SELECT child_id FROM task_links WHERE parent_id = ? ORDER BY child_id", (task_id,))]
    return {
        "card": card_summary(gateway_id, slug, task, governed=contract is not None),
        "body": scrub(task.body), "result": scrub(task.result), "branch_name": task.branch_name,
        "lifecycle": {"status": task.status, "assignee": task.assignee, "block_kind": task.block_kind,
                      "created_at": task.created_at, "started_at": task.started_at,
                      "completed_at": task.completed_at},
        "execution": {"current_run_id": task.current_run_id, "claim_expires": task.claim_expires,
                      "runs": _runs(conn, task_id)},
        "outcome_contract": contract,
        "ci_acceptance": ci_acceptance(conn, task_id),
        "outcome_verification": outcome_verification(conn, task_id, contract),
        "evidence": evidence_rows(conn, task_id, None),
        "prerequisites": parents, "dependents": children,
        "cursor": encode_cursor(gateway_id, slug, generation, head_event_id(conn)),
    }


def task_exists(conn, task_id: str) -> bool:
    return conn.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,)).fetchone() is not None
