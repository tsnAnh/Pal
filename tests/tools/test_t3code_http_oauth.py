"""T3 Code is a plain MCP OAuth connector: its server answers over plain http on the user's own network.

A plain-http double answers the way T3's MCP endpoint and OAuth server do (401 with ``resource_metadata``,
protected-resource and authorization-server documents, S256-only PKCE, dynamic client registration, no refresh
token). The gateway's real discovery, registration, sign-in and probe code runs against it with a temp
``HERMES_HOME``: nothing of the MCP SDK is mocked.
"""

from __future__ import annotations

import json
import urllib.request
from urllib.parse import parse_qs, urlsplit

import pytest

from hermes_constants import get_hermes_home
from tests.tools.t3code_double import (
    TOOLS,
    T3CodeDouble,
    accepts_loopback_only,
    accepts_nothing,
)
from tests.waiting import wait_until
from tools.connectors.mcp_oauth_redirect import (
    APP_REDIRECT_URI,
    GATEWAY_CALLBACK_PATH,
    is_registration_refusal,
)
from tools.mcp_oauth import HermesTokenStorage
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

pytest.importorskip("mcp.client.auth.oauth2")

NAME = "t3code"
PUBLIC = "https://pal.example.com"
GATEWAY_URI = PUBLIC + GATEWAY_CALLBACK_PATH
LOOPBACK_FALLBACK = "http://127.0.0.1:49152/callback"


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def rpc(method, **params):
    response = server._methods[method](1, params)
    assert "error" not in response, response
    return response["result"]


def rpc_error(method, **params):
    response = server._methods[method](1, params)
    assert "error" in response, response
    return response["error"]


def authorize_in_browser(auth_url: str) -> dict:
    opener = urllib.request.build_opener(NoRedirects)
    try:
        opener.open(auth_url, timeout=10)
    except urllib.error.HTTPError as redirect:
        query = parse_qs(urlsplit(redirect.headers["Location"]).query)
        return {k: v[0] for k, v in query.items()}
    raise AssertionError("the double's authorize endpoint did not redirect")


def add_server(double: T3CodeDouble) -> None:
    rpc("mcp.servers.add", name=NAME, config={"url": double.mcp_url, "transport": "http"})


def set_public_url(url: str) -> None:
    (get_hermes_home() / "config.yaml").write_text(
        (get_hermes_home() / "config.yaml").read_text() + f"\nwebapp:\n  public_url: {url}\n")


def finish_in_app(double, started) -> None:
    redirected = authorize_in_browser(started["auth_url"])
    rpc("mcp.servers.oauth.callback", session_id=started["session_id"], name=NAME,
        code=redirected["code"], state=redirected["state"])
    wait_until(lambda: rpc("mcp.servers.oauth.poll", session_id=started["session_id"], name=NAME)["status"]
               == "approved", what="sign-in approved")


@pytest.fixture(autouse=True)
def _fresh_state(monkeypatch):
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    monkeypatch.setattr(sessions, "_sessions", {})


@pytest.fixture
def double():
    with T3CodeDouble() as d:
        yield d


def auth_query(started) -> dict:
    return {k: v[0] for k, v in parse_qs(urlsplit(started["auth_url"]).query).items()}


def test_discovery_registration_and_sign_in_complete_over_plain_http_with_the_app_redirect(double):
    add_server(double)

    started = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri=APP_REDIRECT_URI)

    assert (started["redirect"], started["redirect_uri"]) == ("app", APP_REDIRECT_URI)
    assert [m for m, p in double.requests[:3]] == ["POST", "GET", "GET"]
    assert [p for m, p in double.requests[:3]] == [
        "/mcp", "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server"]
    assert [r["redirect_uris"] for r in double.registrations] == [[APP_REDIRECT_URI]]
    assert started["auth_url"].startswith(double.base + "/oauth/mcp/authorize?")
    query = auth_query(started)
    assert query["code_challenge_method"] == "S256" and query["code_challenge"]
    assert query["redirect_uri"] == APP_REDIRECT_URI and query["response_type"] == "code"

    finish_in_app(double, started)

    stored = json.loads((get_hermes_home() / "mcp-tokens" / f"{NAME}.json").read_text())
    assert stored["access_token"] in double.tokens
    assert "refresh_token" not in stored or not stored["refresh_token"]
    assert double.token_requests[0]["grant_type"] == "authorization_code"
    assert double.token_requests[0]["redirect_uri"] == APP_REDIRECT_URI
    polled = rpc("mcp.servers.oauth.poll", session_id=started["session_id"], name=NAME)
    assert [t["name"] for t in polled["tools"]] == [t["name"] for t in TOOLS]


def test_gateway_hosted_loopback_receiver_completes_in_the_browser_over_plain_http(double):
    add_server(double)

    started = rpc("mcp.servers.oauth.start", name=NAME)

    assert started["redirect"] == "loopback"
    assert started["redirect_uri"].startswith("http://127.0.0.1:") and started["redirect_uri"].endswith("/callback")
    assert double.registrations[0]["redirect_uris"] == [started["redirect_uri"]]
    assert auth_query(started)["code_challenge_method"] == "S256"

    urllib.request.urlopen(started["auth_url"], timeout=10).read()

    wait_until(lambda: rpc("mcp.servers.oauth.poll", session_id=started["session_id"], name=NAME)["status"]
               == "approved", what="sign-in approved")
    assert json.loads((get_hermes_home() / "mcp-tokens" / f"{NAME}.json").read_text())["access_token"] in double.tokens


def test_a_server_that_takes_only_loopback_is_reached_through_the_app_chain_fallback(double):
    double.accepts = accepts_loopback_only
    add_server(double)

    started = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri=APP_REDIRECT_URI,
                  fallback_redirect_uri=LOOPBACK_FALLBACK)

    assert [r["redirect_uris"] for r in double.registrations] == [[APP_REDIRECT_URI], [LOOPBACK_FALLBACK]]
    assert (started["redirect"], started["redirect_uri"]) == ("loopback", LOOPBACK_FALLBACK)
    assert auth_query(started)["code_challenge_method"] == "S256"


def test_a_server_that_takes_https_gets_the_gateway_callback_before_loopback(double):
    double.accepts = lambda uri: uri.startswith("https://") or uri.startswith("http://127.0.0.1:")
    add_server(double)
    set_public_url(PUBLIC)

    started = rpc("mcp.servers.oauth.start", name=NAME, client_redirect_uri=APP_REDIRECT_URI,
                  fallback_redirect_uri=LOOPBACK_FALLBACK)

    assert [r["redirect_uris"] for r in double.registrations] == [[APP_REDIRECT_URI], [GATEWAY_URI]]
    assert (started["redirect"], started["redirect_uri"]) == ("gateway", GATEWAY_URI)
    assert auth_query(started)["code_challenge_method"] == "S256"


def test_a_registration_refusal_is_reported_as_a_redirect_refusal_after_every_redirect_was_tried(double):
    double.accepts = accepts_nothing
    add_server(double)

    error = rpc_error("mcp.servers.oauth.start", name=NAME, client_redirect_uri=APP_REDIRECT_URI,
                      fallback_redirect_uri=LOOPBACK_FALLBACK)

    assert [r["redirect_uris"] for r in double.registrations] == [[APP_REDIRECT_URI], [LOOPBACK_FALLBACK]]
    assert is_registration_refusal(error["message"]), error
    assert "invalid_redirect_uri" in error["message"]
    assert not [r for r in sessions._sessions.values() if not r["flow"].worker_done]
    assert not (get_hermes_home() / "mcp-tokens" / f"{NAME}.json").exists()


@pytest.mark.parametrize("url", [
    "http://100.101.102.103:3773/mcp",
    "http://my-mac.tail1234.ts.net:3773/mcp",
    "http://192.168.1.20:3773/mcp",
])
def test_the_gateway_accepts_plain_http_tailnet_and_private_addresses_for_a_server(url):
    from tui_gateway.mcp_rpc_helpers import endpoint_error

    assert endpoint_error({"url": url, "transport": "http"}) is None


def probe(name=NAME):
    return rpc("mcp.servers.test", name=name)


def sign_in_through_the_loopback_receiver(double):
    started = rpc("mcp.servers.oauth.start", name=NAME)
    urllib.request.urlopen(started["auth_url"], timeout=10).read()
    wait_until(lambda: rpc("mcp.servers.oauth.poll", session_id=started["session_id"], name=NAME)["status"]
               == "approved", what="sign-in approved")


def test_probe_of_an_address_nothing_listens_on_is_unreachable():
    with T3CodeDouble() as gone:
        dead_url = gone.mcp_url
    rpc("mcp.servers.add", name=NAME, config={"url": dead_url, "transport": "http"})

    result = probe()

    assert (result["ok"], result["reason"], result["oauth_needed"], result["tools"]) == (False, "unreachable", False, [])


@pytest.mark.parametrize("behaviour", ["html", "missing"])
def test_probe_of_a_web_server_that_is_not_an_mcp_server_says_not_mcp(behaviour):
    with T3CodeDouble(mcp_behaviour=behaviour) as web:
        add_server(web)

        result = probe()

    assert (result["ok"], result["reason"], result["oauth_needed"], result["tools"]) == (False, "not_mcp", False, [])


def test_probe_of_an_mcp_server_that_wants_sign_in_is_auth_refused_with_oauth_needed(double):
    add_server(double)

    result = probe()

    assert (result["ok"], result["reason"], result["oauth_needed"], result["tools"]) == (
        False, "auth_refused", True, [])


def test_probe_after_sign_in_is_ok_and_lists_the_tools(double):
    add_server(double)
    sign_in_through_the_loopback_receiver(double)

    result = probe()

    assert (result["ok"], result["oauth_needed"], result["oauth_tokens_present"]) == (True, True, True)
    assert [t["name"] for t in result["tools"]] == [t["name"] for t in TOOLS]



@pytest.fixture
def mcp_discovery():
    from tools.mcp_tool_discovery import discover_mcp_tools
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    yield discover_mcp_tools
    shutdown_mcp_servers()


def session_defs(**kwargs):
    import model_tools
    return model_tools.get_tool_definitions(enabled_toolsets=["mcp-t3code", "terminal"], quiet_mode=True, **kwargs)


def tool_search(query):
    import model_tools
    return json.loads(model_tools.handle_function_call(
        function_name="tool_search", function_args={"queries": [query]}, enabled_toolsets=["mcp-t3code"]))


def test_no_t3code_tool_is_discoverable_until_the_server_is_connected(mcp_discovery):
    assert mcp_discovery() == []

    found = tool_search("list projects")

    assert found["tools"] == {} and found["total_available"] == 0
    assert not [d for d in session_defs(skip_tool_search_assembly=True) if d["function"]["name"].startswith("mcp__t3code__")]


def test_connected_t3code_tools_are_deferred_behind_tool_search_not_sent_every_turn(double, mcp_discovery):
    add_server(double)
    sign_in_through_the_loopback_receiver(double)

    assert mcp_discovery() == ["mcp__t3code__list_projects", "mcp__t3code__start_thread"]

    always_sent = [d["function"]["name"] for d in session_defs()]
    assert {"tool_search", "tool_describe", "tool_call", "terminal"} <= set(always_sent)
    assert not [n for n in always_sent if n.startswith("mcp__t3code__")]
    raw = [d["function"]["name"] for d in session_defs(skip_tool_search_assembly=True)]
    assert {"mcp__t3code__list_projects", "mcp__t3code__start_thread"} <= set(raw)

    found = tool_search("list projects")

    assert found["results"][0]["matches"] == ["mcp__t3code__list_projects"]
    assert found["tools"]["mcp__t3code__list_projects"]["source_name"] == "mcp-t3code"
