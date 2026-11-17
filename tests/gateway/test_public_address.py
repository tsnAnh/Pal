"""The gateway's public https address: validation, storage, tailnet suggestion and the reachability check."""

from __future__ import annotations

import json
import subprocess
import types

import pytest

from gateway import public_address as pa
from gateway.public_address import AddressError, Outcome, Problem
from hermes_cli.web_routers.mcp_oauth_callback import REJECTED_MESSAGE
from hermes_constants import get_hermes_home


@pytest.mark.parametrize("raw, stored", [
    ("https://pal.tail1234.ts.net", "https://pal.tail1234.ts.net"),
    ("https://pal.tail1234.ts.net/", "https://pal.tail1234.ts.net"),
    ("  HTTPS://Pal.Tail1234.TS.net/ ", "https://pal.tail1234.ts.net"),
    ("https://pal.example.com:8443", "https://pal.example.com:8443"),
    ("https://pal.example.com.", "https://pal.example.com"),
])
def test_accepts_and_normalises(raw, stored):
    assert pa.normalise(raw) == stored


@pytest.mark.parametrize("raw, problem", [
    ("", Problem.invalid),
    ("pal.example.com", Problem.not_https),
    ("http://pal.example.com", Problem.not_https),
    ("ftp://pal.example.com", Problem.not_https),
    ("https://user:pw@pal.example.com", Problem.userinfo),
    ("https://user@pal.example.com", Problem.userinfo),
    ("https://100.101.102.103", Problem.ip_host),
    ("https://[fd7a:115c:a1e0::1]", Problem.ip_host),
    ("https://localhost", Problem.invalid_host),
    ("https://bad_host.example.com", Problem.invalid_host),
    ("https://-pal.example.com", Problem.invalid_host),
    ("https://pal.example.com/app", Problem.path),
    ("https://pal.example.com//", Problem.path),
    ("https://pal.example.com/?a=1", Problem.query_or_fragment),
    ("https://pal.example.com?a=1", Problem.query_or_fragment),
    ("https://pal.example.com/#top", Problem.query_or_fragment),
    ("https://pal.example.com#", Problem.query_or_fragment),
    ("https://pal example.com", Problem.invalid),
    ("https://pal.example.com:0", Problem.invalid),
    ("https://pal.example.com:99999", Problem.invalid),
    ("https://" + "a" * 250 + ".example.com", Problem.too_long),
])
def test_rejects_each_rule(raw, problem):
    with pytest.raises(AddressError) as caught:
        pa.normalise(raw)
    assert caught.value.problem is problem


def test_set_and_clear_round_trip_through_the_config_file():
    home = get_hermes_home()
    assert pa.read(home, suggest=lambda: None).url is None
    assert pa.save(home, "HTTPS://Pal.Example.com/") == "https://pal.example.com"
    state = pa.read(home, suggest=lambda: "https://suggested.example.com")
    assert (state.url, state.routes_enabled, state.suggestion) == (
        "https://pal.example.com", False, "https://suggested.example.com")
    assert pa.save(home, "  ") is None
    assert pa.read(home, suggest=lambda: None).url is None


def test_a_refused_value_leaves_the_saved_address_alone():
    home = get_hermes_home()
    pa.save(home, "https://pal.example.com")
    with pytest.raises(AddressError):
        pa.save(home, "http://pal.example.com")
    assert pa.read(home, suggest=lambda: None).url == "https://pal.example.com"


def test_a_managed_key_is_refused(monkeypatch):
    from hermes_cli import managed_scope
    monkeypatch.setattr(managed_scope, "is_key_managed", lambda key: key == "webapp.public_url")
    with pytest.raises(pa.ManagedAddressError):
        pa.save(get_hermes_home(), "https://pal.example.com")


def _tailscale(monkeypatch, *, stdout="", returncode=0, present=True, raises=None):
    from hermes_platform import resolver
    monkeypatch.setattr(resolver, "locate_command",
                        lambda name: types.SimpleNamespace(command=("/usr/bin/tailscale",) if present else ()))
    calls = []

    def run(argv, **kwargs):
        calls.append(argv)
        if raises:
            raise raises
        return subprocess.CompletedProcess(argv, returncode, stdout, "")
    return run, calls


STATUS = json.dumps({"Version": "1.80", "Self": {"DNSName": "Pal-Host.tail1234.ts.net.", "HostName": "pal-host"}})


def test_suggestion_comes_from_the_node_s_own_dns_name_and_only_reads(monkeypatch):
    run, calls = _tailscale(monkeypatch, stdout=STATUS)
    assert pa.tailnet_suggestion(run) == "https://pal-host.tail1234.ts.net"
    assert calls == [["/usr/bin/tailscale", "status", "--json"]]


@pytest.mark.parametrize("kwargs", [
    {"present": False},
    {"returncode": 1, "stdout": STATUS},
    {"stdout": "not json"},
    {"stdout": json.dumps({"Self": {}})},
    {"stdout": json.dumps({"Self": {"DNSName": ""}})},
    {"stdout": json.dumps({"Self": {"DNSName": "100.64.0.1"}})},
    {"raises": subprocess.TimeoutExpired("tailscale", 5)},
    {"raises": FileNotFoundError()},
])
def test_no_usable_tailnet_is_no_suggestion_not_an_error(monkeypatch, kwargs):
    run, _ = _tailscale(monkeypatch, **kwargs)
    assert pa.tailnet_suggestion(run) is None


def _responder(status, body):
    seen = []

    def fetch(url):
        seen.append(url)
        return status, body
    return fetch, seen


def test_check_reaches_pals_own_callback_with_one_request():
    fetch, seen = _responder(400, f"<p>{REJECTED_MESSAGE}</p>")
    assert pa.check("https://pal.example.com", fetch) is Outcome.reachable
    assert len(seen) == 1 and seen[0].startswith("https://pal.example.com/webapp/mcp-oauth/callback?")


def test_check_calls_a_host_header_refusal_another_service():
    fetch, _ = _responder(400, '{"detail":"Invalid Host header. Dashboard requests must use the bound hostname"}')
    assert pa.check("https://pal.example.com", fetch) is Outcome.wrong_service


@pytest.mark.parametrize("status, body", [(200, "<html>welcome to nginx</html>"), (404, "nope"),
                                          (502, "bad gateway"), (400, "some other 400")])
def test_check_calls_another_service_wrong(status, body):
    fetch, _ = _responder(status, body)
    assert pa.check("https://pal.example.com", fetch) is Outcome.wrong_service


@pytest.mark.parametrize("error", [ConnectionRefusedError(), TimeoutError(), OSError("dns")])
def test_check_reports_a_failed_connection_as_not_reachable(error):
    def fetch(url):
        raise error
    assert pa.check("https://pal.example.com", fetch) is Outcome.not_reachable


def test_check_without_an_address_makes_no_request():
    fetch, seen = _responder(400, REJECTED_MESSAGE)
    assert pa.check(None, fetch) is Outcome.no_address and seen == []


def test_the_real_fetch_reports_a_closed_port_as_not_reachable():
    assert pa.check("https://127.0.0.1:1") is Outcome.not_reachable


def test_a_saved_address_reaches_the_running_listener_at_once():
    from hermes_cli.web_server_boundary import callback_only_hosts
    home = get_hermes_home()
    assert callback_only_hosts() == frozenset()
    pa.save(home, "https://pal.example.com")
    assert callback_only_hosts() == frozenset({"pal.example.com"})
    pa.save(home, "")
    assert callback_only_hosts() == frozenset()
