from __future__ import annotations

import logging
from typing import Any, MutableSequence, Optional

from agent.message_metadata import stamp_message_uid
from agent.prompt_builder import steer_user_row

logger = logging.getLogger("run_agent")

ADMISSION_IDS = "admission_ids"


def drained_admission_ids(agent: Any, steer_text: str) -> list[str]:
    drained, parts = vars(agent).get("_steer_last_drain") or (None, ())
    if drained != steer_text:
        return []
    return [ticket for ticket, _ in parts if ticket is not None]


def deliver_steer_row(agent: Any, messages: MutableSequence, steer_text: str, *, index: Optional[int] = None) -> None:
    row = steer_user_row(steer_text)
    admission_ids = drained_admission_ids(agent, steer_text)
    if admission_ids:
        row["display_metadata"] = {ADMISSION_IDS: admission_ids}
        stamp_message_uid(row)
    if index is None:
        messages.append(row)
    else:
        messages.insert(index, row)
    callback = getattr(agent, "input_absorbed_callback", None)
    if admission_ids and callback is not None:
        try:
            callback(admission_ids=admission_ids, message_uid=row["message_uid"], text=steer_text)
        except Exception:
            logger.debug("input_absorbed_callback failed", exc_info=True)
