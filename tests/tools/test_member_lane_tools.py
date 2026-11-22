import json
from urllib.parse import parse_qs

import httpx
import pytest

import toolsets
from gateway.audience import Audience
from gateway.chat_slack.api import SlackApi
from gateway.config import Platform
from gateway.session import SessionSource, build_session_key
from gateway.session_context import clear_session_vars, set_session_vars
from tools import slack_tools, url_safety

TOKEN = "fake-token-do-not-use"
INSTALL = slack_tools.SlackInstall("T0TEAM", "Acme", "vault-item-1")

CHANNELS = {
    "C0PUBLIC": {"id": "C0PUBLIC", "name": "general", "is_channel": True, "is_private": False},
    "C0PRIVATE": {"id": "C0PRIVATE", "name": "plans", "is_channel": True, "is_private": True},
    "G0LEGACY": {"id": "G0LEGACY", "name": "legacy", "is_group": True, "is_private": True},
    "D0OWNER": {"id": "D0OWNER", "is_im": True},
    "D0ALICE": {"id": "D0ALICE", "is_im": True},
    "C0NOFLAGS": {"id": "C0NOFLAGS", "name": "mystery"},
}


@pytest.fixture
def slack(monkeypatch):
    calls: list[tuple[str, dict]] = []

    def handle(request: httpx.Request) -> httpx.Response:
        method = request.url.path.rsplit("/", 1)[-1]
        data = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
        calls.append((method, data))
        if method == "conversations.info":
            channel = CHANNELS.get(data["channel"])
            return httpx.Response(200, json={"ok": True, "channel": channel} if channel
                                  else {"ok": False, "error": "channel_not_found"})
        if method in ("conversations.history", "conversations.replies"):
            return httpx.Response(200, json={"ok": True, "messages": [{"ts": "1.1", "user": "U0ALICE", "text": "hi"}]})
        raise AssertionError(f"unexpected Slack method {method}")

    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: INSTALL)
    monkeypatch.setattr(slack_tools, "_bot_token", lambda install: TOKEN)
    monkeypatch.setattr(slack_tools, "_api", lambda: SlackApi(httpx.MockTransport(handle), sleep=lambda s: None))
    return calls


def run(tool: str, args: dict) -> dict:
    return json.loads(slack_tools.run_slack_tool(tool, slack_tools._TOOLS[tool][0], args))


@pytest.fixture
def lane():
    tokens: list = []

    def enter(audience: Audience, chat_id: str, chat_type: str = "group"):
        source = SessionSource(platform=Platform.SLACK, chat_id=chat_id, chat_type=chat_type, user_id="U0ALICE",
                               scope_id="T0TEAM", thread_id="1.0", audience=audience)
        tokens.append(set_session_vars(platform="slack", chat_id=chat_id, chat_type=chat_type,
                                       session_key=build_session_key(source)))

    yield enter
    for token in tokens:
        clear_session_vars(token)


READS = [("slack_read_channel", {"channel": "{c}"}), ("slack_read_thread", {"channel": "{c}", "thread_ts": "1.0"})]


def args_for(args: dict, channel: str) -> dict:
    return {k: v.format(c=channel) if isinstance(v, str) else v for k, v in args.items()}


@pytest.mark.parametrize("tool, args", READS)
@pytest.mark.parametrize("channel", ["C0PRIVATE", "G0LEGACY", "D0OWNER", "C0NOFLAGS", "C0MISSING"])
def test_member_lane_cannot_read_a_conversation_that_is_not_public_or_its_own(slack, lane, tool, args, channel):
    lane(Audience.MEMBER, "C0PUBLIC")
    result = run(tool, args_for(args, channel))
    assert result["code"] == "slack_member_scope"
    assert [m for m, _ in slack if m.startswith("conversations.history") or m == "conversations.replies"] == []


@pytest.mark.parametrize("tool, args", READS)
def test_member_lane_reads_a_public_channel(slack, lane, tool, args):
    lane(Audience.MEMBER, "D0ALICE", "dm")
    assert run(tool, args_for(args, "C0PUBLIC"))["messages"][0]["text"] == "hi"


@pytest.mark.parametrize("tool, args", READS)
@pytest.mark.parametrize("own, chat_type", [("D0ALICE", "dm"), ("C0PRIVATE", "group")])
def test_member_lane_reads_its_own_conversation_even_when_private(slack, lane, tool, args, own, chat_type):
    lane(Audience.MEMBER, own, chat_type)
    assert run(tool, args_for(args, own))["messages"][0]["text"] == "hi"
    assert [m for m, _ in slack] == [m for m, _ in slack if m != "conversations.info"]


@pytest.mark.parametrize("tool, args", READS)
def test_owner_lane_reads_are_unchanged(slack, lane, tool, args):
    lane(Audience.OWNER, "C0PUBLIC")
    assert run(tool, args_for(args, "D0OWNER"))["messages"][0]["text"] == "hi"
    assert "conversations.info" not in [m for m, _ in slack]


def test_untrusted_sender_safe_tools_feed_the_webhook_and_member_toolsets():
    safe = set(toolsets.UNTRUSTED_SENDER_SAFE_TOOLS)
    assert {"web_search", "web_extract", "vision_analyze", "clarify"} == safe
    assert set(toolsets.TOOLSETS["hermes-webhook"]["tools"]) == safe
    member = set(toolsets.resolve_toolset("member"))
    assert member == safe | {"slack_read_thread", "slack_read_channel", "slack_react", "request_owner_action"}
    assert member.isdisjoint({"terminal", "write_file", "patch", "execute_code", "memory", "session_search",
                              "delegate_task", "cronjob_manage", "slack_post_message", "slack_send_dm"})
    assert not any("member" in spec.get("includes", ()) for spec in toolsets.TOOLSETS.values())


def test_forbidding_private_urls_is_bound_to_the_calling_context_and_beats_the_opt_in(monkeypatch):
    monkeypatch.setenv("HERMES_ALLOW_PRIVATE_URLS", "true")
    url_safety._reset_allow_private_cache()
    try:
        assert url_safety.is_safe_url("http://127.0.0.1:9/")
        with url_safety.forbid_private_urls():
            assert not url_safety.is_safe_url("http://127.0.0.1:9/")
        assert url_safety.is_safe_url("http://127.0.0.1:9/")
    finally:
        url_safety._reset_allow_private_cache()
