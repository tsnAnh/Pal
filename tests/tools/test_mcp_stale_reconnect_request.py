from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from tools.mcp_tool import _MCP_AVAILABLE, MCPServerTask

pytestmark = pytest.mark.skipif(not _MCP_AVAILABLE, reason="MCP SDK not installed")


@pytest.mark.asyncio
async def test_a_reconnect_request_made_while_the_server_was_down_does_not_tear_down_the_session_it_got():
    task = MCPServerTask("stale-request")
    task._negotiate_session = AsyncMock(return_value=MagicMock())
    task._discover_tools = AsyncMock()
    seen = []

    async def lifecycle():
        seen.append(task._reconnect_event.is_set())
        return "shutdown"

    task._wait_for_lifecycle_event = lifecycle
    task._reconnect_event.set()
    with patch("tools.mcp_tool_transport._events.start_refresh_task", return_value=None):
        assert await task._serve_session(MagicMock(), 5.0) == "shutdown"
    assert seen == [False]
    assert task._ready.is_set()
