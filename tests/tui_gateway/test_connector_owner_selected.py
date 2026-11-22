from __future__ import annotations

import asyncio

import pytest
from mcp.shared.auth import OAuthToken

from hermes_cli.pal_connectors import load_pal_connectors
from tools.mcp_oauth import HermesTokenStorage
from tui_gateway import server

PROFILE = "work"
PUBLIC = "https://pal.example.ts.net"
ENTRIES = {e.id: e for e in load_pal_connectors()}


@pytest.fixture
def work_home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    (root / "profiles" / PROFILE).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root / "profiles" / PROFILE


@pytest.fixture
def root_home(work_home):
    return work_home.parents[1]


def _call(method, **params):
    return server._methods[method](1, {"profile": PROFILE, **params})


def _ok(method, **params):
    response = _call(method, **params)
    assert "error" not in response, response
    return response["result"]


def _row(slug):
    return {r["slug"]: r for r in _ok("connectors.catalog")["connectors"]}[slug]


def _set_public_url(home, url):
    (home / "config.yaml").write_text(f"webapp:\n  public_url: {url}\n")


@pytest.mark.parametrize("slug", ["posthog", "resend", "higgsfield"])
def test_a_cimd_connector_is_unavailable_without_a_public_address_and_says_why_in_product_language(work_home, slug):
    row = _row(slug)

    assert row["status"] == "needs_setup"
    assert "public web address" in row["notes"]
    assert not any(word in row["notes"].lower() for word in ("cimd", "client_id", "metadata", "oauth"))


@pytest.mark.parametrize("slug", ["posthog", "resend", "higgsfield"])
def test_a_cimd_connector_is_connectable_once_the_gateway_has_an_https_address(work_home, slug):
    _set_public_url(work_home, PUBLIC)

    row = _row(slug)

    assert row["status"] == "not_connected" and row["notes"] is None


def test_a_connected_cimd_connector_stays_connected_if_the_address_is_later_removed(work_home):
    entry = ENTRIES["posthog"]
    _ok("mcp.servers.add", name="posthog", config={"url": entry.mcp_url, "transport": "http"})
    asyncio.run(HermesTokenStorage("posthog", hermes_home=work_home).set_tokens(
        OAuthToken(access_token="tok", token_type="Bearer", expires_in=3600)))

    assert _row("posthog")["status"] == "connected"


def test_connectors_that_register_dynamically_never_need_a_public_address(work_home):
    assert _row("linear")["status"] == "not_connected"
    assert _row("paypal")["status"] == "not_connected"


def _saved_paypal_policy(root_home):
    import hermes_yaml as yaml
    return yaml.safe_load((root_home / "config.yaml").read_text())["mcp_servers"]["paypal"].get("action_policy")


def test_the_gateway_saves_the_paypal_policy_even_when_the_app_sends_none(root_home):
    _ok("mcp.servers.add", name="paypal", config={"url": ENTRIES["paypal"].mcp_url, "transport": "http"})

    assert _saved_paypal_policy(root_home) == ENTRIES["paypal"].action_policy.config()


def test_the_gateway_replaces_a_policy_the_app_sent(root_home):
    _ok("mcp.servers.add", name="paypal", config={
        "url": ENTRIES["paypal"].mcp_url, "transport": "http",
        "action_policy": {"read_tools": ["create_order"], "refused_tools": ["nothing"], "refused_message": "x"}})

    assert _saved_paypal_policy(root_home) == ENTRIES["paypal"].action_policy.config()


def test_a_custom_server_that_borrows_the_name_gets_no_paypal_policy(root_home):
    _ok("mcp.servers.add", name="paypal", config={"url": "https://other.example.com/mcp", "transport": "http"})

    assert _saved_paypal_policy(root_home) is None


def test_other_catalog_servers_are_saved_without_any_policy(root_home):
    import hermes_yaml as yaml
    _ok("mcp.servers.add", name="linear", config={"url": ENTRIES["linear"].mcp_url, "transport": "http"})

    assert "action_policy" not in yaml.safe_load((root_home / "config.yaml").read_text())["mcp_servers"]["linear"]


@pytest.mark.parametrize("slug", ["slack_mcp", "discord_mcp"])
def test_slack_and_discord_tools_need_the_owners_own_client_before_they_connect(work_home, slug):
    assert _row(slug)["status"] == "needs_setup"

    refused = _call("connectors.oauth_client.connect", slug=slug, client_redirect_uri="http://127.0.0.1:53682/callback")

    assert refused["error"]["code"] == 4090
    assert refused["error"]["message"] == "Set up this app on your Pal first."


@pytest.mark.parametrize("slug", ["slack_mcp", "discord_mcp"])
def test_slack_and_discord_tools_show_the_gateway_return_to_register_with_the_vendor(root_home, slug):
    _set_public_url(root_home, PUBLIC)

    setup = _ok("connectors.oauth_client.setup", slug=slug)

    assert setup["configured"] is False
    assert setup["redirect_url"] == PUBLIC + "/webapp/mcp-oauth/callback"
    assert setup["console_url"].startswith("https://")


def test_the_oauth_client_server_config_asks_only_for_the_scopes_the_owner_ticked():
    from gateway import oauth_client_setup as setup

    config = setup.mcp_server_config("slack_mcp", "123.456")

    assert config["url"] == "https://mcp.slack.com/mcp"
    assert config["oauth"]["scope"].split() == list(ENTRIES["slack_mcp"].scopes)
    assert config["oauth"]["client_id"] == "123.456" and "xoxp" not in str(config)
    assert config["oauth"]["client_secret"] == "${SLACK_MCP_CLIENT_SECRET}"
