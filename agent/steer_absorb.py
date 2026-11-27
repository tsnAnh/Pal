from __future__ import annotations

import logging
from typing import Any, MutableSequence, Optional, Sequence

from agent.message_metadata import stamp_message_uid
from agent.prompt_builder import steer_user_row

logger = logging.getLogger("run_agent")

ADMISSION_IDS = "admission_ids"
PART_LENGTHS = "part_lengths"


def batched_input_metadata(parts: Sequence[tuple[Optional[str], str]]) -> dict[str, list]:
    admission_ids = [admission_id for admission_id, _ in parts if admission_id is not None]
    if not admission_ids:
        return {}
    lengths = {PART_LENGTHS: [len(text) for _, text in parts]} if len(admission_ids) == len(parts) else {}
    return {ADMISSION_IDS: admission_ids, **lengths}


def _drained_parts(agent: Any, steer_text: str) -> Sequence[tuple[Optional[str], str]]:
    drained, parts = vars(agent).get("_steer_last_drain") or (None, ())
    return parts if drained == steer_text else ()


def deliver_steer_row(agent: Any, messages: MutableSequence, steer_text: str, *, index: Optional[int] = None) -> None:
    row = steer_user_row(steer_text)
    metadata = batched_input_metadata(_drained_parts(agent, steer_text))
    admission_ids = metadata.get(ADMISSION_IDS)
    if admission_ids:
        row["display_metadata"] = metadata
        stamp_message_uid(row)
    if index is None:
        messages.append(row)
    else:
        messages.insert(index, row)
    callback = getattr(agent, "input_absorbed_callback", None)
    if admission_ids and callback is not None:
        try:
            callback(admission_ids=admission_ids, message_uid=row["message_uid"], text=steer_text,
                     display_kind=row["display_kind"])
        except Exception:
            logger.debug("input_absorbed_callback failed", exc_info=True)
