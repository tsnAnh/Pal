from __future__ import annotations

import logging
import math
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

HISTORY_LIMIT = 20
OUTPUT_MAX_CHARS = 20000
REASON_MAX_CHARS = 240
_LEDGER_WINDOW = 100
_DOC_GRACE_SECONDS = 300.0
_OUTPUT_FILENAME_FORMAT = "%Y-%m-%d_%H-%M-%S"

STATUS_RUNNING = "running"
STATUS_SUCCEEDED = "succeeded"
STATUS_FAILED = "failed"
STATUS_CANCELLED = "cancelled"

_INTERRUPTED_REASON = "The run stopped before it finished."
_NO_REASON = "The run did not complete."


class RunNotFound(LookupError):
    pass


def _epoch(value: Any) -> Optional[float]:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return datetime.fromisoformat(value.strip()).timestamp()
    except ValueError:
        return None


def _doc_epoch(path: Path) -> Optional[float]:
    from hermes_time import get_timezone

    try:
        naive = datetime.strptime(path.stem, _OUTPUT_FILENAME_FORMAT)
    except ValueError:
        return None
    zone = get_timezone()
    return naive.replace(tzinfo=zone).timestamp() if zone is not None else naive.astimezone().timestamp()


def _output_docs(job_id: str) -> list[tuple[float, Path]]:
    from cron.jobs import _job_output_dir

    try:
        files = [path for path in _job_output_dir(job_id).glob("*.md") if path.is_file()]
    except (OSError, ValueError):
        return []
    docs = [(stamp, path) for path in files if (stamp := _doc_epoch(path)) is not None]
    docs.sort(key=lambda item: item[0], reverse=True)
    return docs


def _attempt_window(row: dict[str, Any]) -> tuple[float, Optional[float]]:
    return _epoch(row.get("claimed_at")) or 0.0, _epoch(row.get("finished_at"))


def _doc_belongs_to(doc_stamp: float, row: dict[str, Any]) -> bool:
    claimed, finished = _attempt_window(row)
    if doc_stamp + 0.001 < math.floor(claimed):
        return False
    return finished is None or doc_stamp <= finished + _DOC_GRACE_SECONDS


def _pair_outputs(rows: list[dict[str, Any]], docs: list[tuple[float, Path]]) -> dict[str, Path]:
    """One output doc per attempt. A doc never records its execution, so it is matched to the attempt
    whose window holds its timestamp; the newest such claim wins and an attempt takes at most one doc."""
    paired: dict[str, Path] = {}
    for stamp, path in docs:
        candidates = [row for row in rows if row["id"] not in paired and _doc_belongs_to(stamp, row)]
        if not candidates:
            continue

        def likelihood(row: dict[str, Any]) -> tuple:
            claimed, finished = _attempt_window(row)
            return (finished is not None and stamp > finished, -claimed)

        paired[min(candidates, key=likelihood)["id"]] = path
    return paired


def _bounded_reason(error: Any, fallback: str) -> str:
    from agent.redact import redact_sensitive_text

    text = " ".join(str(error or "").split())
    if not text:
        return fallback
    text = redact_sensitive_text(text, force=True, redact_url_credentials=True)
    return text if len(text) <= REASON_MAX_CHARS else text[: REASON_MAX_CHARS - 1].rstrip() + "…"


def _public_status(row: dict[str, Any], job_id: str) -> tuple[str, Optional[str]]:
    from cron.executions import execution_owner_live

    state = str(row.get("status") or "")
    if state in ("claimed", "running"):
        if execution_owner_live(str(row["id"]), job_id):
            return STATUS_RUNNING, None
        return STATUS_FAILED, _INTERRUPTED_REASON
    if state == "completed":
        return STATUS_SUCCEEDED, None
    if state == "cancelled":
        return STATUS_CANCELLED, _bounded_reason(row.get("error"), "")
    if state == "unknown":
        return STATUS_FAILED, _INTERRUPTED_REASON
    return STATUS_FAILED, _bounded_reason(row.get("error"), _NO_REASON)


def _iso(epoch: Optional[float]) -> Optional[str]:
    return datetime.fromtimestamp(epoch).astimezone().isoformat() if epoch is not None else None


def _run_record(row: dict[str, Any], job_id: str, has_output: bool) -> dict[str, Any]:
    status, reason = _public_status(row, job_id)
    started = _epoch(row.get("started_at")) or _epoch(row.get("claimed_at"))
    finished = _epoch(row.get("finished_at"))
    duration = round(max(0.0, finished - started), 1) if started is not None and finished is not None else None
    return {
        "run_id": str(row["id"]),
        "status": status,
        "reason": reason or None,
        "started_at": _iso(started),
        "finished_at": _iso(finished),
        "duration_seconds": duration,
        "has_output": has_output,
    }


def _attempts(job_id: str) -> list[dict[str, Any]]:
    from cron.executions import list_executions

    rows = list_executions(job_id=job_id, limit=_LEDGER_WINDOW)
    return [row for row in rows if row.get("status") != "missed"]


def list_job_runs(job_id: str, limit: int = HISTORY_LIMIT) -> list[dict[str, Any]]:
    """The job's most recent attempts, newest first, bounded to ``HISTORY_LIMIT``. Statuses are
    running / succeeded / failed (with a short reason) / cancelled; no filesystem path is exposed."""
    try:
        bound = max(1, min(int(limit), HISTORY_LIMIT))
    except (TypeError, ValueError):
        bound = HISTORY_LIMIT
    rows = _attempts(job_id)
    paired = _pair_outputs(rows, _output_docs(job_id))
    return [_run_record(row, job_id, row["id"] in paired) for row in rows[:bound]]


def read_run_output(job_id: str, run_id: str, max_chars: int = OUTPUT_MAX_CHARS) -> dict[str, Any]:
    """The saved output text of one attempt, bounded and redacted. Raises ``RunNotFound`` when the
    attempt is unknown to this job or wrote no output (or it was pruned)."""
    from agent.redact import redact_sensitive_text

    rows = _attempts(job_id)
    row = next((candidate for candidate in rows[:HISTORY_LIMIT] if candidate["id"] == str(run_id)), None)
    if row is None:
        raise RunNotFound("That run is no longer in the history.")
    path = _pair_outputs(rows, _output_docs(job_id)).get(row["id"])
    if path is None:
        raise RunNotFound("This run did not save any output.")
    try:
        raw = path.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as exc:
        raise RunNotFound("This run's output could not be read.") from exc
    text = redact_sensitive_text(raw.strip())
    limit = max(1, min(int(max_chars), OUTPUT_MAX_CHARS))
    truncated = len(text) > limit
    return {"run_id": row["id"], "output": text[:limit], "truncated": truncated}
