from __future__ import annotations

import logging
import uuid
from functools import partial
from typing import Optional

from cron.job_provenance import CREATED_BY_USER, created_by_of

logger = logging.getLogger("cron.scheduler")

ACTIVE_TOKEN = "active"
REACH_PLATFORM = "reach"
REACH_DOMAIN = "cron"
QUEUED_RECEIPT_STATUSES = ("queued", "claimed")


def is_active_token(value: str) -> bool:
    return (value or "").strip().lower() == ACTIVE_TOKEN


def active_target() -> dict:
    return {"platform": REACH_PLATFORM, "chat_id": "", "thread_id": None}


def _execution_key(job: dict, *, for_failure: bool) -> str:
    execution = job.get("execution_id") or job.setdefault("_reach_run_id", uuid.uuid4().hex)
    return f"cron:{job.get('id', '?')}:{execution}" + (":failure" if for_failure else "")


def _lane(job: dict, content: str, *, for_failure: bool):
    from gateway.reach import DurableLane
    from cron.scheduler_delivery import _deliver_to_bot_chat, _resolve_origin
    origin = _resolve_origin(job) or {}
    if str(origin.get("platform", "")).lower() == "local" and origin.get("chat_id"):
        return DurableLane(session_id=str(origin["chat_id"]))
    return DurableLane(land=partial(_deliver_to_bot_chat, job, content, "", for_failure=for_failure))


def _bot_chat_lane_is_queued(job: dict) -> bool:
    receipt = (job.get("_bot_chat_delivery_receipts") or {}).get("bot-chat:(own)")
    return bool(receipt) and receipt.get("status") in QUEUED_RECEIPT_STATUSES


def deliver_active(job: dict, content: str, *, lane_text: str, alert_text: str,
                   for_failure: bool = False) -> Optional[str]:
    from gateway import reach
    from hermes_constants import get_hermes_home
    consent = reach.Consent.REQUESTED if created_by_of(job) == CREATED_BY_USER else reach.Consent.INITIATED
    item = reach.Offer(
        producer_key=_execution_key(job, for_failure=for_failure), domain=REACH_DOMAIN,
        kind=reach.OfferKind.NOTIFY, consent=consent,
        title=str(job.get("name") or job.get("id") or "Scheduled job"), body=alert_text,
        lane=_lane(job, content, for_failure=for_failure), lane_text=lane_text)
    try:
        delivery = reach.offer_threadsafe(get_hermes_home(), item)
    except Exception as exc:
        logger.warning("Job '%s': active delivery failed", job.get("id", "?"), exc_info=True)
        return f"active delivery failed: {type(exc).__name__}: {exc}"
    if delivery is None:
        return "active delivery needs the gateway that owns this profile; the output is saved in the job's last output"
    if delivery.error and not _bot_chat_lane_is_queued(job):
        return delivery.error
    return None
