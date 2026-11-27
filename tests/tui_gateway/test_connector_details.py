from __future__ import annotations

import json
from functools import partial
from types import SimpleNamespace

import pytest

import hermes_yaml as yaml
from hermes_cli import mcp_catalog
from hermes_cli.pal_connectors import load_pal_connectors
from hermes_constants import get_hermes_home
from tools import mcp_action_gate, mcp_tool
from tools import mcp_tool_handlers as handlers
from tools.mcp_connector_policy import reads_need_approval
from tools.mcp_schema_cache import write_cache_entry
from tools.mcp_tool_registration import _make_tool_filter
from tools.registry import registry
from tui_gateway import server

ENTRIES = {entry.id: entry for entry in load_pal_connectors()}
READ_TOOLS = ("search_jobs", "get_job", "list_proposals")
WRITE_TOOLS = ("submit_proposal", "send_message")
NEVER_TOOLS = ("fund_escrow",)
LINEAR = {"url": "https://mcp.linear.app/mcp", "auth": "oauth", "enabled": True}


def rpc(method, **params):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})


def ok(reply):
    assert "error" not in reply, reply.get("error")
    return reply["result"]


def refused(reply, code, reason):
    assert reply.get("error", {}).get("code") == code, reply
    assert reply["error"]["data"]["reason"] == reason, reply
    return reply


def write_config(servers, home=None):
    (home or get_hermes_home()).joinpath("config.yaml").write_text(
        yaml.safe_dump({"mcp_servers": servers}, sort_keys=False))


def stored(slug="upwork", home=None):
    doc = yaml.safe_load((home or get_hermes_home()).joinpath("config.yaml").read_text())
    return doc["mcp_servers"][slug]


def upwork_template(accounts=("default", "work"), **extra):
    template = mcp_catalog._build_server_config(mcp_catalog.get_entry("upwork"), None)
    return {**template, **extra, "accounts": {alias: {} for alias in accounts}}


def linear_template(accounts=("default",), **extra):
    return {**LINEAR, **extra, "accounts": {alias: {} for alias in accounts}}


def live_server(monkeypatch, connection, tool_names):
    tools = [SimpleNamespace(name=name, description=f"{name} description") for name in tool_names]
    live = SimpleNamespace(_tools=tools, session=object())
    monkeypatch.setitem(mcp_tool._servers, connection, live)
    return live


def upwork_tools(monkeypatch, connection="upwork@default"):
    return live_server(monkeypatch, connection, (*READ_TOOLS, *WRITE_TOOLS, *NEVER_TOOLS))


def details(slug="upwork", **params):
    return ok(rpc("connectors.details", slug=slug, **params))


def tool_rows(result):
    return {row["name"]: row for row in result["tools"]}


def set_mode(group, mode, slug="upwork", **params):
    return rpc("connectors.details.policy.set", slug=slug, group=group, mode=mode, **params)


def excluded(connection="upwork@default"):
    from tools.mcp_tool_config import _load_mcp_config
    return (_load_mcp_config(interpolate=False)[connection].get("tools") or {}).get("exclude") or []


@pytest.fixture(autouse=True)
def no_connection_attempts(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise AssertionError("listing connector tools opened a connection")

    monkeypatch.setattr("tools.mcp_tool_discovery.discover_mcp_tools", refuse)
    monkeypatch.setattr("tools.mcp_tool_discovery.register_mcp_servers", refuse)


def test_catalog_rows_carry_the_entry_description_and_source():
    rows = {row["slug"]: row for row in ok(rpc("connectors.catalog"))["connectors"]}

    assert set(rows) == set(ENTRIES)
    for slug, entry in ENTRIES.items():
        assert rows[slug]["description"] == entry.description and rows[slug]["description"], slug
        assert rows[slug]["source"] == entry.source, slug


def test_details_refuses_an_unknown_connector_and_malformed_params():
    refused(rpc("connectors.details", slug="nope"), 4041, "CONNECTOR_NOT_FOUND")
    refused(rpc("connectors.details"), 4000, "INVALID_PARAMS")
    refused(rpc("connectors.details", slug=""), 4000, "INVALID_PARAMS")
    assert rpc("connectors.details", slug="upwork", bogus=1)["error"]["code"] == 4000


def test_a_policy_server_lists_its_discovered_tools_in_read_write_and_never_groups(monkeypatch):
    write_config({"upwork": upwork_template()})
    upwork_tools(monkeypatch)

    result = details()

    assert (result["slug"], result["grouped"], result["tools_known"]) == ("upwork", True, True)
    assert {name: row["group"] for name, row in tool_rows(result).items()} == {
        "search_jobs": "read", "get_job": "read", "list_proposals": "read",
        "submit_proposal": "write", "send_message": "write", "fund_escrow": "never"}
    assert tool_rows(result)["search_jobs"]["title"] == "Search jobs"
    assert tool_rows(result)["search_jobs"]["description"] == "search_jobs description"
    assert result["policy"] == {"read": "auto", "write": "ask"}
    assert result["skills"] == []


def test_a_plain_server_is_ungrouped_with_one_tool_group_and_titles_without_the_server_prefix():
    write_config({"linear": linear_template()})
    write_cache_entry("linear", "any", tools=[
        {"name": "linear_create_issue", "description": "Create an issue.\n  Needs a title."},
        {"name": "listProjects", "description": ""}])

    result = details("linear")

    assert (result["grouped"], result["tools_known"], result["policy"]) == (False, True, {"tool": "on"})
    rows = tool_rows(result)
    assert {row["group"] for row in rows.values()} == {"tool"}
    assert rows["linear_create_issue"]["title"] == "Create issue"
    assert rows["linear_create_issue"]["description"] == "Create an issue. Needs a title."
    assert rows["listProjects"]["title"] == "List projects"


@pytest.mark.parametrize("servers", [{}, {"linear": linear_template()}], ids=["not connected", "nothing discovered"])
def test_tools_nobody_has_discovered_are_unknown_and_never_probed(servers):
    write_config(servers)

    assert details("linear") == {"slug": "linear", "grouped": False, "tools_known": False, "tools": [],
                                 "policy": {}, "skills": []}


def test_a_not_connected_policy_connector_is_still_grouped_from_its_manifest():
    write_config({})

    result = details()

    assert (result["grouped"], result["tools_known"], result["tools"]) == (True, False, [])


@pytest.mark.parametrize("group,mode", [("write", "auto"), ("read", "on"), ("write", "on"), ("tool", "ask")])
def test_impossible_modes_are_refused_and_nothing_is_written(monkeypatch, group, mode):
    write_config({"upwork": upwork_template()})
    upwork_tools(monkeypatch)
    before = get_hermes_home().joinpath("config.yaml").read_text()

    refused(set_mode(group, mode), 4000, "INVALID_POLICY")

    assert get_hermes_home().joinpath("config.yaml").read_text() == before


@pytest.mark.parametrize("mode", ["auto", "ask", "off", "on"])
def test_the_never_group_has_no_setting(monkeypatch, mode):
    write_config({"upwork": upwork_template()})
    upwork_tools(monkeypatch)

    refused(set_mode("never", mode), 4000, "INVALID_POLICY")


def test_groups_a_server_does_not_have_are_refused():
    write_config({"upwork": upwork_template(), "linear": linear_template()})

    refused(set_mode("tool", "off", slug="upwork"), 4000, "INVALID_POLICY")
    refused(set_mode("read", "ask", slug="linear"), 4000, "INVALID_POLICY")
    refused(set_mode("write", "off", slug="linear"), 4000, "INVALID_POLICY")


def test_unknown_group_mode_slug_and_unconnected_connector_are_refused():
    write_config({"upwork": upwork_template()})

    refused(set_mode("bogus", "off"), 4000, "INVALID_PARAMS")
    refused(set_mode("read", "bogus"), 4000, "INVALID_PARAMS")
    refused(set_mode("read", "ask", slug="nope"), 4041, "CONNECTOR_NOT_FOUND")
    refused(set_mode("tool", "off", slug="linear"), 4041, "CONNECTION_NOT_FOUND")
    assert rpc("connectors.details.policy.set", slug="upwork", group="read", mode="ask", bogus=1)["error"]["code"] == 4000


def test_turning_writes_off_before_any_tool_is_known_is_refused_not_silently_ignored():
    write_config({"upwork": upwork_template()})

    refused(set_mode("write", "off"), 5034, "TOOLS_UNAVAILABLE")
    assert "connector_policy" not in stored()


def test_a_setting_is_stored_on_the_template_and_covers_every_account_including_later_ones(monkeypatch):
    write_config({"upwork": upwork_template()})
    upwork_tools(monkeypatch)

    assert ok(set_mode("read", "ask")) == {"ok": True, "policy": {"read": "ask", "write": "ask"}}

    assert stored()["connector_policy"] == {"read": "ask"}
    assert details()["policy"] == {"read": "ask", "write": "ask"}
    assert stored()["accounts"] == {"default": {}, "work": {}}
    write_config({"upwork": {**stored(), "accounts": {"default": {}, "work": {}, "later": {}}}})
    for connection in ("upwork@default", "upwork@work", "upwork@later"):
        assert reads_need_approval(connection, connection)


def test_turning_a_group_off_excludes_its_tools_for_new_sessions_only(monkeypatch):
    write_config({"upwork": upwork_template(("default", "work", "later"))})
    live = upwork_tools(monkeypatch)
    tools_before = list(live._tools)

    def refuse(*_args, **_kwargs):
        raise AssertionError("turning a group off touched the live tool registry")

    monkeypatch.setattr(registry, "register", refuse)
    monkeypatch.setattr(registry, "deregister", refuse)

    assert ok(set_mode("write", "off"))["policy"] == {"read": "auto", "write": "off"}

    for connection in ("upwork@default", "upwork@work", "upwork@later"):
        assert set(excluded(connection)) == set(WRITE_TOOLS)
    from tools.mcp_tool_config import _load_mcp_config
    config = _load_mcp_config(interpolate=False)["upwork@work"]
    keep = _make_tool_filter("upwork@work", config)
    assert [keep(name) for name in (*READ_TOOLS, *WRITE_TOOLS, *NEVER_TOOLS)] == [True] * 3 + [False] * 2 + [True]
    assert live._tools == tools_before
    assert {name for name, row in tool_rows(details()).items() if row["group"] == "write"} == set(WRITE_TOOLS)
    assert details()["policy"]["write"] == "off"


def test_turning_a_group_back_on_removes_only_the_exclusions_this_feature_added(monkeypatch):
    write_config({"upwork": upwork_template(tools={"exclude": ["owner_hidden", "send_message"]})})
    upwork_tools(monkeypatch)

    set_mode("write", "off")
    assert excluded() == ["owner_hidden", "send_message", "submit_proposal"]
    set_mode("read", "off")
    assert {"search_jobs", "owner_hidden"} <= set(excluded())

    ok(set_mode("write", "ask"))
    ok(set_mode("read", "auto"))

    assert excluded() == ["owner_hidden", "send_message"]
    assert "connector_policy" not in stored()


def test_a_read_group_turned_off_hides_the_policy_read_list_even_before_discovery():
    write_config({"upwork": upwork_template()})

    assert ok(set_mode("read", "off"))["ok"]

    assert set(excluded()) == set(mcp_catalog.get_entry("upwork").action_policy.read_tools)
    assert details()["tools_known"] is True


def test_an_ungrouped_connector_turned_off_excludes_everything_now_and_later(monkeypatch):
    write_config({"linear": linear_template()})
    write_cache_entry("linear", "any", tools=[{"name": "create_issue", "description": "Create."}])

    assert ok(set_mode("tool", "off", slug="linear"))["policy"] == {"tool": "off"}

    from tools.mcp_tool_config import _load_mcp_config
    keep = _make_tool_filter("linear@default", _load_mcp_config(interpolate=False)["linear@default"])
    assert not keep("create_issue") and not keep("a_tool_added_next_month")
    assert tool_rows(details("linear"))["create_issue"]["group"] == "tool"

    assert ok(set_mode("tool", "on", slug="linear"))["policy"] == {"tool": "on"}
    assert excluded("linear@default") == [] and "connector_policy" not in stored("linear")


class Approvals:
    def __init__(self, monkeypatch, *, present=True, answer=None):
        self.cards = []
        monkeypatch.setattr(mcp_action_gate, "approver_present", lambda: present)
        monkeypatch.setattr(mcp_action_gate, "_approve", self._approve)
        self.answer = answer

    def _approve(self, server_name, tool_name, args, *_send_rule):
        self.cards.append((server_name, tool_name, dict(args)))
        return self.answer


def gate_call(tool, args=None, connection="upwork@default"):
    return mcp_action_gate.gate(
        mcp_tool._server_action_policies[connection], connection, tool, args or {},
        reads_ask=partial(reads_need_approval, connection, connection))


@pytest.fixture
def policy_server(monkeypatch):
    write_config({"upwork": upwork_template()})
    registered = mcp_catalog._build_server_config(mcp_catalog.get_entry("upwork"), None)
    monkeypatch.setitem(mcp_tool._server_action_policies, "upwork@default", mcp_action_gate.policy_from_config(registered))


def test_a_read_set_to_ask_waits_for_the_owner_with_the_exact_arguments_and_runs_once(monkeypatch, policy_server):
    approvals = Approvals(monkeypatch)
    assert gate_call("search_jobs", {"q": "python"}) == (None, None) and approvals.cards == []

    upwork_tools(monkeypatch)
    ok(set_mode("read", "ask"))
    error, grant = gate_call("search_jobs", {"q": "python"})

    assert error is None and grant is not None
    assert approvals.cards == [("upwork@default", "search_jobs", {"q": "python"})]
    assert grant.consume("upwork@default", "search_jobs", {"q": "python"}) is None
    assert grant.consume("upwork@default", "search_jobs", {"q": "python"}) is not None

    ok(set_mode("read", "auto"))
    assert gate_call("search_jobs", {"q": "python"}) == (None, None) and len(approvals.cards) == 1


def test_a_read_set_to_ask_is_blocked_when_the_owner_denies_or_nobody_can_answer(monkeypatch, policy_server):
    upwork_tools(monkeypatch)
    ok(set_mode("read", "ask"))

    denied = Approvals(monkeypatch, answer="denied")
    assert gate_call("get_job") == ("denied", None) and len(denied.cards) == 1
    Approvals(monkeypatch, present=False)
    error, grant = gate_call("get_job")
    assert grant is None and "NOT run" in error


@pytest.mark.parametrize("settings", [(), (("read", "ask"),), (("read", "off"), ("write", "off"))])
def test_no_setting_lets_a_write_run_unasked_or_a_money_step_run(monkeypatch, policy_server, settings):
    upwork_tools(monkeypatch)
    for group, mode in settings:
        ok(set_mode(group, mode))
    approvals = Approvals(monkeypatch)

    error, grant = gate_call("submit_proposal", {"job_id": "1"})
    assert error is None and grant is not None and approvals.cards == [("upwork@default", "submit_proposal", {"job_id": "1"})]
    Approvals(monkeypatch, present=False)
    assert "NOT run" in gate_call("submit_proposal")[0]
    assert "money" in gate_call("fund_escrow")[0]


def test_the_chat_auto_approve_switch_still_skips_only_the_card(monkeypatch, policy_server):
    from tools.approval_context import reset_current_session_key, set_current_session_key
    upwork_tools(monkeypatch)
    ok(set_mode("read", "ask"))
    approvals = Approvals(monkeypatch)
    monkeypatch.setattr(mcp_action_gate, "_auto_approved", set())
    token = set_current_session_key("chat-a")
    try:
        mcp_action_gate.set_auto_approve("chat-a", "upwork@default", True)
        error, grant = gate_call("search_jobs")
        assert error is None and grant is not None and approvals.cards == []
        assert "money" in gate_call("fund_escrow")[0]
    finally:
        reset_current_session_key(token)



def test_installed_skills_that_name_the_connector_are_listed_with_humanized_titles():
    skills = get_hermes_home() / "skills"
    for name, connector in (("upwork-proposals", "mcp:upwork"), ("linear_triage", "linear"),
                            ("plain-skill", None), ("other-connector", "mcp:notion")):
        folder = skills / name
        folder.mkdir(parents=True)
        header = f"connector: {connector}\n" if connector else ""
        (folder / "SKILL.md").write_text(f"---\nname: {name}\ndescription: Does {name}.\n{header}---\n\nBody.\n")
    write_config({"upwork": upwork_template(), "linear": linear_template()})

    assert details()["skills"] == [
        {"name": "upwork-proposals", "title": "Upwork proposals", "description": "Does upwork-proposals."}]
    assert details("linear")["skills"] == [
        {"name": "linear_triage", "title": "Linear triage", "description": "Does linear_triage."}]


def _two_homes(tmp_path, monkeypatch, slug, tools):
    root = tmp_path / "root"
    work = root / "profiles" / "work"
    work.mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    for home in (root, work):
        cache = home / "cache"
        cache.mkdir()
        cache.joinpath("mcp_schema_cache.json").write_text(json.dumps(
            {slug: {"fingerprint": "x", "tools": [{"name": name, "description": name} for name in tools]}}))
    return root, work


def test_a_root_owned_connector_reads_and_writes_the_root_config_from_any_profile(tmp_path, monkeypatch):
    root, work = _two_homes(tmp_path, monkeypatch, "upwork", ("search_jobs", "send_message"))
    write_config({"upwork": upwork_template()}, home=root)
    write_config({"upwork": upwork_template(connector_policy={"read": "ask"})}, home=work)

    assert details(profile="work")["policy"]["read"] == "auto" and details()["policy"]["read"] == "auto"
    ok(set_mode("write", "off", profile="work"))
    assert stored(home=root)["connector_policy"]["write"] == "off"
    assert stored(home=work)["connector_policy"] == {"read": "ask"}


def test_a_bot_only_connector_reads_and_writes_only_its_own_config(tmp_path, monkeypatch):
    root, work = _two_homes(tmp_path, monkeypatch, "upwork", ("search_jobs", "send_message"))
    write_config({"linear": linear_template()}, home=root)
    write_config({"upwork": upwork_template(connector_policy={"read": "ask"})}, home=work)

    assert details(profile="work")["policy"]["read"] == "ask"
    ok(set_mode("write", "off", profile="work"))
    assert stored(home=work)["connector_policy"]["read"] == "ask" and stored(home=work)["connector_policy"]["write"] == "off"
    assert "upwork" not in yaml.safe_load(root.joinpath("config.yaml").read_text())["mcp_servers"]
