from __future__ import annotations

from pydantic import Field

from .base import JsonValue, Params, Result, WireEnum
from .common import ProfileParams
from .registry import method


class ProfilesRenameParams(Params):
    name: str
    new_name: str


class ProfilesRenameResult(Result):
    """``name`` is the canonical id after the rename; the primary bot keeps ``default`` and carries the
    new label in ``display_name``."""

    ok: bool
    name: str
    path: str
    display_name: str | None = None


method("profiles.rename", params=ProfilesRenameParams, result=ProfilesRenameResult,
       doc="Rename a bot (ws twin of PATCH /api/profiles/{name}); the primary bot only changes its display name.")


class ProfilesDeleteParams(Params):
    name: str


class ProfilesDeleteResult(Result):
    """``settlement_pending`` means the home is already gone and only the durable identity cleanup is
    outstanding; ``retry_command`` finishes it."""

    ok: bool
    name: str
    path: str
    identity_settled: bool | None = None
    settlement_pending: bool | None = None
    retry_command: str | None = None


method("profiles.delete", params=ProfilesDeleteParams, result=ProfilesDeleteResult,
       doc="Delete a bot and its home (ws twin of DELETE /api/profiles/{name}); refuses the primary bot and the bot serving the connection.")


class ProfilesDescribeAutoParams(Params):
    name: str
    overwrite: bool = False


class ProfilesDescribeAutoResult(Result):
    ok: bool
    name: str
    description: str


method("profiles.describe_auto", params=ProfilesDescribeAutoParams, result=ProfilesDescribeAutoResult,
       doc="Write a bot's description with the auxiliary model, as `hermes profile describe --auto`. Owner connections only "
           "(4403); overwrite=false keeps a description the owner wrote (4102 says so). Never a model tool.")


class MessagingSlackStatus(Result):
    """One bot's Slack connection. Credentials are never echoed: only whether each is set. ``state`` is the
    gateway's verdict for the Slack adapter (``connected``, ``not_configured``, ``disabled``, ``pending_restart``,
    ``gateway_stopped``, ``startup_failed``, ``retrying``, ...). When Slack refused the connection, ``error_code`` is
    Slack's own code (``missing_scope``, ``invalid_auth``, ``token_revoked``, ...) and ``needed_scope`` /
    ``provided_scope`` name the scopes involved; none of these is a secret."""

    profile: str
    enabled: bool
    configured: bool
    gateway_running: bool
    state: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    needed_scope: str | None = None
    provided_scope: str | None = None
    bot_token_set: bool
    app_token_set: bool
    allowed_users_set: bool


method("messaging.slack.status", params=ProfileParams, result=MessagingSlackStatus,
       doc="Slack connection state of one bot (never carries a token).")


class MessagingSlackConnectParams(ProfileParams):
    """``bot_token`` (xoxb-) and ``app_token`` (xapp-, Socket Mode) are written to the bot's own .env only.
    ``allowed_users`` are Slack member IDs allowed to talk to the bot. Either token may be sent alone to replace it;
    the other must already be stored."""

    bot_token: str | None = Field(default=None, repr=False)
    app_token: str | None = Field(default=None, repr=False)
    allowed_users: list[str] | None = None


class MessagingSlackConnectResult(MessagingSlackStatus):
    """The status after the write plus what became of the gateway: ``hot_served`` when a running multiplexer
    rebuilt the adapter, else a gateway restart (``restart_started``; refused while a chat is live:
    ``restart_busy``)."""

    hot_served: bool
    restart_started: bool
    restart_busy: bool | None = None
    restart_error: str | None = None


method("messaging.slack.connect", params=MessagingSlackConnectParams, result=MessagingSlackConnectResult,
       doc="Validate and save a bot's Slack tokens (either one alone replaces just that token), enable the adapter and reload it.")
method("messaging.slack.disconnect", params=ProfileParams, result=MessagingSlackConnectResult,
       doc="Remove a bot's Slack tokens and disable the adapter.")


class MessagingTelegramStatus(Result):
    """One bot's Telegram connection. The token is never echoed: only whether it is set. ``state`` is the gateway's
    verdict for the Telegram adapter (``connected``, ``not_configured``, ``disabled``, ``pending_restart``,
    ``gateway_stopped``, ``startup_failed``, ``retrying``, ...). When the connection failed, ``error_code`` names why
    (``telegram_auth_error``: invalid or revoked token, ``telegram_network_error`` / ``telegram_connect_error``:
    Telegram unreachable, ``telegram_polling_conflict``: another copy uses the token); none of these is a secret."""

    profile: str
    enabled: bool
    configured: bool
    gateway_running: bool
    state: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    bot_token_set: bool
    allowed_users_set: bool


method("messaging.telegram.status", params=ProfileParams, result=MessagingTelegramStatus,
       doc="Telegram connection state of one bot (never carries the token).")


class MessagingTelegramConnectParams(ProfileParams):
    """``bot_token`` is the BotFather token; it is written to the bot's own .env only, after Telegram's getMe accepted
    it. A replacement keeps the old token until the new one is accepted and saved. Error 4101: the token has the wrong
    shape or Telegram refused it (invalid or revoked); 5103: Telegram could not be reached."""

    bot_token: str = Field(repr=False)


class MessagingTelegramConnectResult(MessagingTelegramStatus):
    """The status after the write plus what became of the gateway: ``hot_served`` when a running multiplexer
    rebuilt the adapter, else a gateway restart (``restart_started``; refused while a chat is live:
    ``restart_busy``)."""

    hot_served: bool
    restart_started: bool
    restart_busy: bool | None = None
    restart_error: str | None = None


method("messaging.telegram.connect", params=MessagingTelegramConnectParams, result=MessagingTelegramConnectResult,
       doc="Check a bot's Telegram token with getMe, save it (replacing any stored one), enable the adapter and reload it.")
method("messaging.telegram.disconnect", params=ProfileParams, result=MessagingTelegramConnectResult,
       doc="Remove a bot's Telegram token and disable the adapter; the allowlist is kept.")


class MessagingSlackManifestParams(ProfileParams):
    display_name: str | None = None


class MessagingSlackManifestResult(Result):
    """``create_url`` opens Slack's create-from-manifest page with the bot's name already filled in."""

    profile: str
    bot_name: str
    manifest: dict[str, JsonValue]
    create_url: str


method("messaging.slack.manifest", params=MessagingSlackManifestParams, result=MessagingSlackManifestResult,
       doc="Slack app manifest named after the bot, plus the api.slack.com link that creates the app from it.")


class MessagingSettingsKind(WireEnum):
    allowlist = "allowlist"
    home_channel = "home_channel"


class MessagingSettingsField(Result):
    """One editable, non-secret setting. ``values`` is the allowlist's IDs; the single-value kinds
    (``home_channel``) hold zero or one."""

    key: str
    kind: MessagingSettingsKind
    label: str
    values: list[str]


class MessagingSettingsSecret(Result):
    """A credential the platform needs: only whether it is set, never a value or a preview."""

    key: str
    label: str
    is_set: bool


class MessagingSettingsPlatform(Result):
    id: str
    name: str
    enabled: bool
    configured: bool
    state: str | None = None
    error_message: str | None = None
    fields: list[MessagingSettingsField]
    secrets: list[MessagingSettingsSecret]


class MessagingSettingsGetResult(Result):
    profile: str
    gateway_running: bool
    platforms: list[MessagingSettingsPlatform]


method("messaging.settings.get", params=ProfileParams, result=MessagingSettingsGetResult,
       doc="Non-secret messaging settings of one bot (allowlists, home channel, enabled) for Slack and Telegram; credentials appear as set / not set only.")


class MessagingSettingsUpdateParams(ProfileParams):
    """``fields`` maps a setting key from ``messaging.settings.get`` to its new values (an empty list clears it);
    keys left out are untouched. Refused with 4101 and ``error.data.fields`` ({key: plain-words reason}) when any value is invalid;
    nothing is written then."""

    platform: str
    enabled: bool | None = None
    fields: dict[str, list[str]] | None = None


class MessagingSettingsUpdateResult(Result):
    """``changed`` is false for a repeat of the saved values. ``restart_needed`` means the gateway is running
    and no live multiplexer rebuilt the adapter (``hot_served``), so the change applies after a gateway restart."""

    profile: str
    gateway_running: bool
    settings: MessagingSettingsPlatform
    changed: bool
    hot_served: bool
    restart_needed: bool


method("messaging.settings.update", params=MessagingSettingsUpdateParams, result=MessagingSettingsUpdateResult,
       doc="Validate and save one platform's non-secret settings for a bot; idempotent, all-or-nothing.")


class MemoryImportTarget(WireEnum):
    user = "user"
    memory = "memory"


class MemoryImportParams(ProfileParams):
    """``text`` is pasted free text, one fact per line (bullets, numbering and dates are stripped); ``target``
    is the profile notes (``user``, the default) or the agent's own notes (``memory``)."""

    text: str
    target: MemoryImportTarget | None = None


class MemoryImportResult(Result):
    """Counts of the pasted lines: ``added`` landed; ``duplicates`` were already remembered (or repeated),
    ``too_long`` exceeded one entry, ``blocked`` failed the memory safety scan, ``over_budget`` no longer fit
    the store's size cap (the first that did not fit and every one after it). ``usage`` is the store's fill."""

    profile: str
    target: MemoryImportTarget
    candidates: int
    added: int
    duplicates: int
    too_long: int
    blocked: int
    over_budget: int
    usage: str
    entry_count: int


method("memory.import", params=MemoryImportParams, result=MemoryImportResult,
       doc="Import pasted text (a ChatGPT or Claude memory export) into a bot's memory: deduped, size-capped, scanned.")


class AuthRevokeSelfParams(Params):
    """The caller's own native sign-in tokens: holding the refresh token is the proof of ownership."""

    refresh_token: str
    access_token: str | None = None


class AuthRevokeSelfResult(Result):
    """``providers_revoked`` counts the sign-in providers that accepted the revocation; ``forgotten`` the
    recorded native tokens (refresh and access) the gateway stopped honouring at once."""

    ok: bool
    providers_revoked: int
    forgotten: int


method("auth.revoke_self", params=AuthRevokeSelfParams, result=AuthRevokeSelfResult,
       doc="Sign this device out on the gateway: revoke its refresh token with the sign-in providers and drop it from the native sign-in record.")
