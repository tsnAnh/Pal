from __future__ import annotations

import json
import types

import pytest

from gateway import bot_loop_guard
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

NAME = "gateway.guards.status"


@pytest.fixture(autouse=True)
def home(tmp_path, monkeypatch):
    bot_loop_guard._warned.clear()
    path = tmp_path / "home"
    path.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(path))
    return path


def write(home, block):
    (home / "config.yaml").write_text(json.dumps({"gateway": {"bot_loop_guard": block}}), encoding="utf-8")


def call(params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": NAME, "params": params or {}})


def guards():
    response = call()
    assert "error" not in response, response
    METHODS[NAME].result.model_validate(response["result"])
    return {g["key"]: g for g in response["result"]["guards"]}


def test_reports_effective_value_source_and_clamped_flag(home):
    write(home, {"max_hops": 1000, "max_events": "ten"})
    found = guards()
    assert found["gateway.bot_loop_guard.max_hops"] == {
        "key": "gateway.bot_loop_guard.max_hops", "value": bot_loop_guard.MAX_HOPS_CAP, "source": "config", "clamped": True}
    assert found["gateway.bot_loop_guard.max_events"]["source"] == "default"
    assert found["gateway.bot_loop_guard.enabled"]["value"] is True
    assert set(found) == {f"gateway.bot_loop_guard.{k}" for k in (
        "enabled", "max_events", "window_seconds", "cooldown_seconds", "max_hops", "bot_replies_expect_reply")}


def test_an_edit_shows_on_the_next_call_without_a_restart(home):
    write(home, {"max_hops": 10})
    assert guards()["gateway.bot_loop_guard.max_hops"]["value"] == 10
    write(home, {"max_hops": 7})
    assert guards()["gateway.bot_loop_guard.max_hops"]["value"] == 7


def test_secondary_profile_ticket_is_refused():
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        assert call()["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)


def test_not_a_model_tool_and_not_reachable_by_workers():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    from model_tools import get_all_tool_names
    tools = set(get_all_tool_names())
    assert NAME in METHODS and NAME not in tools and NAME.replace(".", "_") not in tools
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    assert not legacy_fallback_allowed(worker, NAME)
    assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), NAME)
    assert legacy_fallback_allowed(owner, NAME)
