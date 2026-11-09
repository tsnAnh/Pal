from __future__ import annotations

import os
from typing import Optional


def external_worker_execution(job: dict, adapters, targets: list) -> str:
    from cron.scheduler_delivery import BOT_CHAT_PLATFORM, ROOM_PLATFORM

    external_execution = os.environ.get("_HERMES_CRON_EXTERNAL_WORKER", "")
    if (external_execution and adapters is None
            and external_execution == str(job.get("execution_id") or "")
            and any(target["platform"] not in (BOT_CHAT_PLATFORM, ROOM_PLATFORM) for target in targets)):
        return external_execution
    return ""


def deliver_via_external_queue(job: dict, content: str, external_execution: str, for_failure: bool) -> Optional[str]:
    from cron.delivery_queue import enqueue_and_wait, get_status
    from cron.jobs import get_job
    from cron.scheduler_delivery import _record_delivery_verification

    _record_delivery_verification(job, [])
    error = enqueue_and_wait(external_execution, job, content, for_failure=for_failure)
    delivery_status = get_status(external_execution)
    if delivery_status and delivery_status["status"] == "suppressed":
        job["_notification_all_targets_suppressed"] = True
    refreshed = get_job(job["id"]) or {}
    job["last_delivery_queued"] = refreshed.get("last_delivery_queued")
    return error


def deliver_bot_chat_target(
    job: dict, content: str, target: dict, for_failure: bool, delivery_errors: list, unverified_targets: list
) -> int:
    from cron.scheduler_delivery import _deliver_to_bot_chat

    bot_chat_error = _deliver_to_bot_chat(job, content, target["chat_id"], for_failure=for_failure)
    suppressed = job.pop("_notification_all_targets_suppressed", False)
    if bot_chat_error:
        receipt_target = f"bot-chat:{target['chat_id'] or '(own)'}"
        receipt = job.get("_bot_chat_delivery_receipts", {}).get(receipt_target)
        if not receipt or receipt["status"] not in ("queued", "claimed"):
            delivery_errors.append(bot_chat_error)
        if receipt and receipt["status"] == "ambiguous":
            unverified_targets.append(bot_chat_error)
    return suppressed
