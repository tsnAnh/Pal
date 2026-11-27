"""Idempotent detached-result appends: delegation deliveries, completion notes and cron deliveries."""


from __future__ import annotations
import time
from typing import Any, Optional
from persistence.sqlite._holder import StoreHolder
from persistence.sqlite.conversation._store.messages import _bump_session_counters, _check_transcript_write_guards, _message_row_params
from persistence.sqlite.conversation._store.rules import MESSAGE_UID, stamp_message_uid


_LINEAGE_MATCH_SQL = """WITH RECURSIVE lineage(id) AS (SELECT ? UNION
    SELECT s.parent_session_id FROM sessions s JOIN lineage l ON s.id = l.id
    JOIN sessions p ON p.id = s.parent_session_id WHERE p.end_reason = 'compression'
) SELECT m.id FROM messages m JOIN lineage l ON m.session_id = l.id WHERE """


_DELEGATION_DELIVERY_MATCH = ("m.display_kind IN ('async_delegation_complete', 'hidden') AND json_extract(m.display_metadata, "
                              "'$.delegation_id') = ? AND coalesce(json_extract(m.display_metadata, '$.delivery_notice'), '') = ?")


def append_delegation_delivery(holder: StoreHolder, session_id: str, content: str, metadata: dict[str, Any]) -> int:
    """Record a detached API result once, keyed by the event's unit id (not its text or active flag)."""
    delegation_id = metadata.get("delegation_id")
    if not delegation_id:
        raise ValueError("Delegation delivery requires a stable delegation_id")
    kind = "hidden" if metadata.get("presentation_suppressed") else "async_delegation_complete"
    return _append_detached_result(holder, session_id, content, kind, metadata, _DELEGATION_DELIVERY_MATCH,
                                        (delegation_id, metadata.get("delivery_notice", "")))


def append_completion_note(holder: StoreHolder, session_id: str, admission_id: str, content: str, display_kind: str,
                           metadata: dict[str, Any]) -> int:
    """Record an unviewed completion's note once, keyed by its admission (stored as ``completion_admission``)."""
    return _append_detached_result(holder,
        session_id, content, display_kind, {**metadata, "completion_admission": admission_id},
        "json_extract(m.display_metadata, '$.completion_admission') = ?", (admission_id,))


_CRON_DELIVERY_MATCH = ("m.role = 'assistant' AND json_extract(m.display_metadata, '$.cron_delivery.job_id') = ? "
                        "AND json_extract(m.display_metadata, '$.cron_delivery.execution_id') = ?")


def append_cron_delivery(holder: StoreHolder, session_id: str, anchor: str, content: str,
                         metadata: dict[str, Any]) -> Optional[tuple[int, str]]:
    marker = metadata["cron_delivery"]
    reply = {"content": content, "display_metadata": metadata}
    row_id, created = _append_detached_rows(
        holder, session_id, (("user", {"content": anchor, "display_kind": "hidden"}), ("assistant", reply)),
        _CRON_DELIVERY_MATCH, (marker["job_id"], marker["execution_id"]))
    return (row_id, reply[MESSAGE_UID]) if created else None


def _append_detached_result(holder: StoreHolder, session_id: str, content: str, display_kind: str, metadata: dict[str, Any],
                            match_sql: str, params: tuple) -> int:
    msg = {"content": content, "display_kind": display_kind, "display_metadata": metadata}
    return _append_detached_rows(holder, session_id, (("user", msg),), match_sql, params)[0]


def _append_detached_rows(holder: StoreHolder, session_id: str, messages: tuple, match_sql: str,
                          params: tuple) -> tuple[int, bool]:
    """``(row id, created)``: a row ``match_sql`` (a condition on ``m``) finds in the compression lineage is
    returned instead of inserting. Check and insert share the writer transaction, so independent gateway
    processes cannot duplicate it; a live turn refuses it."""
    from persistence.sqlite.conversation._store.messages_sql import _INSERT_MESSAGE_SQL
    rows = []
    for role, msg in messages:
        stamp_message_uid(msg)  # a fresh occurrence: mint its durable id
        rows.append(_message_row_params(holder, session_id, role, msg, None, time.time(), keep_reasoning=True))

    def _do(conn):
        existing = conn.execute(_LINEAGE_MATCH_SQL + match_sql + " LIMIT 1", (session_id, *params)).fetchone()
        if existing is not None:
            return existing[0], False
        _check_transcript_write_guards(holder, conn, session_id, None, reject_active_turn_lease=True)
        ids = [conn.execute(_INSERT_MESSAGE_SQL, row).lastrowid for row in rows]
        _bump_session_counters(conn, session_id, len(ids), 0, unit=len(ids) == 1)
        return ids[-1], True

    return holder._execute_write(_do, patience_s=holder._TRANSCRIPT_WRITE_PATIENCE_S)
