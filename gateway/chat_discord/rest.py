from __future__ import annotations

from typing import Any

from tools.discord_tool import _FLAGS_MESSAGE_CONTENT as MESSAGE_CONTENT_FLAGS

from .api import DiscordApi

ADMINISTRATOR = 1 << 3
MANAGE_CHANNELS = 1 << 4
MANAGE_WEBHOOKS = 1 << 29
REQUIRED_PERMISSIONS = {"Manage Channels": MANAGE_CHANNELS, "Manage Webhooks": MANAGE_WEBHOOKS}
GUILD_TEXT = 0
GUILD_CATEGORY = 4


def webhook_url(webhook: dict[str, Any]) -> str:
    return f"https://discord.com/api/webhooks/{webhook['id']}/{webhook['token']}"


def webhook_avatar_url(webhook: dict[str, Any]) -> str | None:
    avatar = webhook.get("avatar")
    return f"https://cdn.discordapp.com/avatars/{webhook['id']}/{avatar}.png" if avatar else None


class DiscordRest:
    def __init__(self, api: DiscordApi, token: str):
        self._api, self._token = api, token

    def _call(self, method: str, path: str, **kwargs: Any) -> Any:
        return self._api.call(method, path, token=self._token, **kwargs)

    def me(self) -> dict[str, Any]:
        return self._call("GET", "/users/@me")

    def guilds(self) -> list[dict[str, Any]]:
        return self._call("GET", "/users/@me/guilds", params={"limit": 200})

    def guild(self, guild_id: str) -> dict[str, Any]:
        return self._call("GET", f"/guilds/{guild_id}")

    def message_content_enabled(self) -> bool:
        return bool(int(self._call("GET", "/applications/@me").get("flags") or 0) & MESSAGE_CONTENT_FLAGS)

    def missing_permissions(self, guild_id: str, bot_id: str) -> list[str]:
        member = self._call("GET", f"/guilds/{guild_id}/members/{bot_id}")
        roles = self._call("GET", f"/guilds/{guild_id}/roles")
        held = set(member.get("roles") or []) | {guild_id}
        granted = 0
        for role in roles:
            if role.get("id") in held:
                granted |= int(role.get("permissions") or 0)
        if granted & ADMINISTRATOR:
            return []
        return [name for name, bit in REQUIRED_PERMISSIONS.items() if not granted & bit]

    def channels(self, guild_id: str) -> list[dict[str, Any]]:
        return self._call("GET", f"/guilds/{guild_id}/channels")

    def channel(self, channel_id: str) -> dict[str, Any]:
        return self._call("GET", f"/channels/{channel_id}")

    def create_channel(self, guild_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        return self._call("POST", f"/guilds/{guild_id}/channels", json=payload, permission="Manage Channels")

    def create_webhook(self, channel_id: str, name: str, avatar: str | None) -> dict[str, Any]:
        payload: dict[str, Any] = {"name": name}
        if avatar:
            payload["avatar"] = avatar
        return self._call("POST", f"/channels/{channel_id}/webhooks", json=payload, permission="Manage Webhooks")

    def webhook(self, webhook_id: str) -> dict[str, Any]:
        return self._call("GET", f"/webhooks/{webhook_id}")

    def edit_webhook(self, webhook_id: str, name: str, avatar: str | None) -> dict[str, Any]:
        payload: dict[str, Any] = {"name": name}
        if avatar:
            payload["avatar"] = avatar
        return self._call("PATCH", f"/webhooks/{webhook_id}", json=payload, permission="Manage Webhooks")

    def delete_webhook(self, webhook_id: str) -> None:
        self._call("DELETE", f"/webhooks/{webhook_id}", permission="Manage Webhooks")
