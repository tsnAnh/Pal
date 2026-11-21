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


def providers() -> frozenset[str]:
    return frozenset({*setup_mod.GOOGLE_PROVIDERS, *setup_mod.preregistered_mcp_entries()})


def _provider(slug: str) -> str:
    if slug not in providers():
        raise OAuthClientRpcError(4041, ConnectorErrorReason.connector_not_found, "Connector not found.")
    return slug


def redirect_url(provider: str) -> str | None:
    if provider in setup_mod.GOOGLE_PROVIDERS:
        return setup_mod.google_redirect_url(_public_url())
    return setup_mod.mcp_redirect_url(_public_url()) or setup_mod.MCP_REDIRECT_URL


def setup(slug: str) -> OAuthClientSetupResult:
    provider = _provider(slug)
    store = setup_mod.build_store()
    return OAuthClientSetupResult(slug=provider, configured=store.client(setup_mod.client_provider(provider)) is not None,
                                  console_url=setup_mod.console_url(provider), redirect_url=redirect_url(provider))


def save(request) -> OAuthClientSetupResult:
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    provider = _provider(request.slug)
    if connection_profile_home() is not None:
        raise OAuthClientRpcError(4030, ConnectorErrorReason.not_owner, "Only the owner can set up this app.")
    try:
        setup_mod.save_client(setup_mod.build_store(), setup_mod.client_provider(provider), _home(),
                              request.client_id_item, request.client_secret_item)
    except setup_mod.SetupError as exc:
        _raise(exc.reason)
    return setup(provider)


def _account_target(provider: str, cfg: dict, account, create: bool):
    from hermes_cli.mcp_config import _get_mcp_servers
    from tui_gateway import mcp_account_rpc as accounts
    merged = {**(_get_mcp_servers().get(provider) or {}), **cfg}
    target, failure = accounts.resolve(provider, {provider: merged}, account, create=create, signin=True)
    if failure:
        _raise_account_failure(failure)
    return target


def _raise_account_failure(failure: tuple[int, str]):
    code, message = failure
    reason = ConnectorErrorReason.alias_taken if code == 4090 else ConnectorErrorReason.invalid_params
    raise OAuthClientRpcError(code, reason, message)


def _connect_mcp(provider: str, store, request) -> OAuthClientConnectResult:
    from tui_gateway import mcp_header_secrets as hs
    from tui_gateway import mcp_oauth_sessions
    record = store.client(provider)
    if record is None:
        _raise("needs_setup")
    client_id, client_secret = setup_mod.resolve_client(record)
    home = str(_home().expanduser().resolve(strict=False))
    gateway = None if request.client_redirect_uri else setup_mod.mcp_redirect_url(_public_url())
    cfg = setup_mod.mcp_server_config(provider, client_id, gateway)
    target = _account_target(provider, cfg, request.account, request.create)
    if not hs.commit(provider, cfg, {setup_mod.mcp_secret_env(provider): client_secret}, []):
        _raise("connect_failed")
    if target.alias is None:
        flow_cfg = {**cfg, "oauth": {**cfg["oauth"], "client_secret": client_secret}}
    else:
        flow_cfg = target.cfg
    if gateway:
        result = mcp_oauth_sessions.start_gateway_flow(home, target.connection, flow_cfg, gateway)
    else:
        result = mcp_oauth_sessions.start_flow(
            home, target.connection, flow_cfg, client_redirect_uri=request.client_redirect_uri)
    return OAuthClientConnectResult(slug=provider, auth_url=result["auth_url"], session_id=result["session_id"])


def connect(request) -> OAuthClientConnectResult:
    provider = _provider(request.slug)
    store = setup_mod.build_store()
    try:
        if provider not in setup_mod.GOOGLE_PROVIDERS:
            return _connect_mcp(provider, store, request)
        link = setup_mod.google_begin(store, _home(), _public_url(), provider)
    except setup_mod.SetupError as exc:
        _raise(exc.reason)
    except OAuthClientRpcError:
        raise
    except Exception as exc:  # health: allow BLE001 -- provider and MCP errors may carry secrets, so only the type is logged
        logger.warning("oauth client connect failed provider=%s error=%s", provider, type(exc).__name__)
        _raise("connect_failed")
    return OAuthClientConnectResult(slug=provider, auth_url=link, session_id=None)


def _remove_sign_in(provider: str) -> bool:
    if provider == setup_mod.ADS_PROVIDER:
        from tui_gateway import google_ads_connector
        google_ads_connector.sign_out()
        return True
    if provider == setup_mod.GOOGLE_PROVIDER:
        setup_mod.google_remove(setup_mod.build_store(), _home())
        return True
    from hermes_cli.config import remove_env_value
    from tui_gateway import mcp_header_secrets as hs
    removed = hs.remove_server(provider)
    remove_env_value(setup_mod.mcp_secret_env(provider))
    return removed


def _remove_account(provider: str, account: str) -> bool:
    from hermes_cli.config import remove_env_value
    from hermes_cli.mcp_accounts import remove_account
    from tools.mcp_accounts import AccountError
    from tui_gateway import mcp_account_rpc as accounts
    try:
        outcome = remove_account(provider, account)
    except AccountError as exc:
        _raise_account_failure(accounts.failure_of(exc))
    if outcome.template_removed:
        remove_env_value(setup_mod.mcp_secret_env(provider))
    return True


def remove(request) -> OAuthClientRemoveResult:
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    provider = _provider(request.slug)
    if request.remove_client and connection_profile_home() is not None:
        raise OAuthClientRpcError(4030, ConnectorErrorReason.not_owner, "Only the owner can remove this app's client.")
    removed = _remove_account(provider, request.account) if request.account else _remove_sign_in(provider)
    if request.remove_client:
        removed = setup_mod.remove_client(setup_mod.build_store(), provider) or removed
    return OAuthClientRemoveResult(slug=provider, removed=removed)


def _legacy_google_signed_in() -> bool:
    from tui_gateway import google_workspace
    try:
        return google_workspace.status()["state"] == "signed_in"
    except (OSError, ValueError, KeyError):
        return False


def oauth_client_status(entry) -> ConnectorCatalogStatus:
    from hermes_cli import mcp_catalog
    from hermes_cli.mcp_accounts import template_state
    store = setup_mod.build_store()
    if entry.id == setup_mod.ADS_PROVIDER:
        if store.client(setup_mod.GOOGLE_PROVIDER) is None:
            return ConnectorCatalogStatus.needs_setup
        status = setup_mod.google_status(store, _home(), entry.id)
        if status is setup_mod.ConnectionStatus.connected:
            return ConnectorCatalogStatus.connected
        return ConnectorCatalogStatus.needs_reconnect if status is not None else ConnectorCatalogStatus.not_connected
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
    return ConnectorCatalogStatus(template_state(entry.id))
