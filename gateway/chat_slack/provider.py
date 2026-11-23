from __future__ import annotations

import io
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from PIL import Image

from agent.vault_store import VaultError, VaultStore, get_vault_store
from hermes_cli.slack_cli import _build_full_manifest
from hermes_constants import get_default_hermes_root
from tui_gateway.chat_install import (
    SLACK_CAPABILITIES,
    SLACK_IDENTITY_POLICY,
    AppCreated,
    OWNER_DM_HOME_NAME,
    BotIdentitySource,
    ChatProvider,
    IdentityUpdate,
    PeoplePage,
    SpaceJoin,
)
from tui_gateway.contracts.chat_provider import (
    Capabilities,
    CapabilityEntry,
    CapabilityMode,
    IdentityProjection,
    IdentityUpdateOutcome,
    Installation,
    InstallationStatus,
    NextAction,
    NextActionKind,
    ProviderCapability,
    SetupErrorCode,
    SetupState,
    SpaceJoinOutcome,
    SpaceKind,
    SpaceLeaveOutcome,
    SpaceRef,
)

from .api import SlackApi, SlackSetupError
from .avatar import prepare_avatar
from .icon import icon_path, store_icon
from .people import list_people, names_for
from .records import SlackRecords
from .token_store import REFRESH_TOKEN_PREFIX, ConfigTokenStore
from .workspace_store import WorkspaceRecords, profile_sources

logger = logging.getLogger(__name__)

EXTRA_BOT_SCOPES = ("channels:join", "reactions:write")
APP_LEVEL_SCOPES = "connections:write"
PROBE_APP_NAME = "Pal workspace check (temp)"
NEEDS_INVITE_ERRORS = {"method_not_supported_for_channel_type", "channel_not_found", "is_private"}
GONE_ERRORS = {"app_not_found", "token_revoked", "invalid_auth"}
REFRESH_LIFETIME_UNKNOWN = "unknown"
BOT_TOKEN_PREFIX = "xoxb-"
APP_TOKEN_PREFIX = "xapp-"
APP_TOKEN_APP_ID = re.compile(r"xapp-\d+-([A-Z0-9]+)-\d+-\S+")
PROBE_ABORTING = (SetupErrorCode.credential_rejected, SetupErrorCode.credential_expired)
MEMBER_ID = re.compile(r"[UW][A-Z0-9]{6,20}")
AVATAR_EXTENSIONS = ("png", "jpg", "jpeg", "webp")
PROBED = (ProviderCapability.set_icon, ProviderCapability.app_level_credential,
          ProviderCapability.gateway_redirect, ProviderCapability.unattended_refresh)
LEFT_ALREADY_ERRORS = {"not_in_channel", "channel_not_found", "is_archived"}
_NO_ACTION = NextAction(kind=NextActionKind.none, action_id="none")
SLACK_APPS_URL = "https://api.slack.com/apps"


@dataclass(frozen=True)
class ProbeCheck:
    capability: ProviderCapability
    passed: bool
    slack_error: str | None = None


def profile_identity(bot: str) -> BotIdentitySource:
    from hermes_cli.profiles import get_profile_dir, read_profile_meta
    home = get_profile_dir(bot)
    avatar = next((path for ext in AVATAR_EXTENSIONS if (path := home / "assets" / f"avatar.{ext}").is_file()), None)
    if avatar is None and (icon := icon_path(bot)).is_file():
        avatar = icon
    return BotIdentitySource(bot=bot, display_name=read_profile_meta(home).get("display_name") or bot,
                             avatar_path=str(avatar) if avatar else None)


def _app_token_app_id(key: str) -> str | None:
    match = APP_TOKEN_APP_ID.fullmatch(key)
    return match.group(1) if match else None


def _username(name: str) -> str:
    slug = re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-._")
    return (slug or "pal")[: SLACK_IDENTITY_POLICY.username_max]


def _probe_icon() -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (SLACK_IDENTITY_POLICY.avatar_min_px,) * 2, (90, 90, 200)).save(out, format="PNG")
    return out.getvalue()


def _pal_slash(entry: dict[str, Any]) -> dict[str, Any]:
    reworded = {key: value.replace("Hermes", "Pal") if isinstance(value, str) and key != "url" else value
                for key, value in entry.items()}
    if reworded.get("command") == "/hermes":
        reworded["command"] = "/pal"
    return reworded


def bot_manifest(projection: IdentityProjection, redirect_url: str | None, description: str) -> dict[str, Any]:
    manifest = _build_full_manifest(projection.app_name, description, messaging_experience="none")
    manifest["features"]["bot_user"]["display_name"] = projection.display_name
    manifest["features"]["slash_commands"] = [_pal_slash(entry) for entry in manifest["features"].get("slash_commands", [])]
    scopes = manifest["oauth_config"]["scopes"]
    scopes["bot"] = sorted({*scopes["bot"], *EXTRA_BOT_SCOPES})
    if redirect_url:
        manifest["oauth_config"]["redirect_urls"] = [redirect_url]
    return manifest


class SlackProvider(ChatProvider):
    provider_id = "slack"
    allowed_users_env = "SLACK_ALLOWED_USERS"

    def __init__(self, *, redirect_url: str | None = None, vault: VaultStore | None = None,
                 api: SlackApi | None = None, records: SlackRecords | None = None,
                 workspace_vault: VaultStore | None = None, workspace_records: SlackRecords | None = None,
                 identity: Callable[[str], BotIdentitySource] = profile_identity,
                 clock: Callable[[], float] = time.time):
        self.redirect_url = redirect_url
        self.vault = vault or get_vault_store()
        self.api = api or SlackApi()
        self.records = records or SlackRecords()
        root = get_default_hermes_root()
        self.workspace_vault = workspace_vault or VaultStore(root / "vault")
        self.workspace_records = workspace_records or WorkspaceRecords(
            root / "chat_slack" / "workspaces.json", self.workspace_vault,
            lambda: profile_sources((self.records, self.vault)))
        self.tokens = ConfigTokenStore(self.workspace_vault, self.api, self.workspace_records, clock=clock)
        self._identity, self._clock = identity, clock

    def capabilities(self, workspace: str | None = None) -> Capabilities:
        stored = self.workspace_records.workspace(workspace).get("capabilities", {}) if workspace is not None else {}
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
        self._probe_if_never_probed(workspace)
        token = self.tokens.valid_config_token(workspace)
        source = self._identity(bot)
        projection, manifest = self._manifest(workspace, source)
        record = self.records.app(bot, workspace)
        app_id = state.app_id or record.get("app_id")
        if not (app_id and record.get("authorize_link") and self._updated(token, app_id, manifest)):
            app_id = self._create(bot, workspace, token, manifest)
        self.records.update_app(bot, workspace, invite_handle=projection.display_name)
        self._finish_app(bot, workspace, token, app_id, source)
        return AppCreated(app_id=app_id, authorize_link=self._with_redirect(self.records.app(bot, workspace)["authorize_link"]))

    def manual_step_action(self, state: SetupState, step: ProviderCapability) -> NextAction:
        page = "oauth" if step is ProviderCapability.gateway_redirect else "general"
        link = f"{SLACK_APPS_URL}/{state.app_id}/{page}" if state.app_id else None
        copy = self.redirect_url if step is ProviderCapability.gateway_redirect else None
        return NextAction(kind=NextActionKind.button, action_id=step.value, link=link, copy_text=copy)

    def _with_redirect(self, link: str) -> str:
        if not self.redirect_url:
            return link
        parts = urlsplit(link)
        query = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "redirect_uri"]
        return urlunsplit(parts._replace(query=urlencode([*query, ("redirect_uri", self.redirect_url)])))

    def _manifest(self, workspace: str, source: BotIdentitySource) -> tuple[IdentityProjection, str]:
        projection = self.identity_projection(source)
        redirect = self.redirect_url if self._automatic(workspace, ProviderCapability.gateway_redirect) else None
        return projection, json.dumps(bot_manifest(projection, redirect, f"{projection.display_name} on Slack"))

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

    def _set_icon(self, bot: str, workspace: str, token: str, app_id: str, avatar_path: str) -> None:
        icon = prepare_avatar(Path(avatar_path).read_bytes())
        self.api.call("apps.icon.set", token=token, data={"app_id": app_id},
                      files={"file": ("avatar.png", icon, "image/png")})
        self.records.update_app(bot, workspace, icon_set=True)

    def _finish_app(self, bot: str, workspace: str, token: str, app_id: str, source: BotIdentitySource) -> None:
        record = self.records.app(bot, workspace)
        if self._automatic(workspace, ProviderCapability.set_icon) and source.avatar_path and not record.get("icon_set"):
            self._set_icon(bot, workspace, token, app_id, source.avatar_path)
        if self._automatic(workspace, ProviderCapability.app_level_credential) and not record.get("app_token_item_id"):
            body = self.api.call("apps.token.create", token=token, data={"app_id": app_id, "scopes": APP_LEVEL_SCOPES})
            item = self.vault.add_item("api_key", f"Slack app {app_id} app-level token", {"api_key": str(body["token"])})
            self.records.update_app(bot, workspace, app_token_item_id=item.id)

    def has_config_credential(self, workspace: str) -> bool:
        return self.tokens.has_usable(workspace)

    def accept_config_credential(self, state: SetupState, vault_item_id: str, refresh_vault_item_id: str | None) -> str:
        workspace = state.workspace
        access = self._secret(vault_item_id)
        refresh = self._secret(refresh_vault_item_id) if refresh_vault_item_id else None
        if refresh is not None and not refresh.startswith(REFRESH_TOKEN_PREFIX):
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        stored_pair = access.startswith((REFRESH_TOKEN_PREFIX, "{"))
        held = self.tokens.adopt(workspace, access) if stored_pair else self.tokens.adopt_pair(workspace, access, refresh)
        renewable = stored_pair or refresh is not None
        stored = dict(self.workspace_records.workspace(workspace).get("capabilities", {}))
        stored[ProviderCapability.unattended_refresh.value] = (CapabilityMode.automatic if renewable else CapabilityMode.guided).value
        self.workspace_records.update_workspace(workspace, capabilities=stored)
        for source in (vault_item_id, refresh_vault_item_id):
            if source and source != held:
                self.vault.remove_item(source)
        if renewable:
            self._probe_after_credential(workspace)
        return held

    def _probe_if_never_probed(self, workspace: str) -> None:
        record = self.workspace_records.workspace(workspace)
        renewable = record.get("capabilities", {}).get(ProviderCapability.unattended_refresh.value) == CapabilityMode.automatic.value
        if renewable and not record.get("probed_at"):
            self._probe_after_credential(workspace)

    def _probe_after_credential(self, workspace: str) -> None:
        try:
            self.probe_workspace(workspace)
        except SlackSetupError as exc:
            if exc.code in PROBE_ABORTING:
                raise
            logger.warning("slack workspace probe skipped, setup stays guided: %s", exc.code.value)

    def accept_app_level_credential(self, state: SetupState, vault_item_id: str) -> None:
        bot, workspace = state.bot, state.workspace
        try:
            key = self._secret(vault_item_id)
        except VaultError:
            raise SlackSetupError(SetupErrorCode.credential_rejected) from None
        if not key.startswith(APP_TOKEN_PREFIX):
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        record = self.records.app(bot, workspace)
        if record.get("app_id") and _app_token_app_id(key) != record["app_id"]:
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        previous = record.get("app_token_item_id")
        self.records.update_app(bot, workspace, app_token_item_id=vault_item_id)
        if previous and previous != vault_item_id:
            self.vault.remove_item(previous)

    def satisfied_manual_steps(self, state: SetupState) -> frozenset[ProviderCapability]:
        done = frozenset(state.manual_steps_done)
        if ProviderCapability.app_level_credential in done and not self._app_key_on_file(state.bot, state.workspace):
            return done - {ProviderCapability.app_level_credential}
        return done

    def _app_key_on_file(self, bot: str, workspace: str) -> bool:
        item_id = self.records.app(bot, workspace).get("app_token_item_id")
        try:
            return bool(item_id and self._secret(item_id))
        except VaultError:
            return False

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

    def adopt_token(self, state: SetupState, vault_item_id: str) -> Installation:
        bot, workspace = state.bot, state.workspace
        token = self._secret(vault_item_id)
        if not token.startswith(BOT_TOKEN_PREFIX):
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        body = self.api.call("auth.test", token=token)
        team_id, bot_user_id = str(body.get("team_id") or ""), str(body.get("user_id") or "")
        if not (team_id and bot_user_id):
            raise SlackSetupError(SetupErrorCode.credential_rejected)
        previous = self.records.app(bot, workspace)
        if previous.get("bot_token_item_id") and previous["bot_token_item_id"] != vault_item_id:
            self.vault.remove_item(previous["bot_token_item_id"])
        now = self._clock()
        self.records.update_app(
            bot, workspace, bot_token_item_id=vault_item_id, team_id=team_id, team_name=str(body.get("team") or ""),
            bot_user_id=bot_user_id, authorizing_user="", installation_id=f"slack-{team_id}-{bot}",
            installed_at=previous.get("installed_at", now), updated_at=now,
        )
        logger.info("slack bot %s adopted in workspace %s", bot, workspace)
        return self._installation(bot, self.records.app(bot, workspace))

    def parse_owner_identity(self, raw: str) -> str | None:
        member = raw.strip().upper()
        return member if MEMBER_ID.fullmatch(member) else None

    def update_identity(self, installation: Installation) -> IdentityUpdate:
        workspace, record = self._record_for(installation)
        bot, source = installation.bot, self._identity(installation.bot)
        self._probe_if_never_probed(workspace)
        token = self.tokens.valid_config_token(workspace)
        projection, manifest = self._manifest(workspace, source)
        self.api.call("apps.manifest.update", token=token, data={"app_id": record["app_id"], "manifest": manifest})
        self.records.update_app(bot, workspace, invite_handle=projection.display_name)
        if not self._automatic(workspace, ProviderCapability.set_icon):
            return IdentityUpdate(IdentityUpdateOutcome.needs_manual_avatar, projection,
                                  NextAction(kind=NextActionKind.button, action_id=ProviderCapability.set_icon.value))
        if source.avatar_path:
            self._set_icon(bot, workspace, token, record["app_id"], source.avatar_path)
        return IdentityUpdate(IdentityUpdateOutcome.updated, projection, _NO_ACTION)

    def store_icon(self, bot: str, png: bytes) -> None:
        store_icon(bot, png)

    def new_install_config(self, installation: Installation, owner: str) -> dict[str, Any]:
        from gateway.config import HomeChannel, Platform
        home = HomeChannel(platform=Platform.SLACK, chat_id=self.open_owner_dm(installation, owner),
                           name=OWNER_DM_HOME_NAME, user_id=owner, scope_id=installation.workspace_id)
        return {"platforms": {self.provider_id: {"audience": {"policy": "workspace"}, "home_channel": home.to_dict()}},
                "slack": {"thread_followup_silence": True}}

    def open_owner_dm(self, installation: Installation, owner: str) -> str:
        token = self._secret(self._record_for(installation)[1]["bot_token_item_id"])
        body = self.api.call("conversations.open", token=token, data={"users": owner})
        return str((body.get("channel") or {})["id"])

    def is_direct_space(self, space_id: str) -> bool:
        return space_id.startswith("D")

    def list_people(self, installation: Installation, query: str, cursor: str) -> PeoplePage:
        record = self._record_for(installation)[1]
        return list_people(self.api, self._secret(record["bot_token_item_id"]), record["team_id"], query, cursor)

    def people_names(self, installation: Installation, member_ids: list[str]) -> dict[str, str]:
        record = self._record_for(installation)[1]
        return names_for(self.api, self._secret(record["bot_token_item_id"]), record["team_id"], member_ids)

    def leave_space(self, installation: Installation, space_id: str) -> SpaceLeaveOutcome:
        token = self._secret(self._record_for(installation)[1]["bot_token_item_id"])
        try:
            body = self.api.call("conversations.leave", token=token, data={"channel": space_id})
        except SlackSetupError as exc:
            if exc.slack_error in LEFT_ALREADY_ERRORS:
                return SpaceLeaveOutcome.not_member
            raise
        return SpaceLeaveOutcome.not_member if body.get("not_in_channel") else SpaceLeaveOutcome.left

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

    def authorizing_identity(self, installation: Installation) -> str | None:
        return self.authorizing_user(installation)

    def adapter_env(self, installation: Installation) -> dict[str, str]:
        record = self._record_for(installation)[1]
        return {"SLACK_BOT_TOKEN": self._secret(record["bot_token_item_id"]),
                "SLACK_APP_TOKEN": self._secret(record["app_token_item_id"])}

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
        self.workspace_records.update_workspace(workspace, capabilities=modes, refresh_token_lifetime=REFRESH_LIFETIME_UNKNOWN,
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
