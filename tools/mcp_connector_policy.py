from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Optional

from tools.mcp_action_gate import ACTION, READ, REFUSED, ActionPolicy

logger = logging.getLogger(__name__)

POLICY_KEY = "connector_policy"
EXCLUDED_KEY = "excluded"
ALL_TOOLS = "*"

GROUP_READ, GROUP_WRITE, GROUP_NEVER, GROUP_TOOL = "read", "write", "never", "tool"
GROUPS = (GROUP_READ, GROUP_WRITE, GROUP_NEVER, GROUP_TOOL)
GROUP_OF_KIND = {READ: GROUP_READ, ACTION: GROUP_WRITE, REFUSED: GROUP_NEVER}

MODES = {GROUP_READ: ("auto", "ask", "off"), GROUP_WRITE: ("ask", "off"), GROUP_TOOL: ("on", "off")}
DEFAULT_MODES = {GROUP_READ: "auto", GROUP_WRITE: "ask", GROUP_TOOL: "on"}
UNREADABLE_MODES = {GROUP_READ: "ask", GROUP_WRITE: "ask", GROUP_TOOL: "on"}
OFF = "off"
ASK = "ask"
_DESCRIPTION_MAX_CHARS = 400


@dataclass(frozen=True)
class ConnectorPolicy:
    modes: Mapping[str, str] = field(default_factory=lambda: dict(DEFAULT_MODES))
    excluded: Mapping[str, Mapping[str, str]] = field(default_factory=dict)

    def mode(self, group: str) -> str:
        return self.modes[group]


def parse(raw: Any) -> ConnectorPolicy:
    raw = raw if isinstance(raw, Mapping) else {}
    modes = {}
    for group, allowed in MODES.items():
        value = raw.get(group)
        modes[group] = value if value in allowed else DEFAULT_MODES[group] if value is None else UNREADABLE_MODES[group]
    ledger = raw.get(EXCLUDED_KEY)
    excluded: dict[str, dict[str, str]] = {}
    if isinstance(ledger, Mapping):
        for group in MODES:
            names = ledger.get(group)
            if isinstance(names, Mapping):
                excluded[group] = {str(n): d if isinstance(d, str) else "" for n, d in names.items()}
    return ConnectorPolicy(modes, excluded)


def serialize(policy: ConnectorPolicy) -> Optional[dict]:
    out: dict[str, Any] = {g: m for g, m in policy.modes.items() if m != DEFAULT_MODES[g]}
    ledger = {g: dict(names) for g, names in policy.excluded.items() if names}
    if ledger:
        out[EXCLUDED_KEY] = ledger
    return out or None


def group_of(action_policy: Optional[ActionPolicy], tool_name: str) -> str:
    return GROUP_OF_KIND[action_policy.classify(tool_name)] if action_policy is not None else GROUP_TOOL


def clean_description(value: Any) -> str:
    text = " ".join(value.split()) if isinstance(value, str) else ""
    return text if len(text) <= _DESCRIPTION_MAX_CHARS else text[:_DESCRIPTION_MAX_CHARS].rstrip() + "..."


def _names_to_hide(group: str, action_policy: Optional[ActionPolicy], tools: Mapping[str, str]) -> dict[str, str]:
    if group == GROUP_TOOL:
        return {ALL_TOOLS: "", **tools}
    hidden = {name: desc for name, desc in tools.items() if group_of(action_policy, name) == group}
    if group == GROUP_READ and action_policy is not None:
        hidden.update({name: tools.get(name, "") for name in action_policy.read_tools})
    return hidden


def with_mode(template: Mapping, group: str, mode: str, action_policy: Optional[ActionPolicy],
              tools: Mapping[str, str]) -> dict:
    current = parse(template.get(POLICY_KEY))
    tools_block = dict(template.get("tools") or {}) if isinstance(template.get("tools"), Mapping) else {}
    exclude = [n for n in (tools_block.get("exclude") or []) if isinstance(n, str)]
    mine = set(current.excluded.get(group, {}))
    exclude = [n for n in exclude if n not in mine]
    ledger = {g: dict(names) for g, names in current.excluded.items() if g != group}
    if mode == OFF:
        added = {n: clean_description(d) for n, d in _names_to_hide(group, action_policy, tools).items()
                 if n not in exclude}
        exclude += list(added)
        ledger[group] = added
    if exclude:
        tools_block["exclude"] = exclude
    else:
        tools_block.pop("exclude", None)
    updated = {k: v for k, v in template.items() if k not in (POLICY_KEY, "tools")}
    if tools_block:
        updated["tools"] = tools_block
    stored = serialize(ConnectorPolicy({**current.modes, group: mode}, ledger))
    if stored is not None:
        updated[POLICY_KEY] = stored
    return updated


def reads_need_approval(server_name: str, key: Any) -> bool:
    try:
        from hermes_cli.config_backend import read_config_doc_readonly
        from hermes_constants import get_hermes_home
        from tools.mcp_accounts import registration_name
        from tools.mcp_tool_scope import _key_scope
        scope = _key_scope(key)
        home = Path(scope) if scope and Path(scope).is_absolute() else get_hermes_home()
        try:
            doc = read_config_doc_readonly(home / "config.yaml")
        except FileNotFoundError:
            return False
        servers = doc.get("mcp_servers") if isinstance(doc, dict) else None
        template = servers.get(registration_name(server_name)) if isinstance(servers, dict) else None
        raw = template.get(POLICY_KEY) if isinstance(template, dict) else None
        return parse(raw).mode(GROUP_READ) == ASK
    except Exception as exc:  # health: allow BLE001 -- an unreadable setting must ask, never run the read silently
        logger.warning("Connector read policy unreadable for '%s' (%s); reads ask", server_name, type(exc).__name__)
        return True
