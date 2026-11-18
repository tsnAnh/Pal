"""The readable card a cron output carries into the Bot Chat row (``bot_relay.deliver``'s ``routine``)."""
from __future__ import annotations

from typing import Optional


def bot_chat_routine(job: dict, content: str, *, for_failure: bool, finished_at: Optional[float]) -> Optional[dict]:
    """The job as sender, its status, the finish time and the whole output, scrubbed as
    ``bot_chat_message`` scrubs it. ``None`` (the row stays a plain notification) when there is no
    output or no finish time to show."""
    from cron.scheduler_delivery import _redact_cron_payload
    if not finished_at or not content.strip():
        return None
    job_name = _redact_cron_payload(job.get("name") or job.get("id") or "?", "job name")
    return {"job_name": job_name[:200], "status": "failed" if for_failure else "ok",
            "finished_at": finished_at, "text": _redact_cron_payload(content, "bot-chat payload")}
