from __future__ import annotations

from typing import Any, Optional

from gateway.audience import SenderFacts


def _workspace_id(value: Any) -> str:
    return value if isinstance(value, str) and value.startswith("T") else ""


def sender_facts(
    user: Any, *, user_id: str, install_team: str, event_author_team: Any, declared_bot: bool,
) -> Optional[SenderFacts]:
    if not isinstance(user, dict) or not user_id or user.get("id") != user_id or user.get("deleted") is True:
        return None
    home = _workspace_id(user.get("team_id"))
    scope = _workspace_id(install_team)
    if not home or not scope:
        return None
    claimed = _workspace_id(event_author_team)
    if claimed and claimed != home:
        return None
    profile = user.get("profile") if isinstance(user.get("profile"), dict) else {}
    name = profile.get("display_name") or profile.get("real_name") or user.get("real_name") or user.get("name") or user_id
    return SenderFacts(
        user_id=user_id,
        scope_id=scope,
        same_scope=home == scope,
        is_bot=bool(declared_bot or user.get("is_bot") or user.get("is_workflow_bot") or profile.get("bot_id")),
        is_restricted=bool(user.get("is_restricted") or user.get("is_ultra_restricted")),
        display_name=str(name),
    )
