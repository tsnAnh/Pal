from __future__ import annotations

import copy
import logging
import re
from dataclasses import dataclass
from typing import Any, Mapping

logger = logging.getLogger(__name__)

ACCOUNTS_KEY = "accounts"
DEFAULT_ACCOUNT = "default"
SEPARATOR = "@"
API_KEY_ENV_ATTR = "api_key_env"
ACCOUNT_PROMPT = "select_account login"
CONNECTOR_ALIAS_PARAM = "connector_alias"
CONNECTOR_ALIAS_DESCRIPTION = (
    "Account name, needed only when this app has more than one connected account. "
    "Omit it when exactly one account is connected."
)

ALIAS_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class AccountError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class AccountRef:
    slug: str
    alias: str

    @property
    def server_name(self) -> str:
        return f"{self.slug}{SEPARATOR}{self.alias}"


def parse_alias(value: Any) -> str:
    text = value.strip() if isinstance(value, str) else ""
    if not ALIAS_PATTERN.match(text):
        raise AccountError(
            "invalid_account",
            "An account name is 1 to 32 characters: lowercase letters, digits and hyphens, starting with a letter or digit.")
    return text


def parse_slug(value: Any) -> str:
    text = value.strip() if isinstance(value, str) else ""
    if not SLUG_PATTERN.match(text):
        raise AccountError("invalid_connector", "This connector cannot hold several accounts.")
    return text


def account_ref(slug: str, alias: str) -> AccountRef:
    return AccountRef(parse_slug(slug), parse_alias(alias))


def server_name(slug: str, alias: str) -> str:
    return account_ref(slug, alias).server_name


def split(name: Any) -> AccountRef | None:
    if not isinstance(name, str) or SEPARATOR not in name:
        return None
    slug, _, alias = name.partition(SEPARATOR)
    if SLUG_PATTERN.match(slug) and ALIAS_PATTERN.match(alias):
        return AccountRef(slug, alias)
    return None


def registration_name(name: str) -> str:
    ref = split(name)
    return ref.slug if ref else name


def is_account_server(name: Any) -> bool:
    return split(name) is not None


def service_for_server(name: str) -> str:
    ref = split(name)
    return f"mcp:{ref.slug}:{ref.alias}" if ref else f"mcp:{name}"


def display_name(name: str) -> str:
    if split(name) is None:
        return name
    from tools.auth_required import service_display_name
    return service_display_name(service_for_server(name))


def split_service(service: Any) -> tuple[str, str | None] | None:
    if not isinstance(service, str) or not service.startswith("mcp:"):
        return None
    slug, _, alias = service[len("mcp:"):].partition(":")
    if not SLUG_PATTERN.match(slug) or (alias and not ALIAS_PATTERN.match(alias)):
        return None
    return slug, alias or None


def api_key_env(slug: str, alias: str) -> str:
    ref = account_ref(slug, alias)
    return "MCP_{}__{}_API_KEY".format(
        re.sub(r"[^A-Za-z0-9]", "_", ref.slug).upper(), re.sub(r"[^A-Za-z0-9]", "_", ref.alias).upper())


def template_accounts(cfg: Any) -> dict[str, dict]:
    raw = cfg.get(ACCOUNTS_KEY) if isinstance(cfg, Mapping) else None
    if not isinstance(raw, Mapping):
        return {}
    out: dict[str, dict] = {}
    for alias, attrs in raw.items():
        if isinstance(alias, str) and ALIAS_PATTERN.match(alias):
            out[alias] = dict(attrs) if isinstance(attrs, Mapping) else {}
        else:
            logger.warning("Ignoring MCP account with an invalid name %r", alias)
    return out


def has_accounts(cfg: Any) -> bool:
    return bool(template_accounts(cfg))


def _with_account_key(headers: Any, env_name: str) -> dict:
    kept = {k: v for k, v in (headers or {}).items() if str(k).lower() != "authorization"}
    return {**kept, "Authorization": f"Bearer ${{{env_name}}}"}


def account_config(template: Mapping, alias: str, attrs: Mapping | None = None) -> dict:
    entry = {k: copy.deepcopy(v) for k, v in template.items() if k != ACCOUNTS_KEY}
    env_name = (attrs or template_accounts(template).get(alias, {})).get(API_KEY_ENV_ATTR)
    if isinstance(env_name, str) and env_name:
        entry["headers"] = _with_account_key(entry.get("headers"), env_name)
    return entry


def with_account_prompt(cfg: Mapping) -> dict:
    oauth = cfg.get("oauth")
    return {**cfg, "oauth": {**(oauth if isinstance(oauth, Mapping) else {}), "prompt": ACCOUNT_PROMPT}}


def without_attempt_hints(cfg: Mapping) -> dict:
    oauth = cfg.get("oauth")
    if not isinstance(oauth, Mapping) or oauth.get("prompt") != ACCOUNT_PROMPT:
        return dict(cfg)
    kept = {k: v for k, v in oauth.items() if k != "prompt"}
    rest = {k: v for k, v in cfg.items() if k != "oauth"}
    return {**rest, "oauth": kept} if kept else rest


def expand(servers: Mapping[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for name, cfg in servers.items():
        accounts = template_accounts(cfg)
        if not accounts:
            out[name] = cfg
            continue
        for alias, attrs in accounts.items():
            out[f"{name}{SEPARATOR}{alias}"] = account_config(cfg, alias, attrs)
    return out


def resolve_alias(slug: str, cfg: Any, alias: Any) -> str:
    accounts = list(template_accounts(cfg))
    given = alias.strip() if isinstance(alias, str) else ""
    if given:
        if given in accounts:
            return given
        raise AccountError("unknown_account", unknown_account_message(slug, accounts, given))
    if len(accounts) == 1:
        return accounts[0]
    raise AccountError("account_required", account_required_message(slug, accounts))


def account_required_message(slug: str, accounts: list[str]) -> str:
    return (f"{slug} has several accounts ({', '.join(accounts)}). "
            f"Call again with {CONNECTOR_ALIAS_PARAM} set to one of them.")


def unknown_account_message(slug: str, accounts: list[str], given: str) -> str:
    return (f"{slug} has no account named '{given}'. Its accounts are: {', '.join(accounts)}. "
            f"Call again with {CONNECTOR_ALIAS_PARAM} set to one of them.")
