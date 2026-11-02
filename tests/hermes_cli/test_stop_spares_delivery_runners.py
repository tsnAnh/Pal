import asyncio
import sys
from contextlib import asynccontextmanager

import pytest

import tools.process_registry as module
from hermes_cli import gateway_tools
from hermes_cli.cli_commands_session_tools import CLICommandsSessionToolsMixin
from hermes_cli.gateway_agent import GatewayAgent
from hermes_cli.gateway_connection import GatewayConnection
from tools.process_registry import InternalProcessPolicy, ProcessRegistry
from tui_gateway import server

SID = "local-stop"
SESSION_KEY = "chat-key"

pytestmark = pytest.mark.platforms("posix")


def _sleeper() -> str:
    return f"{sys.executable} -c 'import time; time.sleep(60)'"


@pytest.fixture()
def registry(monkeypatch):
    registry = ProcessRegistry()
    monkeypatch.setattr(module, "process_registry", registry)
    registry.user = registry.spawn_local(_sleeper(), task_id="t", session_key=SESSION_KEY)
    registry.runner = registry.spawn_local(
        _sleeper(), task_id="t", session_key=SESSION_KEY,
        internal_policy=InternalProcessPolicy(max_lifetime_seconds=3420))
    yield registry
    registry.kill_all()


class ServerBackedClient:
    def __init__(self):
        self.events = asyncio.Queue()
        self.calls = []

    async def rpc(self, method, *, _timeout=None, **params):
        self.calls.append(method)
        if method not in {"process.list", "process.stop", "process.kill"}:
            return {}
        reply = server.handle_request({"id": "r", "method": method, "params": {"session_id": SID, **params}})
        return reply["result"]


@pytest.fixture()
def attached(registry):
    server._sessions[SID] = {"session_key": SESSION_KEY, "history": [], "agent": object()}
    client = ServerBackedClient()

    @asynccontextmanager
    async def connect():
        yield client

    connection = GatewayConnection(connect=connect)
    connection.start(5)
    connection.state(SID)
    gateway_tools.bind(GatewayAgent(connection=connection, session_id=SID))
    yield client
    connection.close()
    gateway_tools._view = None
    server._sessions.pop(SID, None)


def test_local_stop_spares_runners(registry, capsys):
    CLICommandsSessionToolsMixin._handle_stop_command(object())

    out = capsys.readouterr().out
    assert "Stopping 1 background process(es)..." in out and "Stopped 1 process(es)." in out
    assert registry.user.exited and not registry.runner.exited


def test_attached_stop_spares_runners_with_the_same_message(registry, attached, capsys):
    CLICommandsSessionToolsMixin._handle_stop_command(object())

    out = capsys.readouterr().out
    assert "Stopping 1 background process(es)..." in out and "Stopped 1 process(es)." in out
    assert registry.user.exited and not registry.runner.exited


def test_status_bar_counts_only_what_stop_can_reach(registry):
    assert gateway_tools.background_counts()["active_background_processes"] == 1


def test_attached_status_bar_counts_only_what_stop_can_reach(registry, attached):
    gateway_tools.process_registry().list_sessions()

    assert gateway_tools.background_counts()["active_background_processes"] == 1
