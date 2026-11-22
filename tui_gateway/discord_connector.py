from __future__ import annotations

import json
import logging
from dataclasses import dataclass

import httpx

from gateway import connector_setup_checks as checks
from tui_gateway.contracts.connectors import (
    ConnectorErrorReason,
    DiscordBotResult,
    DiscordGuildRow,
    DiscordGuildsResult,
    DiscordSaveResult,
)

logger = logging.getLogger(__name__)

SLUG = "discord"
TOKEN_VAR = "DISCORD_TOKEN"


class DiscordRpcError(Exception):
    def __init__(self, code: int, reason: ConnectorErrorReason, message: str):
        super().__init__(reason.value)
        self.code, self.reason, self.message = code, reason, message


NOT_OWNER = (4030, ConnectorErrorReason.not_owner, "Only the owner can set up this app.")
NEEDS_TOKEN = (4090, ConnectorErrorReason.needs_setup, "Paste your Discord bot token first.")
UNAVAILABLE = (5034, ConnectorErrorReason.check_unavailable, "Couldn't reach Discord. Try again.")
REJECTED = (4000, ConnectorErrorReason.invalid_token, "Discord didn't accept the saved bot token. Paste it again.")


@dataclass(frozen=True)
class SavedBot:
    application_id: str
    name: str


def _home():
    from hermes_cli.shared_catalog_connectors import owner_state_home
    return owner_state_home(SLUG)


def _bot_path():
    return _home() / "connectors" / "discord_bot.json"


def _require_owner() -> None:
    from tui_gateway.ws_legacy_fallback import connection_profile_home
    if connection_profile_home() is not None:
        raise DiscordRpcError(*NOT_OWNER)


def _entry():
    from hermes_cli.pal_connectors import load_pal_connectors
    return next(e for e in load_pal_connectors() if e.id == SLUG)


def saved_token() -> str | None:
    from hermes_cli.config import load_env
    from hermes_cli.shared_catalog_connectors import owner_state_scope
    with owner_state_scope(SLUG):
        return (load_env().get(TOKEN_VAR) or "").strip() or None


def saved_bot() -> SavedBot | None:
    try:
        raw = json.loads(_bot_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict) or not str(raw.get("application_id", "")).isdigit():
        return None
    return SavedBot(raw["application_id"], str(raw.get("name") or raw["application_id"]))


def _client() -> httpx.Client:
    return httpx.Client(transport=checks.default_transport, timeout=checks.TIMEOUT_SECONDS, follow_redirects=False)


def _bot(token: str) -> checks.DiscordBot:
    try:
        with _client() as client:
            bot = checks.discord_bot(client, token)
    except httpx.HTTPError as exc:
        logger.warning("discord bot check unavailable error=%s", type(exc).__name__)
        raise DiscordRpcError(*UNAVAILABLE) from None
    if isinstance(bot, checks.CheckOutcome):
        raise DiscordRpcError(*(REJECTED if bot.reason == "invalid_token" else UNAVAILABLE))
    return bot


def save_token(item: str) -> DiscordBotResult:
    from hermes_cli.config import save_env_value
    from utils import atomic_write_text

    from gateway import oauth_client_setup as setup_mod
    from hermes_cli.shared_catalog_connectors import requested_profile_home
    from tui_gateway.connector_setup_guide import _secret

    _require_owner()
    token = _secret(setup_mod.vault_for(requested_profile_home()), item)
    bot = _bot(token)
    save_env_value(TOKEN_VAR, token)
    path = _bot_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(path, json.dumps({"application_id": bot.id, "name": bot.name}))
    return DiscordBotResult(bot_name=bot.name, application_id=bot.id)


def _live_guilds(token: str) -> list[DiscordGuildRow]:
    try:
        with _client() as client:
            response = client.get(f"{checks.DISCORD_API}/users/@me/guilds", params={"limit": 200},
                                  headers=checks.discord_headers(token))
    except httpx.HTTPError as exc:
        logger.warning("discord guild list unavailable error=%s", type(exc).__name__)
        raise DiscordRpcError(*UNAVAILABLE) from None
    if response.status_code in (401, 403):
        raise DiscordRpcError(*REJECTED)
    try:
        body = response.json()
    except ValueError:
        body = None
    if response.status_code != 200 or not isinstance(body, list):
        raise DiscordRpcError(*UNAVAILABLE)
    return [DiscordGuildRow(id=g["id"], name=str(g.get("name") or g["id"])) for g in body
            if isinstance(g, dict) and str(g.get("id", "")).isdigit()]


def _saved_server() -> dict | None:
    from hermes_cli import mcp_config as mc
    server = mc._get_mcp_servers().get(SLUG)
    return server if isinstance(server, dict) else None


def _allowed(server: dict | None) -> list[str]:
    raw = str(((server or {}).get("env") or {}).get("DISCORD_ALLOWED_GUILDS") or "")
    return [g for g in raw.split(",") if g]


def _read_only(server: dict | None) -> bool:
    return str(((server or {}).get("env") or {}).get("DISCORD_MCP_READ_ONLY", "true")).lower() != "false"


def guilds() -> DiscordGuildsResult:
    _require_owner()
    token = saved_token()
    if token is None:
        raise DiscordRpcError(*NEEDS_TOKEN)
    server = _saved_server()
    return DiscordGuildsResult(guilds=_live_guilds(token), allowed=_allowed(server), read_only=_read_only(server))


def server_config(guild_ids: list[str], read_only: bool) -> dict:
    recipe = _entry().stdio
    env = {**dict(recipe.env), "DISCORD_MCP_READ_ONLY": "true" if read_only else "false",
           "DISCORD_ALLOWED_GUILDS": ",".join(sorted(set(guild_ids)))}
    return {"command": recipe.command, "args": list(recipe.args), "env": env}


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
                         name="discord-connector-restart").start()


def save(guild_ids: list[str], read_only: bool) -> DiscordSaveResult:
    from hermes_cli import mcp_config as mc
    from tui_gateway import mcp_header_secrets as hs

    _require_owner()
    token = saved_token()
    if token is None:
        raise DiscordRpcError(*NEEDS_TOKEN)
    known = {g.id for g in _live_guilds(token)}
    if not guild_ids or not set(guild_ids) <= known:
        raise DiscordRpcError(4000, ConnectorErrorReason.invalid_params, "Pick at least one server the bot is in.")
    previous = _saved_server()
    cfg = server_config(guild_ids, read_only)
    if not hs.commit(SLUG, cfg, {}, []):
        raise DiscordRpcError(5034, ConnectorErrorReason.connect_failed, "Pal refused to start Discord.")
    try:
        tools = mc._probe_single_server(SLUG, cfg)
    except Exception as exc:  # health: allow BLE001 -- any handshake failure means not connected; its text may carry launch env
        logger.warning("discord mcp handshake failed error=%s", type(exc).__name__)
        tools = []
    if not tools:
        _restore(previous)
        raise DiscordRpcError(5034, ConnectorErrorReason.connect_failed, "Discord didn't start on your Pal. Try again.")
    if previous is not None:
        _restart_live()
    return DiscordSaveResult(tools=len(tools), read_only=read_only, guild_ids=sorted(set(guild_ids)))
