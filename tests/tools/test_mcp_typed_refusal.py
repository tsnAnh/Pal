"""A typed auth/permission refusal is a working server's answer: it never strikes the circuit breaker."""

import json
import sys

import pytest

SERVER = '''import json, sys, time
TOOLS = {
    "t3_thread_read": {"readOnlyHint": True},
    "device_list": {"readOnlyHint": True},
    "t3_preview_list": {"readOnlyHint": True},
    "t3_worktree_status": {"readOnlyHint": True},
    "plain_permission": {"readOnlyHint": True},
    "plain_failure": {"readOnlyHint": True},
    "slow": {"readOnlyHint": True},
    "data_with_code": {"readOnlyHint": True},
}
def reply(rid, result):
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
def refusal(code, text=None, structured=True):
    body = {"code": code, "message": text or code}
    out = {"isError": True, "content": [{"type": "text", "text": json.dumps(body)}]}
    if structured:
        out["structuredContent"] = body
    return out
for line in sys.stdin:
    req = json.loads(line)
    if "id" not in req:
        continue
    method = req["method"]
    if method == "initialize":
        reply(req["id"], {"protocolVersion": req["params"]["protocolVersion"],
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-t3", "version": "0.1.9"}})
    elif method == "tools/list":
        reply(req["id"], {"tools": [
            {"name": n, "description": n, "inputSchema": {"type": "object", "properties": {}},
             "annotations": a, "_meta": {"fake/env": "t3"}} for n, a in TOOLS.items()]})
    elif method == "tools/call":
        name = req["params"]["name"]
        if name in ("device_list", "t3_preview_list", "t3_worktree_status"):
            reply(req["id"], refusal("thread_credential_required"))
        elif name == "plain_permission":
            reply(req["id"], refusal("permission_denied", structured=False))
        elif name == "plain_failure":
            reply(req["id"], {"isError": True, "content": [{"type": "text", "text": "disk full"}]})
        elif name == "data_with_code":
            reply(req["id"], {"content": [{"type": "text", "text": "rows"}], "structuredContent": {"code": "forbidden", "rows": 1}})
        elif name == "slow":
            time.sleep(30)
        else:
            reply(req["id"], {"content": [{"type": "text", "text": "thread-list-ok"}]})
    else:
        reply(req["id"], {})
'''


@pytest.fixture
def fake_t3(tmp_path):
    from tools.mcp_tool_discovery import register_mcp_servers
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    path = tmp_path / "fake_t3_server.py"
    path.write_text(SERVER, encoding="utf-8")
    names = register_mcp_servers({"faket3": {"command": sys.executable, "args": [str(path)], "timeout": 1}})
    by_tool = {name.split("faket3_", 1)[1].lstrip("_"): name for name in names}
    assert {"t3_thread_read", "device_list", "slow", "plain_permission"} <= set(by_tool)
    try:
        yield by_tool
    finally:
        shutdown_mcp_servers()


def _call(tool):
    from tools.registry import registry

    return json.loads(registry.dispatch(tool, {}))


def _breaker_state():
    from tools import mcp_tool

    return {k: v for k, v in mcp_tool._server_error_counts.items() if v}, dict(mcp_tool._server_breaker_opened_at)


def test_thread_credential_refusals_never_open_the_breaker(fake_t3):
    for tool in ("device_list", "t3_preview_list", "t3_worktree_status", "device_list"):
        answer = _call(fake_t3[tool])
        assert answer["refusal"] == "thread_credential_required"
        assert answer["retryable"] is False
        assert answer["error"].startswith("needs a T3 Code thread: this tool only works from an agent running inside a T3 Code thread")
    assert _breaker_state() == ({}, {})
    assert _call(fake_t3["t3_thread_read"]) == {"result": "thread-list-ok"}


def test_other_permission_refusals_do_not_count(fake_t3):
    tool = fake_t3["plain_permission"]
    for _ in range(4):
        answer = _call(tool)
        assert answer["refusal"] == "permission_denied" and answer["retryable"] is False
    assert _breaker_state() == ({}, {})
    assert _call(fake_t3["t3_thread_read"]) == {"result": "thread-list-ok"}


def test_successful_data_that_carries_a_code_field_is_not_a_refusal(fake_t3):
    answer = _call(fake_t3["data_with_code"])
    assert "refusal" not in answer and "error" not in answer


def test_ordinary_tool_errors_still_count(fake_t3):
    for _ in range(3):
        assert "refusal" not in _call(fake_t3["plain_failure"])
    assert "rejected the last 3 calls" in _call(fake_t3["t3_thread_read"])["error"]


def test_real_timeouts_still_open_the_breaker(fake_t3):
    for _ in range(3):
        assert "refusal" not in _call(fake_t3["slow"])
    counts, opened = _breaker_state()
    assert list(counts.values()) == [3] and len(opened) == 1
    assert "unreachable after 3 consecutive failures" in _call(fake_t3["t3_thread_read"])["error"]
