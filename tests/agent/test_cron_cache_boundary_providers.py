from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest

from agent import prompt_cache_boundary
from agent.anthropic_adapter import build_anthropic_kwargs
from agent.prompt_cache_boundary import find_stable_prefix
from agent.prompt_caching import build_prompt_cache_plan
from cron.scheduler import _build_job_prompt

PDT = timezone(timedelta(hours=-7), "PDT")
FIRE_1 = datetime(2026, 10, 31, 7, 0, tzinfo=PDT)
FIRE_2 = datetime(2026, 10, 31, 8, 1, tzinfo=PDT)
JOB = {"id": "abc123def456", "prompt": "Check the feed and report new items."}
SYSTEM = {"role": "system", "content": "You are a helpful bot.\nConversation started: Saturday"}
TOOLS = [{"type": "function", "function": {"name": "probe", "description": "d", "parameters": {"type": "object"}}}]


@pytest.fixture(autouse=True)
def _isolated_registry():
    with prompt_cache_boundary._lock:
        prompt_cache_boundary._prefixes.clear()
    yield
    with prompt_cache_boundary._lock:
        prompt_cache_boundary._prefixes.clear()


def _fire(when, script_output):
    with patch("cron.scheduler_prompt._hermes_now", return_value=when):
        return _build_job_prompt(JOB, prerun_script=(True, script_output))


@pytest.fixture
def fires():
    return _fire(FIRE_1, "rows 1"), _fire(FIRE_2, "rows 2")


def _plan(message, *, native, ttl="1h", with_tool_round=False, direct=False):
    messages = [dict(SYSTEM), {"role": "user", "content": message}]
    if with_tool_round:
        messages += [
            {"role": "assistant", "content": "", "tool_calls": [
                {"id": "call_1", "type": "function", "function": {"name": "probe", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "call_1", "content": "ok"},
        ]
    return build_prompt_cache_plan(
        messages, TOOLS, cache_ttl=ttl, native_anthropic=native, direct_native_tool_cache=direct).messages


def _marked(parts):
    return [i for i, part in enumerate(parts) if "cache_control" in part]


LAYOUTS = [
    pytest.param({"native": True}, id="native-blocks"),
    pytest.param({"native": True, "direct": True}, id="direct-native-tool-cache"),
    pytest.param({"native": False}, id="envelope"),
]


@pytest.mark.parametrize("layout", LAYOUTS)
def test_anthropic_breakpoint_sits_on_the_stable_scaffold(fires, layout):
    first, second = fires
    boundary = find_stable_prefix(first)
    assert boundary is not None

    one, two = _plan(first, **layout)[1]["content"], _plan(second, **layout)[1]["content"]

    assert [p["text"] for p in one] == [boundary, first[len(boundary):]]
    assert _marked(one) == [0] and _marked(two) == [0]
    assert one[0] == two[0]
    assert one[1]["text"] != two[1]["text"]


@pytest.mark.parametrize("layout", LAYOUTS)
def test_anthropic_scaffold_bytes_do_not_move_after_a_tool_round(fires, layout):
    first, _ = fires
    opening = _plan(first, **layout)[1]["content"]
    after_tool = _plan(first, with_tool_round=True, **layout)[1]["content"]

    assert [p["text"] for p in after_tool] == [p["text"] for p in opening]


def test_anthropic_wire_keeps_the_scaffold_block_and_its_marker(fires):
    first, second = fires

    def wire(message):
        planned = _plan(message, native=True)
        return build_anthropic_kwargs(
            model="claude-sonnet-5", messages=planned, tools=TOOLS, max_tokens=1024, reasoning_config=None,
            base_url="https://api.anthropic.com",
        )["messages"][0]["content"]

    one, two = wire(first), wire(second)
    boundary = find_stable_prefix(first)

    assert one[0]["text"] == boundary and "cache_control" in one[0]
    assert "cache_control" not in one[1]
    assert one[0] == two[0] and one[1]["text"] != two[1]["text"]


def test_codex_fires_share_cache_key_instructions_tools_and_input_prefix(fires):
    from agent.transports.codex import ResponsesApiTransport

    first, second = fires
    boundary = find_stable_prefix(first)
    assert boundary is not None

    def request(message, stamp):
        return ResponsesApiTransport().build_kwargs(
            model="gpt-5.5", messages=[dict(SYSTEM), {"role": "user", "content": message}], tools=TOOLS,
            session_id=f"cron_{JOB['id']}_{stamp}", base_url="https://chatgpt.com/backend-api/codex",
            is_codex_backend=True,
        )

    one, two = request(first, "20261031_070000"), request(second, "20261031_080100")

    assert one["prompt_cache_key"] == two["prompt_cache_key"]
    assert one["instructions"] == two["instructions"] and one["tools"] == two["tools"]
    text_one, text_two = (str(r["input"][0]["content"]) for r in (one, two))
    shared = next((i for i, (a, b) in enumerate(zip(text_one, text_two)) if a != b), min(len(text_one), len(text_two)))
    assert shared >= len(boundary)
