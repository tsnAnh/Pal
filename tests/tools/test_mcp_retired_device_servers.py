from __future__ import annotations

import hermes_yaml as yaml
import pytest

from hermes_cli import mcp_config
from hermes_cli.config import load_config
from hermes_constants import get_hermes_home
from tools import mcp_tool_config, mcp_tool_discovery
from tui_gateway import server

STALE = {"transport": "device", "device_id": "device-Mac-0000", "server": "t3code"}
NOTES = {"url": "https://notes.example.invalid/mcp", "transport": "http", "enabled": True}
T3_URL = "http://100.101.102.103:3773/mcp"


def _write(servers: dict) -> None:
    (get_hermes_home() / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": servers}))


def _saved() -> dict:
    return yaml.safe_load((get_hermes_home() / "config.yaml").read_text())["mcp_servers"]


def test_a_stale_device_entry_is_dropped_and_the_normal_server_is_still_discovered(monkeypatch):
    _write({"t3code": STALE, "notes": NOTES})
    discovered = []
    monkeypatch.setattr(mcp_tool_discovery, "discover_mcp_tools", lambda *a, **k: discovered.append(True) or [])

    assert set(mcp_tool_config._load_mcp_config()) == {"notes"}
    assert _saved() == {"notes": NOTES}

    assert mcp_tool_discovery.reconcile_mcp_servers_with_config()["added"] == ["notes"]
    assert discovered


def test_adding_t3code_over_a_stale_device_entry_saves_a_plain_http_server():
    _write({"t3code": STALE})

    response = server._methods["mcp.servers.add"](1, {"name": "t3code", "config": {"url": T3_URL, "transport": "http"}})

    assert "error" not in response, response
    saved = _saved()["t3code"]
    assert saved["url"] == T3_URL and saved["transport"] == "http"
    assert not {"device_id", "server"} & set(saved)


def test_a_config_without_retired_entries_is_not_rewritten():
    _write({"notes": NOTES})
    path = get_hermes_home() / "config.yaml"
    before = path.stat().st_mtime_ns, path.read_bytes()

    assert set(mcp_tool_config._load_mcp_config()) == {"notes"}
    assert set(mcp_config._get_mcp_servers()) == {"notes"}

    assert (path.stat().st_mtime_ns, path.read_bytes()) == before


def test_an_entry_that_has_a_url_is_never_taken_for_the_retired_transport():
    kept = {"url": T3_URL, "transport": "device"}
    _write({"odd": kept})

    mcp_tool_config._load_mcp_config()

    assert _saved() == {"odd": kept}



@pytest.mark.parametrize("entry", [None, "t3code", []])
def test_a_malformed_entry_is_left_alone(entry):
    _write({"broken": entry, "notes": NOTES})

    assert "notes" in mcp_tool_config._load_mcp_config()
    assert "broken" in _saved()
