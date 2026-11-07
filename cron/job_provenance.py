from __future__ import annotations

from typing import Any, Mapping, Optional

CREATED_BY_USER = "user"
CREATED_BY_AGENT = "agent"
CREATED_BY_SUGGESTION = "suggestion"
CREATED_BY_VALUES = (CREATED_BY_USER, CREATED_BY_AGENT, CREATED_BY_SUGGESTION)


def normalize_created_by(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip().lower()
    if text not in CREATED_BY_VALUES:
        raise ValueError(f"created_by must be one of {', '.join(CREATED_BY_VALUES)}.")
    return text


def created_by_of(job: Mapping[str, Any]) -> str:
    value = job.get("created_by")
    return value if value in CREATED_BY_VALUES else CREATED_BY_USER
