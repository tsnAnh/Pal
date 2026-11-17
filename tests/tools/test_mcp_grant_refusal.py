"""T3 Code 0.1.10 grant refusals (capability_denied, *_escalation_denied) are typed refusals, never strikes."""

import json
import sys

import pytest

SERVER = '''import json, sys
CODES = ["capability_denied", "runtime_mode_escalation_denied", "sandbox_escalation_denied",
         "connection_denied", "write_denied"]
SHAPES = ["structured", "json", "lead"]
TOOLS = [f"{c}__{s}" for c in CODES for s in SHAPES] + ["ok", "prose_denied"]
def reply(rid, result):
    print(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}), flush=True)
def answer(name):
    if name == "ok":
        return {"content": [{"type": "text", "text": "thread-list-ok"}]}
    if name == "prose_denied":
        return {"isError": True, "content": [{"type": "text", "text": "write denied by the filesystem"}]}
    code, shape = name.split("__")
    body = {"code": code, "message": "secret-free-text"}
    if shape == "structured":
        return {"isError": True, "structuredContent": body, "content": [{"type": "text", "text": "x"}]}
    if shape == "json":
        return {"isError": True, "content": [{"type": "text", "text": json.dumps(body)}]}
    return {"isError": True, "content": [{"type": "text", "text": f"{code}: secret-free-text"}]}
for line in sys.stdin:
    req = json.loads(line)
    if "id" not in req:
        continue
    method = req["method"]
    if method == "initialize":
        reply(req["id"], {"protocolVersion": req["params"]["protocolVersion"],
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-t3", "version": "0.1.10"}})
    elif method == "tools/list":
        reply(req["id"], {"tools": [{"name": n, "description": n, "inputSchema": {"type": "object", "properties": {}},
                                     "annotations": {"readOnlyHint": True}} for n in TOOLS]})
    elif method == "tools/call":
        reply(req["id"], answer(req["params"]["name"]))
    else:
        reply(req["id"], {})
'''

GRANT_CODES = ("capability_denied", "runtime_mode_escalation_denied", "sandbox_escalation_denied")
SHAPES = ("structured", "json", "lead")


@pytest.fixture
def fake_t3(tmp_path):
    from tools.mcp_tool_discovery import register_mcp_servers
    from tools.mcp_tool_lifecycle import shutdown_mcp_servers

    path = tmp_path / "fake_t3_grant_server.py"
    path.write_text(SERVER, encoding="utf-8")
    names = register_mcp_servers({"faket3g": {"command": sys.executable, "args": [str(path)], "timeout": 1}})
    by_tool = {name.split("faket3g_", 1)[1].lstrip("_"): name for name in names}
    assert "ok" in by_tool
    try:
        yield by_tool
    finally:
        shutdown_mcp_servers()


def _call(tool):
    from tools.registry import registry

    return json.loads(registry.dispatch(tool, {}))


@pytest.mark.parametrize("code", GRANT_CODES)
@pytest.mark.parametrize("shape", SHAPES)
def test_grant_refusals_never_strike(fake_t3, code, shape):
    for _ in range(3):
        answer = _call(fake_t3[f"{code}__{shape}"])
        assert answer["refusal"] == code and answer["retryable"] is False
        assert "read-only or lacks the capability" in answer["error"]
        assert "do not retry" in answer["error"].lower() and "escalate" in answer["error"]
        assert "secret-free-text" not in answer["error"]
    assert _call(fake_t3["ok"]) == {"result": "thread-list-ok"}


@pytest.mark.parametrize("tool", ["connection_denied__lead", "write_denied__structured", "prose_denied"])
def test_other_denied_looking_errors_still_strike(fake_t3, tool):
    for _ in range(3):
        assert "refusal" not in _call(fake_t3[tool])
    assert "rejected the last 3 calls" in _call(fake_t3["ok"])["error"]
