from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Mapping
from urllib.parse import urlsplit

HEADER_LIMIT = 20
NAME_LIMIT = 128
VALUE_LIMIT = 4096
CLIENT_ID_LIMIT = 512
Failure = tuple[int, str]

_TOKEN_CHARS = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")
_BEARER = re.compile(r"^bearer\s+(\S.*)$", re.IGNORECASE | re.DOTALL)
_REF = re.compile(r"\$\{([^}]*)\}")
_CLIENT_ID_CHARS = re.compile(r"^[\x21-\x7e]+$")
_TRANSPORT_OWNED = frozenset({
    "host", "content-length", "transfer-encoding", "connection", "upgrade", "te", "trailer", "proxy-authorization"})


@dataclass
class HeaderPlan:
    headers: dict[str, str]
    env_writes: dict[str, str] = field(default_factory=dict)


def authorization_keys(headers: Any) -> list[str]:
    return [k for k in headers if str(k).lower() == "authorization"] if isinstance(headers, dict) else []


def _env_base(name: str) -> str:
    from hermes_cli.mcp_config import _env_key_for_server

    return _env_key_for_server(name).removesuffix("_API_KEY")


def default_token_var(name: str) -> str:
    from hermes_cli.mcp_config import _env_key_for_server

    return _env_key_for_server(name)


def header_var(name: str, key: str) -> str:
    if key.lower() == "authorization":
        return default_token_var(name)
    return f"{_env_base(name)}_HDR_{re.sub(r'[^A-Za-z0-9]', '_', key).upper()}"


def referenced_vars(headers: Any) -> set[str]:
    if not isinstance(headers, dict):
        return set()
    return {m.group(1).strip() for value in headers.values() for m in _REF.finditer(str(value))}


def stored_headers(name: str) -> dict[str, str]:
    from hermes_cli.config import read_user_config_raw

    raw = ((read_user_config_raw().get("mcp_servers") or {}).get(name) or {}).get("headers")
    return {str(k): str(v) for k, v in raw.items()} if isinstance(raw, dict) else {}


def foreign_refs(name: str) -> set[str]:
    from hermes_cli.config import read_user_config_raw

    servers = read_user_config_raw().get("mcp_servers") or {}
    return {var for other, cfg in servers.items() if other != name and isinstance(cfg, dict)
            for var in referenced_vars(cfg.get("headers"))}


def stale_vars(name: str, before: Mapping[str, str], after: Mapping[str, str]) -> list[str]:
    owned_prefix = _env_base(name) + "_HDR_"
    foreign = foreign_refs(name)
    dropped = referenced_vars(dict(before)) - referenced_vars(dict(after)) - foreign
    return sorted(v for v in dropped if v == default_token_var(name) or v.startswith(owned_prefix))


def origin(url: Any) -> tuple[str, str, int | None]:
    parts = urlsplit(str(url or "").strip())
    default = {"http": 80, "https": 443}.get(parts.scheme.lower())
    try:
        port = parts.port or default
    except ValueError:
        port = None
    return parts.scheme.lower(), (parts.hostname or "").lower(), port


def _value_error(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return "header value is required"
    if len(value) > VALUE_LIMIT:
        return "header value is too long"
    if any(ord(c) < 32 and c != "\t" or ord(c) == 127 for c in value):
        return "header value has control characters"
    if "${" in value:
        return "header value cannot contain a variable reference"
    return None


def _validate_names(requested: Mapping[str, Any]) -> Failure | None:
    if len(requested) > HEADER_LIMIT:
        return 4063, f"at most {HEADER_LIMIT} headers"
    seen: set[str] = set()
    for key, value in requested.items():
        if not isinstance(key, str) or not key or len(key) > NAME_LIMIT or not _TOKEN_CHARS.match(key):
            return 4063, "invalid header name"
        folded = key.lower()
        if folded in _TRANSPORT_OWNED:
            return 4063, f"header '{key}' is not allowed"
        if folded in seen:
            return 4063, f"duplicate header '{key}'"
        seen.add(folded)
        if value is not None and (message := _value_error(value)):
            return 4063, f"{message} for '{key}'"
    return None


def _template(var: str, value: str) -> tuple[str, str]:
    stripped = value.strip()
    if match := _BEARER.match(stripped):
        return f"Bearer ${{{var}}}", match.group(1).strip()
    return f"${{{var}}}", stripped


def plan_headers(name: str, current: Mapping[str, str], requested: Mapping[str, Any] | None, *,
                 replace: bool) -> tuple[HeaderPlan | None, Failure | None]:
    if requested is None:
        return HeaderPlan(dict(current)), None
    if failure := _validate_names(requested):
        return None, failure
    stored = {k.lower(): k for k in current}
    foreign = foreign_refs(name)
    final = {} if replace else dict(current)
    writes: dict[str, str] = {}
    for key, value in requested.items():
        existing = stored.get(key.lower())
        if value is None:
            if not replace or existing is None:
                return None, (4063, f"no stored value for header '{key}'")
            final[key] = current[existing]
            continue
        if existing is not None and not replace:
            return None, (4063, f"duplicate header '{key}'")
        if key.lower() == "authorization" and value.strip().lower() == "bearer":
            return None, (4063, "Authorization is not a valid credential")
        var = header_var(name, key)
        if var in writes or var in foreign:
            return None, (4063, f"header '{key}' conflicts with another header")
        final[key], writes[var] = _template(var, value)
    return HeaderPlan(final, writes), None


def bearer_plan(name: str, current: Mapping[str, str], token: str) -> tuple[HeaderPlan | None, Failure | None]:
    from hermes_cli.mcp_config import _bearer_auth_headers, _strip_bearer_prefix

    normalized = _strip_bearer_prefix(str(token))
    if not normalized or normalized.lower() == "bearer":
        return None, (4063, "bearer_token is not a valid credential")
    if message := _value_error(normalized):
        return None, (4063, message.replace("header value", "bearer_token"))
    kept = {k: v for k, v in current.items() if k.lower() != "authorization"}
    return HeaderPlan({**kept, **_bearer_auth_headers(name)}, {default_token_var(name): normalized}), None


def client_id_error(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > CLIENT_ID_LIMIT or not _CLIENT_ID_CHARS.match(value):
        return "invalid client_id"
    return None


def with_client_id(cfg: dict, client_id: str | None) -> None:
    if client_id is None:
        return
    oauth = dict(cfg.get("oauth") or {})
    if client_id:
        oauth["client_id"] = client_id
    else:
        oauth.pop("client_id", None)
    if oauth:
        cfg["oauth"] = oauth
    else:
        cfg.pop("oauth", None)


def commit(name: str, cfg: dict, writes: Mapping[str, str], removes: list[str]) -> bool:
    from hermes_cli import mcp_config as mc
    from hermes_cli.config import load_env, remove_env_value, save_env_value

    previous = {var: load_env().get(var) for var in writes}
    for var, secret in writes.items():
        save_env_value(var, secret)
    try:
        saved = mc._save_mcp_server(name, cfg)
    except BaseException:
        _restore(previous)
        raise
    if not saved:
        _restore(previous)
        return False
    for var in removes:
        remove_env_value(var)
    return True


def _restore(previous: Mapping[str, str | None]) -> None:
    from hermes_cli.config import remove_env_value, save_env_value

    for var, value in previous.items():
        if value is None:
            remove_env_value(var)
        else:
            save_env_value(var, value)


def remove_server(name: str) -> bool:
    from hermes_cli import mcp_config as mc
    from hermes_cli.config import remove_env_value

    headers = stored_headers(name)
    stale = stale_vars(name, headers, {})
    if not mc._remove_mcp_server(name):
        return False
    if name not in mc._get_mcp_servers():
        for var in stale:
            remove_env_value(var)
    return True
