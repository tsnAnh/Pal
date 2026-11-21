from __future__ import annotations

import json
import threading
from types import SimpleNamespace

import hermes_yaml as yaml
import pytest

from hermes_constants import get_hermes_home
from tests.tools.mcp_accounts_double import AccountsDouble, store_account_tokens, write_servers

pytest.importorskip("mcp.client.auth.oauth2")

SLUG = "linear"


@pytest.fixture
def double():
    with AccountsDouble() as d:
        yield d


@pytest.fixture(autouse=True)
def _clean_runtime():
    from tools import mcp_tool_loop as loop
    from tools.mcp_oauth_manager import reset_manager_for_tests
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers
    reset_manager_for_tests()
    yield
    shutdown_mcp_servers()
    loop._stop_mcp_loop()


def connect(double, accounts, **extra):
    from tools.mcp_tool_discovery import discover_mcp_tools
    for alias in accounts:
        store_account_tokens(double, f"{SLUG}@{alias}", alias)
    write_servers(get_hermes_home(), double, SLUG, accounts, **extra)
    return discover_mcp_tools()


def call(tool, **args):
    from tools.registry import registry
    return json.loads(registry.dispatch(f"mcp__{SLUG}__{tool}", args))


def served_account(result):
    return json.loads(result["result"])["account"]


def test_tool_definitions_are_byte_identical_for_one_and_for_two_accounts(double):
    from model_tools import get_tool_definitions
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    def rendered():
        sent = get_tool_definitions(enabled_toolsets=[f"mcp-{SLUG}"], quiet_mode=True)
        raw = get_tool_definitions(enabled_toolsets=[f"mcp-{SLUG}"], quiet_mode=True, skip_tool_search_assembly=True)
        return json.dumps([sent, raw], sort_keys=False)

    assert f"mcp__{SLUG}__whoami" in connect(double, ["work"])
    one = rendered()
    shutdown_mcp_servers()
    connect(double, ["work", "home"])
    two = rendered()

    assert f"mcp__{SLUG}__whoami" in one
    assert one == two
    whoami = next(d for d in json.loads(two)[1] if d["function"]["name"] == f"mcp__{SLUG}__whoami")
    properties = whoami["function"]["parameters"]["properties"]
    assert list(properties)[-1] == "connector_alias" and "connector_alias" not in whoami["function"]["parameters"]["required"]


def test_each_alias_is_served_by_its_own_account(double):
    connect(double, ["work", "home"])

    first = call("whoami", connector_alias="work")
    second = call("whoami", connector_alias="home")
    third = call("whoami", connector_alias="work")

    assert [served_account(r) for r in (first, second, third)] == ["work", "home", "work"]
    calls = double.tool_calls("whoami")
    assert [c.account for c in calls] == ["work", "home", "work"]
    assert len({c.bearer for c in calls}) == 2
    assert all("connector_alias" not in c.arguments for c in calls)


def test_several_accounts_without_an_alias_name_them_and_call_nothing(double):
    connect(double, ["work", "home"])
    before = len(double.tool_calls("whoami"))

    missing = call("whoami")
    unknown = call("whoami", connector_alias="nope")

    for result in (missing, unknown):
        assert "work" in result["error"] and "home" in result["error"] and "connector_alias" in result["error"]
    assert len(double.tool_calls("whoami")) == before


def test_one_account_works_without_an_alias(double):
    connect(double, ["work"])

    assert served_account(call("whoami")) == "work"
    assert served_account(call("whoami", connector_alias="work")) == "work"


def test_a_legacy_connection_becomes_account_main_and_keeps_working(double):
    from tools.mcp_oauth import HermesTokenStorage
    from tools.mcp_tool_config import _load_mcp_config
    from tools.mcp_tool_discovery import discover_mcp_tools

    token = store_account_tokens(double, SLUG, "default")
    home = get_hermes_home()
    legacy_client = home / "mcp-tokens" / f"{SLUG}.client.json"
    legacy_client.write_text(json.dumps({"client_id": "legacy-client", "redirect_uris": ["http://127.0.0.1:1/cb"]}))
    legacy_meta = home / "mcp-tokens" / f"{SLUG}.meta.json"
    legacy_meta.write_text(json.dumps({"issuer": double.base}))
    write_servers(home, double, SLUG)

    assert f"mcp__{SLUG}__whoami" in discover_mcp_tools()

    assert served_account(call("whoami")) == "default"
    assert double.tool_calls("whoami")[0].bearer == token
    account_dir = home / "mcp-tokens" / "accounts" / SLUG
    assert {p.name for p in account_dir.iterdir()} >= {"default.json", "default.client.json", "default.meta.json"}
    assert not any((home / "mcp-tokens" / f"{SLUG}{suffix}").exists() for suffix in (".json", ".client.json", ".meta.json"))
    assert list(yaml.safe_load((home / "config.yaml").read_text())["mcp_servers"][SLUG]["accounts"]) == ["default"]
    assert HermesTokenStorage(f"{SLUG}@default").has_cached_tokens()

    stamp = [(p.name, p.stat().st_mtime_ns) for p in sorted(account_dir.iterdir())]
    config_stamp = (home / "config.yaml").stat().st_mtime_ns
    assert list(_load_mcp_config()) == [f"{SLUG}@default"]
    assert [(p.name, p.stat().st_mtime_ns) for p in sorted(account_dir.iterdir())] == stamp
    assert (home / "config.yaml").stat().st_mtime_ns == config_stamp


def test_an_interrupted_migration_loses_nothing_and_the_moved_copy_wins(double):
    from tools.mcp_tool_config import _load_mcp_config

    home = get_hermes_home()
    token_dir = home / "mcp-tokens"
    account_dir = token_dir / "accounts" / SLUG
    account_dir.mkdir(parents=True)
    store_account_tokens(double, SLUG, "default")
    legacy_tokens = (token_dir / f"{SLUG}.json").read_bytes()
    (token_dir / f"{SLUG}.client.json").write_text(json.dumps({"client_id": "still-legacy"}))
    (account_dir / "default.json").write_bytes(legacy_tokens)
    (account_dir / "default.meta.json").write_text(json.dumps({"issuer": "moved-before-the-crash"}))
    (token_dir / f"{SLUG}.meta.json").write_text(json.dumps({"issuer": "stale-legacy-copy"}))
    write_servers(home, double, SLUG, ["default"])

    assert list(_load_mcp_config()) == [f"{SLUG}@default"]

    assert (account_dir / "default.json").read_bytes() == legacy_tokens
    assert json.loads((account_dir / "default.client.json").read_text()) == {"client_id": "still-legacy"}
    assert json.loads((account_dir / "default.meta.json").read_text()) == {"issuer": "moved-before-the-crash"}
    assert not [p for p in token_dir.iterdir() if p.is_file() and p.name.startswith(SLUG)]


def test_reauth_of_one_account_leaves_the_other_connected(double):
    from tools.auth_required import detect
    from tools.mcp_oauth import HermesTokenStorage, pending_reauth_reason

    connect(double, ["work", "home"])
    HermesTokenStorage(f"{SLUG}@work").mark_reauth_required()

    assert pending_reauth_reason(f"{SLUG}@work") is not None
    assert pending_reauth_reason(f"{SLUG}@home") is None
    blocked = call("whoami", connector_alias="work")
    need = detect(f"mcp__{SLUG}__whoami", {}, json.dumps(blocked))
    assert blocked["needs_reauth"] is True and need is not None
    assert need.service == f"mcp:{SLUG}:work"
    assert served_account(call("whoami", connector_alias="home")) == "home"


def test_revoking_one_accounts_token_does_not_break_the_other(double):
    connect(double, ["work", "home"])
    double.revoke("work")

    assert call("whoami", connector_alias="work").get("error")
    assert served_account(call("whoami", connector_alias="home")) == "home"


class Owner:
    def __init__(self, key="chat-a"):
        from gateway.session_context import set_session_vars
        from gateway.session_ingress import viewer_turn
        from tools import approval
        from tools.approval_context import set_current_session_key
        self.key, self.cards = key, []
        live = SimpleNamespace(event_stream=SimpleNamespace(lock=threading.RLock()), route=key,
                               subscribers={"app": SimpleNamespace(capabilities={"session:approve"})})
        self._viewer = viewer_turn.set(live)
        self._vars = set_session_vars(platform="telegram", session_key=key)
        self._key = set_current_session_key(key)
        approval.register_gateway_notify(key, self._answer)

    def _answer(self, data):
        from tools import approval
        self.cards.append(dict(data))
        approval.resolve_gateway_approval(self.key, "once", request_id=data["request_id"])

    def close(self):
        from gateway.session_context import clear_session_vars
        from gateway.session_ingress import viewer_turn
        from tools import approval
        from tools.approval_context import reset_current_session_key
        approval.unregister_gateway_notify(self.key)
        reset_current_session_key(self._key)
        clear_session_vars(self._vars)
        viewer_turn.reset(self._viewer)


def test_auto_approve_on_one_account_does_not_approve_the_other(double):
    from tools import mcp_action_gate

    policy = {"action_policy": {"read_tools": ["whoami", "list_projects"]}}
    connect(double, ["work", "home"], **policy)
    owner = Owner()
    try:
        mcp_action_gate.set_auto_approve("chat-a", f"{SLUG}@work", True)

        approved = call("create_item", connector_alias="work", title="a")
        assert owner.cards == []
        asked = call("create_item", connector_alias="home", title="b")
    finally:
        owner.close()
        mcp_action_gate.set_auto_approve("chat-a", f"{SLUG}@work", False)

    assert json.loads(approved["result"])["account"] == "work"
    assert len(owner.cards) == 1
    assert "home" in json.dumps(owner.cards[0]) and "@" not in owner.cards[0]["draft"]["channel"]
    assert json.loads(asked["result"])["account"] == "home"


def test_removing_one_account_leaves_the_other_connected_and_the_last_removes_the_server(double):
    from hermes_cli import mcp_accounts
    from tools.registry import registry

    connect(double, ["work", "home"])

    assert mcp_accounts.remove_account(SLUG, "work").template_removed is False

    assert mcp_accounts.account_names(SLUG) == ["home"]
    assert registry.get_tool_names_for_toolset(f"mcp-{SLUG}")
    assert served_account(call("whoami")) == "home"
    assert not (get_hermes_home() / "mcp-tokens" / "accounts" / SLUG / "work.json").exists()
    assert (get_hermes_home() / "mcp-tokens" / "accounts" / SLUG / "home.json").exists()

    assert mcp_accounts.remove_account(SLUG, "home").template_removed is True

    assert SLUG not in (yaml.safe_load((get_hermes_home() / "config.yaml").read_text()).get("mcp_servers") or {})
    assert registry.get_tool_names_for_toolset(f"mcp-{SLUG}") == []
