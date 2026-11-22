from __future__ import annotations

import copy
import functools
import logging
import re
import threading
from dataclasses import dataclass
from typing import Any, Callable, Mapping

from hermes_cli import mcp_config as mc
from hermes_cli.config import (
    _CONFIG_LOCK, get_env_value, is_managed, load_config, load_config_readonly, remove_env_value, save_config)
from hermes_cli.pal_connectors import load_pal_connectors
from hermes_cli.shared_catalog import home_is_root, is_root_owned, visible_mcp_servers
from hermes_cli.shared_catalog_connectors import adopt_profile_connectors_if_due, root_secret_reader
from tools.mcp_accounts import (
    ACCOUNTS_KEY, API_KEY_ENV_ATTR, DEFAULT_ACCOUNT, AccountError, AccountRef, account_config, has_accounts, parse_alias,
    parse_slug, registration_name, server_name, template_accounts, without_attempt_hints)
from tools.mcp_oauth import HermesTokenStorage
from tools.mcp_tool_common import mcp_server_enabled

logger = logging.getLogger(__name__)

CONNECTED = "connected"
NEEDS_RECONNECT = "needs_reconnect"
NOT_CONNECTED = "not_connected"

_MIGRATION_LOCK = threading.RLock()
_ENV_REFERENCE = re.compile(r"\$\{([^}]*)\}")


@dataclass(frozen=True)
class RemoveOutcome:
    template_removed: bool


@dataclass(frozen=True)
class AccountStatus:
    name: str
    status: str
    reason: str | None


@functools.lru_cache(maxsize=1)
def capable_slugs() -> frozenset[str]:
    return frozenset(entry.id for entry in load_pal_connectors() if entry.multi_account)


@functools.lru_cache(maxsize=1)
def oauth_slugs() -> frozenset[str]:
    from hermes_cli.pal_connectors import ConnectionMethod

    oauth = (ConnectionMethod.MCP_OAUTH, ConnectionMethod.OAUTH_CLIENT)
    return frozenset(entry.id for entry in load_pal_connectors() if entry.method in oauth)


def _entries(config: Mapping) -> dict[str, Any]:
    return visible_mcp_servers(config.get("mcp_servers"))


def _template(slug: str, config: Mapping | None = None) -> dict | None:
    entry = _entries(config if config is not None else load_config_readonly()).get(slug)
    return entry if isinstance(entry, dict) else None


def _has_authorization_header(cfg: Mapping) -> bool:
    headers = cfg.get("headers")
    return isinstance(headers, Mapping) and any(str(key).lower() == "authorization" for key in headers)


def _needs_migration(slug: str, cfg: Any) -> bool:
    if not isinstance(cfg, Mapping) or (not home_is_root() and is_root_owned(slug)):
        return False
    return bool(HermesTokenStorage(slug).state_paths()) or (not has_accounts(cfg) and _has_authorization_header(cfg))


def migrate_legacy_accounts() -> list[str]:
    try:
        adopt_profile_connectors_if_due()
    except Exception:  # health: allow BLE001 -- adoption is repeatable; a failed pass must not blank the MCP surfaces that call this
        logger.warning("Adopting profile connector logins into the root profile failed", exc_info=True)
    entries = _entries(load_config_readonly())
    if not any(slug in entries and _needs_migration(slug, entries[slug]) for slug in capable_slugs()):
        return []
    with _MIGRATION_LOCK, _CONFIG_LOCK:
        if is_managed():
            return []
        return [slug for slug in sorted(capable_slugs()) if _migrate_slug(slug)]


def _migrate_slug(slug: str) -> bool:
    config = load_config()
    raw = config.get("mcp_servers")
    visible = _entries(config).get(slug)
    if not isinstance(raw, dict) or not isinstance(raw.get(slug), dict) or not _needs_migration(slug, visible):
        return False
    accounts = dict(visible.get(ACCOUNTS_KEY) or {}) if isinstance(visible.get(ACCOUNTS_KEY), Mapping) else {}
    if DEFAULT_ACCOUNT not in accounts:
        accounts[DEFAULT_ACCOUNT] = {}
        if not _write_accounts(config, slug, accounts):
            return False
    HermesTokenStorage(server_name(slug, DEFAULT_ACCOUNT)).absorb(HermesTokenStorage(slug))
    logger.info("Migrated the %s connection to account '%s'", slug, DEFAULT_ACCOUNT)
    return True


def _write_accounts(config: dict, slug: str, accounts: dict) -> bool:
    config["mcp_servers"][slug][ACCOUNTS_KEY] = accounts
    save_config(config)
    return DEFAULT_ACCOUNT in template_accounts(_template(slug, load_config()))


def account_names(slug: str) -> list[str]:
    return list(template_accounts(mc._get_mcp_servers().get(slug)))


def update_template(slug: str, mutate: Callable[[dict | None], dict | None]) -> bool:
    with _CONFIG_LOCK:
        current = _template(slug, load_config())
        updated = mutate(copy.deepcopy(current))
        return updated is None or updated == current or mc._save_mcp_server(slug, updated)


def add_account(slug: str, alias: str, template: Mapping | None = None, *, api_key_env: str | None = None) -> None:
    slug, alias = parse_slug(slug), parse_alias(alias)

    def mutate(current: dict | None) -> dict | None:
        if current is None and template is None:
            raise AccountError("unknown_connector", "This connector is not set up yet.")
        merged = {**(current or {}), **{k: v for k, v in (template or {}).items() if k != ACCOUNTS_KEY}}
        accounts = dict(current.get(ACCOUNTS_KEY) or {}) if current and isinstance(current.get(ACCOUNTS_KEY), Mapping) else {}
        attrs = dict(accounts.get(alias) or {})
        if api_key_env:
            attrs[API_KEY_ENV_ATTR] = api_key_env
        accounts[alias] = attrs
        merged[ACCOUNTS_KEY] = accounts
        return merged

    if not update_template(slug, mutate):
        raise AccountError("save_failed", "This connector could not be saved. Check the settings and try again.")


def save_account_entry(ref: AccountRef, cfg: Mapping) -> bool:
    existing = template_accounts(_template(ref.slug, load_config())).get(ref.alias, {})

    def mutate(current: dict | None) -> dict | None:
        incoming = {k: v for k, v in without_attempt_hints(cfg).items() if k != ACCOUNTS_KEY}
        if existing.get(API_KEY_ENV_ATTR) and isinstance(incoming.get("headers"), Mapping):
            shared = {k: v for k, v in incoming["headers"].items() if str(k).lower() != "authorization"}
            incoming["headers"] = {**((current or {}).get("headers") or {}), **shared}
        merged = {**(current or {}), **incoming}
        accounts = dict(current.get(ACCOUNTS_KEY) or {}) if current and isinstance(current.get(ACCOUNTS_KEY), Mapping) else {}
        accounts.setdefault(ref.alias, {})
        merged[ACCOUNTS_KEY] = accounts
        return merged

    return update_template(ref.slug, mutate)


def _drop_alias(ref: AccountRef) -> bool:
    return update_template(ref.slug, lambda cfg: {
        **cfg, ACCOUNTS_KEY: {k: v for k, v in cfg[ACCOUNTS_KEY].items() if k != ref.alias}})


def remove_account_entry(ref: AccountRef) -> bool:
    with _CONFIG_LOCK:
        current = _template(ref.slug, load_config())
        accounts = template_accounts(current)
        if ref.alias not in accounts:
            return False
        if len(accounts) == 1:
            return mc._remove_mcp_server(ref.slug)
        secrets = _secret_vars(ref.slug, current, {ref.alias})
        if not _drop_alias(ref):
            return False
    forget_accounts(ref.slug, [ref.alias], secrets)
    return True


def _secret_vars(slug: str, template: Mapping | None, leaving: set[str]) -> list[str]:
    from tui_gateway import mcp_header_secrets as hs

    accounts = template_accounts(template)
    names = {attrs[API_KEY_ENV_ATTR] for alias, attrs in accounts.items()
             if alias in leaving and isinstance(attrs.get(API_KEY_ENV_ATTR), str) and attrs[API_KEY_ENV_ATTR]}
    uses_header = any(not attrs.get(API_KEY_ENV_ATTR) for alias, attrs in accounts.items() if alias in leaving)
    stays_on_header = any(not attrs.get(API_KEY_ENV_ATTR) for alias, attrs in accounts.items() if alias not in leaving)
    token_var = hs.default_token_var(slug)
    if uses_header and not stays_on_header and token_var in hs.referenced_vars(hs.stored_headers(slug)):
        names.add(token_var)
    return sorted(names)


def forget_accounts(slug: str, aliases: list[str], secrets: list[str]) -> None:
    from tools.mcp_oauth_manager import get_manager

    for alias in aliases:
        name = server_name(slug, alias)
        get_manager().evict(name)
        HermesTokenStorage(name).purge()
    for var in secrets:
        remove_env_value(var)


def _reconcile_live_servers() -> None:
    from tools.mcp_tool_discovery import reconcile_mcp_servers_with_config

    try:
        reconcile_mcp_servers_with_config()
    except Exception:  # health: allow BLE001 -- the config is already saved; the config watcher converges the live set
        logger.warning("MCP reconcile after an account change failed", exc_info=True)


def remove_account(slug: str, alias: str) -> RemoveOutcome:
    from tui_gateway import mcp_header_secrets as hs

    slug, alias = parse_slug(slug), parse_alias(alias)
    template = mc._get_mcp_servers().get(slug)
    if alias not in template_accounts(template):
        raise AccountError("unknown_account", f"There is no account named '{alias}' on this connector.")
    last = len(template_accounts(template)) == 1
    if last:
        hs.remove_server(slug)
        _reconcile_live_servers()
    else:
        secrets = _secret_vars(slug, template, {alias})
        _drop_alias(AccountRef(slug, alias))
        _reconcile_live_servers()
        forget_accounts(slug, [alias], secrets)
    return RemoveOutcome(template_removed=last)


def rename_account(slug: str, old: str, new: str) -> None:
    slug, old, new = parse_slug(slug), parse_alias(old), parse_alias(new)
    template = mc._get_mcp_servers().get(slug)
    accounts = template_accounts(template)
    if old not in accounts:
        raise AccountError("unknown_account", f"There is no account named '{old}' on this connector.")
    if old == new:
        return
    if new in accounts:
        raise AccountError("account_exists", f"There is already an account named '{new}' on this connector.")
    from tools.mcp_oauth_manager import get_manager

    HermesTokenStorage(server_name(slug, new)).absorb(HermesTokenStorage(server_name(slug, old)))

    def mutate(current: dict | None) -> dict | None:
        renamed = {(new if key == old else key): value for key, value in (current or {}).get(ACCOUNTS_KEY, {}).items()}
        return {**(current or {}), ACCOUNTS_KEY: renamed}

    update_template(slug, mutate)
    get_manager().evict(server_name(slug, old))
    _reconcile_live_servers()


def _missing_credential(connection: str, cfg: Mapping) -> bool:
    headers = cfg.get("headers")
    if not isinstance(headers, Mapping):
        return False
    read = root_secret_reader(connection) or (lambda var, _default=None: get_env_value(var))
    return any(not read(match.group(1).strip())
               for value in headers.values() for match in _ENV_REFERENCE.finditer(str(value)))


def connection_state(connection: str, cfg: Mapping | None) -> tuple[str, str | None]:
    if not isinstance(cfg, Mapping) or not mcp_server_enabled(cfg):
        return NOT_CONNECTED, None
    if cfg.get("auth") == "oauth" or registration_name(connection) in oauth_slugs():
        from tools.mcp_oauth import pending_reauth_reason

        if reason := pending_reauth_reason(connection):
            return NEEDS_RECONNECT, reason
        return (CONNECTED, None) if HermesTokenStorage(connection).has_cached_tokens() else (NOT_CONNECTED, None)
    return (NOT_CONNECTED, None) if _missing_credential(connection, cfg) else (CONNECTED, None)


def template_state(slug: str) -> str:
    return connection_state(slug, mc._get_mcp_servers().get(slug))[0]


def account_statuses(slug: str) -> list[AccountStatus]:
    template = mc._get_mcp_servers().get(slug)
    return [AccountStatus(alias, *connection_state(server_name(slug, alias), account_config(template, alias, attrs)))
            for alias, attrs in template_accounts(template).items()]


def resolve_for_connect(slug: str, template: Mapping | None, alias: str | None, *, create: bool = False) -> str:
    accounts = list(template_accounts(template))
    if alias is not None and str(alias).strip():
        chosen = parse_alias(alias)
    elif len(accounts) == 1:
        chosen = accounts[0]
    elif not accounts:
        chosen = DEFAULT_ACCOUNT
    else:
        raise AccountError("account_required", f"Name the account to use: {', '.join(accounts)}.")
    if create and chosen in accounts:
        raise AccountError("account_exists", f"There is already an account named '{chosen}' on this connector.")
    return chosen


def is_extra_account(slug: str, alias: str) -> bool:
    return any(other != alias for other in account_names(slug))
