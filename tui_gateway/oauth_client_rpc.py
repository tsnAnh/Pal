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

PROVIDERS = frozenset({setup_mod.GOOGLE_PROVIDER})
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
    redirect = setup_mod.google_redirect_url(_public_url())
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


def connect(slug: str) -> OAuthClientConnectResult:
    provider = _provider(slug)
    try:
        link = setup_mod.google_begin(setup_mod.build_store(), _home(), _public_url())
    except setup_mod.SetupError as exc:
        _raise(exc.reason)
    except OAuthClientRpcError:
        raise
    except Exception as exc:  # health: allow BLE001 -- provider and MCP errors may carry secrets, so only the type is logged
        logger.warning("oauth client connect failed provider=%s error=%s", provider, type(exc).__name__)
        _raise("connect_failed")
    return OAuthClientConnectResult(slug=provider, auth_url=link)


def remove(slug: str) -> OAuthClientRemoveResult:
    provider = _provider(slug)
    setup_mod.google_remove(setup_mod.build_store(), _home())
    return OAuthClientRemoveResult(slug=provider, removed=True)


def _legacy_google_signed_in() -> bool:
    from tui_gateway import google_workspace
    try:
        return google_workspace.status()["state"] == "signed_in"
    except (OSError, ValueError, KeyError):
        return False


def oauth_client_status(entry) -> ConnectorCatalogStatus:
    if entry.id != setup_mod.GOOGLE_PROVIDER:
        return ConnectorCatalogStatus.needs_setup
    store = setup_mod.build_store()
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
