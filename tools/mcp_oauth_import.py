"""Import an OAuth sign-in that ran in the owner's app on their own computer.

Some hosted MCP servers approve redirects only for apps on the owner's computer, so the gateway host cannot run
the browser flow. The app does, then hands over the registered public client and the tokens; this module writes
them where the MCP OAuth provider reads them (``HermesTokenStorage``), so refresh and rotation are the
provider's, as for any other server. Nothing here logs, returns or stores a token anywhere else.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlsplit

logger = logging.getLogger(__name__)

_MAX_URL_CHARS = 2048
_MAX_TOKEN_CHARS = 8192
_MAX_EXPIRES_IN = 10 * 365 * 24 * 3600
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})

NOT_OAUTH_SERVICE = "not_oauth_service"
SERVER_MISMATCH = "server_mismatch"
INVALID_REQUEST = "invalid_request"
SAVE_FAILED = "save_failed"


@dataclass(frozen=True)
class OwnerTokens:
    client_id: str
    redirect_uri: str
    token_endpoint: str
    issuer: str
    access_token: str = ""
    refresh_token: Optional[str] = None
    expires_in: Optional[int] = None
    scope: Optional[str] = None
    token_type: Optional[str] = None


def _https_url(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > _MAX_URL_CHARS or not value.isascii():
        return False
    parts = urlsplit(value)
    return parts.scheme == "https" and bool(parts.hostname) and not parts.username and not parts.fragment


def _redirect_uri_ok(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > _MAX_URL_CHARS or not value.isascii():
        return False
    parts = urlsplit(value)
    if parts.fragment or parts.username or not parts.hostname:
        return False
    return parts.scheme == "https" or (parts.scheme == "http" and parts.hostname in _LOOPBACK_HOSTS)


def _text(value: Any, limit: int, *, required: bool = True) -> bool:
    if value is None:
        return not required
    return isinstance(value, str) and 0 < len(value) <= limit and value.isprintable() and value == value.strip()


def validate(tokens: OwnerTokens) -> Optional[str]:
    checks = (
        ("client_id", _text(tokens.client_id, 512) and " " not in tokens.client_id),
        ("redirect_uri", _redirect_uri_ok(tokens.redirect_uri)),
        ("token_endpoint", _https_url(tokens.token_endpoint)),
        ("issuer", _https_url(tokens.issuer)),
        ("access_token", _text(tokens.access_token, _MAX_TOKEN_CHARS)),
        ("refresh_token", _text(tokens.refresh_token, _MAX_TOKEN_CHARS, required=False)),
        ("scope", _text(tokens.scope, 1024, required=False)),
        ("token_type", tokens.token_type is None
         or (isinstance(tokens.token_type, str) and tokens.token_type.lower() == "bearer")),
        ("expires_in", tokens.expires_in is None
         or (type(tokens.expires_in) is int and 0 < tokens.expires_in <= _MAX_EXPIRES_IN)),
    )
    return next((name for name, ok in checks if not ok), None)


def catalog_entry(server_name: str) -> Any:
    from hermes_cli.mcp_catalog import get_entry
    entry = get_entry(server_name)
    if entry is None or entry.auth.type != "oauth" or entry.auth.provider or entry.transport.type != "http":
        return None
    return entry


def _ensure_server_config(entry: Any, home: Path) -> Optional[str]:
    """Install the catalog entry when absent; when present, it must be this entry's server. The catalog's
    gate and sign-in keys are always (re)applied, so an older bare entry of the same name gains the gate."""
    from hermes_cli.mcp_catalog import _build_server_config
    from hermes_cli.mcp_config import _get_mcp_servers, _save_mcp_server
    wanted = _build_server_config(entry, None)
    current = _get_mcp_servers().get(entry.name)
    if isinstance(current, dict) and str(current.get("url") or "").rstrip("/") != wanted["url"].rstrip("/"):
        return SERVER_MISMATCH
    merged = {**(current if isinstance(current, dict) else {"enabled": True}), **{
        key: value for key, value in wanted.items() if key in ("url", "auth", "signin_on", "action_policy")}}
    if merged != current and not _save_mcp_server(entry.name, merged):
        return SAVE_FAILED
    return None


async def _write_state(storage: Any, tokens: OwnerTokens) -> None:
    from tools.mcp_oauth import _sdk_class
    client_cls, meta_cls, token_cls = (_sdk_class(n) for n in ("OAuthClientInformationFull", "OAuthMetadata", "OAuthToken"))
    if None in (client_cls, meta_cls, token_cls):
        raise RuntimeError("MCP OAuth support is unavailable")
    storage.remove()
    await storage.set_client_info(client_cls.model_validate({
        "client_id": tokens.client_id, "redirect_uris": [tokens.redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
        "token_endpoint_auth_method": "none", **({"scope": tokens.scope} if tokens.scope else {})}))
    # authorization_endpoint is required by the model but only a re-authorization would use it, and this
    # server's authorization never runs on this host.
    storage.save_oauth_metadata(meta_cls.model_validate({
        "issuer": tokens.issuer, "authorization_endpoint": tokens.issuer, "token_endpoint": tokens.token_endpoint,
        "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
        "token_endpoint_auth_methods_supported": ["none"], "code_challenge_methods_supported": ["S256"]}))
    storage.bind_issuer(tokens.issuer)
    await storage.set_tokens(token_cls.model_validate({
        "access_token": tokens.access_token, "token_type": "Bearer",
        **({"refresh_token": tokens.refresh_token} if tokens.refresh_token else {}),
        **({"expires_in": tokens.expires_in} if tokens.expires_in else {}),
        **({"scope": tokens.scope} if tokens.scope else {})}))


def _wake_connection(server_name: str, home: Path) -> None:
    from tools.mcp_oauth_manager import get_manager
    from tools.mcp_tool_loop import reconnect_mcp_server
    get_manager().evict(server_name, hermes_home=home)
    reconnect_mcp_server(server_name)


async def import_owner_tokens(home: Path, server_name: str, tokens: OwnerTokens) -> Optional[str]:
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from tools.mcp_oauth import HermesTokenStorage
    if (entry := catalog_entry(server_name)) is None:
        return NOT_OAUTH_SERVICE
    if validate(tokens) is not None:
        return INVALID_REQUEST
    scope = set_hermes_home_override(home)
    try:
        if (refusal := _ensure_server_config(entry, home)) is not None:
            return refusal
        storage = HermesTokenStorage(server_name, hermes_home=home)
        before = storage.snapshot()
        try:
            await _write_state(storage, tokens)
        except Exception as exc:  # health: allow BLE001 -- restore the previous state on any write failure; only the exception type is logged because pydantic errors echo the token input
            storage.restore(before)
            logger.warning("OAuth hand-over for MCP server '%s' was not saved (%s)", server_name, type(exc).__name__)
            return SAVE_FAILED
        _wake_connection(server_name, home)
    finally:
        reset_hermes_home_override(scope)
    return None
