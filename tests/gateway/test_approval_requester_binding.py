"""Who may answer a shared-chat exec approval, per ``approvals.approvers`` in config.yaml.

Default (``["*"]``, or the key absent): any admitted member answers, exactly as before.
Opt-in (``[]`` or a list of ids): another member's /approve (or a button click, which runs
the same check) gets "Only <requester> can answer this approval." and the command stays pending.
"""

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest
import hermes_yaml as yaml

from gateway.config import GatewayConfig, Platform, PlatformConfig
from gateway.platforms.event import MessageEvent
from gateway.session import SessionSource

DEFAULT = "<no approvers key>"


def _runner(extra=None):
    from gateway.run import GatewayRunner

    runner = object.__new__(GatewayRunner)
    runner.config = GatewayConfig(platforms={Platform.TELEGRAM: PlatformConfig(
        enabled=True, token="***", extra=extra or {})})
    adapter = MagicMock()
    adapter.send = AsyncMock()
    runner.adapters = {Platform.TELEGRAM: adapter}
    runner.hooks = SimpleNamespace(emit=AsyncMock(), loaded_hooks=False)
    runner.session_store = MagicMock()
    runner._running_agents = {}
    runner._background_tasks = set()
    return runner


def _event(text, user_id, user_name):
    # thread_id makes this a shared thread session: everyone in it maps to one session key.
    return MessageEvent(text=text, message_id="m1", source=SessionSource(
        platform=Platform.TELEGRAM, chat_id="-100group", chat_type="group", thread_id="t1",
        user_id=user_id, user_name=user_name))


def write_approvers(approvers):
    """Write the profile's config.yaml as a user would (``DEFAULT`` leaves the key out)."""
    from hermes_constants import get_hermes_home

    approvals = {"mode": "manual", **({} if approvers == DEFAULT else {"approvers": approvers})}
    (get_hermes_home() / "config.yaml").write_text(yaml.safe_dump({"approvals": approvals}), encoding="utf-8")


def pending_from(user_id, user_name, session_key, platform="telegram"):
    """Enqueue an approval the way the agent thread does, inside the requester's turn, with its card
    shown whole (the Deny-only mark lifted)."""
    from gateway.session_context import clear_session_vars, set_session_vars
    from tools import approval as approval_mod
    from tools.approval_gateway_wait import _ApprovalEntry

    tokens = set_session_vars(platform=platform, user_id=user_id, user_name=user_name, session_key=session_key)
    try:
        entry = _ApprovalEntry({"command": "rm -rf build"})
    finally:
        clear_session_vars(tokens)
    approval_mod._gateway_queues.setdefault(session_key, []).append(entry)
    approval_mod.restrict_gateway_approval_card_to_deny(session_key, entry.data["request_id"], restricted=False)
    return entry


@pytest.fixture(autouse=True)
def _clean_queues():
    from tools import approval as approval_mod

    approval_mod._gateway_queues.clear()
    yield
    approval_mod._gateway_queues.clear()


