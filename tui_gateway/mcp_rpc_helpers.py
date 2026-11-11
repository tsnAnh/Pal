"""Shared helpers for the per-profile MCP lifecycle RPCs (mcp.servers.*).

Published onto ``tui_gateway.server`` as ``_mcp_summarize_server`` so the rebound handler
bodies in methods_tools resolve it.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

from tui_gateway import mcp_header_secrets as hs


def server_configs_with_sources(config_servers: Mapping[str, dict]) -> tuple[dict[str, dict], dict[str, str | None]]:
    servers = {name: dict(cfg) for name, cfg in config_servers.items() if isinstance(cfg, dict)}
    plugins: dict[str, str | None] = {name: None for name in servers}
    try:
        from hermes_cli.plugins import discover_plugins, get_plugin_manager
        from tools.mcp_tool_config import _filter_suspicious_mcp_servers

        discover_plugins()
        manager = get_plugin_manager()
        portable = _filter_suspicious_mcp_servers(manager.get_portable_mcp_servers())
        owners = manager.get_portable_mcp_server_plugins()
        for name, cfg in portable.items():
            if name not in servers:
                servers[name] = dict(cfg)
                plugins[name] = owners.get(name)
    except Exception:
        pass
    return servers, plugins


def summarize_server(name: str, cfg: dict, plugin: str | None = None) -> dict[str, Any]:
    from hermes_cli.mcp_config import _oauth_tokens_present
    from tools.mcp_tool_common import mcp_server_enabled

    cfg = cfg if isinstance(cfg, dict) else {}
    if cfg.get("url"):
        transport = "sse" if cfg.get("transport") == "sse" else "http"
    else:
        transport = "stdio" if cfg.get("command") else "unknown"
    auth = cfg.get("auth")
    headers = cfg.get("headers") or {}
    if not auth and isinstance(headers, dict) and any(str(key).lower() == "authorization" for key in headers):
        auth = "header"
    return {
        "name": name,
        "transport": transport,
        "url": cfg.get("url"),
        "command": cfg.get("command"),
        "args": list(cfg.get("args") or []),
        "env": sorted(str(k) for k in (cfg.get("env") or {})),
        "auth": auth,
        "headers": [str(key) for key in headers] if isinstance(headers, dict) else [],
        "client_id": (cfg.get("oauth") or {}).get("client_id") if isinstance(cfg.get("oauth"), dict) else None,
        "oauth_tokens_present": _oauth_tokens_present(name) if auth == "oauth" else None,
        "enabled": mcp_server_enabled(cfg),
        "tools": cfg.get("tools"),
        "source": "plugin" if plugin is not None else "config",
        "plugin": plugin}


def record_mcp_add(entry: Any, server_config: Mapping[str, Any], saved: bool) -> None:
    """Count an ``mcp.servers.add`` as an MCP extension install. A save fails only on a suspicious
    command/args configuration (``_save_mcp_server`` returns False)."""
    from hermes_cli.mcp_catalog import record_mcp_install

    source = "catalog" if entry is not None else ("url" if server_config.get("url") else "local")
    record_mcp_install(source, entry.name if entry is not None else None, "success" if saved else "failed",
                       failure_class=None if saved else "config_rejected")


ENDPOINT_TRANSPORTS = ("http", "sse")
AUTH_MODES = ("none", "bearer", "oauth")
_MIN_REDACTED_LEN = 6
_HTTP_STATUS = re.compile(r"\bHTTP (\d{3})\b|'(\d{3}) [A-Za-z ]+' for url")
_TRANSPORT_FAILURES = frozenset({
    "ConnectError", "ConnectTimeout", "ReadTimeout", "WriteTimeout", "PoolTimeout", "TimeoutException",
    "NetworkError", "TransportError", "gaierror"})
Failure = tuple[int, str]


def endpoint_error(cfg: Mapping[str, Any]) -> str | None:
    """Plain client message for a url server's bad ``url`` / ``transport``; ``None`` for anything else."""
    from tools.mcp_tool_errors import InvalidMcpUrlError, _validate_remote_mcp_url

    if not cfg.get("url"):
        return None
    try:
        _validate_remote_mcp_url("server", cfg["url"])
    except InvalidMcpUrlError:
        return "invalid url"
    transport = cfg.get("transport")
    return None if transport is None or transport in ENDPOINT_TRANSPORTS else "unsupported transport"


def _plan_auth(entry: dict, params: Mapping[str, Any]) -> tuple[str | None, str | None, Failure | None]:
    """``(mode, normalized bearer token, error)`` for an update request."""
    from hermes_cli.mcp_config import _strip_bearer_prefix

    mode, raw_token = params.get("auth"), params.get("bearer_token")
    if mode is not None and mode not in AUTH_MODES:
        return None, None, (4063, "unsupported auth")
    token = None
    if raw_token is not None:
        token = _strip_bearer_prefix(str(raw_token))
        if not token or token.lower() == "bearer":
            return None, None, (4063, "bearer_token is not a valid credential")
        mode = mode or "bearer"
        if mode != "bearer":
            return None, None, (4063, "bearer_token requires auth bearer")
    if mode == "bearer" and token is None and not hs.authorization_keys(entry.get("headers")):
        return None, None, (4063, "bearer_token required")
    return mode, token, None


def plan_add_headers(name: str, server_config: dict, params: Mapping[str, Any]) -> tuple[dict[str, str], Failure | None]:
    client_id = params.get("client_id")
    if client_id and (message := hs.client_id_error(client_id)):
        return {}, (4063, message)
    current = server_config.get("headers")
    current = {str(k): str(v) for k, v in current.items()} if isinstance(current, dict) else {}
    writes: dict[str, str] = {}
    if (requested := params.get("headers")) is not None:
        plan, failure = hs.plan_headers(name, current, requested, replace=False)
        if failure:
            return {}, failure
        current, writes = plan.headers, plan.env_writes
    if token := params.get("bearer_token"):
        plan, failure = hs.bearer_plan(name, current, str(token))
        if failure:
            return {}, failure
        current, writes = plan.headers, {**writes, **plan.env_writes}
    if current:
        server_config["headers"] = current
    hs.with_client_id(server_config, client_id or None)
    return writes, None


def apply_client_id(cfg: dict, client_id: Any) -> str | None:
    if not client_id:
        return None
    if message := hs.client_id_error(client_id):
        return message
    hs.with_client_id(cfg, client_id)
    return None


def add_server(name: str, server_config: dict, writes: Mapping[str, str]) -> bool:
    return hs.commit(name, server_config, writes, [])


def update_server(name: str, entry: dict, params: Mapping[str, Any]) -> tuple[dict | None, Failure | None]:
    """Edit a saved url server (endpoint, auth, headers, client id) → ``(saved entry, None)`` or
    ``(None, (code, message))``. Everything is validated before the first write so a refused edit
    leaves config and ``.env`` untouched."""
    from hermes_cli import mcp_config as mc
    from hermes_cli.mcp_security import validate_mcp_server_entry

    if not entry.get("url"):
        return None, (4063, "only url servers can be edited")
    edit = params.get("config") or {}
    cfg = {**entry, **{k: edit[k] for k in ("url", "transport") if edit.get(k) is not None}}
    if message := endpoint_error(cfg):
        return None, (4063, message)
    mode, token, failure = _plan_auth(entry, params)
    if failure:
        return None, failure
    requested = params.get("headers")
    if requested is not None and (mode is not None or token is not None):
        return None, (4063, "headers cannot be combined with auth or bearer_token")
    client_id = params.get("client_id")
    if client_id and (message := hs.client_id_error(client_id)):
        return None, (4063, message)
    before = hs.stored_headers(name)
    headers, writes = dict(before), {}
    if requested is not None:
        plan, failure = hs.plan_headers(name, before, requested, replace=True)
        if failure:
            return None, failure
        headers, writes = plan.headers, plan.env_writes
    if mode in ("none", "bearer", "oauth"):
        if mode != "bearer":
            headers = {k: v for k, v in headers.items() if k.lower() != "authorization"}
        cfg.pop("auth", None)
        if mode == "oauth":
            cfg["auth"] = "oauth"
    if token is not None:
        plan, failure = hs.bearer_plan(name, headers, token)
        if failure:
            return None, failure
        headers, writes = plan.headers, {**writes, **plan.env_writes}
    if headers:
        cfg["headers"] = headers
    else:
        cfg.pop("headers", None)
    hs.with_client_id(cfg, client_id)
    if hs.origin(entry.get("url")) != hs.origin(cfg.get("url")) and hs.referenced_vars(headers) - set(writes):
        return None, (4063, "re-enter headers for the new address")
    if validate_mcp_server_entry(name, cfg):
        return None, (4001, f"server '{name}' rejected: suspicious command/args configuration")
    if not hs.commit(name, cfg, writes, hs.stale_vars(name, before, headers)):
        return None, (4001, f"server '{name}' rejected: suspicious command/args configuration")
    return mc._get_mcp_servers().get(name, cfg), None


def _secret_values(cfg: Mapping[str, Any]) -> list[str]:
    """Header and env values of a server entry plus their credential-only forms (``Bearer`` stripped)."""
    values: set[str] = set()
    for block in (cfg.get("headers"), cfg.get("env")):
        for value in (block.values() if isinstance(block, dict) else ()):
            text = str(value)
            values.update({text, re.sub(r"^(?:bearer|basic)\s+", "", text, flags=re.IGNORECASE)})
    return sorted((v for v in values if len(v) >= _MIN_REDACTED_LEN), key=len, reverse=True)


def redact_secrets(text: str, cfg: Mapping[str, Any]) -> str:
    for secret in _secret_values(cfg):
        text = text.replace(secret, "***")
    return text


def _http_statuses(nodes: list[BaseException]) -> set[int]:
    found: set[int] = set()
    for node in nodes:
        status = getattr(getattr(node, "response", None), "status_code", None)
        if isinstance(status, int):
            found.add(status)
        found.update(int(m.group(1) or m.group(2)) for m in _HTTP_STATUS.finditer(str(node)))
    return found


def classify_probe_failure(exc: BaseException) -> str:
    """``auth_refused`` (HTTP 401/403 anywhere in the failure), else ``server_error`` for any other HTTP
    status, ``unreachable`` for a connect/DNS/TLS/timeout failure, ``server_error`` for the rest. The
    transport wraps a rejection in a plain ``ConnectionError``, so the status is read from the text too."""
    from tools.mcp_tool_errors import _iter_exception_nodes

    nodes = _iter_exception_nodes(exc)
    statuses = _http_statuses(nodes)
    if statuses & {401, 403}:
        return "auth_refused"
    if statuses:
        return "server_error"
    unreachable = any(isinstance(node, (TimeoutError, OSError)) or type(node).__name__ in _TRANSPORT_FAILURES
                      for node in nodes)
    return "unreachable" if unreachable else "server_error"


def _bearer_challenged(nodes: list[BaseException]) -> bool:
    for node in nodes:
        headers = getattr(getattr(node, "response", None), "headers", None)
        if headers is not None and re.match(r"\s*(bearer|oauth)\b", str(headers.get("www-authenticate", "")), re.IGNORECASE):
            return True
    return False


def oauth_challenged(exc: BaseException, cfg: Mapping[str, Any]) -> bool:
    from tools.mcp_tool_errors import _iter_exception_nodes

    nodes = _iter_exception_nodes(exc)
    headers = cfg.get("headers")
    if 401 not in _http_statuses(nodes) or hs.authorization_keys(headers):
        return False
    return _bearer_challenged(nodes) or not headers
