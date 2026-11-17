from __future__ import annotations

import io
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from PIL import Image

from agent.vault_store import VaultStore, get_vault_store
from hermes_cli.slack_cli import _build_full_manifest
from tui_gateway.chat_install import (
    SLACK_CAPABILITIES,
    SLACK_IDENTITY_POLICY,
    AppCreated,
    BotIdentitySource,
    ChatProvider,
    SpaceJoin,
)
from tui_gateway.contracts.chat_provider import (
    Capabilities,
    CapabilityEntry,
    CapabilityMode,
    IdentityProjection,
    Installation,
    InstallationStatus,
    NextAction,
    NextActionKind,
    ProviderCapability,
    SetupErrorCode,
    SetupState,
    SpaceJoinOutcome,
    SpaceKind,
    SpaceRef,
)

from .api import SlackApi, SlackSetupError
from .avatar import prepare_avatar
from .records import SlackRecords
from .token_store import ConfigTokenStore

logger = logging.getLogger(__name__)

EXTRA_BOT_SCOPES = ("channels:join", "reactions:write")
APP_LEVEL_SCOPES = "connections:write"
PROBE_APP_NAME = "Pal workspace check (temp)"
NEEDS_INVITE_ERRORS = {"method_not_supported_for_channel_type", "channel_not_found", "is_private"}
GONE_ERRORS = {"app_not_found", "token_revoked", "invalid_auth"}
REFRESH_LIFETIME_UNKNOWN = "unknown"
PROBED = (ProviderCapability.set_icon, ProviderCapability.app_level_credential,
          ProviderCapability.gateway_redirect, ProviderCapability.unattended_refresh)
_NO_ACTION = NextAction(kind=NextActionKind.none, action_id="none")


@dataclass(frozen=True)
class ProbeCheck:
    capability: ProviderCapability
    passed: bool
    slack_error: str | None = None


def _default_identity(bot: str) -> BotIdentitySource:
    return BotIdentitySource(bot=bot, display_name=bot, avatar_path=None)


def _username(name: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-._")
    return (slug or "pal")[: SLACK_IDENTITY_POLICY.username_max]


def _probe_icon() -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (SLACK_IDENTITY_POLICY.avatar_min_px,) * 2, (90, 90, 200)).save(out, format="PNG")
    return out.getvalue()


def bot_manifest(projection: IdentityProjection, redirect_url: str | None, description: str) -> dict[str, Any]:
    manifest = _build_full_manifest(projection.app_name, description)
    manifest["features"]["bot_user"]["display_name"] = projection.display_name
    scopes = manifest["oauth_config"]["scopes"]
    scopes["bot"] = sorted({*scopes["bot"], *EXTRA_BOT_SCOPES})
    if redirect_url:
        manifest["oauth_config"]["redirect_urls"] = [redirect_url]
    return manifest


class SlackProvider(ChatProvider):
    provider_id = "slack"

    def __init__(self, *, redirect_url: str | None = None, vault: VaultStore | None = None,
                 api: SlackApi | None = None, records: SlackRecords | None = None,
                 identity: Callable[[str], BotIdentitySource] = _default_identity,
                 clock: Callable[[], float] = time.time):
        self.redirect_url = redirect_url
        self.vault = vault or get_vault_store()
        self.api = api or SlackApi()
        self.records = records or SlackRecords()
        self.tokens = ConfigTokenStore(self.vault, self.api, self.records, clock=clock)
        self._identity, self._clock = identity, clock

    def capabilities(self, workspace: str | None = None) -> Capabilities:
        stored = self.records.workspace(workspace).get("capabilities", {}) if workspace else {}
        entries = [CapabilityEntry(capability=e.capability, mode=CapabilityMode(stored.get(e.capability.value, e.mode.value)))
                   for e in SLACK_CAPABILITIES.capabilities]
        return SLACK_CAPABILITIES.model_copy(update={"capabilities": entries})

    def _automatic(self, workspace: str, capability: ProviderCapability) -> bool:
        return any(e.capability is capability and e.mode is CapabilityMode.automatic
                   for e in self.capabilities(workspace).capabilities)

    def identity_projection(self, source: BotIdentitySource) -> IdentityProjection:
        name = source.display_name.strip() or source.bot
        avatar = Path(source.avatar_path) if source.avatar_path else None
        size = avatar.stat().st_size if avatar and avatar.is_file() else None
        return IdentityProjection(
            app_name=name[: SLACK_IDENTITY_POLICY.app_name_max].strip(),
            display_name=name[: SLACK_IDENTITY_POLICY.display_name_max].strip(),
            username=_username(name), avatar_ref=source.avatar_path if size else None, avatar_bytes=size,
        )

    def begin_install(self, state: SetupState, config_vault_item_id: str | None) -> AppCreated:
        if not self.redirect_url:
            raise SlackSetupError(SetupErrorCode.app_create_failed)
        workspace, bot = state.workspace, state.bot
        if config_vault_item_id:
            self.tokens.bind(workspace, config_vault_item_id)
        token = self.tokens.valid_config_token(workspace)
        source = self._identity(bot)
        projection = self.identity_projection(source)
        redirect = self.redirect_url if self._automatic(workspace, ProviderCapability.gateway_redirect) else None
        manifest = json.dumps(bot_manifest(projection, redirect, f"{projection.display_name} on Slack"))
        record = self.records.app(bot, workspace)
        app_id = state.app_id or record.get("app_id")
        if not (app_id and record.get("authorize_link") and self._updated(token, app_id, manifest)):
            app_id = self._create(bot, workspace, token, manifest)
        self.records.update_app(bot, workspace, invite_handle=projection.display_name)
        self._finish_app(bot, workspace, token, app_id, source)
        return AppCreated(app_id=app_id, authorize_link=self.records.app(bot, workspace)["authorize_link"])

    def _updated(self, token: str, app_id: str, manifest: str) -> bool:
        try:
            self.api.call("apps.manifest.update", token=token, data={"app_id": app_id, "manifest": manifest})
        except SlackSetupError as exc:
            if exc.slack_error == "app_not_found":
                return False
            raise
        return True

    def _create(self, bot: str, workspace: str, token: str, manifest: str) -> str:
        body = self.api.call("apps.manifest.create", token=token, data={"manifest": manifest})
        app_id, credentials = str(body["app_id"]), body.get("credentials") or {}
        item = self.vault.add_item("api_key", f"Slack app {app_id} credentials",
                                   {"api_key": json.dumps(credentials)})
        stale = self.records.app(bot, workspace)
        self.records.drop_app(bot, workspace)
        self.records.update_app(bot, workspace, app_id=app_id, authorize_link=str(body["oauth_authorize_url"]),
                                credentials_item_id=item.id)
        for old in ("credentials_item_id", "app_token_item_id", "bot_token_item_id"):
            if stale.get(old):
                self.vault.remove_item(stale[old])
        logger.info("slack app %s created for bot %s", app_id, bot)
        return app_id

    def _finish_app(self, bot: str, workspace: str, token: str, app_id: str, source: BotIdentitySource) -> None:
        record = self.records.app(bot, workspace)
        if self._automatic(workspace, ProviderCapability.set_icon) and source.avatar_path and not record.get("icon_set"):
            icon = prepare_avatar(Path(source.avatar_path).read_bytes())
            self.api.call("apps.icon.set", token=token, data={"app_id": app_id},
                          files={"file": ("avatar.png", icon, "image/png")})
            self.records.update_app(bot, workspace, icon_set=True)
        if self._automatic(workspace, ProviderCapability.app_level_credential) and not record.get("app_token_item_id"):
            body = self.api.call("apps.token.create", token=token, data={"app_id": app_id, "scopes": APP_LEVEL_SCOPES})
            item = self.vault.add_item("api_key", f"Slack app {app_id} app-level token", {"api_key": str(body["token"])})
            self.records.update_app(bot, workspace, app_token_item_id=item.id)

    def accept_app_level_credential(self, bot: str, workspace: str, vault_item_id: str) -> None:
        self.records.update_app(bot, workspace, app_token_item_id=vault_item_id)

    def complete_install(self, state: SetupState, authorization_code: str) -> Installation:
        bot, workspace = state.bot, state.workspace
        record = self.records.app(bot, workspace)
        if not record.get("credentials_item_id"):
            raise SlackSetupError(SetupErrorCode.install_failed)
        credentials = json.loads(self._secret(record["credentials_item_id"]))
        body = self.api.call("oauth.v2.access", data={
            "client_id": credentials.get("client_id", ""), "client_secret": credentials.get("client_secret", ""),
            "code": authorization_code, "redirect_uri": self.redirect_url or "",
        })
        team = body.get("team") or {}
        secret = {"api_key": str(body["access_token"])}
        if record.get("bot_token_item_id"):
            self.vault.update_item(record["bot_token_item_id"], secret=secret)
            item_id = record["bot_token_item_id"]
        else:
            item_id = self.vault.add_item("api_key", f"Slack bot token for {bot}", secret).id
        now = self._clock()
        self.records.update_app(
            bot, workspace, bot_token_item_id=item_id, team_id=str(team.get("id", "")),
            team_name=str(team.get("name", "")), bot_user_id=str(body.get("bot_user_id", "")),
            authorizing_user=str((body.get("authed_user") or {}).get("id", "")),
            installation_id=f"slack-{team.get('id', workspace)}-{bot}",
            installed_at=record.get("installed_at", now), updated_at=now,
        )
        logger.info("slack bot %s installed in workspace %s", bot, workspace)
        return self._installation(bot, self.records.app(bot, workspace))

    def _installation(self, bot: str, record: dict[str, Any]) -> Installation:
        items = [record[k] for k in ("bot_token_item_id", "app_token_item_id", "credentials_item_id") if record.get(k)]
        return Installation(
            id=record["installation_id"], provider_id=self.provider_id, bot=bot, workspace_id=record["team_id"],
            workspace_name=record["team_name"], status=InstallationStatus.active,
            created_at=record["installed_at"], updated_at=record["updated_at"], vault_item_ids=items,
        )

    def _record_for(self, installation: Installation) -> tuple[str, dict[str, Any]]:
        workspace, record = self.records.app_by_installation(installation.id)
        if record is None:
            raise SlackSetupError(SetupErrorCode.install_failed)
        return workspace, record

    def authorizing_user(self, installation: Installation) -> str:
        return self._record_for(installation)[1].get("authorizing_user", "")

    def _secret(self, item_id: str) -> str:
        return str(self.vault.resolve_secret(item_id).get("api_key") or "")

    def list_spaces(self, installation: Installation) -> list[SpaceRef]:
        token = self._secret(self._record_for(installation)[1]["bot_token_item_id"])
        spaces, cursor = [], ""
        while True:
            body = self.api.call("conversations.list", token=token, data={
                "types": "public_channel,private_channel", "exclude_archived": "true", "limit": "200", "cursor": cursor})
            spaces += [SpaceRef(id=c["id"], name=c.get("name", ""), joined=bool(c.get("is_member")),
                                kind=SpaceKind.private if c.get("is_private") else SpaceKind.public)
                       for c in body.get("channels", [])]
            cursor = (body.get("response_metadata") or {}).get("next_cursor") or ""
            if not cursor:
                return spaces

    def join_space(self, installation: Installation, space_id: str) -> SpaceJoin:
        _, record = self._record_for(installation)
        try:
            body = self.api.call("conversations.join", token=self._secret(record["bot_token_item_id"]),
                                 data={"channel": space_id})
        except SlackSetupError as exc:
            if exc.slack_error not in NEEDS_INVITE_ERRORS:
                raise
            return SpaceJoin(SpaceJoinOutcome.needs_invite, NextAction(
                kind=NextActionKind.copy_text, action_id="invite",
                copy_text=f"/invite @{record.get('invite_handle') or installation.bot}",
                link=f"https://slack.com/app_redirect?team={record['team_id']}&channel={space_id}"))
        already = body.get("warning") == "already_in_channel"
        return SpaceJoin(SpaceJoinOutcome.already_joined if already else SpaceJoinOutcome.joined, _NO_ACTION)

    def revoke(self, installation: Installation) -> None:
        workspace, record = self._record_for(installation)
        self._tolerate_gone("auth.revoke", token=self._secret(record["bot_token_item_id"]))
        self._tolerate_gone("apps.manifest.delete", token=self.tokens.valid_config_token(workspace),
                            data={"app_id": record["app_id"]})
        for key in ("bot_token_item_id", "app_token_item_id", "credentials_item_id"):
            if record.get(key):
                self.vault.remove_item(record[key])
        self.records.drop_app(installation.bot, workspace)
        logger.info("slack bot %s revoked", installation.bot)

    def _tolerate_gone(self, method: str, **kwargs: Any) -> None:
        try:
            self.api.call(method, **kwargs)
        except SlackSetupError as exc:
            if exc.slack_error not in GONE_ERRORS:
                raise

    def probe_workspace(self, workspace: str, config_vault_item_id: str | None = None) -> list[ProbeCheck]:
        if config_vault_item_id:
            self.tokens.bind(workspace, config_vault_item_id)
        token = self.tokens.rotate(workspace)
        checks = [ProbeCheck(ProviderCapability.unattended_refresh, True), self._probe_redirect(token)]
        redirect = self.redirect_url if checks[1].passed else None
        projection = IdentityProjection(app_name=PROBE_APP_NAME, display_name=PROBE_APP_NAME, username="pal-check")
        manifest = json.dumps(bot_manifest(projection, redirect, "Temporary app; Pal deletes it right away"))
        app_id = str(self.api.call("apps.manifest.create", token=token, data={"manifest": manifest})["app_id"])
        try:
            checks.append(self._try(ProviderCapability.set_icon, "apps.icon.set", token=token, data={"app_id": app_id},
                                    files={"file": ("probe.png", _probe_icon(), "image/png")}))
            checks.append(self._try(ProviderCapability.app_level_credential, "apps.token.create", token=token,
                                    data={"app_id": app_id, "scopes": APP_LEVEL_SCOPES}))
        finally:
            self._delete_probe_app(token, app_id)
        modes = {c.capability.value: (CapabilityMode.automatic if c.passed else CapabilityMode.guided).value for c in checks}
        self.records.update_workspace(workspace, capabilities=modes, refresh_token_lifetime=REFRESH_LIFETIME_UNKNOWN,
                                      probed_at=self._clock())
        return checks

    def _probe_redirect(self, token: str) -> ProbeCheck:
        if not self.redirect_url:
            return ProbeCheck(ProviderCapability.gateway_redirect, False, "no_redirect_url")
        projection = IdentityProjection(app_name=PROBE_APP_NAME, display_name=PROBE_APP_NAME, username="pal-check")
        manifest = json.dumps(bot_manifest(projection, self.redirect_url, "Temporary app"))
        body = self.api.call("apps.manifest.validate", token=token, data={"manifest": manifest}, raw=True)
        pointers = [str(e.get("pointer", "")) for e in body.get("errors") or [] if isinstance(e, dict)]
        rejected = bool(body.get("invalid_redirect_urls")) or any("redirect_urls" in p for p in pointers)
        if not body.get("ok") and not rejected:
            raise SlackSetupError(SetupErrorCode.app_create_failed, str(body.get("error") or ""))
        return ProbeCheck(ProviderCapability.gateway_redirect, not rejected,
                          "invalid_redirect_urls" if rejected else None)

    def _try(self, capability: ProviderCapability, method: str, **kwargs: Any) -> ProbeCheck:
        try:
            self.api.call(method, **kwargs)
        except SlackSetupError as exc:
            if exc.code in (SetupErrorCode.provider_unreachable, SetupErrorCode.credential_rejected,
                            SetupErrorCode.credential_expired):
                raise
            return ProbeCheck(capability, False, exc.slack_error or None)
        return ProbeCheck(capability, True)

    def _delete_probe_app(self, token: str, app_id: str) -> None:
        try:
            self.api.call("apps.manifest.delete", token=token, data={"app_id": app_id})
        except SlackSetupError as exc:
            if exc.slack_error != "app_not_found":
                logger.error("slack probe app %s could not be deleted", app_id)
                raise SlackSetupError(SetupErrorCode.app_create_failed, exc.slack_error, app_id=app_id) from None
