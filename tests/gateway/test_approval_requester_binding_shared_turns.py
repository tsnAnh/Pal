"""``approvals.approvers: []`` binds an approval to the member who asked, also in a Telegram observe-mode
group (whose session route has no user), never to the first of two members whose texts one turn merged,
and never to "anyone" when no requester could be recorded. A Discord DM-only admin answers DM approvals,
not group ones, on the buttons exactly as on ``/approve``.
"""

from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from gateway.config import GatewayConfig, PlatformConfig
from gateway.platforms.event import MessageType
from gateway.session import build_session_context, build_session_key
from gateway.session_context import _UNSET, _VAR_MAP
from tests.gateway.test_approval_requester_binding import DEFAULT, write_approvers
from tests.gateway.test_telegram_group_gating import _group_message, _make_adapter, _mention_entity


@pytest.fixture(autouse=True)
def _clean_state():
    from tools import approval as approval_mod

    approval_mod._gateway_queues.clear()
    yield
    approval_mod._gateway_queues.clear()
    for var in _VAR_MAP.values():
        var.set(_UNSET)


def _observed_event(adapter, uid, name, body):
    text = f"@hermes_bot {body}"
    msg = _group_message(text, from_user_id=uid, from_user_name=name, entities=[_mention_entity(text)])
    return adapter._apply_telegram_group_observe_attribution(adapter._build_message_event(msg, MessageType.TEXT))


def _approval_raised_in(event):
    """The approval the agent raises inside *event*'s turn, through the gateway's real session binding."""
    from gateway.run import GatewayRunner
    from tools import approval as approval_mod
    from tools.approval_gateway_wait import _ApprovalEntry

    key = build_session_key(event.source)
    runner = object.__new__(GatewayRunner)
    tokens = runner._set_session_env(build_session_context(event.source, GatewayConfig(), event=event))
    try:
        entry = _ApprovalEntry({"command": "rm -rf notes"})
    finally:
        runner._clear_session_env(tokens)
    approval_mod._gateway_queues.setdefault(key, []).append(entry)
    return key


def _observe_adapter():
    return _make_adapter(require_mention=True, allowed_chats=["-100"], group_allowed_chats=["-100"],
                         observe_unmentioned_group_messages=True)


