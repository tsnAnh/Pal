from __future__ import annotations

from .base import JsonValue, Params, Result
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


class MessagingSlackStatus(Result):
    """One bot's Slack connection. Credentials are never echoed: only whether each is set. ``state`` is the
    gateway's verdict for the Slack adapter (``connected``, ``not_configured``, ``disabled``, ``pending_restart``,
    ``gateway_stopped``, ``startup_failed``, ...)."""

    profile: str
    enabled: bool
    configured: bool
    gateway_running: bool
    state: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    bot_token_set: bool
    app_token_set: bool
    allowed_users_set: bool


method("messaging.slack.status", params=ProfileParams, result=MessagingSlackStatus,
       doc="Slack connection state of one bot (never carries a token).")


class MessagingSlackConnectParams(ProfileParams):
    """``bot_token`` (xoxb-) and ``app_token`` (xapp-, Socket Mode) are written to the bot's own .env only.
    ``allowed_users`` are Slack member IDs allowed to talk to the bot."""

    bot_token: str
    app_token: str
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
       doc="Validate and save a bot's Slack tokens, enable the adapter and reload it.")
method("messaging.slack.disconnect", params=ProfileParams, result=MessagingSlackConnectResult,
       doc="Remove a bot's Slack tokens and disable the adapter.")


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
