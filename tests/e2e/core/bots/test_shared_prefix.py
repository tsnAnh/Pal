from __future__ import annotations

import json
from pathlib import Path

from tests.e2e.core.bots._world import DEAD_URL, World, marker_for
from tests.e2e.core.history._helpers import Spawned, prefix_breaks, run_oneshot
from tests.fakes.fake_llm_provider import FakeLLMServer, Text, ToolCall

NEW_SKILL = "late-shared"


def system_text(request: dict) -> str:
    first = request["messages"][0]
    assert first["role"] == "system"
    return first["content"] if isinstance(first["content"], str) else json.dumps(first["content"])


def test_skills_and_mcp_added_between_turns_never_rewrite_the_cached_prefix(tmp_path: Path) -> None:
    marker = marker_for(NEW_SKILL)

    def responder(rec: dict):
        messages = rec["body"]["messages"]
        asked = any(tc.get("function", {}).get("name") == "skill_view"
                    for m in messages for tc in (m.get("tool_calls") or []))
        if "load the new skill" in json.dumps(messages[-1]) and not asked:
            return ToolCall("skill_view", {"name": NEW_SKILL})
        return Text("ok")

    spawned = Spawned()
    with FakeLLMServer(responder) as srv:
        w = World(tmp_path, srv.base_url)
        w.catalog_skill("existing-shared")
        w.save_catalog_mcp({"early": {"url": DEAD_URL}})
        w.add_bot("alice", mcp_servers={"early": {"enabled": True}},
                  extra={"skills": {"enabled": ["existing-shared", NEW_SKILL]}})
        w.add_bot("bob")
        env = w.env("alice")

        _, sid = run_oneshot(env, w.workdir, "first turn", spawned)
        turn_one = len(srv.main_requests())

        w.catalog_skill(NEW_SKILL, connector="mcp:late")
        servers = w.catalog_mcp()
        servers["late"] = {"url": DEAD_URL}
        w.save_catalog_mcp(servers)
        w.set_mcp_enabled("alice", "late", True)

        run_oneshot(env, w.workdir, "load the new skill", spawned, resume=sid)
        requests = srv.main_requests()

    assert not spawned.reap()
    assert turn_one >= 1 and len(requests) > turn_one
    assert "existing-shared" in system_text(requests[0]), "catalog skills must be indexed for the bot"
    assert prefix_breaks(requests, tools=False) == []
    assert all(system_text(r) == system_text(requests[0]) for r in requests)
    assert NEW_SKILL not in system_text(requests[0]), "a skill shared mid-session must not rewrite the index"

    tool_results = [m for m in requests[-1]["messages"] if m.get("role") == "tool"]
    assert tool_results, "the model never got a skill_view result"
    payload = json.loads(tool_results[-1]["content"])
    assert payload.get("success") is True, payload
    assert marker in payload["content"]
