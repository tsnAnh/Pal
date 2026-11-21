from __future__ import annotations

import asyncio
import json
from urllib.parse import parse_qs, urlsplit

import hermes_yaml as yaml
import pytest

from hermes_cli.config import get_env_value
from hermes_constants import get_hermes_home
from tests.tools.mcp_accounts_double import AccountsDouble, follow_authorization, store_account_tokens, write_servers
from tests.waiting import wait_until
from tools.mcp_oauth import HermesTokenStorage
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

pytest.importorskip("mcp.client.auth.oauth2")

SLUG = "linear"
REDIRECT = "http://127.0.0.1:53999/callback"
GITHUB = {"url": "https://api.githubcopilot.com/mcp/", "transport": "http", "enabled": True,
          "headers": {"Authorization": "Bearer ${MCP_GITHUB_API_KEY}"}}


@pytest.fixture
def double():
    with AccountsDouble() as d:
        yield d


@pytest.fixture(autouse=True)
def _fresh_state(monkeypatch):
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    monkeypatch.setattr(sessions, "_sessions", {})
    from hermes_cli import mcp_accounts
    monkeypatch.setattr(mcp_accounts, "_reconcile_live_servers", lambda: None)
    yield
    reset_manager_for_tests()


def rpc(method: str, **params) -> dict:
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})


def ok(reply: dict) -> dict:
    assert "error" not in reply, reply.get("error")
    return reply["result"]


def refused(reply: dict, code: int) -> str:
    assert reply.get("error", {}).get("code") == code, reply
    return reply["error"]["message"]


def config() -> dict:
    return yaml.safe_load((get_hermes_home() / "config.yaml").read_text()).get("mcp_servers") or {}


def write_config(servers: dict) -> None:
    (get_hermes_home() / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": servers}, sort_keys=False))


def put_tokens(name: str) -> None:
    from mcp.shared.auth import OAuthToken
    asyncio.run(HermesTokenStorage(name).set_tokens(OAuthToken(access_token=f"tok-{name}", token_type="Bearer", expires_in=3600)))


def sign_in(double: AccountsDouble, account: str | None, **extra) -> dict:
    params = {"name": SLUG, "client_redirect_uri": REDIRECT, **({"account": account} if account else {}), **extra}
    started = ok(rpc("mcp.servers.oauth.start", **params))
    landed = follow_authorization(started["auth_url"])
    scope = {"name": SLUG, "session_id": started["session_id"], **({"account": account} if account else {})}
    assert ok(rpc("mcp.servers.oauth.callback", **scope, code=landed["code"], state=landed["state"]))["ok"]
    wait_until(lambda: ok(rpc("mcp.servers.oauth.poll", **scope))["status"] == "approved", what="sign-in approved")
    return started


def test_a_second_account_signs_in_with_the_account_prompt_and_lands_under_its_own_name(double):
    write_servers(get_hermes_home(), double, SLUG, ["default"])
    put_tokens(f"{SLUG}@default")
    double.sign_in_as("work")

    started = sign_in(double, "work", create=True)

    query = parse_qs(urlsplit(started["auth_url"]).query)
    assert query["prompt"] == ["select_account login"] and double.authorize_queries[-1]["prompt"] == "select_account login"
    assert started["private_window_hint"] is True
    assert list(config()[SLUG]["accounts"]) == ["default", "work"]
    stored = asyncio.run(HermesTokenStorage(f"{SLUG}@work").get_tokens()).access_token
    assert double.account_by_token[stored] == "work"
    assert asyncio.run(HermesTokenStorage(f"{SLUG}@default").get_tokens()).access_token == f"tok-{SLUG}@default"
    assert "prompt" not in (get_hermes_home() / "config.yaml").read_text()


def test_the_first_account_signs_in_without_a_prompt_and_is_named_default(double):
    write_servers(get_hermes_home(), double, SLUG)
    double.sign_in_as("me")

    started = sign_in(double, None)

    assert "prompt" not in double.authorize_queries[-1] and started["private_window_hint"] is False
    assert list(config()[SLUG]["accounts"]) == ["default"]
    assert HermesTokenStorage(f"{SLUG}@default").has_cached_tokens()
    assert not HermesTokenStorage(SLUG).has_cached_tokens()


def test_signing_in_to_an_existing_account_again_asks_for_the_prompt_only_when_others_exist(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    started = ok(rpc("mcp.servers.oauth.start", name=SLUG, account="work", client_redirect_uri=REDIRECT))
    assert parse_qs(urlsplit(started["auth_url"]).query)["prompt"] == ["select_account login"]
    ok(rpc("mcp.servers.oauth.cancel", name=SLUG, account="work", session_id=started["session_id"]))


def test_a_flow_is_found_by_its_session_with_or_without_the_account_and_never_under_another_one(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    started = ok(rpc("mcp.servers.oauth.start", name=SLUG, account="work", client_redirect_uri=REDIRECT))
    sid = started["session_id"]

    assert ok(rpc("mcp.servers.oauth.poll", name=SLUG, session_id=sid))["status"] == "pending"
    assert ok(rpc("mcp.servers.oauth.poll", name=SLUG, account="work", session_id=sid))["status"] == "pending"
    elsewhere = ok(rpc("mcp.servers.oauth.poll", name=SLUG, account="default", session_id=sid))
    assert elsewhere["status"] == "error" and "mismatch" in elsewhere["error_message"]
    ok(rpc("mcp.servers.oauth.cancel", name=SLUG, session_id=sid))


def test_a_name_that_is_not_a_valid_account_name_or_an_account_on_a_plain_server_is_refused(double):
    write_servers(get_hermes_home(), double, SLUG, ["default"])
    refused(rpc("mcp.servers.oauth.start", name=SLUG, account="Bad Name", create=True, client_redirect_uri=REDIRECT), 4063)
    refused(rpc("mcp.servers.oauth.start", name=SLUG, account="ghost", client_redirect_uri=REDIRECT), 4064)
    refused(rpc("mcp.servers.oauth.poll", name=SLUG, account="Bad Name", session_id="x"), 4063)
    write_config({"custom": {"url": double.mcp_url, "transport": "http", "auth": "oauth"}})
    refused(rpc("mcp.servers.oauth.start", name="custom", account="work", create=True, client_redirect_uri=REDIRECT), 4063)


def test_creating_an_account_whose_name_is_taken_answers_4090_and_changes_nothing(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    before = (get_hermes_home() / "config.yaml").read_text()

    refused(rpc("mcp.servers.oauth.start", name=SLUG, account="work", create=True, client_redirect_uri=REDIRECT), 4090)
    refused(rpc("mcp.servers.accounts.rename", name=SLUG, account="work", new_account="default"), 4090)
    write_config({"github": {**GITHUB, "accounts": {"default": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}}})
    refused(rpc("mcp.servers.set_api_key", name="github", account="work", create=True, value="ghp_second"), 4090)

    assert not sessions._sessions
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    assert (get_hermes_home() / "config.yaml").read_text() == before


def test_renaming_an_account_moves_its_sign_in_and_leaves_the_others(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    put_tokens(f"{SLUG}@default")
    put_tokens(f"{SLUG}@work")

    result = ok(rpc("mcp.servers.accounts.rename", name=SLUG, account="work", new_account="office"))

    assert result == {"ok": True, "name": SLUG, "account": "office"}
    assert list(config()[SLUG]["accounts"]) == ["default", "office"]
    assert HermesTokenStorage(f"{SLUG}@office").has_cached_tokens() and not HermesTokenStorage(f"{SLUG}@work").has_cached_tokens()
    assert HermesTokenStorage(f"{SLUG}@default").has_cached_tokens()
    refused(rpc("mcp.servers.accounts.rename", name=SLUG, account="work", new_account="x"), 4064)
    refused(rpc("mcp.servers.accounts.rename", name=SLUG, account="office", new_account="Not Valid"), 4063)
    refused(rpc("mcp.servers.accounts.rename", name=SLUG, account="office"), 4063)


def test_removing_one_account_keeps_the_others_and_removing_the_last_takes_the_connector(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    put_tokens(f"{SLUG}@default")
    put_tokens(f"{SLUG}@work")

    assert ok(rpc("mcp.servers.remove", name=SLUG, account="work")) == {"ok": True, "removed": True}
    assert list(config()[SLUG]["accounts"]) == ["default"]
    assert not HermesTokenStorage(f"{SLUG}@work").has_cached_tokens() and HermesTokenStorage(f"{SLUG}@default").has_cached_tokens()
    refused(rpc("mcp.servers.remove", name=SLUG, account="work"), 4064)

    assert ok(rpc("mcp.servers.remove", name=SLUG, account="default"))["removed"] is True
    assert SLUG not in config() and not HermesTokenStorage(f"{SLUG}@default").has_cached_tokens()


def test_removing_a_connector_without_naming_an_account_removes_every_account(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    put_tokens(f"{SLUG}@work")

    assert ok(rpc("mcp.servers.remove", name=SLUG))["removed"] is True

    assert SLUG not in config() and not HermesTokenStorage(f"{SLUG}@work").has_cached_tokens()


def test_each_account_of_an_api_key_connector_keeps_its_own_key():
    write_config({"github": {**GITHUB, "accounts": {"default": {}}}})
    from hermes_cli.config import save_env_value
    save_env_value("MCP_GITHUB_API_KEY", "ghp_first")

    added = ok(rpc("mcp.servers.set_api_key", name="github", account="work", create=True, value="Bearer ghp_second"))
    renewed = ok(rpc("mcp.servers.set_api_key", name="github", account="default", value="ghp_first_renewed"))

    assert added["account"] == "work" and added["env_var"] == "MCP_GITHUB__WORK_API_KEY"
    assert renewed["account"] == "default" and renewed["env_var"] == "MCP_GITHUB_API_KEY"
    assert get_env_value("MCP_GITHUB__WORK_API_KEY") == "ghp_second"
    assert get_env_value("MCP_GITHUB_API_KEY") == "ghp_first_renewed"
    accounts = config()["github"]["accounts"]
    assert accounts == {"default": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}
    saved = (get_hermes_home() / "config.yaml").read_text()
    assert "ghp_second" not in saved and "ghp_first" not in saved and "Bearer ${MCP_GITHUB_API_KEY}" in saved
    refused(rpc("mcp.servers.set_api_key", name="github", account="ghost", value="x"), 4064)
    refused(rpc("mcp.servers.set_api_key", name="github", account="work", value="Bearer "), 4063)


def test_removing_an_api_key_account_forgets_its_key_and_keeps_the_others():
    write_config({"github": {**GITHUB, "accounts": {"default": {}}}})
    ok(rpc("mcp.servers.set_api_key", name="github", account="work", create=True, value="ghp_second"))

    ok(rpc("mcp.servers.remove", name="github", account="work"))

    assert get_env_value("MCP_GITHUB__WORK_API_KEY") in (None, "")
    assert list(config()["github"]["accounts"]) == ["default"]


def test_the_catalog_lists_every_account_with_its_own_reason_and_an_aggregate_status(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    put_tokens(f"{SLUG}@default")
    put_tokens(f"{SLUG}@work")
    HermesTokenStorage(f"{SLUG}@work").mark_reauth_required()

    row = {r["slug"]: r for r in ok(rpc("connectors.catalog"))["connectors"]}[SLUG]

    assert row["multi_account"] is True and row["status"] == "connected"
    assert row["accounts"] == [
        {"name": "default", "status": "connected", "reason": None},
        {"name": "work", "status": "needs_reconnect",
         "reason": "Sign in again: Linear (work) stopped accepting the saved sign-in"}]
    HermesTokenStorage(f"{SLUG}@default").mark_reauth_required()
    row = {r["slug"]: r for r in ok(rpc("connectors.catalog"))["connectors"]}[SLUG]
    assert row["status"] == "needs_reconnect" and {a["status"] for a in row["accounts"]} == {"needs_reconnect"}


def test_a_connector_with_no_account_reports_an_empty_list_and_keeps_its_status(double):
    rows = {r["slug"]: r for r in ok(rpc("connectors.catalog"))["connectors"]}

    assert rows[SLUG]["multi_account"] is True and rows[SLUG]["accounts"] == []
    assert rows[SLUG]["status"] == "not_connected"
    assert rows["t3code"]["multi_account"] is False and rows["t3code"]["accounts"] == []


def test_a_disabled_connector_shows_every_account_as_not_connected(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"], enabled=False)
    row = {r["slug"]: r for r in ok(rpc("connectors.catalog"))["connectors"]}[SLUG]

    assert row["status"] == "not_connected" and {a["status"] for a in row["accounts"]} == {"not_connected"}


def test_the_mcp_catalog_row_of_a_connector_reads_the_reason_from_its_accounts(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    put_tokens(f"{SLUG}@default")
    HermesTokenStorage(f"{SLUG}@work").mark_reauth_required()

    row = {r["name"]: r for r in ok(rpc("mcp.catalog"))["servers"]}[SLUG]
    assert row["needs_auth_reason"] is None
    assert [a["name"] for a in row["accounts"]] == ["default", "work"]

    HermesTokenStorage(f"{SLUG}@default").mark_reauth_required()
    row = {r["name"]: r for r in ok(rpc("mcp.catalog"))["servers"]}[SLUG]
    assert row["needs_auth_reason"] == "Sign in again: Linear (default) stopped accepting the saved sign-in"


def test_no_internal_connection_name_reaches_the_status_or_list_rows(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    HermesTokenStorage(f"{SLUG}@work").mark_reauth_required()

    status = ok(rpc("mcp.servers.status"))["servers"]
    listed = ok(rpc("mcp.servers.list"))["servers"]

    assert [(r["name"], r["account"]) for r in status] == [(SLUG, "default"), (SLUG, "work")]
    assert next(r for r in status if r["account"] == "work")["needs_auth"] is True
    assert next(r for r in status if r["account"] == "default")["needs_auth"] is False
    assert [r["name"] for r in listed] == [SLUG]
    assert "@" not in json.dumps([status, listed, ok(rpc("mcp.catalog")), ok(rpc("connectors.catalog"))])


def test_a_plain_server_row_has_no_account_key(double):
    write_config({"custom": {"url": double.mcp_url, "transport": "http"}})

    row = ok(rpc("mcp.servers.status"))["servers"][0]

    assert row["name"] == "custom" and "account" not in row


def test_a_connector_test_goes_through_the_named_account(double):
    write_servers(get_hermes_home(), double, SLUG, ["default", "work"])
    store_account_tokens(double, f"{SLUG}@default", "default")
    store_account_tokens(double, f"{SLUG}@work", "work")

    tested = ok(rpc("mcp.servers.test", name=SLUG, account="work"))

    assert tested["ok"] is True and tested["oauth_tokens_present"] is True
    assert double.mcp_requests[-1].account == "work"
    assert "Name the account" in refused(rpc("mcp.servers.test", name=SLUG), 4063)
    refused(rpc("mcp.servers.test", name=SLUG, account="ghost"), 4064)


def test_account_writes_land_in_the_named_profile_and_never_in_the_launch_profile(tmp_path, monkeypatch, double):
    root = tmp_path / "root"
    (root / "profiles" / "work").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    write_servers(root / "profiles" / "work", double, SLUG, ["default", "side"])

    assert ok(rpc("mcp.servers.accounts.rename", name=SLUG, account="side", new_account="later", profile="work"))
    ok(rpc("mcp.servers.remove", name=SLUG, account="default", profile="work"))

    stored = yaml.safe_load((root / "profiles" / "work" / "config.yaml").read_text())["mcp_servers"]
    assert list(stored[SLUG]["accounts"]) == ["later"]
    assert not (root / "config.yaml").exists()


def test_every_account_verb_is_served_on_the_native_socket_under_the_control_guard():
    from gateway.session_mcp_controls import VERBS
    from tui_gateway.contracts.registry import CANONICAL_METHODS

    assert VERBS["mcp.servers.accounts.rename"].scope == "session:control"
    for name in ("mcp.servers.accounts.rename", "mcp.servers.remove", "mcp.servers.set_api_key", "mcp.servers.oauth.start",
                 "mcp.servers.oauth.poll", "mcp.servers.oauth.cancel", "mcp.servers.oauth.callback"):
        assert name in VERBS and name in CANONICAL_METHODS


def test_an_unknown_parameter_on_an_account_verb_is_refused_before_the_handler_runs():
    refused(rpc("mcp.servers.accounts.rename", name=SLUG, account="a", new_account="b", surprise=True), 4000)
