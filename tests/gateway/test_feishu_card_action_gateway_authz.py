"""Feishu update-prompt card clicks with no Feishu allowlist or admins.

Setup's default leaves FEISHU_ALLOWED_USERS and the admin list empty (pairing mode). A click
must then pass the gateway authorization inbound messages get, and is refused when that check
denies or was never registered. A configured Feishu allowlist still decides on its own.
"""

import importlib.util
import sys
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


def _ensure_feishu_mocks():
    if importlib.util.find_spec("lark_oapi") is None and "lark_oapi" not in sys.modules:
        mod = MagicMock()
        for name in ("lark_oapi", "lark_oapi.api.im.v1", "lark_oapi.event", "lark_oapi.event.callback_type"):
            sys.modules.setdefault(name, mod)
    if importlib.util.find_spec("aiohttp") is None and "aiohttp" not in sys.modules:
        aio = MagicMock()
        sys.modules.setdefault("aiohttp", aio)
        sys.modules.setdefault("aiohttp.web", aio.web)


_ensure_feishu_mocks()

from gateway.config import PlatformConfig
import plugins.platforms.feishu.adapter as feishu_module
from plugins.platforms.feishu.adapter import FeishuAdapter


class _FakeCallBackCard:
    def __init__(self):
        self.type = None
        self.data = None


class _FakeP2Response:
    def __init__(self):
        self.card = None


@pytest.fixture(autouse=True)
def _patch_callback_card_types(monkeypatch):
    monkeypatch.setattr(feishu_module, "P2CardActionTriggerResponse", _FakeP2Response)
    monkeypatch.setattr(feishu_module, "CallBackCard", _FakeCallBackCard)


def _close_submitted_coro(coro, _loop):
    coro.close()
    return SimpleNamespace(add_done_callback=lambda *_args, **_kwargs: None)


def _make_adapter(*, allowed=(), admins=()) -> FeishuAdapter:
    adapter = FeishuAdapter(PlatformConfig(enabled=True))
    adapter._client = MagicMock()
    adapter._loop = MagicMock()
    adapter._loop.is_closed = MagicMock(return_value=False)
    adapter._allowed_group_users = set(allowed)
    adapter._admins = set(admins)
    adapter._update_prompt_state[2] = {"session_key": "sess-2", "message_id": "msg-2", "chat_id": "oc_group"}
    return adapter


class _GatewayCheck:
    """Stand-in for the runner's ``set_authorization_check`` callback."""

    def __init__(self, allowed_ids):
        self.allowed_ids = set(allowed_ids)
        self.seen = []

    def __call__(self, user_id, chat_type=None, chat_id=None, **_kw):
        self.seen.append((user_id, chat_type, chat_id))
        return user_id in self.allowed_ids


_gateway_check = _GatewayCheck


def _update_prompt_click(open_id):
    return SimpleNamespace(event=SimpleNamespace(
        token="tok", context=SimpleNamespace(open_chat_id="oc_group"),
        operator=SimpleNamespace(open_id=open_id),
        action=SimpleNamespace(tag="button", value={"hermes_update_prompt_action": "y", "update_prompt_id": 2}),
    ))


class TestNoFeishuAllowlist:


    def test_update_prompt_refused_when_gateway_denies(self):
        adapter = _make_adapter()
        adapter.set_authorization_check(_gateway_check(set()))

        with patch("asyncio.run_coroutine_threadsafe") as submit:
            response = adapter._on_card_action_trigger(_update_prompt_click("ou_bystander"))

        assert response.card is None
        submit.assert_not_called()
        assert 2 in adapter._update_prompt_state


    @pytest.mark.asyncio
    async def test_non_approval_card_action_still_routes(self):
        adapter = _make_adapter()
        adapter._default_group_policy = "open"  # admitted by the chat; only the approval gate is absent
        data = SimpleNamespace(event=SimpleNamespace(
            token="tok_other", context=SimpleNamespace(open_chat_id="oc_group"),
            operator=SimpleNamespace(open_id="ou_bystander"),
            action=SimpleNamespace(tag="button", value={"custom_action": "x"}),
        ))
        with (
            patch.object(adapter, "_resolve_sender_profile", new_callable=AsyncMock,
                         return_value={"user_id": "ou_bystander", "user_name": "B", "user_id_alt": None}),
            patch.object(adapter, "get_chat_info", new_callable=AsyncMock, return_value={"name": "Chat"}),
            patch.object(adapter, "_handle_message_with_guards", new_callable=AsyncMock) as handle,
        ):
            await adapter._handle_card_action_event(data)

        handle.assert_called_once()



class TestFeishuAllowlistMatchesEveryOperatorId:
    """A Feishu list may name a user by any id intake accepts (open_id / user_id / union_id)."""


    @pytest.mark.asyncio
    async def test_update_prompt_recheck_matches_tenant_user_id(self, tmp_path, monkeypatch):
        monkeypatch.setenv("HERMES_HOME", str(tmp_path))
        adapter = _make_adapter(allowed={"u_tenant"})

        await adapter._resolve_update_prompt(2, "y", "Alice", open_id="ou_x", chat_id="oc_group", user_id="u_tenant")

        assert 2 not in adapter._update_prompt_state
