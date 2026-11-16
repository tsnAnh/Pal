"""Completion pre-checks split out of ``hermes_cli.kanban_db`` (origin names are reached late-bound via ``_kb``)."""

from __future__ import annotations

import sqlite3
from typing import Optional


def _substantive_text(value: Optional[str]) -> bool:
    return bool(value is not None and str(value).strip())


def _gate_empty_completion(
    conn: sqlite3.Connection,
    task_id: str,
    *,
    result: Optional[str],
    summary: Optional[str],
) -> None:
    """Refuse a completion that would leave the card with no evidence.

    Review approvals are exempt: a human vouches for the card and
    ``_REVIEW_APPROVED_NOTE`` is the documented record.
    """
    row = conn.execute(
        "SELECT status, result FROM tasks WHERE id = ?",
        (task_id,),
    ).fetchone()
    if row is None:
        return
    if row["status"] == "review":
        return
    stored = row["result"]
    if _substantive_text(result) or _substantive_text(summary) or _substantive_text(stored):
        return
    with _kb.write_txn(conn):
        _kb._append_event(
            conn, task_id, "completion_blocked_empty_result",
            {
                "result_preview": _kb._first_line(result, 200) or None,
                "summary_preview": _kb._first_line(summary, 200) or None,
            },
        )
    raise _kb.EmptyCompletionError(task_id)


# Late-bound origin namespace; imported LAST so this module is fully populated first.
from hermes_cli import kanban_db as _kb
