"""`connectors.hosted: false` turns the hosted connector surface off for its own profile only.

One process serves a profile that switched it off and one that kept the default. Every check runs
under the owning profile's bound scope, the way a turn, a cron tick and an RPC handler bind it.
"""

from __future__ import annotations

import contextlib
import json
from pathlib import Path

import pytest

from agent.runtime_scope import bind_state, scope_for_profile
from tools.connectors.gateway.errors import ToolGatewayError
from tui_gateway import server


@pytest.fixture
def profiles(tmp_path, monkeypatch):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    launch = tmp_path / ".hermes"
    launch.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(launch))
    homes = {}
    for name, hosted in (("pal", False), ("desk", True)):
        home = launch / "profiles" / name
        home.mkdir(parents=True)
        (home / "config.yaml").write_text(f"connectors:\n  hosted: {str(hosted).lower()}\n")
        homes[name] = home
    return homes


@contextlib.contextmanager
def in_profile(home):
    tokens = bind_state(scope_for_profile(home))
    try:
        yield
    finally:
        tokens.reset()


def offered_tools(home, platform):
    import model_tools
    from cron.scheduler import _resolve_cron_enabled_toolsets
    from hermes_cli.config import load_config
    from hermes_cli.tools_config import _get_platform_tools
    from toolsets import session_disabled_toolsets

    with in_profile(home):
        config = load_config()
        enabled = (_resolve_cron_enabled_toolsets({}, config) if platform == "cron"
                   else sorted(_get_platform_tools(config, platform)))
        definitions = model_tools.get_tool_definitions(
            enabled_toolsets=enabled, disabled_toolsets=session_disabled_toolsets(None, platform),
            quiet_mode=True, skip_tool_search_assembly=True)
    return {tool["function"]["name"] for tool in definitions or []}


@pytest.mark.parametrize("platform", ["cli", "cron"])
def test_manage_connections_is_offered_only_to_the_profile_that_kept_hosted_on(profiles, platform):
    assert "manage_connections" not in offered_tools(profiles["pal"], platform)
    assert "manage_connections" in offered_tools(profiles["desk"], platform)
    assert "manage_connections" not in offered_tools(profiles["pal"], platform)


def call(method, profile, **params):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method,
                                  "params": {"profile": profile, **params}})


PORTAL_CALLS = (
    ("connectors.list", {"owner": {"type": "account", "source": "desktop"}}),
    ("connectors.connect", {"owner": {"type": "account", "source": "desktop"}, "connectors": ["gmail"]}),
    ("connectors.tools", {"slug": "gmail"}),
    ("connectors.accounts", {}),
    ("connectors.policy.get", {}),
)


@pytest.mark.parametrize("method,params", PORTAL_CALLS, ids=[name for name, _ in PORTAL_CALLS])
def test_portal_rpcs_refuse_with_connectors_unavailable_in_the_off_profile_only(profiles, monkeypatch, method, params):
    reached = []
    monkeypatch.setattr("tools.connectors.gateway.client.ConnectorClient._request",
                        lambda self, *a, **k: reached.append(a) or (_ for _ in ()).throw(RuntimeError("no network")))
    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient._request",
                        lambda self, *a, **k: reached.append(a) or (_ for _ in ()).throw(RuntimeError("no network")))

    off = call(method, "pal", **params)
    assert off["error"]["code"] == 4031 and off["error"]["data"]["reason"] == "CONNECTORS_UNAVAILABLE", off
    assert reached == []

    on = call(method, "desk", **params)
    assert on.get("error", {}).get("data", {}).get("reason") != "CONNECTORS_UNAVAILABLE", on


class RecordingTransport:
    def __init__(self):
        self.requests = []

    def request(self, method, url, **kwargs):
        self.requests.append((method, url))
        raise OSError("recorded")


def test_the_off_profile_mints_no_guest_identity_and_sends_no_request_while_the_other_profile_does(profiles, monkeypatch):
    from tools.connectors.gateway import config as gateway_config
    from tools.connectors.gateway.client import ConnectorClient
    from tools.connectors.portal.client import PortalConnectorClient

    minted = []
    monkeypatch.setattr("hermes_cli.anon_auth.ensure_portal_identity", lambda **k: minted.append(k))
    gateway_transport, portal_transport = RecordingTransport(), RecordingTransport()

    def clients():
        return (ConnectorClient(transport=gateway_transport, endpoint_resolver=lambda: "https://gateway.test",
                                header_provider=lambda url: {"Authorization": "Bearer t"}, sleep=lambda s: None),
                PortalConnectorClient(transport=portal_transport, endpoint_resolver=lambda: "https://portal.test",
                                      header_provider=lambda url: {"Authorization": "Bearer t"}))

    with in_profile(profiles["pal"]):
        gateway, portal = clients()
        assert gateway_config.guest_identity_pending() is False
        assert gateway_config.ensure_guest_identity() is None
        for refused in (gateway.list_connectors, portal.list_accounts):
            with pytest.raises(ToolGatewayError) as raised:
                refused()
            assert raised.value.code == "CONNECTORS_DISABLED"
    assert minted == [] and gateway_transport.requests == [] and portal_transport.requests == []

    with in_profile(profiles["desk"]):
        gateway, portal = clients()
        with contextlib.suppress(Exception):
            gateway.list_connectors()
        with contextlib.suppress(Exception):
            portal.list_accounts()
    assert gateway_transport.requests and portal_transport.requests


def test_hosted_stays_on_for_a_profile_that_never_set_it(tmp_path, monkeypatch):
    from tools.connectors.hosted_switch import hosted_enabled

    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    assert hosted_enabled() is True
    (home / "config.yaml").write_text(json.dumps({"connectors": {"hosted": "off"}}))
    assert hosted_enabled() is False
