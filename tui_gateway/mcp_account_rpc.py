from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from tools.mcp_accounts import (
    API_KEY_ENV_ATTR, AccountError, api_key_env, expand, registration_name, server_name, split,
    template_accounts, with_account_prompt)

Failure = tuple[int, str]

_CODES = {
    "invalid_account": 4063,
    "invalid_connector": 4063,
    "account_required": 4063,
    "unknown_account": 4064,
    "unknown_connector": 4064,
    "account_exists": 4090,
}
_STATUS_KEYS = ("name", "transport", "tools", "connected", "disabled", "status", "needs_auth", "needs_auth_reason")


@dataclass(frozen=True)
class Target:
    name: str
    alias: str | None
    connection: str
    cfg: dict
    others: bool


def failure_of(exc: AccountError) -> Failure:
    return _CODES.get(exc.code, 5024), exc.message


def resolve(name: str, servers: Mapping[str, Any], account: Any, *, create: bool = False,
            signin: bool = False) -> tuple[Target | None, Failure | None]:
    from hermes_cli.mcp_accounts import capable_slugs, resolve_for_connect
    from tools.mcp_accounts import account_config

    template = servers.get(name)
    accounts = template_accounts(template)
    if not accounts and name not in capable_slugs():
        if isinstance(account, str) and account.strip():
            return None, (4063, "This connector cannot hold several accounts.")
        return Target(name, None, name, dict(template or {}), False), None
    try:
        alias = resolve_for_connect(name, template, account, create=create)
    except AccountError as exc:
        return None, failure_of(exc)
    if accounts and alias not in accounts and not create:
        return None, (4064, f"There is no account named '{alias}' on this connector.")
    cfg = account_config(template or {}, alias, accounts.get(alias, {}))
    others = any(other != alias for other in accounts)
    return Target(name, alias, server_name(name, alias), with_account_prompt(cfg) if signin and others else cfg,
                  others), None


def flow_connection(params: Mapping[str, Any]) -> tuple[str | None, Failure | None]:
    name = str(params.get("name") or "").strip()
    account = params.get("account")
    if not (isinstance(account, str) and account.strip()):
        return name, None
    try:
        return server_name(name, account), None
    except AccountError as exc:
        return None, failure_of(exc)


def account_rows(slug: str) -> list[dict]:
    from hermes_cli.mcp_accounts import account_statuses

    return [{"name": s.name, "status": s.status, "reason": s.reason} for s in account_statuses(slug)]


def aggregate_status(rows: list[dict]) -> str | None:
    from hermes_cli.mcp_accounts import CONNECTED, NEEDS_RECONNECT, NOT_CONNECTED

    if not rows:
        return None
    states = {row["status"] for row in rows}
    return CONNECTED if CONNECTED in states else NEEDS_RECONNECT if NEEDS_RECONNECT in states else NOT_CONNECTED


def connector_reason(slug: str, rows: list[dict] | None = None) -> str | None:
    from hermes_cli.mcp_accounts import CONNECTED
    from tools.mcp_oauth import pending_reauth_reason

    rows = account_rows(slug) if rows is None else rows
    if not rows:
        return pending_reauth_reason(slug)
    if any(row["status"] == CONNECTED for row in rows):
        return None
    return next((row["reason"] for row in rows if row["reason"]), None)


def status_rows(configured: Mapping[str, Any], plugins: Mapping[str, str | None], include_runtime: bool) -> list[dict]:
    from tools.mcp_tool_discovery import get_mcp_status

    out = []
    for entry in get_mcp_status(expand(configured), include_runtime=include_runtime):
        ref = split(entry["name"])
        slug = registration_name(entry["name"])
        plugin = plugins.get(slug)
        out.append({**{k: entry[k] for k in _STATUS_KEYS if k in entry}, "name": slug,
                    **({"account": ref.alias} if ref else {}),
                    "source": "plugin" if plugin is not None else "config", "plugin": plugin})
    return out


def _referenced_default_key(entry: Mapping, slug: str) -> bool:
    from hermes_cli import mcp_config as mc
    from tui_gateway import mcp_header_secrets as hs

    return mc._env_key_for_server(slug) in hs.referenced_vars(hs.stored_headers(slug))


def _account_env_var(entry: Mapping, slug: str, alias: str) -> tuple[str, bool]:
    attrs = template_accounts(entry).get(alias, {})
    env_var = attrs.get(API_KEY_ENV_ATTR)
    if isinstance(env_var, str) and env_var:
        return env_var, True
    if alias in template_accounts(entry) and _referenced_default_key(entry, slug):
        from hermes_cli import mcp_config as mc
        return mc._env_key_for_server(slug), False
    return api_key_env(slug, alias), True


def set_api_key(name: str, entry: Any, params: Mapping[str, Any]) -> tuple[dict | None, Failure | None]:
    from hermes_cli import mcp_config as mc
    from hermes_cli.config import save_env_value
    from hermes_cli.mcp_accounts import add_account
    from tui_gateway.mcp_rpc_helpers import summarize_server

    if not isinstance(entry, dict):
        return None, (4001, "malformed server config")
    target, failure = resolve(name, {name: entry}, params.get("account"), create=bool(params.get("create")))
    if failure:
        return None, failure
    value = params.get("value")
    if entry.get("url"):
        normalized = mc._strip_bearer_prefix(str(value))
        if not normalized or normalized.lower() == "bearer":
            return None, (4063, "value is not a valid credential")
    if target.alias is not None:
        if not entry.get("url"):
            return None, (4063, "This connector cannot hold several accounts.")
        env_var, records_env = _account_env_var(entry, name, target.alias)
        save_env_value(env_var, normalized)
        add_account(name, target.alias, api_key_env=env_var if records_env else None)
        saved = mc._get_mcp_servers().get(name, entry)
        return {"ok": True, "name": name, "account": target.alias, "env_var": env_var,
                "server": summarize_server(name, saved)}, None
    return _store_plain_key(name, entry, value, params), None


def _store_plain_key(name: str, entry: dict, value: Any, params: Mapping[str, Any]) -> dict:
    from hermes_cli import config as hc
    from hermes_cli import mcp_config as mc
    from tui_gateway.mcp_rpc_helpers import summarize_server

    env_var = str(params.get("env_var") or "").strip() or mc._env_key_for_server(name)
    if entry.get("url"):
        hc.save_env_value(env_var, mc._strip_bearer_prefix(str(value)))
        bearer = (mc._bearer_auth_headers(name) if env_var == mc._env_key_for_server(name)
                  else {"Authorization": f"Bearer ${{{env_var}}}"})
        kept = {k: v for k, v in (entry.get("headers") or {}).items() if str(k).lower() != "authorization"}
        entry["headers"] = {**kept, **bearer}
    else:
        hc.save_env_value(env_var, str(value))
        env_block = entry.get("env")
        entry["env"] = env_block if isinstance(env_block, dict) else {}
        entry["env"][env_var] = f"${{{env_var}}}"
    cfg = hc.load_config()
    cfg.setdefault("mcp_servers", {})[name] = entry
    hc.save_config(cfg)
    return {"ok": True, "name": name, "env_var": env_var, "server": summarize_server(name, entry)}


def remove(name: str, account: Any) -> tuple[dict | None, Failure | None]:
    from hermes_cli.mcp_accounts import remove_account
    from tui_gateway import mcp_header_secrets as hs

    if isinstance(account, str) and account.strip():
        try:
            remove_account(name, account)
        except AccountError as exc:
            return None, failure_of(exc)
        return {"ok": True, "removed": True}, None
    if not hs.remove_server(name):
        return None, (4064, f"server '{name}' not found")
    return {"ok": True, "removed": True}, None


def rename(params: Mapping[str, Any]) -> tuple[dict | None, Failure | None]:
    from hermes_cli.mcp_accounts import rename_account

    values = {key: str(params.get(key) or "").strip() for key in ("name", "account", "new_account")}
    for key, value in values.items():
        if not value:
            return None, (4063, f"{key} required")
    try:
        rename_account(values["name"], values["account"], values["new_account"])
    except AccountError as exc:
        return None, failure_of(exc)
    return {"ok": True, "name": values["name"], "account": values["new_account"]}, None

