from __future__ import annotations

from typing import Any, Iterable, Mapping, Optional

CREATED_BY_USER = "user"
CREATED_BY_AGENT = "agent"
CREATED_BY_SUGGESTION = "suggestion"
CREATED_BY_VALUES = (CREATED_BY_USER, CREATED_BY_AGENT, CREATED_BY_SUGGESTION)
AGENT_EDITED_FIELDS = "agent_edited_fields"
TARGET_FIELDS = frozenset({"deliver", "origin"})
INSTRUCTION_FIELDS = frozenset({"prompt", "skills", "script", "monitor_script", "monitor_url", "context_from",
                                "workdir"})
OWNER_TEXT_FIELDS = TARGET_FIELDS | INSTRUCTION_FIELDS


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


def with_agent_edits(job: Mapping[str, Any], fields: Iterable[str]) -> list[str]:
    return sorted(set(job.get(AGENT_EDITED_FIELDS) or ()) | (OWNER_TEXT_FIELDS & set(fields)))


def _comparable(value: Any) -> Any:
    return (value.strip() if isinstance(value, str) else value) or None


def changed_owner_fields(before: Mapping[str, Any], after: Mapping[str, Any]) -> set[str]:
    return {field for field in OWNER_TEXT_FIELDS if _comparable(before.get(field)) != _comparable(after.get(field))}


def merged_update(job: Mapping[str, Any], updates: Mapping[str, Any]) -> dict[str, Any]:
    # A form re-saves every field, so only a changed value counts as the owner writing it.
    merged = {**job, **updates}
    if AGENT_EDITED_FIELDS not in updates:
        owned = changed_owner_fields(job, merged)
        if kept := [field for field in job.get(AGENT_EDITED_FIELDS) or () if field not in owned]:
            merged[AGENT_EDITED_FIELDS] = kept
        else:
            merged.pop(AGENT_EDITED_FIELDS, None)
    return merged


def written_by_owner(job: Mapping[str, Any]) -> bool:
    # Stricter than ``created_by_of``: a record with no stored provenance cannot show who wrote it.
    return (job.get("created_by") == CREATED_BY_USER
            and not INSTRUCTION_FIELDS & set(job.get(AGENT_EDITED_FIELDS) or ()))


def set_by_owner(job: Mapping[str, Any], field: str) -> bool:
    return field not in (job.get(AGENT_EDITED_FIELDS) or ())
