from __future__ import annotations

import uuid

from cron.job_title import job_title

_NAME_LIMIT = 200


def delivery_run_id(job: dict) -> str:
    return str(job.get("execution_id") or job.setdefault("_delivery_run_id", uuid.uuid4().hex))


def cron_delivery(job: dict, content: str) -> dict | None:
    from cron.scheduler_delivery import _redact_cron_payload
    if not content.strip():
        return None
    return {"job_id": str(job.get("id") or "?"), "execution_id": delivery_run_id(job),
            "name": _redact_cron_payload(job_title(job), "job name")[:_NAME_LIMIT],
            "text": _redact_cron_payload(content, "bot-chat payload")}
