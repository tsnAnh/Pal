from __future__ import annotations

import json
from typing import Any, Callable

import pytest

from tests.e2e.core.bots._gate import EXPECTED_VISIBLE, build, point_at
from tests.e2e.core.bots._world import World, marker_for
from tests.e2e.core.history._helpers import Spawned, prefix_breaks, run_oneshot
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall


@pytest.fixture(scope="module")
def legacy_world(tmp_path_factory) -> World:
    w = World(tmp_path_factory.mktemp("gate-entrypoints"))
    build(w, "legacy")
    return w


def run_chat(w: World, bot: str, srv: FakeLLMServer, prompt: str, *extra: str) -> None:
    point_at(w, srv)
    w.hermes(bot, "chat", "-q", prompt, "-Q", *extra)


def system_prompt(requests: list[dict]) -> str:
    first = requests[0]["messages"][0]
    assert first["role"] == "system"
    return first["content"] if isinstance(first["content"], str) else json.dumps(first["content"])


@pytest.mark.parametrize("bot,skill", [("a", "gated-mcp"), ("b", "gated-mcp"), ("c", "gated-oauth")])
def test_cli_preload_and_prompt_index_include_only_connected_skills(legacy_world, bot: str, skill: str) -> None:
    w = legacy_world
    with FakeLLMServer(default_text="done") as srv:
        run_chat(w, bot, srv, "say hi", "-s", skill)
        requests = srv.main_requests()
    assert requests, "the chat run never reached the model"
    marker = marker_for(skill)
    connected = skill in EXPECTED_VISIBLE[bot]
    assert (marker in json.dumps(requests)) == connected, "preloaded skill body presence is wrong for this bot"
    assert (f"Use when probing {skill}." in system_prompt(requests)) == connected, "system-prompt skill index is wrong for this bot"
    assert "ungated" in system_prompt(requests)


def delegating_responder(skill: str) -> Callable[[dict], Any]:
    def respond(rec: dict):
        messages = rec["body"]["messages"]
        first_user = next((str(m.get("content")) for m in messages if m.get("role") == "user"), "")
        has_tool = any(m.get("role") == "tool" for m in messages)
        if "CHILD-GOAL" in first_user:
            return Text("child done") if has_tool else ToolCall("skill_view", {"name": skill})
        return Text("parent done") if has_tool else ToolCall(
            "delegate_task", {"goal": "CHILD-GOAL load the skill and report", "context": "skill probe"})
    return respond


@pytest.mark.parametrize("bot,skill", [("a", "gated-mcp"), ("b", "gated-mcp")])
def test_delegated_child_cannot_read_a_skill_its_bot_is_not_connected_to(legacy_world, bot: str, skill: str) -> None:
    w = legacy_world
    with FakeLLMServer(delegating_responder(skill)) as srv:
        run_chat(w, bot, srv, "PARENT-PROMPT delegate this")
        requests = srv.main_requests()
    child_requests = [r for r in requests if "CHILD-GOAL" in json.dumps(r["messages"][1:2])]
    assert child_requests, "no delegated child request was made; the delegation path did not run"
    tool_results = json.dumps([m for r in child_requests for m in r["messages"] if m.get("role") == "tool"])
    marker = marker_for(skill)
    if skill in EXPECTED_VISIBLE[bot]:
        assert marker in tool_results
    else:
        assert marker not in tool_results, "child read a gated skill through skill_view"
        assert "connector_not_connected" in tool_results


@pytest.mark.parametrize("mode,skill,disconnect", [
    ("legacy", "gated-mcp", lambda w: w.set_mcp_enabled("a", "srv", False)),
    ("shared", "gated-oauth", lambda w: w.remove_token("a", "oauthsrv")),
], ids=["config-disabled", "token-removed"])
def test_disconnect_mid_session_keeps_the_index_but_denies_the_next_call(
    tmp_path, mode: str, skill: str, disconnect,
) -> None:
    fresh = World(tmp_path)
    build(fresh, mode)
    marker = marker_for(skill)
    spawned = Spawned()

    def responder(rec: dict):
        messages = rec["body"]["messages"]
        calls_skill_view = any(
            tc.get("function", {}).get("name") == "skill_view" for m in messages for tc in (m.get("tool_calls") or []))
        if "now load the skill" in json.dumps(messages[-1]) and not calls_skill_view:
            return ToolCall("skill_view", {"name": skill})
        return Text("ok")

    with FakeLLMServer(responder) as srv:
        point_at(fresh, srv)
        env = fresh.env("a")
        _, sid = run_oneshot(env, fresh.workdir, "first turn", spawned)
        before = len(srv.main_requests())
        disconnect(fresh)
        run_oneshot(env, fresh.workdir, "now load the skill", spawned, resume=sid)
        requests = srv.main_requests()
    assert not spawned.reap()
    assert skill in system_prompt(requests), "skill was not indexed while connected"
    assert system_prompt(requests[before:]) == system_prompt(requests), "system prompt index changed mid-session"
    assert prefix_breaks(requests, tools=False) == []
    tool_results = json.dumps([m for m in requests[-1]["messages"] if m.get("role") == "tool"])
    assert "connector_not_connected" in tool_results, tool_results[:400]
    assert marker not in tool_results
