"""A Pal connection driving its own MCP operations never reaches the hosted connector stack.

The same gateway process serves Desktop and Pal, so the operation RPCs gate hosted behaviour by
the operation's own kind. Every module that talks to the Nous portal is replaced by a sentinel that
records and refuses any attribute read.
"""

from __future__ import annotations

import threading
from contextlib import ExitStack

import pytest

from tests.tools.nous_sentinels import install_sentinels
from tests.tui_gateway.test_connector_operation_rpc import PipeClient, SID, _rpc
from tools.connectors import live
from tools.connectors.contract import Actor, TargetState
from tools.connectors.operation import ConnectionOperation, Target
from tui_gateway import server


@pytest.fixture
def nous_sentinels(monkeypatch):
    return install_sentinels(monkeypatch)


@pytest.fixture
def pal_session(monkeypatch):
    live._open.clear()
    with ExitStack() as stack:
        client = PipeClient(stack)
        session = dict(transport=client.transport, agent=None, session_key=SID, history=[],
                       history_lock=threading.Lock(), history_version=0, running=False,
                       attached_images=[], source="ios")
        monkeypatch.setitem(server._sessions, SID, session)
        yield client
    live._open.clear()


def open_mcp_operation():
    operation = ConnectionOperation([Target("linear", "mcp", "install"), Target("notion", "mcp", "install")],
                                    session_key=SID)
    live.open(operation)
    return operation


def test_status_wake_and_respond_of_a_pal_mcp_operation_never_touch_a_nous_module(pal_session, nous_sentinels):
    operation = open_mcp_operation()
    operation.transition("linear", TargetState.initiated, Actor.backend_watcher)

    status = _rpc(pal_session, "connectors.operation.status", op_id=operation.op_id)
    assert status["result"]["op_id"] == operation.op_id

    operation.wake.clear()
    woke = _rpc(pal_session, "connectors.operation.wake", op_id=operation.op_id)
    assert woke["result"] == {"status": "ok"}
    assert operation.wake.is_set()

    answered = _rpc(pal_session, "connection.respond", op_id=operation.op_id,
                    result={"targets": [{"name": "notion", "status": "skipped"}]})
    assert answered["error"]["data"]["reason"] == "INVALID_ANSWER", answered
    assert operation.target("notion").state == TargetState.pending

    assert nous_sentinels == []


def test_an_account_owned_request_for_a_pal_mcp_operation_needs_no_hosted_gate(pal_session, nous_sentinels):
    operation = open_mcp_operation()

    response = server.dispatch({"jsonrpc": "2.0", "id": 9, "method": "connectors.operation.status",
                                "params": {"owner": {"type": "account", "source": "ios"}, "op_id": operation.op_id}},
                               pal_session.transport)

    assert response["result"]["op_id"] == operation.op_id
    assert nous_sentinels == []
