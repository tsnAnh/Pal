from __future__ import annotations

from types import SimpleNamespace

import hermes_yaml as yaml

from gateway.config import load_gateway_config
from gateway.run_platform_reload import reload_routes_verb

ROUTE = {"name": "pal-discord-ada-111", "platform": "discord", "chat_id": "111", "profile": "ada"}


def _write_routes(home, routes):
    (home / "config.yaml").write_text(yaml.safe_dump({"profile_routes": routes}), encoding="utf-8")


def test_verb_swaps_in_routes_saved_after_the_gateway_started(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    _write_routes(tmp_path, [])
    runner = SimpleNamespace(config=load_gateway_config())
    assert runner.config.profile_routes == []

    _write_routes(tmp_path, [ROUTE])
    answer = reload_routes_verb(runner)({})

    assert answer == {"reloaded": True, "routes": 1}
    route = runner.config.profile_routes[0]
    assert (route.platform, route.chat_id, route.profile, route.bot_profile) == ("discord", "111", "ada", None)


def test_verb_drops_a_route_removed_from_the_saved_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    _write_routes(tmp_path, [ROUTE])
    runner = SimpleNamespace(config=load_gateway_config())
    assert len(runner.config.profile_routes) == 1

    _write_routes(tmp_path, [])

    assert reload_routes_verb(runner)({}) == {"reloaded": True, "routes": 0}
    assert runner.config.profile_routes == []
