from __future__ import annotations

from pathlib import Path
from typing import Optional

from tools.bot_dm_wire import split_sender_stamp
from tools.bot_thread_identity import inbound
from tools.bot_thread_ledger import Direction, ExchangeKey, Outcome, Status, record_message, record_outcome

_TERMINAL = {"settled", "failed", "cancelled"}


def outcome_from_receipt(receipt: dict) -> Optional[Outcome]:
    status = receipt.get("status")
    if status == "settled":
        return Outcome.answered(str(receipt.get("reply") or ""))
    if status in ("failed", "cancelled"):
        return Outcome.failed(str(receipt.get("reason") or ""))
    return None


def mirror_receipt(home: Path | str, previous: Optional[dict], receipt: dict) -> None:
    key = ExchangeKey.of(Direction.inbound, receipt.get("delivery_id"))
    if key is None or not receipt.get("admission_id"):
        return
    if not (previous or {}).get("admission_id"):
        from tools.bot_relay import read_remote_roster
        message = str(receipt.get("message") or "")
        stamp = split_sender_stamp(message)
        counterpart = inbound(receipt.get("author"), stamp, read_remote_roster(home))
        if counterpart is None:
            return
        record_message(home, key, counterpart, stamp.body if stamp else message, status=Status.delivered,
                       anchor_session_id=receipt.get("session_id") or None)
    if receipt.get("status") in _TERMINAL and receipt.get("status") != (previous or {}).get("status"):
        outcome = outcome_from_receipt(receipt)
        if outcome is not None:
            record_outcome(home, key, outcome)
