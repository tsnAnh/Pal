"""``webapp.public_url.*``: owner-only RPCs over the validator and the config key the routes read."""

from __future__ import annotations

import pytest

from gateway import public_address
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home

NAMES = ["webapp.public_url.get", "webapp.public_url.set", "webapp.public_url.check"]


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


@pytest.fixture(autouse=True)
def no_tailnet(monkeypatch):
    monkeypatch.setattr(public_address, "tailnet_suggestion", lambda *a, **k: "https://node.tail1.ts.net")
    monkeypatch.setattr(public_address.subprocess, "run", lambda *a, **k: pytest.fail("no process may run"))


def test_contracts_are_registered():
    assert set(NAMES) <= set(METHODS)


def test_set_get_clear_round_trip_with_the_suggestion():
    empty = _call("webapp.public_url.get")["result"]
    assert empty == {"url": None, "routes_enabled": False, "suggestion": "https://node.tail1.ts.net"}
    saved = _call("webapp.public_url.set", {"url": "HTTPS://Pal.Example.com/"})["result"]
    assert saved["url"] == "https://pal.example.com"
    from gateway.chat_install_runtime import public_url_for
    from hermes_constants import get_hermes_home
    assert public_url_for(get_hermes_home()) == "https://pal.example.com"
    assert _call("webapp.public_url.set", {"url": ""})["result"]["url"] is None


def test_a_refused_address_names_the_rule():
    error = _call("webapp.public_url.set", {"url": "https://100.64.0.1"})["error"]
    assert error["code"] == 4000
    assert error["data"] == {"reason": "invalid_params", "field": "url", "problem": "ip_host"}


def test_check_reports_the_outcome_for_the_saved_address(monkeypatch):
    assert _call("webapp.public_url.check")["result"] == {"outcome": "no_address", "url": None}
    _call("webapp.public_url.set", {"url": "https://pal.example.com"})
    monkeypatch.setattr(public_address, "check", lambda url: public_address.Outcome.reachable)
    assert _call("webapp.public_url.check")["result"] == {"outcome": "reachable", "url": "https://pal.example.com"}


def test_a_secondary_profile_ticket_is_refused_and_changes_nothing():
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        for name in NAMES:
            error = _call(name, {"url": "https://pal.example.com"} if name.endswith("set") else None)["error"]
            assert error["code"] == 4403 and error["data"] == {"reason": "owner_only"}
    finally:
        _connection_profile_home.reset(token)
    assert _call("webapp.public_url.get")["result"]["url"] is None


def test_config_set_still_refuses_the_key():
    error = _call("config.set", {"key": "webapp.public_url", "value": "https://pal.example.com"})["error"]
    assert error["code"] == 4002
