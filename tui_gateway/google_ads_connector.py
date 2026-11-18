from __future__ import annotations

import contextlib
import logging
import os
import re
from pathlib import Path

import httpx

from gateway import oauth_client_setup as setup_mod
from tui_gateway.contracts.connectors import (
    ConnectorErrorReason,
    GoogleAdsCheck,
    GoogleAdsSaveResult,
    GoogleAdsState,
    GoogleAdsStatusResult,
    GoogleAdsVerifyResult,
)

logger = logging.getLogger(__name__)

SLUG = setup_mod.ADS_PROVIDER
CREDENTIALS_FILE = "credentials.json"
TOOLS_CONFIG_FILE = "tools_config.yaml"
CREDENTIALS_ENV = "GOOGLE_APPLICATION_CREDENTIALS"
TOOLS_CONFIG_ENV = "GOOGLE_ADS_MCP_TOOLS_CONFIG"
LOGIN_CUSTOMER_ENV = "GOOGLE_ADS_LOGIN_CUSTOMER_ID"
READ_ONLY_NAMESPACES = {"customers": True, "search": True, "metadata": True, "labels": False, "assets": False}
READ_ONLY_TOOLS = (
    "customers_list_accessible_customers",
    "metadata_get_resource_metadata",
    "search_search",
)
LOGIN_CUSTOMER_ID = re.compile(r"^[0-9]{1,20}$")
TOKEN_URI = "https://oauth2.googleapis.com/token"
ACCESSIBLE_CUSTOMERS_URL = "https://googleads.googleapis.com/v25/customers:listAccessibleCustomers"
HTTP_TIMEOUT_SECONDS = 15.0
NOT_APPROVED_CODES = ("CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION", "DEVELOPER_TOKEN_NOT_APPROVED")
REAUTH_ERRORS = ("invalid_grant", "invalid_client", "unauthorized_client")


class GoogleAdsRpcError(Exception):
    def __init__(self, code: int, reason: ConnectorErrorReason, message: str):
        super().__init__(reason.value)
        self.code, self.reason, self.message = code, reason, message


NOT_OWNER = (4030, ConnectorErrorReason.not_owner, "Only the owner can set up this app.")
NEEDS_SETUP = (4090, ConnectorErrorReason.needs_setup, "Set up Google Workspace first. Google Ads uses the same Google sign-in client.")
NEEDS_SIGN_IN = (4090, ConnectorErrorReason.needs_setup, "Sign in to Google Ads first.")
CLIENT_UNREADABLE = (4000, ConnectorErrorReason.client_unreadable, "Couldn't read the saved Google client. Set it up again.")
BAD_LOGIN_ID = (4000, ConnectorErrorReason.invalid_params, "Enter the manager account ID as digits only.")
START_FAILED = (5034, ConnectorErrorReason.connect_failed, "Google Ads didn't start on your Pal. Try again.")


def _home() -> Path:
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def _require_owner() -> None:
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        raise GoogleAdsRpcError(*NOT_OWNER)


def _entry():
    from hermes_cli.pal_connectors import load_pal_connectors
    return next(e for e in load_pal_connectors() if e.id == SLUG)


def connector_dir(home) -> Path:
    return Path(home) / "connectors" / SLUG


def credentials_path(home) -> Path:
    return connector_dir(home) / CREDENTIALS_FILE


def tools_config_path(home) -> Path:
    return connector_dir(home) / TOOLS_CONFIG_FILE


def tools_config_text() -> str:
    rows = "".join(f"  {name}: {'true' if enabled else 'false'}\n" for name, enabled in READ_ONLY_NAMESPACES.items())
    return "namespaces:\n" + rows


def clean_login_customer_id(raw: str | None) -> str | None:
    text = (raw or "").strip()
    if not text:
        return None
    if not LOGIN_CUSTOMER_ID.match(text):
        raise GoogleAdsRpcError(*BAD_LOGIN_ID)
    return text


def write_credentials(home, client_id: str, client_secret: str, refresh_token: str) -> Path:
    from utils import atomic_json_write, atomic_write_text
    directory = connector_dir(home)
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    atomic_json_write(credentials_path(home), {
        "type": "authorized_user", "client_id": client_id, "client_secret": client_secret,
        "refresh_token": refresh_token}, mode=0o600)
    atomic_write_text(tools_config_path(home), tools_config_text(), mode=0o600)
    return credentials_path(home)


def delete_credentials(home) -> None:
    directory = connector_dir(home)
    for name in (CREDENTIALS_FILE, TOOLS_CONFIG_FILE):
        (directory / name).unlink(missing_ok=True)
    with contextlib.suppress(OSError):
        directory.rmdir()


def _sign_in_secrets(home, store: setup_mod.OAuthClientStore) -> tuple[str, str, str]:
    row = store.connection(SLUG, setup_mod.profile_key(home))
    if row is None or row[1] is None:
        raise GoogleAdsRpcError(*NEEDS_SIGN_IN)
    record = store.client(setup_mod.GOOGLE_PROVIDER)
    if record is None:
        raise GoogleAdsRpcError(*NEEDS_SETUP)
    from agent.vault_store import VaultError
    try:
        client_id, client_secret = setup_mod.resolve_client(record)
        refresh = str(setup_mod.vault_for(setup_mod.profile_key(home)).resolve_secret(row[1]).get("api_key") or "").strip()
    except (setup_mod.SetupError, VaultError):
        raise GoogleAdsRpcError(*CLIENT_UNREADABLE) from None
    if not refresh:
        raise GoogleAdsRpcError(*CLIENT_UNREADABLE)
    return client_id, client_secret, refresh


def refresh_credentials(home, store: setup_mod.OAuthClientStore | None = None) -> Path:
    client_id, client_secret, refresh = _sign_in_secrets(home, store or setup_mod.build_store(home))
    return write_credentials(home, client_id, client_secret, refresh)


def server_config(home, login_customer_id: str | None) -> dict:
    recipe = _entry().stdio
    env = {**dict(recipe.env), CREDENTIALS_ENV: str(credentials_path(home)), TOOLS_CONFIG_ENV: str(tools_config_path(home))}
    if login_customer_id:
        env[LOGIN_CUSTOMER_ENV] = login_customer_id
    return {"command": recipe.command, "args": list(recipe.args), "env": env, "tools": {"include": list(READ_ONLY_TOOLS)}}


def _saved_server() -> dict | None:
    from hermes_cli import mcp_config as mc
    server = mc._get_mcp_servers().get(SLUG)
    return server if isinstance(server, dict) else None


def _saved_login_customer_id(server: dict | None) -> str | None:
    return str(((server or {}).get("env") or {}).get(LOGIN_CUSTOMER_ENV) or "").strip() or None


def status() -> GoogleAdsStatusResult:
    _require_owner()
    store = setup_mod.build_store()
    home = _home()
    server = _saved_server()
    configured = server is not None
    if configured:
        from hermes_cli import mcp_catalog
        configured = mcp_catalog.is_enabled(SLUG)
    if store.client(setup_mod.GOOGLE_PROVIDER) is None:
        state = GoogleAdsState.needs_setup
    else:
        link = setup_mod.google_status(store, home, SLUG)
        if link is None:
            state = GoogleAdsState.needs_sign_in
        elif link is setup_mod.ConnectionStatus.needs_reconnect:
            state = GoogleAdsState.needs_reconnect
        else:
            state = GoogleAdsState.signed_in
    return GoogleAdsStatusResult(state=state, configured=configured, login_customer_id=_saved_login_customer_id(server))


def _restore(previous: dict | None) -> None:
    from tui_gateway import mcp_header_secrets as hs
    if previous is None:
        from hermes_cli import mcp_config as mc
        mc._remove_mcp_server(SLUG)
    else:
        hs.commit(SLUG, previous, {}, [])


def _restart_live() -> None:
    from agent.memory_provider import spawn_context_thread
    from tools import mcp_tool_discovery as discovery
    spawn_context_thread(discovery.restart_mcp_servers_with_new_inputs, args=({SLUG},),
                         name="google-ads-connector-restart").start()


def save(login_customer_id: str | None) -> GoogleAdsSaveResult:
    from hermes_cli import mcp_config as mc
    from tui_gateway import mcp_header_secrets as hs

    _require_owner()
    login = clean_login_customer_id(login_customer_id)
    home = _home()
    refresh_credentials(home)
    previous = _saved_server()
    cfg = server_config(home, login)
    if not hs.commit(SLUG, cfg, {}, []):
        raise GoogleAdsRpcError(*START_FAILED)
    try:
        tools = mc._probe_single_server(SLUG, cfg)
    except Exception as exc:  # health: allow BLE001 -- any handshake failure means not connected; its text may carry launch env
        logger.warning("google ads mcp handshake failed error=%s", type(exc).__name__)
        tools = []
    names = {name for name, _ in tools}
    if not names or not names <= set(READ_ONLY_TOOLS):
        logger.warning("google ads mcp refused tools=%d unexpected=%d", len(names), len(names - set(READ_ONLY_TOOLS)))
        _restore(previous)
        raise GoogleAdsRpcError(*START_FAILED)
    if previous is not None:
        _restart_live()
    return GoogleAdsSaveResult(tools=len(names), login_customer_id=login)


def not_approved(body: object) -> bool:
    return any(code in str(body) for code in NOT_APPROVED_CODES)


def _access_token(secrets: tuple[str, str, str]) -> str | GoogleAdsCheck:
    client_id, client_secret, refresh = secrets
    response = httpx.post(TOKEN_URI, timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False, data={
        "client_id": client_id, "client_secret": client_secret, "refresh_token": refresh, "grant_type": "refresh_token"})
    try:
        reply = response.json()
    except ValueError:
        reply = {}
    if response.status_code == 200 and isinstance(reply, dict) and reply.get("access_token"):
        return str(reply["access_token"])
    error = reply.get("error") if isinstance(reply, dict) else None
    return GoogleAdsCheck.needs_reauth if error in REAUTH_ERRORS else GoogleAdsCheck.unreachable


def _mark_reconnect(store: setup_mod.OAuthClientStore, home) -> None:
    key = setup_mod.profile_key(home)
    row = store.connection(SLUG, key)
    if row is not None:
        store.set_connection(SLUG, key, setup_mod.ConnectionStatus.needs_reconnect, row[1])


def verify() -> GoogleAdsVerifyResult:
    _require_owner()
    home = _home()
    store = setup_mod.build_store(home)
    secrets = _sign_in_secrets(home, store)
    try:
        token = _access_token(secrets)
        if isinstance(token, GoogleAdsCheck):
            if token is GoogleAdsCheck.needs_reauth:
                _mark_reconnect(store, home)
            return GoogleAdsVerifyResult(check=token, accounts=None)
        response = httpx.get(ACCESSIBLE_CUSTOMERS_URL, headers={"Authorization": f"Bearer {token}"},
                             timeout=HTTP_TIMEOUT_SECONDS, follow_redirects=False)
    except httpx.HTTPError as exc:
        logger.warning("google ads verify unreachable error=%s", type(exc).__name__)
        return GoogleAdsVerifyResult(check=GoogleAdsCheck.unreachable, accounts=None)
    try:
        body = response.json()
    except ValueError:
        body = {}
    if response.status_code == 200 and isinstance(body, dict):
        names = body.get("resourceNames")
        return GoogleAdsVerifyResult(check=GoogleAdsCheck.ready, accounts=len(names) if isinstance(names, list) else 0)
    if response.status_code == 401:
        _mark_reconnect(store, home)
        return GoogleAdsVerifyResult(check=GoogleAdsCheck.needs_reauth, accounts=None)
    if response.status_code == 403 and not_approved(body):
        return GoogleAdsVerifyResult(check=GoogleAdsCheck.explorer_access_needed, accounts=None)
    logger.warning("google ads verify refused status=%s", response.status_code)
    return GoogleAdsVerifyResult(check=GoogleAdsCheck.unreachable, accounts=None)


def sign_out() -> None:
    from hermes_cli import mcp_config as mc
    home = _home()
    setup_mod.google_remove(setup_mod.build_store(home), home, SLUG)
    if mc._get_mcp_servers().get(SLUG) is not None:
        mc._remove_mcp_server(SLUG)
