"""Canonical declarations of the verbs ``gateway/session_legacy_bridge.py`` serves on the native socket.

Each name reuses the sidecar method's own ``Params`` and ``Result`` models, so the wire is identical and
the canonical dispatcher gives it the closed key set: an unknown key is ``4001 invalid_params`` before the
handler runs. ``profiles.set_primary`` has no sidecar twin and is declared here in full.
"""

from __future__ import annotations

from .base import Params, Result
from .registry import METHODS, canonical_method

BRIDGED = (
    "account.subscriptions", "auth.revoke_self",
    "library.list", "library.asset",
    "cron.manage",
    "capabilities.status", "messaging.slack.status", "messaging.slack.manifest", "messaging.slack.connect", "messaging.slack.disconnect",
    "messaging.telegram.status", "messaging.telegram.connect", "messaging.telegram.disconnect",
    "messaging.settings.get", "messaging.settings.update",
    "bot_mode.about_you.get", "bot_mode.about_you.set", "bot_mode.about_you.set_photo", "bot_mode.about_you.photo",
    "memory.import",
    "profiles.get_asset", "profiles.template.export", "profiles.create", "profiles.configure",
    "profiles.set_asset", "profiles.rename", "profiles.delete",
    "display.status", "display.thumbnail", "display.start", "display.stop", "display.reset", "display.observe",
    "display.lease.acquire", "display.lease.release", "display.lease.resolve",
    "shared_metrics.status", "shared_metrics.set",
    "connectors.list", "connectors.catalog", "connectors.details", "connectors.details.policy.set",
    "connectors.connect", "connectors.operation.status", "connectors.operation.wake", "connection.respond", "connectors.accounts", "connectors.accounts.remove",
    "mcp.catalog", "mcp.servers.add", "mcp.servers.update", "mcp.servers.remove", "mcp.servers.set_api_key",
    "mcp.servers.accounts.rename",
    "mcp.servers.oauth.start", "mcp.servers.oauth.poll", "mcp.servers.oauth.cancel", "mcp.servers.oauth.callback",
    "vault.list", "vault.sources", "vault.add", "vault.update", "vault.remove", "vault.unlock", "vault.lock",
    "skills.manage",
    "chat.provider.list", "chat.install.status", "chat.install.begin", "chat.install.advance",
    "chat.spaces.list", "chat.space.join", "chat.binding.list", "chat.install.revoke", "chat.install.update_identity",
    "chat.install.set_icon", "chat.space.leave", "chat.audience.get", "chat.audience.set", "chat.people.list",
    "chat.report.get", "chat.report.set", "chat.desk.list", "chat.desk.decide",
    "diag.recent", "diag.report",
    "webapp.public_url.get", "webapp.public_url.set", "webapp.public_url.check",
)

HANDLER_VALIDATED = frozenset({"connection.respond"})

for _name in BRIDGED:
    if _name in HANDLER_VALIDATED:
        continue
    _shared = METHODS[_name]
    canonical_method(_name, params=_shared.params, result=_shared.result, doc=_shared.doc)


class ProfilesSetPrimaryParams(Params):
    name: str


class ProfilesSetPrimaryResult(Result):
    ok: bool
    name: str


canonical_method("profiles.set_primary", params=ProfilesSetPrimaryParams, result=ProfilesSetPrimaryResult,
                 doc="Make a bot the install's primary: the one the apps open first. Only a pointer in the "
                     "install-wide config moves; nothing is copied. An unknown name answers not_found.")
