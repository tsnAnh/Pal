from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

import pytest

from tests.e2e.core.platforms import _contract as C
from tests.e2e.core.platforms._drv_slack import SlackDriver
from tests.e2e.core.platforms._helpers import Director, GatewayUnderTest
from tests.fakes.fake_llm_provider import FakeLLMServer
from tests.fakes.platforms._standin import wait_until
from tests.fakes.platforms.slack_standin import BOT_USER_ID, TEAM_ID

OWNER = SlackDriver.user_id
ALICE, BOB, GUEST, EXTERNAL, BLIND = "U0000AAA", "U0000BBB", "U0000GGG", "U0000XXX", "U0000NNN"
EXTERNAL_TEAM = "T0EXTERNAL"
MEMORY_CANARY = "canary-memory-7f3a9"
USER_CANARY = "canary-user-profile-51cd2"
CONTEXT_CANARY = "canary-context-file-b84e0"
MEMBER_COMMAND_REFUSAL = "Only my owner can use commands here."
RATE_NOTICE = "I'm getting a lot of requests right now"
OWNER_ONLY_TOOLS = {"terminal", "process_manage", "read_file", "write_file", "patch", "search_files",
                    "execute_code", "memory", "session_search", "delegate_task", "cronjob_manage",
                    "slack_post_message", "slack_send_dm", "slack_list_users", "slack_list_channels"}
BRIDGE_TOOLS = {"tool_search", "tool_describe", "tool_call"}
MEMBER_TOOLS = {"web_search", "web_extract", "vision_analyze", "clarify", "slack_read_thread", "slack_read_channel",
               "request_owner_action"}
MEMBER_SURFACE = MEMBER_TOOLS | BRIDGE_TOOLS


def user_record(user_id: str, *, team: str = TEAM_ID, **flags: Any) -> dict[str, Any]:
    name = f"user{user_id.lower()}"
    return {"id": user_id, "team_id": team, "name": name, "real_name": name.title(), "deleted": False,
            "is_bot": False, "is_app_user": False, "tz": "UTC",
            "profile": {"display_name": name, "real_name": name.title(), "bot_id": None}, **flags}


class MemberDriver(SlackDriver):
    def __init__(self, audience: Optional[dict[str, Any]], free_channels: tuple[str, ...] = ()) -> None:
        super().__init__()
        self.audience = audience
        self.free_channels = free_channels

    def gateway_config(self) -> dict[str, Any]:
        extra: dict[str, Any] = {"require_mention": True}
        if self.free_channels:
            extra["free_response_channels"] = list(self.free_channels)
        platform: dict[str, Any] = {"enabled": True, "extra": extra}
        if self.audience is not None:
            platform["audience"] = self.audience
        return {"platforms": {"slack": platform}}


@dataclass
class World(C.Rig):
    root: Optional[Path] = None

    def sessions_of(self, needle: str) -> list[tuple[str, str]]:
        conn = sqlite3.connect(f"file:{self.gw.db_path}?mode=ro", uri=True, timeout=30)
        try:
            return sorted(set(conn.execute(
                "SELECT s.session_key, s.id FROM messages m JOIN sessions s ON s.id = m.session_id "
                "WHERE m.role = 'user' AND m.content LIKE ?", (f"%{needle}%",))))
        finally:
            conn.close()

    def session_ended(self, session_id: str) -> bool:
        conn = sqlite3.connect(f"file:{self.gw.db_path}?mode=ro", uri=True, timeout=30)
        try:
            row = conn.execute("SELECT ended_at FROM sessions WHERE id = ?", (session_id,)).fetchone()
        finally:
            conn.close()
        return row is not None and row[0] is not None

    def session_keys(self) -> list[str]:
        conn = sqlite3.connect(f"file:{self.gw.db_path}?mode=ro", uri=True, timeout=30)
        try:
            return [row[0] for row in conn.execute("SELECT session_key FROM sessions WHERE session_key IS NOT NULL")]
        finally:
            conn.close()

    def request(self, token: str, index: int = -1) -> dict[str, Any]:
        return self.director.requests[token][index]

    def settle(self) -> None:
        C.barrier(self, f"settle-{time.monotonic_ns()}")


def tool_names(body: dict[str, Any]) -> set[str]:
    return {t.get("function", {}).get("name") for t in body.get("tools") or []}


def system_text(body: dict[str, Any]) -> str:
    parts = []
    for message in body.get("messages", []):
        if message.get("role") == "system":
            content = message.get("content")
            parts.append(content if isinstance(content, str) else json.dumps(content))
    return "\n".join(parts)


def surface_fingerprint(body: dict[str, Any]) -> dict[str, str]:
    tools = json.dumps(sorted(body.get("tools") or [], key=lambda t: t["function"]["name"]), sort_keys=True)
    return {"tools": hashlib.sha256(tools.encode()).hexdigest()[:16],
            "system": hashlib.sha256(system_text(body).encode()).hexdigest()[:16]}


def make_world(factory: pytest.TempPathFactory, label: str, *, audience: Optional[dict[str, Any]],
               free_channels: tuple[str, ...] = (), extra_cfg: Optional[dict[str, Any]] = None,
               prepare: Optional[Callable[[GatewayUnderTest, MemberDriver], None]] = None) -> World:
    drv = MemberDriver(audience, free_channels)
    drv.start()
    director = Director()
    llm = FakeLLMServer(director)
    llm.start()
    root = factory.mktemp(label)
    gw = GatewayUnderTest(root, llm_base_url=llm.base_url, config=C.merge(drv.gateway_config(), extra_cfg or {}),
                          env={**drv.gateway_env(), "HERMES_GATEWAY_EXTERNAL_SUPERVISOR": "1"}, ready=drv.connected)
    (gw.hermes_home / "memories").mkdir(parents=True, exist_ok=True)
    (gw.hermes_home / "memories" / "MEMORY.md").write_text(f"{MEMORY_CANARY}\n", encoding="utf-8")
    (gw.hermes_home / "memories" / "USER.md").write_text(f"{USER_CANARY}\n", encoding="utf-8")
    (gw.home / "AGENTS.md").write_text(f"# project rules\n{CONTEXT_CANARY}\n", encoding="utf-8")
    standin = drv.standin
    standin.users[ALICE] = user_record(ALICE)
    standin.users[BOB] = user_record(BOB)
    standin.users[GUEST] = user_record(GUEST, is_restricted=True)
    standin.users[EXTERNAL] = user_record(EXTERNAL, team=EXTERNAL_TEAM, is_stranger=True)
    standin.users[BLIND] = user_record(BLIND)
    standin.fail("users.info", {"ok": False, "error": "user_not_found"}, times=10_000,
                 match=lambda params: params.get("user") == BLIND)
    world = World(gw=gw, drv=drv, director=director, llm=llm, root=root)
    try:
        if prepare is not None:
            prepare(gw, drv)
        gw.start()
    except BaseException:
        teardown(world)
        raise
    return world


def teardown(world: World) -> None:
    world.gw.stop()
    for pid in world.gw.pids:
        try:
            os.kill(pid, 9)
        except (ProcessLookupError, PermissionError):
            pass
    world.llm.stop()
    world.drv.stop()


def write_artifact(world: World, name: str) -> Path:
    standin = world.drv.standin
    with standin._lock:
        calls = [{"method": c.method, "params": _plain(c.params), "faulted": c.faulted} for c in standin.calls
                 if c.method not in ("socket_ack", "socket_connect", "socket_close")]
    sessions = {}
    for token, bodies in sorted(world.director.requests.items()):
        sessions[token] = [{"tools": sorted(n for n in tool_names(b) if n), **surface_fingerprint(b)} for b in bodies]
    path = (world.root or Path(".")) / name
    path.write_text(json.dumps({"slack_calls": calls, "model_requests_by_token": sessions,
                                "session_keys": world.session_keys()}, indent=2, sort_keys=True, default=str),
                    encoding="utf-8")
    return path


def _plain(params: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in params.items() if k not in ("blocks", "token")}


def post(world: World, user: str, channel: str, text: str, *, mention: bool = True,
         thread_ts: Optional[str] = None, **extra: Any) -> str:
    standin = world.drv.standin
    body = f"<@{BOT_USER_ID}> {text}" if mention else text
    message = standin.message_event(channel, user, body, channel_type="channel", thread_ts=thread_ts, **extra)
    if mention:
        mentioned = dict(message, type="app_mention")
        mentioned.pop("channel_type", None)
        standin.deliver(mentioned)
    standin.deliver(message)
    return message["ts"]


def dm(world: World, user: str, text: str, **extra: Any) -> str:
    return world.drv.standin.dm(user, text, **extra)["payload"]["event"]["ts"]


def scripted(world: World, token: str, *responses: Any) -> str:
    aid = f"A-{token}"
    world.director.script(token, *(responses or (C.answer(aid, "ok"),)))
    return aid


def wait_turns(world: World, token: str, count: int = 1) -> None:
    wait_until(lambda: C.turns(world, token) >= count, f"{count} model turn(s) for {token}",
               timeout=C.TURN_TIMEOUT, on_timeout=world.ctx)


def assert_no_turn(world: World, token: str) -> None:
    world.settle()
    assert C.turns(world, token) == 0, f"{token} started a model turn\n{world.ctx()}"
