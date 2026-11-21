from __future__ import annotations

from typing import Any, Mapping

from tools.mcp_accounts import SEPARATOR, registration_name, template_accounts
from tools.mcp_connector_policy import clean_description
from tools.mcp_tool_common import _core
from tools.mcp_tool_scope import _key_name


def _live_rows(slug: str) -> list[tuple[str, str]]:
    scope = _core._mcp_registry_scope()
    with _core._lock:
        servers = [server for key, server in _core._servers.items()
                   if registration_name(_key_name(key)) == slug and _core._server_visible_in_scope(key, scope)]
    return [(name, getattr(tool, "description", None) or "")
            for server in servers for tool in list(getattr(server, "_tools", ()))
            if isinstance(name := getattr(tool, "name", None), str) and name]


def _cached_rows(slug: str, template: Mapping[str, Any]) -> list[tuple[str, str]]:
    from tools.mcp_schema_cache import cached_tool_rows
    connections = [slug, *(f"{slug}{SEPARATOR}{alias}" for alias in template_accounts(template))]
    return [(row["name"], row.get("description") or "") for connection in connections
            for row in cached_tool_rows(connection) if isinstance(row, dict) and isinstance(row.get("name"), str)]


def known_tools(slug: str, template: Mapping[str, Any]) -> dict[str, str]:
    tools: dict[str, str] = {}
    for name, description in _cached_rows(slug, template) + _live_rows(slug):
        tools[name] = clean_description(description)
    return tools
