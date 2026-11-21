from __future__ import annotations

import re
from dataclasses import dataclass

from tools.mcp_action_gate import ActionPolicy
from tools.mcp_connector_policy import (
    ALL_TOOLS, GROUP_NEVER, GROUP_TOOL, GROUP_WRITE, GROUPS, MODES, OFF, POLICY_KEY, group_of, parse, with_mode)
from tui_gateway.contracts.connectors import (
    ConnectorDetailsPolicy, ConnectorDetailsPolicySetResult, ConnectorDetailsResult, ConnectorDetailsSkill,
    ConnectorDetailsTool, ConnectorErrorReason)

_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_WORD_BREAKS = re.compile(r"[_\-\s]+")
_NOT_CONNECTED = (4041, ConnectorErrorReason.connection_not_found, "Connect this app first.")


class DetailsRpcError(Exception):
    def __init__(self, code: int, reason: ConnectorErrorReason, message: str):
        super().__init__(reason.value)
        self.code, self.reason, self.message = code, reason, message


@dataclass(frozen=True)
class _Connector:
    slug: str
    template: dict | None
    action_policy: ActionPolicy | None

    def tools(self) -> dict[str, str]:
        if self.template is None:
            return {}
        from tools.mcp_known_tools import known_tools
        hidden = {name: desc for names in parse(self.template.get(POLICY_KEY)).excluded.values()
                  for name, desc in names.items() if name != ALL_TOOLS}
        return {**hidden, **known_tools(self.slug, self.template)}

    def policy_view(self, tools: dict[str, str]) -> ConnectorDetailsPolicy:
        modes = parse((self.template or {}).get(POLICY_KEY)).modes
        present = {group_of(self.action_policy, name) for name in tools} - {GROUP_NEVER}
        return ConnectorDetailsPolicy(**{group: modes[group] for group in GROUPS if group in present})


def humanize(name: str, slug: str | None = None) -> str:
    text = name
    for prefix in (f"mcp__{slug}__", f"mcp_{slug}_", f"{slug}_", f"{slug}-") if slug else ():
        if text.lower().startswith(prefix) and len(text) > len(prefix):
            text = text[len(prefix):]
            break
    words = [w for w in _WORD_BREAKS.split(_CAMEL_BOUNDARY.sub(" ", text)) if w]
    sentence = " ".join(w if w.isupper() and len(w) > 1 else w.lower() for w in words)
    return sentence[:1].upper() + sentence[1:] if sentence else name


def _connector(slug: str) -> _Connector:
    from hermes_cli import mcp_catalog
    from hermes_cli.mcp_config import _get_mcp_servers
    from hermes_cli.pal_connectors import load_pal_connectors
    from tools.mcp_action_gate import policy_from_config

    if slug not in {entry.id for entry in load_pal_connectors()}:
        raise DetailsRpcError(4041, ConnectorErrorReason.connector_not_found, "Connector not found.")
    configured = _get_mcp_servers().get(slug)
    if isinstance(configured, dict):
        return _Connector(slug, configured, policy_from_config(configured))
    manifest = mcp_catalog.get_entry(slug)
    spec = manifest.action_policy if manifest else None
    policy = ActionPolicy.from_config({
        "read_tools": list(spec.read_tools), "refused_tools": list(spec.refused_tools),
        "refused_message": spec.refused_message}) if spec else None
    return _Connector(slug, None, policy)


def _skills(slug: str) -> list[ConnectorDetailsSkill]:
    from agent.skill_utils import CONNECTOR_KIND_HOSTED, CONNECTOR_KIND_MCP
    from tools.skills_tool import _skill_catalog

    named = (CONNECTOR_KIND_MCP, CONNECTOR_KIND_HOSTED)
    rows = [row for row in _skill_catalog(skip_connector_gate=True)
            if row["load_name"] and any(ref.kind in named and ref.name == slug for ref in row.get("connectors", ()))]
    return sorted((ConnectorDetailsSkill(name=row["load_name"], title=humanize(row["load_name"]),
                                         description=row["description"] or "") for row in rows),
                  key=lambda skill: skill.title)


def details(slug: str) -> ConnectorDetailsResult:
    connector = _connector(slug)
    tools = connector.tools()
    rows = sorted((ConnectorDetailsTool(name=name, title=humanize(name, slug), description=description,
                                        group=group_of(connector.action_policy, name))
                   for name, description in tools.items()),
                  key=lambda row: (GROUPS.index(row.group.value), row.name))
    return ConnectorDetailsResult(
        slug=slug, grouped=connector.action_policy is not None, tools_known=bool(tools), tools=rows,
        policy=connector.policy_view(tools), skills=_skills(slug))


def _invalid(message: str) -> DetailsRpcError:
    return DetailsRpcError(4000, ConnectorErrorReason.invalid_policy, message)


def set_mode(slug: str, group: str, mode: str) -> ConnectorDetailsPolicySetResult:
    from hermes_cli.mcp_accounts import update_template

    connector = _connector(slug)
    if group == GROUP_NEVER:
        raise _invalid("Steps that are never allowed have no setting.")
    if mode not in MODES[group]:
        raise _invalid("That setting is not available for this group.")
    if (group == GROUP_TOOL) == (connector.action_policy is not None):
        raise _invalid("This connector does not have that group.")
    if connector.template is None:
        raise DetailsRpcError(*_NOT_CONNECTED)
    tools = connector.tools()
    if mode == OFF and group == GROUP_WRITE and not tools:
        raise DetailsRpcError(5034, ConnectorErrorReason.tools_unavailable,
                              "This app's tools are not known yet, so they cannot be turned off.")

    def mutate(current):
        if current is None:
            raise DetailsRpcError(*_NOT_CONNECTED)
        return with_mode(current, group, mode, connector.action_policy, tools)

    if not update_template(slug, mutate):
        raise DetailsRpcError(5034, ConnectorErrorReason.connector_request_failed,
                              "Connector request failed. Try again explicitly.")
    refreshed = _connector(slug)
    return ConnectorDetailsPolicySetResult(ok=True, policy=refreshed.policy_view(refreshed.tools()))
