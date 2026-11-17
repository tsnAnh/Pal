"""Every tool outside the 15-tool eager set sits behind tool_search / tool_describe / tool_call.

Failure cases pinned here: a deferred tool nobody can find or call; a session-gated tool (iPhone,
desktop GUI) listed or callable where its session kind does not carry it; a disabled toolset still
visible; a device tool listed with no device registered (ghost entry); a gated tool (Slack write,
per-device shell) skipping its approval because it arrived through the bridge.
"""

import json
from types import SimpleNamespace

import pytest

import model_tools
from gateway import device_connectors
from tools import approval, devices_tool, mcp_action_gate, slack_tools
from tools.registry import registry
from tools.tool_search import BRIDGE_TOOL_NAMES, EAGER_TOOL_NAMES

DEVICE_TOOLS = {"iphone", "devices_list", "device"}
GUI_TOOLS = {"read_window_below", "set_theme", "focus_pane"}
SESSIONS = {
    "bot_chat": (["hermes-cli"], False),
    "iphone_chat": (["hermes-cli", "iphone"], True),
    "desktop_gui": (["hermes-cli", "desktop_ui", "project"], False),
}


@pytest.fixture
def services(monkeypatch):
    """Every service-gated tool available except devices, which follow ``registered``."""
    state = {"registered": True}
    for entry in list(registry._tools.values()):
        if entry.toolset != "iphone":
            monkeypatch.setattr(entry, "check_fn", None)
    monkeypatch.setattr(registry, "_toolset_checks", {})
    monkeypatch.setattr(device_connectors, "any_enabled", lambda _home: state["registered"])
    model_tools._clear_tool_defs_cache()
    yield state
    model_tools._clear_tool_defs_cache()


def _names(toolsets, disabled=None, *, assembled):
    defs = model_tools.get_tool_definitions(
        enabled_toolsets=toolsets, disabled_toolsets=disabled, quiet_mode=True,
        skip_tool_search_assembly=not assembled)
    return [d["function"]["name"] for d in defs]


def _description(toolsets, disabled=None):
    defs = model_tools.get_tool_definitions(enabled_toolsets=toolsets, disabled_toolsets=disabled, quiet_mode=True)
    return next(d["function"]["description"] for d in defs if d["function"]["name"] == "tool_search")


def _bridge(name, args, toolsets, disabled=None):
    result, redispatch = model_tools._dispatch_bridge_tool(name, args, toolsets, disabled)
    return redispatch if result is None else json.loads(result)


def _call(name, toolsets, arguments=None):
    return _bridge("tool_call", {"calls": [{"name": name, "arguments": arguments or {}}]}, toolsets)


def _blocked(outcome, fragment):
    return isinstance(outcome, dict) and fragment in outcome.get("error", "")


def test_the_array_a_session_sends_is_the_eager_set_plus_the_bridge(services):
    for toolsets, _ in SESSIONS.values():
        assert set(_names(toolsets, assembled=True)) == EAGER_TOOL_NAMES | BRIDGE_TOOL_NAMES


@pytest.mark.parametrize("session", SESSIONS)
def test_every_deferred_tool_is_found_described_and_callable(services, session):
    toolsets, _ = SESSIONS[session]
    deferred = set(_names(toolsets, assembled=False)) - EAGER_TOOL_NAMES - BRIDGE_TOOL_NAMES
    assert len(deferred) > 20
    for name in sorted(deferred):
        found = _bridge("tool_search", {"queries": [name], "limit": 50}, toolsets)
        assert name in found["results"][0]["matches"], name
        assert name in _bridge("tool_describe", {"names": [name]}, toolsets)["tools"], name
        outcome = _call(name, toolsets)
        assert isinstance(outcome, tuple) or "missing required argument" in outcome["error"], (name, outcome)


def test_deferred_names_are_listed_in_the_description_without_schemas(services):
    description = _description(SESSIONS["bot_chat"][0])
    for name in ("kanban_show", "slack_post_message", "browser_exec", "delegate_task", "cronjob_manage",
                 "manage_connections", "todo_list", "skill_manage"):
        assert name in description, name
    assert "\"properties\"" not in description


def test_device_tools_follow_the_registered_device(services):
    toolsets = SESSIONS["iphone_chat"][0]
    services["registered"] = False
    model_tools._clear_tool_defs_cache()
    assert not DEVICE_TOOLS & set(_names(toolsets, assembled=False))
    assert not any(name in _description(toolsets) for name in DEVICE_TOOLS)
    found = _bridge("tool_search", {"queries": ["device", "iphone"]}, toolsets)
    assert not DEVICE_TOOLS & set(found["tools"])
    assert _blocked(_call("device", toolsets), "not available in this execution context")

    services["registered"] = True
    model_tools._clear_tool_defs_cache()
    assert not DEVICE_TOOLS & set(_names(toolsets, assembled=True))
    description = _description(toolsets)
    assert all(name in description for name in DEVICE_TOOLS)
    assert "devices_list" in _bridge("tool_search", {"queries": ["list devices"]}, toolsets)["tools"]


def test_device_tools_are_absent_from_sessions_without_the_iphone_toolset(services):
    for session in ("bot_chat", "desktop_gui"):
        toolsets = SESSIONS[session][0]
        assert not DEVICE_TOOLS & set(_names(toolsets, assembled=False))
        assert not any(name in _description(toolsets) for name in DEVICE_TOOLS)
        assert _blocked(_call("devices_list", toolsets), "not available in this execution context")


def test_gui_tools_follow_the_session_kind(services):
    gui = SESSIONS["desktop_gui"][0]
    assert GUI_TOOLS <= set(_names(gui, assembled=False))
    assert not GUI_TOOLS & set(_names(gui, assembled=True))
    assert all(name in _description(gui) for name in GUI_TOOLS)
    assert isinstance(_call("read_window_below", gui), tuple)

    chat = SESSIONS["bot_chat"][0]
    assert not GUI_TOOLS & set(_names(chat, assembled=False))
    assert not any(name in _description(chat) for name in GUI_TOOLS)
    assert _blocked(_call("read_window_below", chat), "desktop-app session")


def test_a_disabled_toolset_is_neither_eager_nor_listed_nor_callable(services):
    toolsets = SESSIONS["bot_chat"][0]
    for disabled, hidden in ((["kanban"], "kanban_show"), (["browser"], "browser_exec"),
                             (["file"], "read_file"), (["memory"], "memory")):
        names = _names(toolsets, disabled, assembled=True)
        assert hidden not in names
        assert hidden not in _description(toolsets, disabled)
        outcome = _bridge("tool_call", {"calls": [{"name": hidden, "arguments": {}}]}, toolsets, disabled)
        assert _blocked(outcome, "not available in this execution context"), (hidden, outcome)


class _Owner:
    def __init__(self, monkeypatch, *, answer):
        self.cards = []

        def ask(**card):
            self.cards.append(card)
            return {"approved": answer}
        monkeypatch.setattr(mcp_action_gate, "approver_present", lambda: True)
        monkeypatch.setattr(approval, "request_draft_approval", ask)


def test_a_slack_write_through_the_bridge_still_asks_the_owner_and_denial_sends_nothing(services, monkeypatch):
    posted = []
    monkeypatch.setattr(slack_tools, "active_install", lambda bot=None: slack_tools.SlackInstall("T0", "Acme", "v1"))
    monkeypatch.setattr(slack_tools, "_bot_token", lambda install: "fake-token")
    monkeypatch.setattr(slack_tools, "_api", lambda: SimpleNamespace(
        call=lambda *a, **k: posted.append((a, k)) or {"channel": {"name": "general"}}))
    owner = _Owner(monkeypatch, answer=False)
    toolsets = SESSIONS["bot_chat"][0]

    outcome = _call("slack_post_message", toolsets, {"channel": "C0GEN", "text": "hello"})

    assert isinstance(outcome, tuple) and outcome[0] == "slack_post_message"
    result = json.loads(model_tools.handle_function_call(
        "tool_call", {"calls": [{"name": "slack_post_message", "arguments": {"channel": "C0GEN", "text": "hello"}}]},
        enabled_toolsets=toolsets))
    assert result["code"] == "approval_denied" and len(owner.cards) == 1
    assert not any("chat.postMessage" in str(call) for call in posted)


class _View(SimpleNamespace):
    pass


def test_a_deferred_device_shell_call_hits_the_per_device_capability_and_approval(services, monkeypatch):
    from tui_gateway.contracts.canonical_device import DeviceConnectorState

    view = _View(kind="mac", label="Studio Mac", type="Mac", online=True, device_id="dev-1", last_seen_at=0.0,
                 connectors={"shell": DeviceConnectorState.ASK})
    monkeypatch.setattr(devices_tool, "_bound", lambda home: object())
    monkeypatch.setattr(devices_tool, "_resolved", lambda *a: (view, None))
    asked = []
    monkeypatch.setattr(approval, "request_tool_approval",
                        lambda tool, text: asked.append((tool, text)) or {"approved": False})
    from gateway import device_tools
    monkeypatch.setattr(device_tools, "call_from_thread",
                        lambda *a, **k: pytest.fail("the device was reached without approval"))
    arguments = {"device": "Studio Mac", "action": "shell.run", "args": {"command": "ls"}}
    toolsets = SESSIONS["iphone_chat"][0]

    via_bridge = json.loads(model_tools.handle_function_call(
        "tool_call", {"calls": [{"name": "device", "arguments": arguments}]}, enabled_toolsets=toolsets))
    direct = json.loads(model_tools.handle_function_call("device", arguments, enabled_toolsets=toolsets))

    assert via_bridge["code"] == direct["code"] == "approval_denied"
    assert [tool for tool, _ in asked] == ["device", "device"]

    view.connectors["shell"] = DeviceConnectorState.OFF
    off = json.loads(model_tools.handle_function_call(
        "tool_call", {"calls": [{"name": "device", "arguments": arguments}]}, enabled_toolsets=toolsets))
    assert off["code"] == "connector_off" and len(asked) == 2
