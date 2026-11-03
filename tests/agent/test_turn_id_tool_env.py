"""A tool subprocess learns the id of the turn that ran it, so a plugin's per-turn record can be matched to a command.

Real AIAgent turns against a local OpenAI-compatible stub, real terminal subprocesses, a recording ``pre_llm_call``
and ``pre_tool_call`` plugin: the id a command prints is the id the plugin saw.
"""

from __future__ import annotations

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from hermes_cli.plugins import get_plugin_manager
from tests.waiting import wait_until

TURN_ID_ENV = "HERMES_TURN_ID"


class StubModel:
    def __init__(self, script):
        self.script = script
        self.requests = []
        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                stub.requests.append(request)
                message = stub.script(request) or {"role": "assistant", "content": "DONE"}
                tool = "tool_calls" in message
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream" if request.get("stream") else "application/json")
                self.end_headers()
                if request.get("stream"):
                    if tool:
                        message["tool_calls"][0]["index"] = 0
                    for delta, finish in [(message, None), ({}, "tool_calls" if tool else "stop")]:
                        frame = {"id": "stub", "object": "chat.completion.chunk", "created": 1, "model": "stub",
                                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                        self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                else:
                    self.wfile.write(json.dumps({"id": "stub", "object": "chat.completion", "created": 1, "model": "stub",
                                                 "choices": [{"index": 0, "message": message,
                                                              "finish_reason": "tool_calls" if tool else "stop"}]}).encode())
                self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def tool_call(name, arguments, call_id="call-1"):
    return {"role": "assistant", "content": None, "tool_calls": [
        {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}


def tool_results(request):
    messages = request.get("messages", [])
    last_user = max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)
    return [m for m in messages[last_user + 1:] if m.get("role") == "tool"]


@pytest.fixture()
def hooks():
    seen = {"pre_llm_call": [], "pre_tool_call": []}
    manager = get_plugin_manager()

    def recorder(store):
        def record(**kwargs):
            store.append(kwargs)

        return record

    callbacks = {name: recorder(seen[name]) for name in seen}
    for name, callback in callbacks.items():
        manager._hooks.setdefault(name, []).append(callback)
    yield seen
    for name, callback in callbacks.items():
        manager._hooks[name].remove(callback)


@pytest.fixture()
def home(tmp_path, monkeypatch):
    config = {"agent": {"environment_probe": False}, "auxiliary": {"title_generation": {"enabled": False}},
              "terminal": {"backend": "local", "cwd": str(tmp_path)}}
    (tmp_path / "config.yaml").write_text(json.dumps(config))
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv(TURN_ID_ENV, raising=False)
    return tmp_path


def agent_for(stub, **kwargs):
    from run_agent import AIAgent

    return AIAgent(model="stub", provider="custom", base_url=stub.url, api_key="stub", quiet_mode=True,
                   save_trajectories=False, max_iterations=4, skip_memory=True, **kwargs)


def printed(result):
    outputs = [json.loads(m["content"]).get("output", "") for m in result["messages"] if m["role"] == "tool"]
    return outputs[-1].strip() if outputs else None


def terminal_script(command):
    def script(request):
        return None if tool_results(request) else tool_call("terminal", {"command": command})

    return script


def test_a_terminal_command_sees_the_turn_id_the_plugin_hooks_saw(home, hooks):
    stub = StubModel(terminal_script(f'printf "%s" "${TURN_ID_ENV}"'))
    try:
        agent = agent_for(stub, enabled_toolsets=["terminal"], platform="tui")
        result = agent.run_conversation("merge #1")
    finally:
        stub.close()
    turn_id = hooks["pre_llm_call"][0]["turn_id"]
    assert turn_id
    assert hooks["pre_tool_call"][0]["turn_id"] == turn_id
    assert printed(result) == turn_id
    assert TURN_ID_ENV not in os.environ


def test_each_turn_exports_its_own_id_and_none_outlives_the_turn(home, hooks):
    stub = StubModel(terminal_script(f'printf "%s" "${TURN_ID_ENV}"'))
    try:
        agent = agent_for(stub, enabled_toolsets=["terminal"], platform="tui")
        first = printed(agent.run_conversation("one"))
        second = printed(agent.run_conversation("two", conversation_history=[]))
    finally:
        stub.close()
    ids = [call["turn_id"] for call in hooks["pre_llm_call"]]
    assert [first, second] == ids
    assert first != second
    assert TURN_ID_ENV not in os.environ


def test_a_background_process_keeps_the_id_of_the_turn_that_started_it(home, hooks):
    def script(request):
        if tool_results(request):
            return None
        return tool_call("terminal", {"command": f'sleep 1; printf "%s" "${TURN_ID_ENV}" > {home}/late.txt',
                                      "background": True})

    stub = StubModel(script)
    try:
        agent = agent_for(stub, enabled_toolsets=["terminal"], platform="tui")
        agent.run_conversation("start a loop")
        late = home / "late.txt"
        assert wait_until(late.exists, timeout=15)
    finally:
        stub.close()
    assert late.read_text() == hooks["pre_llm_call"][0]["turn_id"]


def test_a_delegate_task_child_never_gets_a_turn_id(home, hooks):
    probe = home / "child.txt"

    def script(request):
        is_child = "CHILD_GOAL" in json.dumps(request["messages"][1:2])
        if is_child:
            if tool_results(request):
                return None
            return tool_call("terminal", {"command": f'printf "[%s]" "${{{TURN_ID_ENV}-unset}}" > {probe}'}, "child-call")
        return None if tool_results(request) else tool_call("delegate_task", {"goal": "CHILD_GOAL run the probe"})

    stub = StubModel(script)
    try:
        agent = agent_for(stub, enabled_toolsets=["terminal", "delegation"], platform="tui")
        agent.run_conversation("delegate it")
        assert wait_until(probe.exists, timeout=20)
    finally:
        stub.close()
    assert probe.read_text() == "[unset]"


@pytest.fixture()
def one_session():
    from tools.approval_context import reset_current_session_key, set_current_session_key

    token = set_current_session_key("turn-id-session")
    yield
    reset_current_session_key(token)


def execute_code_script(code):
    def script(request):
        return None if tool_results(request) else tool_call("execute_code", {"code": code})

    return script


def test_a_later_turns_execute_code_cell_sees_that_turns_id_not_the_one_the_kernel_started_in(home, hooks, one_session):
    stub = StubModel(execute_code_script(f'import os; print(os.environ.get("{TURN_ID_ENV}", "unset"))'))
    try:
        agent = agent_for(stub, enabled_toolsets=["code_execution"], platform="tui")
        first = printed(agent.run_conversation("one"))
        second = printed(agent.run_conversation("two", conversation_history=[]))
    finally:
        stub.close()
    ids = [call["turn_id"] for call in hooks["pre_llm_call"]]
    assert ids[0] != ids[1]
    assert [first, second] == ids
    assert TURN_ID_ENV not in os.environ


def test_a_delegate_task_childs_execute_code_cell_never_sees_a_turn_id_even_in_a_kernel_started_by_a_turn(home, hooks, one_session):
    probe = home / "child-cell.txt"
    cell = f'import os; open({str(probe)!r}, "w").write("[" + os.environ.get("{TURN_ID_ENV}", "unset") + "]")'

    def script(request):
        is_child = "CHILD_GOAL" in json.dumps(request["messages"][1:2])
        if is_child:
            return None if tool_results(request) else tool_call("execute_code", {"code": cell}, "child-call")
        if tool_results(request):
            return None
        if "delegate" in json.dumps(request["messages"][-1]):
            return tool_call("delegate_task", {"goal": "CHILD_GOAL run the cell"})
        return tool_call("execute_code", {"code": "x = 1"})

    stub = StubModel(script)
    try:
        agent = agent_for(stub, enabled_toolsets=["code_execution", "delegation"], platform="tui")
        agent.run_conversation("start the kernel")
        agent.run_conversation("delegate it", conversation_history=[])
        assert wait_until(probe.exists, timeout=20)
    finally:
        stub.close()
    assert probe.read_text() == "[unset]"
