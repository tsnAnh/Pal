from __future__ import annotations

import contextlib
import json
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Optional

from tools.bot_thread_identity import CounterpartRef
from tools.bot_thread_ledger import Direction, ExchangeKey, Outcome, Status, record_message, record_outcome

_FAILED_STATUSES = frozenset({"failed", "cancelled", "refused"})
_OPEN_STATUSES = frozenset({"queued", "claimed", "ambiguous"})


@dataclass(frozen=True, slots=True)
class Handoff:
    home: Path
    body: str
    anchor_session_id: Optional[str]
    counterpart: Optional[CounterpartRef] = None

    def to(self, counterpart: CounterpartRef) -> Handoff:
        return replace(self, counterpart=counterpart)

    def sent(self, delivery_id: str, status: Status) -> None:
        key = ExchangeKey.of(Direction.outbound, delivery_id)
        if self.counterpart is None or key is None:
            return
        record_message(self.home, key, self.counterpart, self.body, status=status,
                       anchor_session_id=self.anchor_session_id)

    def failed_to_start(self, delivery_id: str, ack: str) -> None:
        try:
            refusal = json.loads(ack)
        except ValueError:
            return
        if isinstance(refusal, dict) and refusal.get("error"):
            settle(self.home, delivery_id, Outcome.failed(str(refusal.get("reason") or "")))


def settle(home: Path | str, delivery_id: str, outcome: Outcome, *, learned_origin: Optional[str] = None) -> None:
    key = ExchangeKey.of(Direction.outbound, delivery_id)
    if key is not None:
        record_outcome(home, key, outcome, learned_origin=learned_origin)


def outcome_from_live_payload(payload: dict) -> Outcome:
    status = str(payload.get("status") or "")
    if status == "settled":
        return Outcome.answered(str(payload.get("reply") or ""))
    if status in _FAILED_STATUSES:
        return Outcome.failed(str(payload.get("reason") or ""))
    return Outcome.unknown()


def outcome_from_peer_result(result: dict) -> Outcome:
    status = str(result.get("status") or "")
    if status == "settled":
        return Outcome.answered(str(result.get("reply") or ""))
    if status == "failed":
        return Outcome.failed(str(result.get("reason") or ""))
    return Outcome.unknown()


def read_peer_result(path: str) -> Optional[dict]:
    try:
        with open(path, encoding="utf-8-sig") as stream:
            result = json.load(stream)
    except (OSError, ValueError):
        return None
    finally:
        with contextlib.suppress(OSError):
            os.unlink(path)
    return result if isinstance(result, dict) else None
