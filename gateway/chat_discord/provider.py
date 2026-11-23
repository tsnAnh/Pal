from __future__ import annotations

import logging
import re
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from agent.vault_store import VaultError, VaultStore
from gateway.chat_slack.icon import store_icon
from gateway.chat_slack.provider import profile_identity
from hermes_constants import get_default_hermes_root
from tui_gateway.chat_install import (
    DISCORD_CAPABILITIES,
    DISCORD_IDENTITY_POLICY,
    BotIdentitySource,
    ChatProvider,
    IdentityUpdate,
    SpaceJoin,
)
from tui_gateway.contracts.chat_provider import (
    Capabilities,
    IdentityProjection,
    IdentityUpdateOutcome,
    Installation,
    InstallationStatus,
    NextAction,
    NextActionKind,
    SetupErrorCode,
    SetupState,
    SpaceJoinOutcome,
    SpaceKind,
    SpaceLeaveOutcome,
    SpaceRef,
)

from .api import (
    BOT_NOT_IN_SERVER, MISSING_INTENT, MISSING_PERMISSION, NO_TOKEN, DiscordApi, DiscordGone, DiscordSetupError,
)
from .default_profile import OwnerAllowlist, ProfileRoutes, RouteConflict
from .naming import CATEGORY_NAME, avatar_data_uri, unique_channel_name, webhook_name
from .records import DiscordRecords
from .rest import GUILD_CATEGORY, GUILD_TEXT, DiscordRest, webhook_url

logger = logging.getLogger(__name__)

SNOWFLAKE = re.compile(r"\d{1,20}")
MENTION = re.compile(r"<@!?(\d{1,20})>")
_NO_ACTION = NextAction(kind=NextActionKind.none, action_id="none")
_NEEDS_ACCESS = NextAction(kind=NextActionKind.button, action_id="grant_channel_access")


def saved_app_token() -> str | None:
    from tui_gateway.discord_connector import saved_token
    return saved_token()


class DiscordProvider(ChatProvider):
    provider_id = "discord"
    per_bot_adapter = False
    needs_public_url = False

    def __init__(self, *, vault: VaultStore | None = None, api: DiscordApi | None = None,
                 records: DiscordRecords | None = None, routes: ProfileRoutes | None = None,
                 allowlist: OwnerAllowlist | None = None,
                 identity: Callable[[str], BotIdentitySource] = profile_identity,
                 token_source: Callable[[], str | None] = saved_app_token,
                 clock: Callable[[], float] = time.time):
        self.vault = vault or VaultStore(get_default_hermes_root() / "vault")
        self.api = api or DiscordApi()
        self.records = records or DiscordRecords()
        self.routes = routes or ProfileRoutes()
        self.allowlist = allowlist or OwnerAllowlist()
        self._identity, self._token_source, self._clock = identity, token_source, clock

    def capabilities(self, workspace: str | None = None) -> Capabilities:
        return DISCORD_CAPABILITIES

    def identity_projection(self, source: BotIdentitySource) -> IdentityProjection:
        name = source.display_name.strip() or source.bot
        avatar = Path(source.avatar_path) if source.avatar_path else None
        size = avatar.stat().st_size if avatar and avatar.is_file() else None
        username = webhook_name(name)
        return IdentityProjection(
            app_name=username[: DISCORD_IDENTITY_POLICY.app_name_max].strip(),
            display_name=name[: DISCORD_IDENTITY_POLICY.display_name_max].strip(), username=username,
            avatar_ref=source.avatar_path if size else None, avatar_bytes=size,
        )

    def parse_owner_identity(self, raw: str) -> str | None:
        text = raw.strip()
        mention = MENTION.fullmatch(text)
        user = mention.group(1) if mention else text
        return user if SNOWFLAKE.fullmatch(user) else None

    def authorizing_identity(self, installation: Installation) -> str | None:
        return self._record_for(installation)[1].get("owner_id") or None

    def adapter_env(self, installation: Installation) -> dict[str, str]:
        return {}

    def apply_owner(self, installation: Installation, owner: str) -> None:
        if self.allowlist.ensure(owner):
            self.allowlist.apply_live()

    def install_in_place(self, state: SetupState) -> Installation:
        token = self._token()
        rest = DiscordRest(self.api, token)
        guild_id = self._guild_for(rest, state.workspace)
        return self._ensure(rest, state.bot, guild_id)

    def update_identity(self, installation: Installation) -> IdentityUpdate:
        rest = DiscordRest(self.api, self._token())
        self._ensure(rest, installation.bot, installation.workspace_id)
        projection = self.identity_projection(self._identity(installation.bot))
        return IdentityUpdate(IdentityUpdateOutcome.updated, projection, _NO_ACTION)

    def store_icon(self, bot: str, png: bytes) -> None:
        store_icon(bot, png)

    def _token(self) -> str:
        token = self._token_source()
        if not token:
            raise DiscordSetupError(SetupErrorCode.credential_rejected, NO_TOKEN)
        return token

    @staticmethod
    def _guild_for(rest: DiscordRest, workspace: str) -> str:
        if workspace:
            if not SNOWFLAKE.fullmatch(workspace):
                raise DiscordSetupError(SetupErrorCode.install_failed, "bad_server_id")
            return workspace
        guilds = rest.guilds()
        if not guilds:
            raise DiscordSetupError(SetupErrorCode.allow_denied, BOT_NOT_IN_SERVER)
        if len(guilds) > 1:
            raise DiscordSetupError(SetupErrorCode.install_failed, "choose_server")
        return str(guilds[0]["id"])

    def _ensure(self, rest: DiscordRest, bot: str, guild_id: str) -> Installation:
        bot_id = str(rest.me()["id"])
        guild = self._guild(rest, guild_id)
        if not rest.message_content_enabled():
            raise DiscordSetupError(SetupErrorCode.install_failed, MISSING_INTENT)
        if missing := rest.missing_permissions(guild_id, bot_id):
            raise DiscordSetupError(SetupErrorCode.install_failed, MISSING_PERMISSION, permissions=tuple(missing))
        source = self._identity(bot)
        projection = self.identity_projection(source)
        avatar = avatar_data_uri(projection.avatar_ref)
        record = self.records.app(bot, guild_id)
        channel_id = self._ensure_channel(rest, bot, guild_id, record, projection)
        self.records.update_app(bot, guild_id, guild_id=guild_id, guild_name=str(guild.get("name") or guild_id),
                                channel_id=channel_id)
        webhook_id, item_id = self._ensure_webhook(rest, bot, channel_id, record, projection, avatar)
        self.records.update_app(bot, guild_id, webhook_id=webhook_id, webhook_item_id=item_id)
        extras = [c for c in record.get("extra_channel_ids", []) if c != channel_id]
        self._route(bot, [channel_id, *extras], record.get("channel_id"))
        now = self._clock()
        self.records.update_app(
            bot, guild_id, guild_id=guild_id, guild_name=str(guild.get("name") or guild_id), channel_id=channel_id,
            webhook_id=webhook_id, webhook_item_id=item_id, extra_channel_ids=extras, owner_id=self._owner(record),
            installation_id=f"discord-{guild_id}-{bot}", installed_at=record.get("installed_at", now), updated_at=now)
        logger.info("discord bot %s installed in server %s channel %s", bot, guild_id, channel_id)
        return self._installation(bot, self.records.app(bot, guild_id))

    @staticmethod
    def _guild(rest: DiscordRest, guild_id: str) -> dict[str, Any]:
        try:
            return rest.guild(guild_id)
        except DiscordGone:
            raise DiscordSetupError(SetupErrorCode.allow_denied, BOT_NOT_IN_SERVER) from None

    def _owner(self, record: dict[str, Any]) -> str:
        return (self.allowlist.users() or [str(record.get("owner_id") or "")])[0]

    def _ensure_channel(self, rest: DiscordRest, bot: str, guild_id: str, record: dict[str, Any],
                        projection: IdentityProjection) -> str:
        channels = rest.channels(guild_id)
        known = {str(c["id"]) for c in channels if c.get("type") == GUILD_TEXT}
        if record.get("channel_id") in known:
            return str(record["channel_id"])
        taken = {str(c.get("name")) for c in channels}
        parent = self._category(rest, guild_id, channels)
        created = rest.create_channel(guild_id, {
            "name": unique_channel_name(projection.display_name, taken), "type": GUILD_TEXT, "parent_id": parent,
            "topic": f"{projection.display_name} on Pal"})
        return str(created["id"])

    @staticmethod
    def _category(rest: DiscordRest, guild_id: str, channels: list[dict[str, Any]]) -> str:
        found = next((c for c in channels if c.get("type") == GUILD_CATEGORY
                      and str(c.get("name", "")).lower() == CATEGORY_NAME.lower()), None)
        if found is not None:
            return str(found["id"])
        return str(rest.create_channel(guild_id, {"name": CATEGORY_NAME, "type": GUILD_CATEGORY})["id"])

    def _ensure_webhook(self, rest: DiscordRest, bot: str, channel_id: str, record: dict[str, Any],
                        projection: IdentityProjection, avatar: str | None) -> tuple[str, str]:
        webhook_id, item_id = record.get("webhook_id"), record.get("webhook_item_id")
        if webhook_id and item_id and self._secret_on_file(item_id):
            try:
                live = rest.webhook(webhook_id)
            except DiscordGone:
                live = None
            if live is not None and str(live.get("channel_id")) == channel_id:
                rest.edit_webhook(webhook_id, projection.username, avatar)
                return webhook_id, item_id
        self._drop_webhook(rest, webhook_id, item_id)
        created = rest.create_webhook(channel_id, projection.username, avatar)
        item = self.vault.add_item("api_key", f"Discord webhook for {bot}", {"api_key": webhook_url(created)})
        return str(created["id"]), item.id

    def _drop_webhook(self, rest: DiscordRest, webhook_id: str | None, item_id: str | None) -> None:
        if webhook_id:
            try:
                rest.delete_webhook(webhook_id)
            except DiscordGone:
                pass
        if item_id:
            self.vault.remove_item(item_id)

    def _route(self, bot: str, channels: list[str], previous_home: str | None) -> None:
        changed = False
        try:
            for channel_id in channels:
                changed = self.routes.set(bot, channel_id) or changed
        except RouteConflict:
            raise DiscordSetupError(SetupErrorCode.install_failed, "route_conflict") from None
        if previous_home and previous_home != channels[0]:
            changed = self.routes.remove(bot, previous_home) or changed
        if changed:
            self.routes.apply_live()

    def _secret_on_file(self, item_id: str) -> bool:
        try:
            return bool(self.vault.resolve_secret(item_id).get("api_key"))
        except VaultError:
            return False

    def _installation(self, bot: str, record: dict[str, Any]) -> Installation:
        return Installation(
            id=record["installation_id"], provider_id=self.provider_id, bot=bot, workspace_id=record["guild_id"],
            workspace_name=record["guild_name"], status=InstallationStatus.active, created_at=record["installed_at"],
            updated_at=record["updated_at"], vault_item_ids=[record["webhook_item_id"]])

    def _record_for(self, installation: Installation) -> tuple[str, dict[str, Any]]:
        guild_id, record = self.records.app_by_installation(installation.id)
        if record is None or not record.get("webhook_id"):
            raise DiscordSetupError(SetupErrorCode.install_failed, "no_record")
        return guild_id, record

    def list_spaces(self, installation: Installation) -> list[SpaceRef]:
        _, record = self._record_for(installation)
        mine = {record["channel_id"], *record.get("extra_channel_ids", [])}
        channels = DiscordRest(self.api, self._token()).channels(installation.workspace_id)
        return [SpaceRef(id=str(c["id"]), name=str(c.get("name", "")), kind=SpaceKind.public, joined=str(c["id"]) in mine)
                for c in channels if c.get("type") == GUILD_TEXT]

    def join_space(self, installation: Installation, space_id: str) -> SpaceJoin:
        guild_id, record = self._record_for(installation)
        mine = [record["channel_id"], *record.get("extra_channel_ids", [])]
        if space_id in mine:
            return SpaceJoin(SpaceJoinOutcome.already_joined, _NO_ACTION)
        visible = {str(c["id"]) for c in DiscordRest(self.api, self._token()).channels(guild_id) if c.get("type") == GUILD_TEXT}
        if space_id not in visible:
            return SpaceJoin(SpaceJoinOutcome.needs_invite, _NEEDS_ACCESS)
        self._route(installation.bot, [*mine, space_id], None)
        self.records.update_app(installation.bot, guild_id, extra_channel_ids=[*record.get("extra_channel_ids", []), space_id])
        return SpaceJoin(SpaceJoinOutcome.joined, _NO_ACTION)

    def leave_space(self, installation: Installation, space_id: str) -> SpaceLeaveOutcome:
        guild_id, record = self._record_for(installation)
        extras = list(record.get("extra_channel_ids", []))
        if space_id not in extras:
            return SpaceLeaveOutcome.not_member
        if self.routes.remove(installation.bot, space_id):
            self.routes.apply_live()
        self.records.update_app(installation.bot, guild_id, extra_channel_ids=[c for c in extras if c != space_id])
        return SpaceLeaveOutcome.left

    def revoke(self, installation: Installation) -> None:
        guild_id, record = self.records.app_by_installation(installation.id)
        if record is None or not record.get("webhook_id"):
            return
        self._delete_remote_webhook(record["webhook_id"])
        removed = [self.routes.remove(installation.bot, c) for c in [record["channel_id"], *record.get("extra_channel_ids", [])]]
        if any(removed):
            self.routes.apply_live()
        self.vault.remove_item(record["webhook_item_id"])
        self.records.update_app(installation.bot, guild_id, webhook_id="", webhook_item_id="", extra_channel_ids=[],
                                updated_at=self._clock())
        logger.info("discord bot %s revoked; its channel %s stays", installation.bot, record["channel_id"])

    def _delete_remote_webhook(self, webhook_id: str) -> None:
        if not (token := self._token_source()):
            logger.warning("discord webhook %s not deleted: no saved bot token", webhook_id)
            return
        try:
            DiscordRest(self.api, token).delete_webhook(webhook_id)
        except DiscordGone:
            return
        except DiscordSetupError as exc:
            if exc.code is SetupErrorCode.provider_unreachable:
                raise
            logger.warning("discord webhook %s not deleted: %s", webhook_id, exc.code.value)
