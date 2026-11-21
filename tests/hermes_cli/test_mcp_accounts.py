from __future__ import annotations

import asyncio

import hermes_yaml as yaml
import pytest

from hermes_cli import mcp_accounts
from hermes_cli.config import get_env_value, save_env_value
from hermes_cli.mcp_config import _get_mcp_servers, _remove_mcp_server, _save_mcp_server
from hermes_constants import get_hermes_home
from tools.mcp_accounts import AccountError, api_key_env
from tools.mcp_oauth import HermesTokenStorage

SLUG = "linear"
URL = "https://mcp.linear.app/mcp"
TEMPLATE = {"url": URL, "transport": "http", "auth": "oauth", "enabled": True}
GITHUB = {"url": "https://api.githubcopilot.com/mcp/", "transport": "http", "enabled": True,
          "headers": {"Authorization": "Bearer ${MCP_GITHUB_API_KEY}"}}


@pytest.fixture(autouse=True)
def reconciles(monkeypatch):
    calls = []
    monkeypatch.setattr(mcp_accounts, "_reconcile_live_servers", lambda: calls.append("reconcile"))
    return calls


def write_servers(servers: dict) -> None:
    (get_hermes_home() / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": servers}, sort_keys=False))


def stored() -> dict:
    return yaml.safe_load((get_hermes_home() / "config.yaml").read_text()).get("mcp_servers") or {}


def put_tokens(name: str, access_token: str = "tok") -> None:
    from mcp.shared.auth import OAuthToken
    asyncio.run(HermesTokenStorage(name).set_tokens(OAuthToken(access_token=access_token, token_type="Bearer", expires_in=3600)))


def has_tokens(name: str) -> bool:
    return HermesTokenStorage(name).has_cached_tokens()


def test_adding_an_account_creates_the_template_once_and_keeps_the_accounts_in_order():
    mcp_accounts.add_account(SLUG, "work", TEMPLATE)
    mcp_accounts.add_account(SLUG, "home", TEMPLATE)
    mcp_accounts.add_account(SLUG, "side")

    assert list(stored()) == [SLUG]
    assert list(stored()[SLUG]["accounts"]) == ["work", "home", "side"]
    assert stored()[SLUG]["url"] == URL
    assert mcp_accounts.account_names(SLUG) == ["work", "home", "side"]


def test_adding_the_same_account_again_changes_nothing_and_a_key_variable_is_recorded_once():
    mcp_accounts.add_account("github", "work", GITHUB, api_key_env=api_key_env("github", "work"))
    stamp = (get_hermes_home() / "config.yaml").stat().st_mtime_ns

    mcp_accounts.add_account("github", "work", GITHUB, api_key_env=api_key_env("github", "work"))

    assert (get_hermes_home() / "config.yaml").stat().st_mtime_ns == stamp
    assert stored()["github"]["accounts"] == {"work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}


@pytest.mark.parametrize("alias", ["", "Work", "-work", "a" * 33, "w ork", "w@rk", None])
def test_an_invalid_account_name_is_refused_and_nothing_is_written(alias):
    with pytest.raises(AccountError) as refused:
        mcp_accounts.add_account(SLUG, alias, TEMPLATE)

    assert refused.value.code == "invalid_account" and "@" not in refused.value.message
    assert not (get_hermes_home() / "config.yaml").exists() or SLUG not in stored()


def test_an_account_cannot_be_added_to_a_connector_that_was_never_set_up():
    with pytest.raises(AccountError) as refused:
        mcp_accounts.add_account(SLUG, "work")

    assert refused.value.code == "unknown_connector"


def test_saving_an_account_server_merges_into_the_template_and_never_writes_a_top_level_key():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}}}})

    assert _save_mcp_server(f"{SLUG}@home", {**TEMPLATE, "signin_on": "owner_app"})

    servers = stored()
    assert list(servers) == [SLUG]
    assert list(servers[SLUG]["accounts"]) == ["work", "home"] and servers[SLUG]["signin_on"] == "owner_app"
    assert list(_get_mcp_servers()) == [SLUG]


def test_saving_an_account_server_for_a_connector_with_no_template_creates_it_with_that_account():
    assert _save_mcp_server(f"{SLUG}@work", TEMPLATE)

    assert list(stored()) == [SLUG] and list(stored()[SLUG]["accounts"]) == ["work"]


def test_saving_a_whole_connector_without_accounts_keeps_the_accounts_it_has():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})

    assert _save_mcp_server(SLUG, {**TEMPLATE, "signin_on": "owner_app"})

    assert list(stored()[SLUG]["accounts"]) == ["work", "home"] and stored()[SLUG]["signin_on"] == "owner_app"


def test_an_api_key_accounts_own_authorization_header_never_replaces_the_templates():
    write_servers({"github": {**GITHUB, "accounts": {"default": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}}})
    from tools.mcp_tool_config import _load_mcp_config

    expanded = _load_mcp_config(interpolate=False)
    assert expanded["github@work"]["headers"]["Authorization"] == "Bearer ${MCP_GITHUB__WORK_API_KEY}"
    assert expanded["github@default"]["headers"]["Authorization"] == "Bearer ${MCP_GITHUB_API_KEY}"

    assert _save_mcp_server("github@work", expanded["github@work"])

    assert stored()["github"]["headers"] == {"Authorization": "Bearer ${MCP_GITHUB_API_KEY}"}


def test_removing_an_account_name_removes_only_that_account_from_config():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    put_tokens(f"{SLUG}@work")
    put_tokens(f"{SLUG}@home")

    assert _remove_mcp_server(f"{SLUG}@work") is True
    assert list(stored()[SLUG]["accounts"]) == ["home"]
    assert not has_tokens(f"{SLUG}@work") and has_tokens(f"{SLUG}@home")
    assert _remove_mcp_server(f"{SLUG}@work") is False

    assert _remove_mcp_server(f"{SLUG}@home") is True
    assert SLUG not in stored() and not has_tokens(f"{SLUG}@home")


def test_removing_a_whole_connector_forgets_every_accounts_sign_in_and_key():
    write_servers({"github": {**GITHUB, "accounts": {"default": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}}})
    save_env_value("MCP_GITHUB__WORK_API_KEY", "work-secret")
    put_tokens("github@default")
    put_tokens("github@work")

    assert _remove_mcp_server("github") is True

    assert "github" not in stored()
    assert not has_tokens("github@default") and not has_tokens("github@work")
    assert get_env_value("MCP_GITHUB__WORK_API_KEY") in (None, "")


def test_removing_one_account_deletes_its_tokens_and_reconciles_the_live_servers(reconciles):
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    put_tokens(f"{SLUG}@work")
    put_tokens(f"{SLUG}@home")

    outcome = mcp_accounts.remove_account(SLUG, "work")

    assert outcome.template_removed is False
    assert mcp_accounts.account_names(SLUG) == ["home"]
    assert not has_tokens(f"{SLUG}@work") and has_tokens(f"{SLUG}@home")
    assert reconciles == ["reconcile"]


def test_removing_the_last_account_removes_the_connector_its_tokens_and_secrets(reconciles):
    write_servers({"github": {**GITHUB, "accounts": {"work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}}})
    save_env_value("MCP_GITHUB__WORK_API_KEY", "work-secret")
    put_tokens("github@work")

    outcome = mcp_accounts.remove_account("github", "work")

    assert outcome.template_removed is True
    assert "github" not in stored() and not has_tokens("github@work")
    assert get_env_value("MCP_GITHUB__WORK_API_KEY") in (None, "")
    assert reconciles == ["reconcile"]


def test_removing_an_account_that_uses_the_templates_key_keeps_it_while_another_account_still_does():
    write_servers({"github": {**GITHUB, "accounts": {"default": {}, "second": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}}}})
    save_env_value("MCP_GITHUB_API_KEY", "shared-secret")

    mcp_accounts.remove_account("github", "default")
    assert get_env_value("MCP_GITHUB_API_KEY") == "shared-secret"

    mcp_accounts.remove_account("github", "second")
    assert get_env_value("MCP_GITHUB_API_KEY") in (None, "")


def test_removing_an_unknown_account_is_refused():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}}}})

    with pytest.raises(AccountError) as refused:
        mcp_accounts.remove_account(SLUG, "nope")

    assert refused.value.code == "unknown_account" and mcp_accounts.account_names(SLUG) == ["work"]


def test_renaming_moves_the_tokens_and_keeps_the_key_pointer(reconciles):
    write_servers({"github": {**GITHUB, "accounts": {
        "first": {}, "work": {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}, "last": {}}}})
    put_tokens("github@work", "work-token")
    HermesTokenStorage("github@work").mark_reauth_required()

    mcp_accounts.rename_account("github", "work", "office")

    accounts = stored()["github"]["accounts"]
    assert set(accounts) == {"first", "office", "last"} and "work" not in accounts
    assert accounts["office"] == {"api_key_env": "MCP_GITHUB__WORK_API_KEY"}
    assert asyncio.run(HermesTokenStorage("github@office").get_tokens()).access_token == "work-token"
    assert HermesTokenStorage("github@office").reauth_required()
    assert not has_tokens("github@work") and not HermesTokenStorage("github@work").reauth_required()
    assert reconciles == ["reconcile"]


@pytest.mark.parametrize("old,new,code", [("nope", "other", "unknown_account"), ("work", "home", "account_exists"),
                                          ("work", "Bad Name", "invalid_account")])
def test_a_refused_rename_changes_nothing(old, new, code):
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    put_tokens(f"{SLUG}@work")

    with pytest.raises(AccountError) as refused:
        mcp_accounts.rename_account(SLUG, old, new)

    assert refused.value.code == code and "@" not in refused.value.message
    assert list(stored()[SLUG]["accounts"]) == ["work", "home"] and has_tokens(f"{SLUG}@work")


def test_a_rename_interrupted_after_the_tokens_moved_completes_on_the_next_try():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}}}})
    put_tokens(f"{SLUG}@work", "work-token")
    HermesTokenStorage(f"{SLUG}@office").absorb(HermesTokenStorage(f"{SLUG}@work"))

    mcp_accounts.rename_account(SLUG, "work", "office")

    assert list(stored()[SLUG]["accounts"]) == ["office"]
    assert asyncio.run(HermesTokenStorage(f"{SLUG}@office").get_tokens()).access_token == "work-token"


def test_account_statuses_name_each_account_and_the_one_that_needs_signing_in_again():
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}, "new": {}}}})
    put_tokens(f"{SLUG}@home")
    HermesTokenStorage(f"{SLUG}@work").mark_reauth_required()

    statuses = {s.name: s for s in mcp_accounts.account_statuses(SLUG)}

    assert list(statuses) == ["work", "home", "new"]
    assert statuses["work"].status == "needs_reconnect" and "Linear (work)" in statuses["work"].reason
    assert (statuses["home"].status, statuses["home"].reason) == ("connected", None)
    assert (statuses["new"].status, statuses["new"].reason) == ("not_connected", None)


def test_every_account_of_a_disabled_connector_is_not_connected_and_a_pending_connector_has_none():
    write_servers({SLUG: {**TEMPLATE, "enabled": False, "accounts": {"work": {}}}, "notion": {"url": "https://mcp.notion.com/mcp", "auth": "oauth"}})

    assert [(s.name, s.status) for s in mcp_accounts.account_statuses(SLUG)] == [("work", "not_connected")]
    assert mcp_accounts.account_statuses("notion") == []
    assert mcp_accounts.account_statuses("unknown") == []


@pytest.mark.parametrize("accounts,alias,create,expected", [
    ({}, None, False, "default"),
    ({}, "work", False, "work"),
    ({}, "work", True, "work"),
    ({"work": {}}, None, False, "work"),
    ({"work": {}}, "home", True, "home"),
    ({"work": {}}, "work", False, "work"),
    ({"work": {}, "home": {}}, "home", False, "home"),
])
def test_the_account_to_sign_in_is_the_named_one_the_only_one_or_default(accounts, alias, create, expected):
    template = {**TEMPLATE, "accounts": accounts} if accounts else TEMPLATE

    assert mcp_accounts.resolve_for_connect(SLUG, template, alias, create=create) == expected


@pytest.mark.parametrize("accounts,alias,create,code", [
    ({"work": {}, "home": {}}, None, False, "account_required"),
    ({"work": {}}, "work", True, "account_exists"),
    ({"work": {}}, None, True, "account_exists"),
    ({}, "Not Valid", False, "invalid_account"),
])
def test_sign_in_refuses_an_ambiguous_duplicate_or_malformed_account(accounts, alias, create, code):
    template = {**TEMPLATE, "accounts": accounts} if accounts else TEMPLATE

    with pytest.raises(AccountError) as refused:
        mcp_accounts.resolve_for_connect(SLUG, template, alias, create=create)

    assert refused.value.code == code and "@" not in refused.value.message


def test_a_second_account_is_an_extra_one_and_the_first_is_not():
    assert mcp_accounts.is_extra_account(SLUG, "work") is False
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}}}})
    assert mcp_accounts.is_extra_account(SLUG, "work") is False
    assert mcp_accounts.is_extra_account(SLUG, "home") is True
    write_servers({SLUG: {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    assert mcp_accounts.is_extra_account(SLUG, "work") is True


def test_migration_gives_an_api_key_connector_account_main_and_leaves_its_secret_alone():
    write_servers({"github": GITHUB})
    save_env_value("MCP_GITHUB_API_KEY", "legacy-secret")

    assert mcp_accounts.migrate_legacy_accounts() == ["github"]

    assert stored()["github"]["accounts"] == {"default": {}}
    assert stored()["github"]["headers"] == GITHUB["headers"]
    assert get_env_value("MCP_GITHUB_API_KEY") == "legacy-secret"
    assert mcp_accounts.migrate_legacy_accounts() == []


def test_migration_leaves_connectors_that_cannot_hold_accounts_and_pending_ones_alone():
    write_servers({
        "discord": {"command": "uvx", "args": ["x"], "enabled": True},
        "slack": {"url": "https://mcp.slack.com/mcp", "auth": "oauth"},
        "custom": {"url": "https://custom.example/mcp", "auth": "oauth"},
        SLUG: TEMPLATE})
    for name in ("discord", "slack", "custom"):
        put_tokens(name)
    before = (get_hermes_home() / "config.yaml").read_text()

    assert mcp_accounts.migrate_legacy_accounts() == []

    assert (get_hermes_home() / "config.yaml").read_text() == before
    assert all(has_tokens(name) for name in ("discord", "slack", "custom"))


def test_migration_moves_every_legacy_state_file_and_the_connection_name_is_the_accounts():
    write_servers({SLUG: TEMPLATE})
    legacy = HermesTokenStorage(SLUG)
    put_tokens(SLUG, "legacy-token")
    legacy.mark_reauth_required()
    legacy.update_redirect_pref(redirect="app")

    assert mcp_accounts.migrate_legacy_accounts() == [SLUG]

    default_storage = HermesTokenStorage(f"{SLUG}@default")
    assert asyncio.run(default_storage.get_tokens()).access_token == "legacy-token"
    assert default_storage.reauth_required() and default_storage.redirect_pref() == {"redirect": "app"}
    assert legacy.state_paths() == []
    assert list(_get_mcp_servers()[SLUG]["accounts"]) == ["default"]
