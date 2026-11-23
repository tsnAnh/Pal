import asyncio
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from tools import mcp_tool
from tools import mcp_tool_handlers as handlers
from tools.mcp_tool import MCPServerTask

CALLS = 2
WAIT_SECONDS = 5


@pytest.fixture
def mcp_loop():
    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()

    def run_on_loop(coro_or_factory, timeout=30):
        coro = coro_or_factory() if callable(coro_or_factory) else coro_or_factory
        return asyncio.run_coroutine_threadsafe(coro, loop).result(timeout)

    with patch("tools.mcp_tool_loop._run_on_mcp_loop", side_effect=run_on_loop), \
         patch.dict(mcp_tool._servers, {}, clear=True), \
         patch.dict(mcp_tool._server_error_counts, {}, clear=True), \
         patch.dict(mcp_tool._server_trust_levels, {"srv": "full"}), \
         patch.dict(mcp_tool._tool_read_only_hints, {}, clear=True):
        yield loop
    loop.call_soon_threadsafe(loop.stop)
    thread.join()
    loop.close()


class RendezvousSession:

    def __init__(self):
        self.entered = 0
        self.together = asyncio.Event()

    async def call_tool(self, name, arguments=None, **kwargs):
        self.entered += 1
        if self.entered == CALLS:
            self.together.set()
        await asyncio.wait_for(self.together.wait(), WAIT_SECONDS)
        return SimpleNamespace(content=[SimpleNamespace(type="text", text="ok")], isError=False,
                               structuredContent=None)


def _connected(config, session):
    server = MCPServerTask("srv")
    server._config = config
    server.session = session
    mcp_tool._servers["srv"] = server
    return server


def test_two_bots_calls_are_in_flight_together_on_one_http_connection(mcp_loop):
    _connected({"url": "https://mcp.example/x"}, RendezvousSession())
    handler = handlers._make_tool_handler("srv", "tool", WAIT_SECONDS * 3)

    with ThreadPoolExecutor(CALLS) as pool:
        results = [json.loads(raw) for raw in pool.map(lambda _: handler({}), range(CALLS))]

    assert all("error" not in result for result in results), results


def test_a_stdio_connection_runs_calls_one_at_a_time(mcp_loop):
    server = _connected({"command": "mcp-server"}, None)
    state = {"active": 0, "most": 0}

    async def call():
        async with server._rpc_lock.shared():
            state["active"] += 1
            state["most"] = max(state["most"], state["active"])
            for _ in range(5):
                await asyncio.sleep(0)
            state["active"] -= 1

    async def both():
        await asyncio.gather(*(call() for _ in range(CALLS)))

    asyncio.run_coroutine_threadsafe(both(), mcp_loop).result(WAIT_SECONDS)
    assert state["most"] == 1
