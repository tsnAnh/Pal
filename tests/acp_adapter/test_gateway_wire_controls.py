"""Additional real-wire controls for the ACP authority client."""

import pytest

from acp_adapter.server import HermesACPAgent
from hermes_cli.gateway_client import GatewayClientError
from tests.acp_adapter.test_gateway_sessions import viewer


@pytest.mark.platforms("linux")
@pytest.mark.asyncio
async def test_profile_mismatch_refuses_before_creation(daemon, tmp_path, monkeypatch):
    import acp_adapter.gateway_server as server
    agent = HermesACPAgent()
    agent._home = tmp_path / "foreign-profile"
    # A real authenticated connection to the wrong profile, not a fake descriptor.
    monkeypatch.setattr(server, "connect_gateway", lambda: viewer(daemon))
    with pytest.raises(GatewayClientError, match="profile_mismatch"):
        await agent.new_session(cwd=str(tmp_path))
    assert agent._gateway is None
    async with viewer(daemon) as ws:
        assert (await ws.rpc("session.list"))["sessions"] == []
