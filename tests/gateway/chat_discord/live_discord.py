from __future__ import annotations

import asyncio
import json
import threading
from dataclasses import dataclass, field

import httpx
from aiohttp import WSMsgType, web

from tests.gateway.chat_discord.fake_discord import API_PREFIX, BOT_ID, GUILD_ID, OWNER_ID, FakeDiscord

BOT_TOKEN = ".".join(("F" * 24, "F" * 6, "F" * 27))
GATEWAY_PATH = "/gateway"
HELLO, HEARTBEAT, IDENTIFY, HEARTBEAT_ACK, DISPATCH = 10, 1, 2, 11, 0
AUTHENTICATION_FAILED, DISALLOWED_INTENTS = 4004, 4014
LIBRARY_AGENT_MARK = "Rapptz/discord.py"


def _reply(payload, status: int = 200) -> web.Response:
    return web.Response(status=status, body=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})


def _user(user_id: str, name: str, *, bot: bool) -> dict:
    return {"id": user_id, "username": name, "discriminator": "0", "avatar": None, "global_name": name, "bot": bot}


APPLICATION = {"name": "Pal", "description": "", "icon": None, "bot_public": True, "bot_require_code_grant": False,
               "verify_key": "0" * 64,
               "owner": {"id": OWNER_ID, "username": "owner", "discriminator": "0", "avatar": None}}


@dataclass
class LiveDiscord:
    rest: FakeDiscord = field(default_factory=lambda: FakeDiscord(application_extra=APPLICATION))
    refuse_login: bool = False
    refuse_intents: bool = False
    stall_ready: bool = False
    hidden_channels: bool = False
    identified: list[int] = field(default_factory=list)
    webhook_posts: list[tuple[str, dict]] = field(default_factory=list)
    url: str = ""

    def __post_init__(self) -> None:
        self._loop = asyncio.new_event_loop()
        self._sockets: list[web.WebSocketResponse] = []
        self._ready = threading.Event()
        self._stop: asyncio.Event | None = None
        self._thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> LiveDiscord:
        self._thread.start()
        assert self._ready.wait(10), "fake Discord did not start"
        return self

    def __exit__(self, *_exc) -> None:
        if self._stop is not None:
            self._loop.call_soon_threadsafe(self._stop.set)
        self._thread.join(10)

    def _run(self) -> None:
        self._loop.run_until_complete(self._serve())
        self._loop.close()

    async def _serve(self) -> None:
        self._stop = asyncio.Event()
        app = web.Application()
        app.router.add_get(GATEWAY_PATH, self._gateway)
        app.router.add_get(GATEWAY_PATH + "/", self._gateway)
        app.router.add_route("*", "/{tail:.*}", self._http)
        runner = web.AppRunner(app, shutdown_timeout=1)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        self.url = f"http://127.0.0.1:{runner.addresses[0][1]}"
        self._ready.set()
        await self._stop.wait()
        for socket in list(self._sockets):
            await socket.close()
        await runner.cleanup()

    async def _http(self, request: web.Request) -> web.Response:
        path = request.path.removeprefix(API_PREFIX)
        library = LIBRARY_AGENT_MARK in request.headers.get("User-Agent", "")
        raw = await request.read()
        if request.method == "POST" and path.startswith("/webhooks/"):
            return self._webhook_post(path, request.content_type, raw)
        if library and self.refuse_login:
            return _reply({"code": 0, "message": "401: Unauthorized"}, 401)
        if library and path == "/users/@me":
            return _reply(_user(BOT_ID, "Pal", bot=True))
        if path == "/oauth2/applications/@me":
            path = "/applications/@me"
        if self.hidden_channels and request.method == "GET" and path.startswith("/channels/"):
            return _reply({"code": 50001, "message": "Missing Access"}, 403)
        reply = self.rest.handler(httpx.Request(
            request.method, f"https://discord.com{API_PREFIX}{path}", content=raw or None,
            headers={"Authorization": request.headers.get("Authorization", "")}))
        if reply.status_code == 404 and library:
            return _reply([] if request.method in ("GET", "PUT") else {})
        return web.Response(status=reply.status_code, body=reply.content or None,
                            headers={"Content-Type": "application/json"})

    def _webhook_post(self, path: str, content_type: str, raw: bytes) -> web.Response:
        body = json.loads(raw) if content_type == "application/json" and raw else {"raw": raw.decode("utf-8", "replace")}
        webhook_id = path.split("/")[2]
        self.webhook_posts.append((webhook_id, body))
        channel = self.rest.webhooks.get(webhook_id, {}).get("channel_id", "0")
        return _reply(self._message(self.rest.next_id(6), channel, body.get("content", ""),
                                    _user(webhook_id, "Pal", bot=True)))

    @staticmethod
    def _message(message_id: str, channel_id: str, content: str, author: dict) -> dict:
        return {"id": message_id, "channel_id": channel_id, "guild_id": GUILD_ID, "content": content, "author": author,
                "timestamp": "2026-01-01T00:00:00+00:00", "edited_timestamp": None, "tts": False,
                "mention_everyone": False, "mentions": [], "mention_roles": [], "attachments": [], "embeds": [],
                "pinned": False, "type": 0, "flags": 0}

    def _guild(self) -> dict:
        channels = [{**channel, "position": 0, "permission_overwrites": []} for channel in self.rest.channels.values()]
        members = [{"user": _user(BOT_ID, "Pal", bot=True), "roles": [], "joined_at": "2026-01-01T00:00:00+00:00",
                    "deaf": False, "mute": False, "flags": 0}]
        return {"id": GUILD_ID, "name": f"Server {GUILD_ID[-3:]}", "owner_id": OWNER_ID, "channels": channels,
                "members": members, "member_count": 1, "threads": [], "presences": [], "voice_states": [],
                "emojis": [], "stickers": [], "features": [], "unavailable": False, "large": False,
                "roles": [{"id": GUILD_ID, "name": "@everyone", "permissions": "68608", "position": 0, "color": 0,
                           "hoist": False, "managed": False, "mentionable": False, "flags": 0}]}

    async def _gateway(self, request: web.Request) -> web.WebSocketResponse:
        socket = web.WebSocketResponse()
        await socket.prepare(request)
        self._sockets.append(socket)
        sequence = 0
        await socket.send_json({"op": HELLO, "d": {"heartbeat_interval": 5000}, "s": None, "t": None})
        try:
            async for frame in socket:
                if frame.type is not WSMsgType.TEXT:
                    continue
                payload = json.loads(frame.data)
                if payload["op"] == HEARTBEAT:
                    await socket.send_json({"op": HEARTBEAT_ACK, "d": None, "s": None, "t": None})
                elif payload["op"] == IDENTIFY:
                    self.identified.append(int(payload["d"]["intents"]))
                    if payload["d"]["token"] != BOT_TOKEN:
                        await socket.close(code=AUTHENTICATION_FAILED)
                    elif self.refuse_intents:
                        await socket.close(code=DISALLOWED_INTENTS)
                    elif not self.stall_ready:
                        ready = {"v": 10, "user": _user(BOT_ID, "Pal", bot=True), "session_id": "fake-session",
                                 "resume_gateway_url": self.url.replace("http", "ws", 1) + GATEWAY_PATH,
                                 "guilds": [{"id": GUILD_ID, "unavailable": True}],
                                 "application": {"id": BOT_ID, "flags": 0}}
                        for event, data in (("READY", ready), ("GUILD_CREATE", self._guild())):
                            sequence += 1
                            await socket.send_json({"op": DISPATCH, "t": event, "s": sequence, "d": data})
        finally:
            self._sockets.remove(socket)
        return socket

    def online(self) -> bool:
        return bool(self._sockets)

    def say(self, channel_id: str, content: str, *, author_id: str = OWNER_ID) -> None:
        data = self._message(self.rest.next_id(7), channel_id, content, _user(author_id, "owner", bot=False))
        data["member"] = {"roles": [], "joined_at": "2026-01-01T00:00:00+00:00", "deaf": False, "mute": False, "flags": 0}

        async def push() -> None:
            for socket in list(self._sockets):
                await socket.send_json({"op": DISPATCH, "t": "MESSAGE_CREATE", "s": 1000, "d": data})

        asyncio.run_coroutine_threadsafe(push(), self._loop).result(10)
