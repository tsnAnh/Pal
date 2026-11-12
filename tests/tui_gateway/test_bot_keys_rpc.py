"""bot_keys.status / bot_keys.set and profiles.describe_auto: owner-only, name-only answers, a failed save keeps
the old value, and nothing a worker or a bot's own connection can reach."""

from __future__ import annotations

import logging
import types
import uuid
from pathlib import Path

import pytest

from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import bot_keys, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

NAMES = {"bot_keys.status", "bot_keys.set", "profiles.describe_auto"}


@pytest.fixture
def bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for name in bot_keys.SETTABLE_KEYS:
        monkeypatch.delenv(name, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    return home


def _canary() -> str:
    return f"CANARY-{uuid.uuid4().hex}"


def _call(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _status(profile: str = "scout") -> dict[str, dict]:
    response = _call("bot_keys.status", {"profile": profile})
    assert "error" not in response, response.get("error")
    result = METHODS["bot_keys.status"].result.model_validate(response["result"])
    assert result.profile == profile
    return {row["name"]: row for group in response["result"]["groups"] for row in group["keys"]}


def _set(profile: str, key: str, value: str | None) -> dict:
    response = _call("bot_keys.set", {"profile": profile, "key_name": key, "value": value})
    assert "error" not in response, response.get("error")
    return METHODS["bot_keys.set"].result.model_validate(response["result"]).model_dump(mode="json")


def _env(profile: str) -> dict[str, str]:
    path = get_profile_dir(profile) / ".env"
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line) if path.exists() else {}


def test_set_replace_and_remove_flip_only_that_bots_row(bots, caplog):
    caplog.set_level(logging.DEBUG)
    assert _status()["MEM0_API_KEY"]["is_set"] is False
    first, second = _canary(), _canary()
    assert _set("scout", "MEM0_API_KEY", first)["is_set"] is True
    assert _env("scout")["MEM0_API_KEY"] == first
    assert _status()["MEM0_API_KEY"]["is_set"] is True
    assert _status("pilot")["MEM0_API_KEY"]["is_set"] is False
    assert _set("scout", "MEM0_API_KEY", second)["is_set"] is True
    assert _env("scout")["MEM0_API_KEY"] == second
    assert _set("scout", "MEM0_API_KEY", None)["is_set"] is False
    assert "MEM0_API_KEY" not in _env("scout")
    assert first not in caplog.text and second not in caplog.text


def test_answers_carry_names_and_states_never_values(bots):
    value = _canary()
    response = _call("bot_keys.set", {"profile": "scout", "key_name": "NOTION_API_KEY", "value": value})
    assert value not in repr(response)
    assert value not in repr(_call("bot_keys.status", {"profile": "scout"}))


def test_a_name_outside_the_list_is_refused(bots):
    for name in ("OPENAI_API_KEY", "WEBHOOK_SECRET", "API_SERVER_KEY", "PATH"):
        response = _call("bot_keys.set", {"profile": "scout", "key_name": name, "value": _canary()})
        assert response["error"]["code"] == 4101
    assert _env("scout") == {}


def test_a_failed_save_keeps_the_old_value(bots, monkeypatch, caplog):
    old, new = _canary(), _canary()
    _set("scout", "LINEAR_API_KEY", old)

    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr("hermes_cli.config.save_env_value_secure", boom)
    response = _call("bot_keys.set", {"profile": "scout", "key_name": "LINEAR_API_KEY", "value": new})
    assert response["error"]["code"] == 5103
    assert new not in repr(response) and new not in caplog.text
    assert _env("scout")["LINEAR_API_KEY"] == old


def test_secondary_profile_ticket_is_refused(bots):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        assert _call("bot_keys.status", {"profile": "scout"})["error"]["code"] == 4403
        response = _call("bot_keys.set", {"profile": "scout", "key_name": "MEM0_API_KEY", "value": _canary()})
        assert response["error"]["code"] == 4403
        assert _call("profiles.describe_auto", {"name": "scout"})["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert _env("scout") == {}


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_worker_and_capability_less_connections_cannot_reach_the_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_describe_auto_writes_an_auto_description_and_keeps_the_owners(bots, monkeypatch):
    from hermes_cli import profile_describer, profiles

    def fake(name, *, overwrite=False, timeout=None):
        meta = profiles.read_profile_meta(get_profile_dir(name))
        if meta.get("description") and not meta.get("description_auto") and not overwrite:
            return profile_describer.DescribeOutcome(name, False, "profile already has a user-authored description")
        profiles.write_profile_meta(get_profile_dir(name), description="Finds things.", description_auto=True)
        return profile_describer.DescribeOutcome(name, True, description="Finds things.")

    monkeypatch.setattr(profile_describer, "describe_profile", fake)
    ok = _call("profiles.describe_auto", {"name": "scout"})
    assert ok["result"]["description"] == "Finds things."
    profiles.write_profile_meta(get_profile_dir("scout"), description="Mine.", description_auto=False)
    refused = _call("profiles.describe_auto", {"name": "scout"})
    assert refused["error"]["code"] == 4102
    assert _call("profiles.describe_auto", {"name": "scout", "overwrite": True})["result"]["ok"] is True


def test_a_profile_created_but_not_configured_is_listed_and_deletable(bots):
    listing = _call("profiles.list", {})["result"]["profiles"]
    assert "scout" in {p["name"] for p in listing}
    assert _call("profiles.delete", {"name": "scout"})["result"]["ok"] is True
    assert "scout" not in {p["name"] for p in _call("profiles.list", {})["result"]["profiles"]}
