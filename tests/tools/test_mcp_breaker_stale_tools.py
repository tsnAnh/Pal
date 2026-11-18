"""T3 Code 0.1.10 shapes: per-call JSON-RPC errors never open the breaker, and a reconnect refreshes the tool list."""

import json
import sys
import time

import pytest

SERVER = '''import json, os, sys, time
STATE = sys.argv[1]
GEN = open(STATE).read().strip() if os.path.exists(STATE) else "v1"
if GEN == "down":
    time.sleep(3600)
TOOLS = ["t3_thread_list", "device_list", "t3_preview_list", "t3_worktree_status", "t3_thread_read",
         "bad_params", "internal", "unknown_method", "restart"]
REMOVED = ("device_list", "t3_preview_list", "t3_worktree_status") if GEN in ("v2", "stale") else ()
if GEN == "v2":
    TOOLS = [t for t in TOOLS if t not in REMOVED] + ["t3_new"]
def send(obj):
    print(json.dumps(obj), flush=True)
def error(rid, code, message):
    send({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})
for line in sys.stdin:
    req = json.loads(line)
    if "id" not in req:
        continue
    rid, method = req["id"], req["method"]
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": req["params"]["protocolVersion"],
              "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-t3", "version": "0.1.10"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": rid, "result": {"tools": [
            {"name": n, "description": n, "inputSchema": {"type": "object", "properties": {}},
             "annotations": {"readOnlyHint": True}} for n in TOOLS]}})
    elif method == "tools/call":
        name = req["params"]["name"]
        if name not in TOOLS or name in REMOVED or name == "unknown_method":
            error(rid, -32602 if name != "unknown_method" else -32601, f"MCP error: Tool '{name}' not found")
        elif name == "bad_params":
            error(rid, -32602, "Invalid arguments for tool bad_params")
        elif name == "internal":
            error(rid, -32603, "Internal error")
        elif name == "t3_thread_read":
            body = {"code": "thread_credential_required", "message": "needs a thread"}
            send({"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "structuredContent": body,
                  "content": [{"type": "text", "text": json.dumps(body)}]}})
        elif name == "restart":
            send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "bye"}]}})
            sys.exit(0)
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text", "text": "thread-list-ok"}]}})
    else:
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
'''


@pytest.fixture
def fake_t3(tmp_path, request):
    from tools.mcp_tool_discovery import register_mcp_servers
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    path, state = tmp_path / "fake_t3_server.py", tmp_path / "state"
    path.write_text(SERVER, encoding="utf-8")
    state.write_text(getattr(request, "param", "v1"))
    register_mcp_servers({"faket3": {"command": sys.executable, "args": [str(path), str(state)], "timeout": 1}})
    try:
        yield state
    finally:
        shutdown_mcp_servers()


def _names():
    from tools.registry import registry

    return {n.split("faket3_", 1)[1].lstrip("_"): n for n in registry.get_tool_names_for_toolset("mcp-faket3")}


def _call(tool):
    from tools.registry import registry

    return json.loads(registry.dispatch(tool, {}))


def _breaker_state():
    from tools import mcp_tool

    return {k: v for k, v in mcp_tool._server_error_counts.items() if v}, dict(mcp_tool._server_breaker_opened_at)


def _restart(state, gen):
    state.write_text(gen)
    before = set(_names())
    _call(_names()["restart"])
    _call(_names()["t3_thread_list"])
    for _ in range(50):
        if set(_names()) != before:
            return _names()
        time.sleep(0.1)
    return _names()


@pytest.mark.parametrize("fake_t3", ["stale"], indirect=True)
def test_tool_not_found_errors_never_open_the_breaker(fake_t3):
    names = _names()
    for tool in ("device_list", "t3_preview_list", "t3_worktree_status", "unknown_method"):
        assert "not found" in _call(names[tool])["error"]
    assert _breaker_state() == ({}, {})
    assert _call(names["t3_thread_list"]) == {"result": "thread-list-ok"}


def test_other_per_call_error_shapes_do_not_count(fake_t3):
    names = _names()
    for tool in ("bad_params", "internal", "bad_params", "internal"):
        assert "error" in _call(names[tool])
    assert _call(names["t3_thread_read"])["refusal"] == "thread_credential_required"
    assert _breaker_state() == ({}, {})
    assert _call(names["t3_thread_list"]) == {"result": "thread-list-ok"}


def test_reconnect_with_a_smaller_list_withdraws_removed_tools(fake_t3):
    old = _names()
    assert {"device_list", "t3_preview_list", "t3_worktree_status"} <= set(old)
    new = _restart(fake_t3, "v2")
    assert not {"device_list", "t3_preview_list", "t3_worktree_status"} & set(new)
    after_restart = _breaker_state()
    for tool in ("device_list", "t3_preview_list", "t3_worktree_status", "device_list"):
        answer = _call(old[tool])
        assert answer["error"] == f"{old[tool]} is no longer offered by faket3; its tool list was refreshed"
        assert answer["retryable"] is False
    assert _breaker_state() == after_restart
    assert _call(new["t3_thread_list"]) == {"result": "thread-list-ok"}


def test_reconnect_registers_an_added_tool(fake_t3):
    assert "t3_new" not in _names()
    new = _restart(fake_t3, "v2")
    assert _call(new["t3_new"]) == {"result": "thread-list-ok"}


def test_transport_failures_still_open_the_breaker(fake_t3, monkeypatch):
    from tools import mcp_tool

    monkeypatch.setattr(mcp_tool, "_STDIO_RESPAWN_WAIT_SEC", 2)
    names = _names()
    fake_t3.write_text("down")
    _call(names["restart"])
    for _ in range(3):
        assert "error" in _call(names["t3_thread_list"])
    counts, opened = _breaker_state()
    assert list(counts.values()) == [3] and len(opened) == 1
    assert mcp_tool._CIRCUIT_BREAKER_COOLDOWN_SEC == 60.0
    assert "unreachable after 3 consecutive failures" in _call(names["t3_thread_list"])["error"]
