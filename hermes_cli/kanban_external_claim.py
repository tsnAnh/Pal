"""Claim, heartbeat and run-ownership checks for coordinator-owned (``external``) boards.

A coordinator is a long-lived named profile that executes elsewhere. Its run carries
``executor='external'`` and no PID; the claim lock is ``external:<profile>:<nonce>`` so the
dispatcher's PID-based crash sweeps never see it and only the claim TTL reclaims it.
Identity is always the bound profile, never a caller-supplied value.
"""
from __future__ import annotations

import time
import uuid
from typing import Optional

from hermes_cli.kanban_board_mode import board_dispatch_mode
from hermes_cli.kanban_db_connect import write_txn

EXECUTOR = "external"


class ExternalClaimError(ValueError):
    def __init__(self, reason: str, detail: str):
        self.reason, self.detail = reason, detail
        super().__init__(f"external claim refused ({reason}): {detail}")


class ExternalRunFenceError(ValueError):
    pass


def bound_profile() -> Optional[str]:
    from hermes_cli.profiles import current_profile_name
    return current_profile_name(None)


def require_named_profile(profile: Optional[str]) -> str:
    from hermes_cli.profiles import normalize_profile_name
    if not isinstance(profile, str) or not profile.strip():
        raise ExternalClaimError("no_profile", "no profile is bound to this call; run as the project's named profile")
    name = normalize_profile_name(profile)
    if name == "default":
        raise ExternalClaimError("default_profile", "the default profile cannot act as a coordinator; run as the project's named profile")
    return name


def claim_external(conn, task_id: str, *, profile: Optional[str], session_id: Optional[str] = None,
                   ttl_seconds: Optional[int] = None, board: Optional[str] = None):
    """``ready -> running`` for the bound coordinator profile; ``None`` when another claimant won."""
    from hermes_cli import kanban_db as kb
    name = require_named_profile(profile)
    if board_dispatch_mode(board) != EXECUTOR:
        raise ExternalClaimError("not_external_board", "this board is not coordinator-owned (dispatch_mode=external)")
    now = int(time.time())
    expires = now + kb._resolve_claim_ttl_seconds(ttl_seconds)
    lock = f"{EXECUTOR}:{name}:{uuid.uuid4().hex}"
    with write_txn(conn):
        row = conn.execute("SELECT assignee, status FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None:
            raise ExternalClaimError("unknown_task", f"no such task: {task_id}")
        if not row["assignee"]:
            raise ExternalClaimError("unassigned", "the card has no assignee; assign it to the coordinator profile first")
        if row["assignee"] != name:
            raise ExternalClaimError("wrong_profile", f"the card is assigned to {row['assignee']!r}, not {name!r}")
        if row["status"] == "ready" and not kb._parents_satisfied(conn, task_id):
            raise ExternalClaimError("parents_unmet", "parent cards are not done yet")
        kb._reclaim_dangling_run(conn, task_id, statuses=("ready",), now=now, note="invariant recovery on re-claim")
        run_id = kb._claim_and_open_run(
            conn, task_id, "ready", lock, expires, now,
            event_extra={"executor": EXECUTOR, "profile": name, "session": session_id})
        if run_id is None:
            return None
        conn.execute("UPDATE task_runs SET executor = ?, executor_session = ? WHERE id = ?",
                     (EXECUTOR, session_id, run_id))
        claimed = kb.get_task(conn, task_id)
    kb._fire_task_hook("kanban_task_claimed", claimed, task_id, run_id)
    return claimed


def current_external_run(conn, task_id: str, run_id: int, profile: Optional[str]):
    """The run row when ``run_id`` is the card's live external run owned by ``profile``, else None."""
    from hermes_cli.profiles import normalize_profile_name
    if not isinstance(profile, str) or not profile.strip():
        return None
    return conn.execute(
        "SELECT r.* FROM task_runs r JOIN tasks t ON t.current_run_id = r.id "
        "WHERE t.id = ? AND t.status = 'running' AND r.id = ? AND r.ended_at IS NULL "
        "AND r.executor = ? AND r.profile = ?",
        (task_id, int(run_id), EXECUTOR, normalize_profile_name(profile))).fetchone()


def heartbeat_external(conn, task_id: str, run_id: int, profile: Optional[str], *,
                       note: Optional[str] = None, ttl_seconds: Optional[int] = None) -> bool:
    from hermes_cli import kanban_db as kb
    now = int(time.time())
    expires = now + kb._resolve_claim_ttl_seconds(ttl_seconds)
    with write_txn(conn):
        if current_external_run(conn, task_id, run_id, profile) is None:
            return False
        conn.execute("UPDATE tasks SET claim_expires = ?, last_heartbeat_at = ? WHERE id = ?", (expires, now, task_id))
        conn.execute("UPDATE task_runs SET claim_expires = ?, last_heartbeat_at = ? WHERE id = ?", (expires, now, int(run_id)))
        kb._append_event(conn, task_id, "heartbeat", {"note": note} if note else None, run_id=int(run_id))
    return True
