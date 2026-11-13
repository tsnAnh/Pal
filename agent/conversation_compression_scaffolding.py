"""Which user-role rows are runtime scaffolding rather than something the person typed."""

from __future__ import annotations

from typing import Any

_SYNTHETIC_USER_PREFIXES = (
    "[System: Your previous response was truncated", "[System: The previous response was cut off",
    "[System: Your previous tool call", "[Your active task list was preserved across context compression]",
    "[IMPORTANT: Background process ",
)


def _message_text(message: Any) -> str:
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            str(part.get("text") or part.get("content") or "") for part in content if isinstance(part, dict)
        )
    return ""


_SYNTHETIC_USER_FLAGS = (
    "_todo_snapshot_synthetic", "_empty_recovery_synthetic", "_verification_stop_synthetic", "_pre_verify_synthetic",
    "_dropped_toolcall_nudge",
)


def has_scaffolding_flag(message: dict) -> bool:
    """A runtime user-role row stamped by its producer (nudges, task-list snapshots)."""
    return any(message.get(f) for f in _SYNTHETIC_USER_FLAGS)


def is_user_role_scaffolding(message: dict) -> bool:
    """A runtime row in the user role, by flag or opening text (nudges, task-list snapshots, single background-process completion and watch-match notices)."""
    return has_scaffolding_flag(message) or _message_text(message).strip().startswith(_SYNTHETIC_USER_PREFIXES)


# Compaction re-injects the todo list verbatim but prunes skills to markers, so
# couple them: tell the model to reload pruned skills BEFORE acting on tasks.
# Lives after TODO_INJECTION_HEADER so it strips with the snapshot next time.
PRUNED_SKILL_RELOAD_NOTICE_HEADER = "[Skills pruned during compression — reload before acting on these tasks]"


def pruned_skill_reload_notice(compressed: list) -> str:
    """Reload notice for skills whose bodies were pruned, or ``""``.
    Scans ``[SKILL_PRUNED: ...]`` markers in the post-compression transcript; first-seen order, deduplicated,
    capped at ``_MAX_PRUNED_SKILL_MARKERS``."""
    from agent.context_compressor import _MAX_PRUNED_SKILL_MARKERS, _extract_pruned_skill_names
    names: list = []
    for message in compressed:
        if not isinstance(message, dict):
            continue
        for name in _extract_pruned_skill_names(_message_text(message)):
            if name not in names:
                names.append(name)
    del names[_MAX_PRUNED_SKILL_MARKERS:]
    if not names:
        return ""
    calls = "; ".join(f"skill_view(name='{name}')" for name in names)
    return (
        f"{PRUNED_SKILL_RELOAD_NOTICE_HEADER}\n"
        "The task list above crossed the compression boundary verbatim, but "
        "the skill instructions that governed it were pruned. Before "
        f"executing any preserved task that depends on these skills, reload "
        f"them first: {calls}. After reloading, re-check that each pending "
        "task is still justified — findings recorded before the boundary may have invalidated it."
    )
