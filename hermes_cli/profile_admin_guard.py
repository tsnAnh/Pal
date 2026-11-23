from __future__ import annotations

import os
from typing import MutableMapping

AGENT_TOOL_MARKER_ENV = "HERMES_AGENT_TOOL_CONTEXT"
CREATE_REFUSED_MESSAGE = "Bots are created from the Create Bot form in the app."
CREATING_ACTIONS = frozenset({"create", "import", "install"})


class ProfileAdminDenied(PermissionError):
    pass


def in_agent_context() -> bool:
    if os.environ.get(AGENT_TOOL_MARKER_ENV):
        return True
    from agent.delegation_context import is_delegated_child_process_context
    from tools.approval_context import _is_cron_approval_context
    return (is_delegated_child_process_context() or _is_cron_approval_context()
            or bool((os.environ.get("HERMES_KANBAN_TASK") or "").strip()))


def agent_tool_env(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    env[AGENT_TOOL_MARKER_ENV] = "1"
    return env


def leave_agent_context() -> None:
    os.environ.pop(AGENT_TOOL_MARKER_ENV, None)


def refuse_agent_profile_creation(action: str) -> None:
    if action in CREATING_ACTIONS and in_agent_context():
        raise ProfileAdminDenied(CREATE_REFUSED_MESSAGE)
