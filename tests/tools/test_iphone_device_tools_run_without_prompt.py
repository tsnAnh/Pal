"""A write action on the owner's iPhone or Mac reaches the device with no approval step in between."""

import json
from types import SimpleNamespace

import pytest

from gateway import device_tools
from gateway.device_actions import ACTIONS
from tools import devices_tool, iphone_tool
from tools.terminal_tool import set_approval_callback


@pytest.fixture
def reached(monkeypatch):
    calls = []
    monkeypatch.setattr(device_tools, "call_from_thread",
                        lambda *a, **k: calls.append(a) or SimpleNamespace(ok=True, data={"done": True}))
    asked = []
    set_approval_callback(lambda command, description, **kw: asked.append(command) or "deny")
    yield calls, asked
    set_approval_callback(None)


def test_iphone_write_action_executes_without_asking(reached, monkeypatch):
    calls, asked = reached
    monkeypatch.setattr(device_tools, "preflight", lambda home, spec: None)
    monkeypatch.setattr(device_tools, "settings", lambda home: None)
    result = json.loads(iphone_tool.iphone_tool({"action": "reminders.add", "args": {"title": "Milk"}}))
    assert result["success"] is True
    assert len(calls) == 1 and asked == []


def test_device_write_action_executes_without_asking(reached, monkeypatch):
    from tui_gateway.contracts.canonical_device import DeviceConnectorState

    calls, asked = reached
    spec = ACTIONS["shell.run"]
    view = SimpleNamespace(kind="mac", label="Studio Mac", type="Mac", online=True, device_id="dev-1",
                           last_seen_at=0.0, connectors={spec.connector.value: DeviceConnectorState.ASK})
    monkeypatch.setattr(devices_tool, "_bound", lambda home: object())
    monkeypatch.setattr(devices_tool, "_resolved", lambda *a: (view, None))
    monkeypatch.setattr(devices_tool, "_checked", lambda *a: None)
    result = json.loads(devices_tool.device_tool({"device": "Studio Mac", "action": "shell.run", "args": {"command": "ls"}}))
    assert result["success"] is True
    assert len(calls) == 1 and asked == []
