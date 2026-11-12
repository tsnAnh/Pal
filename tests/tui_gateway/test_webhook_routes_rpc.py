from __future__ import annotations

import json
import logging
import socket
import ssl
import types

import httpx
import pytest

from tui_gateway import server, webhook_routes
from tui_gateway.contracts import METHODS
from tui_gateway.webhook_routes import Hop, diagnose
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

NAMES = ["webhook.routes.list", "webhook.routes.add", "webhook.routes.remove", "webhook.routes.probe"]
TYPED_SECRET = "typed-secret-CANARY-0123456789"
BASE = "https://hermes.example.test"


class Net:
    def __init__(self):
        self.requests: list[dict] = []
        self.local: object = 401
        self.public: object = 502

    def client(self, **kwargs):
        net = self
        assert kwargs.get("follow_redirects") is False and kwargs.get("timeout") and kwargs.get("trust_env") is False

        class Client:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def post(self, url, content=None, headers=None):
                net.requests.append({"url": url, "content": content})
                outcome = net.local if url.startswith("http://127.0.0.1") else net.public
                if isinstance(outcome, BaseException):
                    raise outcome
                return httpx.Response(outcome, request=httpx.Request("POST", url))

        return Client()


@pytest.fixture
def net(monkeypatch):
    fake = Net()
    monkeypatch.setattr(webhook_routes.httpx, "Client", fake.client)
    monkeypatch.setattr(webhook_routes, "_cert_expiry", lambda host, port: "2030-01-01T00:00:00Z")
    monkeypatch.setattr(webhook_routes, "listener_address", lambda: (True, "127.0.0.1", 8644))
    monkeypatch.setattr(webhook_routes, "public_base_url", lambda: BASE)
    return fake


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def _add(name="paint-pr", **params):
    return _call("webhook.routes.add", {"name": name, "generate_secret": True, **params})


def _stored():
    return json.loads((webhook_routes_home() / "webhook_subscriptions.json").read_text())


def webhook_routes_home():
    from hermes_constants import get_hermes_home
    return get_hermes_home()


def test_add_list_remove_round_trip(net):
    added = _add(events=["pull_request"])["result"]
    METHODS["webhook.routes.add"].result.model_validate(added)
    assert added["route"]["path"] == "/webhooks/paint-pr"
    assert added["route"]["public_url"] == f"{BASE}/webhooks/paint-pr"
    assert added["route"]["events"] == ["pull_request"]
    listed = _call("webhook.routes.list")["result"]
    METHODS["webhook.routes.list"].result.model_validate(listed)
    assert [r["name"] for r in listed["routes"]] == ["paint-pr"]
    assert listed["public_base_url"] == BASE
    assert _call("webhook.routes.remove", {"name": "paint-pr"})["result"] == {"ok": True}
    assert _call("webhook.routes.list")["result"]["routes"] == []
    assert _call("webhook.routes.remove", {"name": "paint-pr"})["error"]["code"] == 4404


def test_generated_secret_is_returned_once_and_never_listed_or_logged(net, caplog):
    caplog.set_level(logging.DEBUG)
    added = _add()["result"]
    secret = added["secret"]
    assert len(secret) >= 32 and secret == _stored()["paint-pr"]["secret"]
    listed = json.dumps(_call("webhook.routes.list")["result"])
    probed = json.dumps(_call("webhook.routes.probe", {"name": "paint-pr"}))
    assert secret not in listed and secret not in probed
    assert secret not in caplog.text
    assert secret not in json.dumps(added["route"])


def test_typed_secret_is_stored_but_never_echoed(net, caplog):
    caplog.set_level(logging.DEBUG)
    response = _call("webhook.routes.add", {"name": "typed", "secret": TYPED_SECRET})
    assert response["result"]["secret"] is None
    assert TYPED_SECRET not in json.dumps(response) and TYPED_SECRET not in caplog.text
    assert _stored()["typed"]["secret"] == TYPED_SECRET
    assert TYPED_SECRET not in json.dumps(_call("webhook.routes.list"))


@pytest.mark.parametrize("params", [
    {"name": "x"},
    {"name": "x", "secret": TYPED_SECRET, "generate_secret": True},
    {"name": "x", "secret": "short"},
    {"name": "x", "secret": "INSECURE_NO_AUTH"},
    {"name": "Bad Name", "generate_secret": True},
    {"name": "../etc", "generate_secret": True},
    {"name": "x", "generate_secret": True, "profile": "no-such-profile"},
])
def test_invalid_adds_write_nothing(net, params):
    assert _call("webhook.routes.add", params)["error"]["code"] in {4101, 4000}
    assert _call("webhook.routes.list")["result"]["routes"] == []


def test_duplicate_name_is_refused_and_keeps_the_first_secret(net):
    first = _add()["result"]["secret"]
    assert _add()["error"]["code"] == 4409
    assert _stored()["paint-pr"]["secret"] == first


def test_add_is_refused_while_webhook_receiving_is_off(net, monkeypatch):
    monkeypatch.setattr(webhook_routes, "listener_address", lambda: (False, "127.0.0.1", 8644))
    error = _add()["error"]
    assert error["code"] == 5321 and error["data"]["code"] == "webhook_disabled"
    assert not (webhook_routes_home() / "webhook_subscriptions.json").exists()


def test_routes_load_without_a_gateway_restart(net):
    from gateway.config import PlatformConfig
    from gateway.platforms.webhook import WebhookAdapter
    adapter = WebhookAdapter(PlatformConfig(enabled=True, extra={"secret": "global-secret-0123456789"}))
    adapter._reload_dynamic_routes()
    assert "paint-pr" not in adapter._routes
    _add()
    adapter._reload_dynamic_routes()
    assert "paint-pr" in adapter._routes
    _call("webhook.routes.remove", {"name": "paint-pr"})
    adapter._reload_dynamic_routes()
    assert "paint-pr" not in adapter._routes


def test_non_default_profile_route_gets_the_profile_prefixed_path(net, monkeypatch):
    monkeypatch.setattr(webhook_routes, "_checked_profile", lambda value: value or "default")
    route = _add(profile="paint_by_number")["result"]["route"]
    assert route["path"] == "/p/paint_by_number/webhooks/paint-pr"
    assert route["public_url"] == f"{BASE}/p/paint_by_number/webhooks/paint-pr"


L401, L404 = Hop(status=401, ms=3), Hop(status=404, ms=3)


@pytest.mark.parametrize("local, public, configured, code", [
    (L404, None, True, "route_not_loaded"),
    (Hop(status=403), None, True, "route_disabled"),
    (Hop(error="unreachable"), None, True, "local_unreachable"),
    (Hop(error="skipped"), None, True, "probe_skipped"),
    (Hop(status=500), None, True, "local_unexpected"),
    (L401, None, False, "public_unconfigured"),
    (L401, Hop(status=401), True, "ok"),
    (Hop(status=200), Hop(status=200), True, "ok"),
    (L401, Hop(status=502), True, "public_not_reaching_gateway"),
    (L401, Hop(status=504), True, "public_not_reaching_gateway"),
    (L401, Hop(status=530), True, "public_not_reaching_gateway"),
    (L401, Hop(status=404), True, "public_wrong_target"),
    (L401, Hop(error="timeout"), True, "public_timeout"),
    (L401, Hop(error="tls"), True, "public_tls"),
    (L401, Hop(error="dns"), True, "public_dns"),
    (L401, Hop(error="unreachable"), True, "public_unreachable"),
])
def test_diagnosis_table(local, public, configured, code):
    assert diagnose(local, public, configured)[0] == code


def test_the_502_case_reads_plainly():
    message = diagnose(L401, Hop(status=502), True)[1]
    assert "answers 401 (expected for an unsigned request)" in message
    assert "502" in message and "tunnel or proxy is not reaching this gateway" in message


def test_probe_502_end_to_end(net):
    _add()
    result = _call("webhook.routes.probe", {"name": "paint-pr"})["result"]
    METHODS["webhook.routes.probe"].result.model_validate(result)
    assert result["local"]["status"] == 401 and result["public"]["status"] == 502
    assert result["diagnosis"]["code"] == "public_not_reaching_gateway"
    assert result["tunnel"] == {"resolves": True, "tls_expires_at": "2030-01-01T00:00:00Z"}
    assert [r["url"] for r in net.requests] == ["http://127.0.0.1:8644/webhooks/paint-pr", f"{BASE}/webhooks/paint-pr"]


def test_probe_local_404_never_touches_the_public_hop(net):
    _add()
    net.local = 404
    result = _call("webhook.routes.probe", {"name": "paint-pr"})["result"]
    assert result["diagnosis"]["code"] == "route_not_loaded"
    assert len(net.requests) == 1 and result["tunnel"]["resolves"] is None


def test_probe_without_a_public_url(net, monkeypatch):
    monkeypatch.setattr(webhook_routes, "public_base_url", lambda: None)
    _add()
    result = _call("webhook.routes.probe", {"name": "paint-pr"})["result"]
    assert result["diagnosis"]["code"] == "public_unconfigured"
    assert len(net.requests) == 1


def test_probe_public_timeout(net):
    _add()
    net.public = httpx.ReadTimeout("slow")
    assert _call("webhook.routes.probe", {"name": "paint-pr"})["result"]["diagnosis"]["code"] == "public_timeout"


def _connect_error(cause):
    error = httpx.ConnectError("failed")
    error.__cause__ = cause
    return error


@pytest.mark.parametrize("cause, code", [
    (ssl.SSLCertVerificationError("bad cert"), "public_tls"),
    (socket.gaierror("no such host"), "public_dns"),
    (ConnectionRefusedError(), "public_unreachable"),
])
def test_probe_connect_failures(net, cause, code):
    _add()
    net.public = _connect_error(cause)
    result = _call("webhook.routes.probe", {"name": "paint-pr"})["result"]
    assert result["diagnosis"]["code"] == code
    assert result["tunnel"]["tls_expires_at"] is None


def test_probe_local_listener_down(net):
    _add()
    net.local = httpx.ConnectError("refused")
    assert _call("webhook.routes.probe", {"name": "paint-pr"})["result"]["diagnosis"]["code"] == "local_unreachable"


def test_probe_skips_routes_with_signature_checking_off(net):
    from hermes_cli import webhook as store
    store._replace_subscription("open", {"secret": "INSECURE_NO_AUTH"}, store._MISSING_SUBSCRIPTION)
    result = _call("webhook.routes.probe", {"name": "open"})["result"]
    assert result["diagnosis"]["code"] == "probe_skipped" and net.requests == []


@pytest.mark.parametrize("name", [
    "https://evil.example/x", "evil.example", "../webhooks/other", "paint-pr/../../x", "paint-pr?x=1", "127.0.0.1:22", "", "UNKNOWN",
])
def test_probe_refuses_anything_outside_the_route_table(net, name):
    _add()
    assert _call("webhook.routes.probe", {"name": name})["error"]["code"] in {4404, 4000}
    assert net.requests == []


def test_probe_params_reject_a_client_supplied_url(net):
    _add()
    response = _call("webhook.routes.probe", {"name": "paint-pr", "url": "https://evil.example/"})
    assert "error" in response and net.requests == []


def test_public_url_comes_only_from_the_configured_setting(net, monkeypatch):
    monkeypatch.undo()
    monkeypatch.setattr(webhook_routes.httpx, "Client", net.client)
    monkeypatch.setattr(webhook_routes, "listener_address", lambda: (True, "127.0.0.1", 8644))
    from hermes_cli.config import load_config, save_config
    config = load_config()
    config["webapp"] = {"public_url": "https://tunnel.example.test/"}
    save_config(config)
    assert webhook_routes.public_base_url() == "https://tunnel.example.test"
    _add()
    _call("webhook.routes.probe", {"name": "paint-pr"})
    assert net.requests[1]["url"] == "https://tunnel.example.test/webhooks/paint-pr"


def test_secondary_profile_ticket_is_refused(net):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        extra = {"webhook.routes.add": {"name": "paint-pr", "generate_secret": True},
                 "webhook.routes.remove": {"name": "paint-pr"}, "webhook.routes.probe": {"name": "paint-pr"}}
        for name in NAMES:
            assert _call(name, extra.get(name))["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert net.requests == [] and not (webhook_routes_home() / "webhook_subscriptions.json").exists()


def test_worker_and_capability_less_connections_cannot_reach_the_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_methods_are_not_model_tools():
    from tools.registry import registry
    known = set(registry.get_all_tool_names())
    assert not known & set(NAMES)
    assert not any(name.startswith("webhook.routes") or name.startswith("webhook_routes") for name in known)
