from __future__ import annotations

import logging

from gateway import oauth_client_setup as setup_mod
from tui_gateway.contracts.connectors import (
    ConnectorCatalogStatus,
    ConnectorErrorReason,
    OAuthClientConnectResult,
    OAuthClientRemoveResult,
    OAuthClientSetupResult,
)

logger = logging.getLogger(__name__)

PROVIDERS = frozenset({setup_mod.ASANA_PROVIDER, setup_mod.GOOGLE_PROVIDER})
_REASONS = {
    "needs_setup": (4090, ConnectorErrorReason.needs_setup, "Set up this app on your Pal first."),
    "needs_public_url": (4412, ConnectorErrorReason.needs_public_url, "Set this gateway's public address first."),
    "invalid_client": (4000, ConnectorErrorReason.invalid_client, "That doesn't look like this app's client ID."),
    "client_unreadable": (4000, ConnectorErrorReason.client_unreadable, "Couldn't read the saved client. Set it up again."),
}


class OAuthClientRpcError(Exception):
    def __init__(self, code: int, reason: ConnectorErrorReason, message: str):
        super().__init__(reason.value)
        self.code, self.reason, self.message = code, reason, message


def _raise(reason: str):
    code, wire, message = _REASONS.get(reason, (5034, ConnectorErrorReason.connect_failed, "Couldn't start the sign-in."))
    raise OAuthClientRpcError(code, wire, message)


def _home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def _public_url() -> str | None:
    from gateway.chat_install_runtime import public_url_for
    return public_url_for(_home())


def _provider(slug: str) -> str:
    if slug not in PROVIDERS:
        raise OAuthClientRpcError(4041, ConnectorErrorReason.connector_not_found, "Connector not found.")
    return slug


def setup(slug: str) -> OAuthClientSetupResult:
    provider = _provider(slug)
    store = setup_mod.build_store()
    redirect = (setup_mod.ASANA_REDIRECT_URL if provider == setup_mod.ASANA_PROVIDER
                else setup_mod.google_redirect_url(_public_url()))
    return OAuthClientSetupResult(slug=provider, configured=store.client(provider) is not None,
                                  console_url=setup_mod.CONSOLE_URLS[provider], redirect_url=redirect)


def save(request) -> OAuthClientSetupResult:
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    provider = _provider(request.slug)
    if connection_profile_home() is not None:
        raise OAuthClientRpcError(4030, ConnectorErrorReason.not_owner, "Only the owner can set up this app.")
    try:
        setup_mod.save_client(setup_mod.build_store(), provider, _home(), request.client_id_item,
                              request.client_secret_item)
    except setup_mod.SetupError as exc:
        _raise(exc.reason)
    return setup(provider)


def _connect_asana(store, client_redirect_uri: str | None) -> OAuthClientConnectResult:
    from tui_gateway import mcp_header_secrets as hs
    from tui_gateway import mcp_oauth_sessions
    record = store.client(setup_mod.ASANA_PROVIDER)
    if record is None:
        _raise("needs_setup")
    client_id, client_secret = setup_mod.resolve_client(record)
    cfg = setup_mod.asana_server_config(client_id)
    if not hs.commit(setup_mod.ASANA_PROVIDER, cfg, {setup_mod.ASANA_SECRET_ENV: client_secret}, []):
        _raise("connect_failed")
    live = {**cfg, "oauth": {**cfg["oauth"], "client_secret": client_secret}}
    home = str(_home().expanduser().resolve(strict=False))
    result = mcp_oauth_sessions.start_flow(home, setup_mod.ASANA_PROVIDER, live, client_redirect_uri=client_redirect_uri)
    return OAuthClientConnectResult(slug=setup_mod.ASANA_PROVIDER, auth_url=result["auth_url"],
                                    session_id=result["session_id"])


def connect(request) -> OAuthClientConnectResult:
    provider = _provider(request.slug)
    store = setup_mod.build_store()
    try:
        if provider == setup_mod.ASANA_PROVIDER:
            return _connect_asana(store, request.client_redirect_uri)
        link = setup_mod.google_begin(store, _home(), _public_url())
    except setup_mod.SetupError as exc:
        _raise(exc.reason)
    except OAuthClientRpcError:
        raise
    except Exception as exc:  # health: allow BLE001 -- provider and MCP errors may carry secrets, so only the type is logged
        logger.warning("oauth client connect failed provider=%s error=%s", provider, type(exc).__name__)
        _raise("connect_failed")
    return OAuthClientConnectResult(slug=provider, auth_url=link, session_id=None)


def remove(slug: str) -> OAuthClientRemoveResult:
    provider = _provider(slug)
    if provider == setup_mod.ASANA_PROVIDER:
        from hermes_cli.config import remove_env_value
        from tui_gateway import mcp_header_secrets as hs
        removed = hs.remove_server(provider)
        remove_env_value(setup_mod.ASANA_SECRET_ENV)
        return OAuthClientRemoveResult(slug=provider, removed=removed)
    setup_mod.google_remove(setup_mod.build_store(), _home())
    return OAuthClientRemoveResult(slug=provider, removed=True)


def _legacy_google_signed_in() -> bool:
    from tui_gateway import google_workspace
    try:
        return google_workspace.status()["state"] == "signed_in"
    except (OSError, ValueError, KeyError):
        return False


def oauth_client_status(entry) -> ConnectorCatalogStatus:
    from hermes_cli import mcp_catalog
    from tools.mcp_oauth import pending_reauth_reason
    store = setup_mod.build_store()
    if entry.id == setup_mod.GOOGLE_PROVIDER:
        status = setup_mod.google_status(store, _home())
        if status is setup_mod.ConnectionStatus.connected:
            return ConnectorCatalogStatus.connected
        if _legacy_google_signed_in():
            return ConnectorCatalogStatus.connected
        if store.client(entry.id) is None:
            return ConnectorCatalogStatus.needs_setup
        if status is setup_mod.ConnectionStatus.needs_reconnect:
            return ConnectorCatalogStatus.needs_reconnect
        return ConnectorCatalogStatus.not_connected
    if store.client(entry.id) is None:
        return ConnectorCatalogStatus.needs_setup
    if not mcp_catalog.is_enabled(entry.id):
        return ConnectorCatalogStatus.not_connected
    if pending_reauth_reason(entry.id):
        return ConnectorCatalogStatus.needs_reconnect
    return ConnectorCatalogStatus.connected
