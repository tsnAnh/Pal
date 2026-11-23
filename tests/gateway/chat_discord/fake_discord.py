from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

import httpx

TOKEN = "FAKE-DISCORD-TOKEN-NOT-REAL"
GUILD_ID = "100000000000000001"
BOT_ID = "200000000000000002"
BOT_ROLE_ID = "300000000000000003"
OWNER_ID = "123456789012345678"
ADMINISTRATOR = 1 << 3
MANAGE_CHANNELS = 1 << 4
MANAGE_WEBHOOKS = 1 << 29
MESSAGE_CONTENT_INTENT = 1 << 18
API_PREFIX = "/api/v10"
AVATAR_HASH = "a1b2c3d4e5f6"

ROUTES = (
    ("GET", r"/users/@me", "me"),
    ("GET", r"/users/@me/guilds", "guilds"),
    ("GET", r"/applications/@me", "application"),
    ("GET", r"/guilds/(?P<guild>\d+)", "guild"),
    ("GET", r"/guilds/(?P<guild>\d+)/members/(?P<member>\d+)", "member"),
    ("GET", r"/guilds/(?P<guild>\d+)/roles", "roles"),
    ("GET", r"/guilds/(?P<guild>\d+)/channels", "list_channels"),
    ("POST", r"/guilds/(?P<guild>\d+)/channels", "create_channel"),
    ("GET", r"/channels/(?P<channel>\d+)", "channel"),
    ("POST", r"/channels/(?P<channel>\d+)/webhooks", "create_webhook"),
    ("GET", r"/webhooks/(?P<webhook>\d+)", "webhook"),
    ("PATCH", r"/webhooks/(?P<webhook>\d+)", "edit_webhook"),
    ("DELETE", r"/webhooks/(?P<webhook>\d+)", "delete_webhook"),
)


@dataclass
class Recorded:
    method: str
    path: str
    body: dict | None
    authorization: str


@dataclass
class FakeDiscord:
    guild_ids: list[str] = field(default_factory=lambda: [GUILD_ID])
    permissions: int = MANAGE_CHANNELS | MANAGE_WEBHOOKS
    intent_enabled: bool = True
    reject_auth: bool = False
    rate_limits: int = 0
    network_down: bool = False
    server_error: bool = False
    deny_channel_create: bool = False
    deny_webhook_create: bool = False
    channels: dict[str, dict] = field(default_factory=dict)
    webhooks: dict[str, dict] = field(default_factory=dict)
    requests: list[Recorded] = field(default_factory=list)
    hidden_guilds: set[str] = field(default_factory=set)
    forbidden_guilds: set[str] = field(default_factory=set)
    sequence: int = 0

    def __post_init__(self) -> None:
        self.transport = httpx.MockTransport(self.handler)

    def next_id(self, prefix: int) -> str:
        self.sequence += 1
        return f"{prefix}{self.sequence:017d}"

    def add_channel(self, name: str, kind: int = 0, parent_id: str | None = None, guild: str = GUILD_ID) -> str:
        channel_id = self.next_id(5)
        self.channels[channel_id] = {"id": channel_id, "name": name, "type": kind, "parent_id": parent_id,
                                     "guild_id": guild}
        return channel_id

    def delete_channel(self, channel_id: str) -> None:
        self.channels.pop(channel_id)
        for webhook_id in [w for w, hook in self.webhooks.items() if hook["channel_id"] == channel_id]:
            del self.webhooks[webhook_id]

    def delete_webhook_remote(self, webhook_id: str) -> None:
        self.webhooks.pop(webhook_id)

    def text_channels(self) -> list[dict]:
        return [c for c in self.channels.values() if c["type"] == 0]

    def categories(self) -> list[dict]:
        return [c for c in self.channels.values() if c["type"] == 4]

    def calls(self, method: str, suffix: str | None = None) -> list[Recorded]:
        return [r for r in self.requests if r.method == method and (suffix is None or r.path.endswith(suffix))]

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path.removeprefix(API_PREFIX)
        body = json.loads(request.content) if request.content else None
        self.requests.append(Recorded(request.method, path, body, request.headers.get("Authorization", "")))
        if self.network_down:
            raise httpx.ConnectError("unreachable", request=request)
        if self.rate_limits > 0:
            self.rate_limits -= 1
            return httpx.Response(429, json={"message": "You are being rate limited.", "retry_after": 0.5, "global": False})
        if self.reject_auth:
            return httpx.Response(401, json={"code": 0, "message": "401: Unauthorized"})
        if self.server_error:
            return httpx.Response(500, json={"message": "Internal Server Error"})
        for method, pattern, name in ROUTES:
            match = re.fullmatch(pattern, path)
            if method == request.method and match:
                return getattr(self, f"route_{name}")(body, **match.groupdict())
        return error(404, 0, "404: Not Found")

    def route_me(self, body):
        return httpx.Response(200, json={"id": BOT_ID, "username": "Pal", "bot": True})

    def route_guilds(self, body):
        return httpx.Response(200, json=[{"id": g, "name": f"Server {g[-3:]}"} for g in self.guild_ids])

    def route_application(self, body):
        return httpx.Response(200, json={"id": BOT_ID, "flags": MESSAGE_CONTENT_INTENT if self.intent_enabled else 0})

    def guild_error(self, guild: str):
        if guild in self.forbidden_guilds:
            return error(403, 50001, "Missing Access")
        if guild in self.hidden_guilds or guild not in self.guild_ids:
            return error(404, 10004, "Unknown Guild")
        return None

    def route_guild(self, body, guild):
        return self.guild_error(guild) or httpx.Response(200, json={"id": guild, "name": f"Server {guild[-3:]}"})

    def route_member(self, body, guild, member):
        return self.guild_error(guild) or httpx.Response(200, json={"user": {"id": member}, "roles": [BOT_ROLE_ID]})

    def route_roles(self, body, guild):
        return self.guild_error(guild) or httpx.Response(200, json=[
            {"id": guild, "name": "@everyone", "permissions": "0"},
            {"id": BOT_ROLE_ID, "name": "Pal", "permissions": str(self.permissions)}])

    def route_list_channels(self, body, guild):
        return self.guild_error(guild) or httpx.Response(200, json=list(self.channels.values()))

    def route_create_channel(self, body, guild):
        if self.deny_channel_create:
            return error(403, 50013, "Missing Permissions")
        channel_id = self.add_channel(body["name"], body["type"], body.get("parent_id"), guild)
        self.channels[channel_id]["topic"] = body.get("topic")
        return httpx.Response(201, json={"id": channel_id})

    def route_channel(self, body, channel):
        if channel not in self.channels:
            return error(404, 10003, "Unknown Channel")
        return httpx.Response(200, json=self.channels[channel])

    def route_create_webhook(self, body, channel):
        if channel not in self.channels:
            return error(404, 10003, "Unknown Channel")
        if self.deny_webhook_create:
            return error(403, 50013, "Missing Permissions")
        webhook_id = self.next_id(4)
        self.webhooks[webhook_id] = {"id": webhook_id, "token": f"FAKE-WEBHOOK-SECRET-{self.sequence}",
                                     "channel_id": channel, "name": body["name"], "avatar": body.get("avatar")}
        created = self.webhooks[webhook_id]
        return httpx.Response(200, json={"id": webhook_id, "token": created["token"], "channel_id": channel,
                                         "avatar": AVATAR_HASH if body.get("avatar") else None})

    def route_webhook(self, body, webhook):
        if webhook not in self.webhooks:
            return error(404, 10015, "Unknown Webhook")
        return httpx.Response(200, json={k: v for k, v in self.webhooks[webhook].items() if k != "token"})

    def route_edit_webhook(self, body, webhook):
        if webhook not in self.webhooks:
            return error(404, 10015, "Unknown Webhook")
        self.webhooks[webhook].update(body)
        return httpx.Response(200, json={"id": webhook, "avatar": AVATAR_HASH if self.webhooks[webhook].get("avatar") else None})

    def route_delete_webhook(self, body, webhook):
        if self.webhooks.pop(webhook, None) is None:
            return error(404, 10015, "Unknown Webhook")
        return httpx.Response(204)


def error(status: int, code: int, message: str) -> httpx.Response:
    return httpx.Response(status, json={"code": code, "message": message})
