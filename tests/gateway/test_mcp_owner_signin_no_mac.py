"""After the one-time Mac sign-in nothing needs the Mac: reads, token refresh and approved actions run from the
gateway-held tokens with only an iPhone chat attached, and that iPhone answers the approval card.

Invariants: the hand-over records nothing about the device that made it; once that device has left, a chat from
an iPhone session still reads, refreshes and runs an approved action; the card goes to the chat's own approving
subscriber whatever device kind it is, and a denied card runs nothing; a dead sign-in raises the Mac prompt to the
attached apps without holding the bot turn.
"""

import asyncio
import json
import time

import pytest

from gateway import auth_prompts
from gateway.reach_presence import ClientKind, slot_of
from gateway.session_context import clear_session_vars, set_session_vars
from gateway.session_controls import AuthorityConnection
from gateway.session_ingress import viewer_turn
from tests.gateway.device_tools_harness import connect_phone, device_id_for, home_of
from tests.gateway.test_auth_prompts import _required, _wait_for
from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner
from tests.tools.test_mcp_action_gate import _call, _register
from tests.tools.test_mcp_owner_signin_reauth import ROTATED, invalid_grant, refresh_grant, through_the_provider
from tools import approval, auth_required, mcp_action_gate
from tools.approval_context import reset_current_session_key, set_current_session_key
from tools.mcp_oauth import HermesTokenStorage

pytest_plugins = ('tests.gateway.device_tools_harness', 'tests.tools.test_mcp_action_gate')

HANDOVER = {
    'service': 'mcp:upwork', 'client_id': 'client-abc', 'redirect_uri': 'http://127.0.0.1:53682/callback',
    'token_endpoint': 'https://auth.upwork.example/oauth2/token', 'issuer': 'https://auth.upwork.example',
    'access_token': 'at-canary-5c1e90ab77d2', 'refresh_token': 'rt-canary-1b84e0d6f9a3', 'expires_in': 3600,
    'scope': 'read', 'token_type': 'Bearer'}


@pytest.fixture(autouse=True)
def clean_registry():
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    yield
    reset_manager_for_tests()
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


class IphoneChat:
    """A viewer turn in an iOS-source chat whose only approving subscriber is the iPhone's own connection."""

    def __init__(self, live, choice='once'):
        self.live, self.choice, self.cards = live, choice, []

    def __enter__(self):
        route = self.live.route
        self._viewer = viewer_turn.set(self.live)
        self._vars = set_session_vars(platform='ios', session_key=route, session_id=route)
        self._key = set_current_session_key(route)
        approval.register_gateway_notify(route, self._answer)
        return self

    def __exit__(self, *exc):
        approval.unregister_gateway_notify(self.live.route)
        reset_current_session_key(self._key)
        clear_session_vars(self._vars)
        viewer_turn.reset(self._viewer)

    def _answer(self, data):
        self.cards.append(dict(data))
        approval.resolve_gateway_approval(self.live.route, self.choice, request_id=data['request_id'])


def _expire(home):
    path = home / 'mcp-tokens' / 'upwork.json'
    data = json.loads(path.read_text())
    data['expires_at'] = time.time() - 10
    path.write_text(json.dumps(data))


def _mac_slots(authority):
    return [t for t in authority.events.values()
            if (slot := slot_of(t)) is not None and slot.device.kind is ClientKind.MAC]


@pytest.mark.asyncio
async def test_with_only_an_iphone_chat_attached_the_read_the_refresh_and_the_approved_action_run(
        tmp_path, monkeypatch, server):
    home = tmp_path / 'home'
    store, _runner, authority, _owner_connection = _owner(home, monkeypatch, {'model': {'default': 'm'}})
    authority.profile_id = str(home)
    mac = await connect_phone(authority, 'Mac', kind='mac')
    try:
        assert (await mac.call('auth.submit_oauth_tokens', HANDOVER))['result'] == {'ok': True}
        await mac.connection.close()
        assert _mac_slots(authority) == [], 'the signing-in Mac is gone'
        stored = ''.join(p.read_text() for p in (home / 'mcp-tokens').iterdir()) + (home / 'config.yaml').read_text()
        assert device_id_for('Mac') not in stored and 'Mac' not in stored, 'the credential records no device'

        phone = await connect_phone(authority, 'iPhone', kind='ios')
        live, policy = await _create(phone.connection, authority, 'chat', tmp_path, source='ios')
        assert policy.source == 'ios' and _mac_slots(authority) == []
        _register()
        token_requests, bearers = through_the_provider(server, refresh_grant)
        _expire(home)
        with IphoneChat(live) as chat:
            assert await asyncio.to_thread(_call, 'search_jobs', {'q': 'python'}) == {'result': 'ok'}
            assert await asyncio.to_thread(_call, 'submit_proposal', {'job_id': '~1', 'cover_letter': 'Hi'}) == {'result': 'ok'}
        assert len(token_requests) == 1 and bearers == ['Bearer at-after-refresh'] * 2
        assert len(chat.cards) == 1 and chat.cards[0]['draft']['subject'] == 'submit_proposal'
        assert json.loads((home / 'mcp-tokens' / 'upwork.json').read_text())['refresh_token'] == ROTATED
        assert _mac_slots(authority) == []
        with IphoneChat(live, choice='deny') as denied:
            result = await asyncio.to_thread(_call, 'submit_proposal', {'job_id': '~2'})
        assert result['code'] == mcp_action_gate.ACTION_DENIED and len(denied.cards) == 1
        assert server.call_tool.await_count == 2
    finally:
        store.close_all_db_handles()


@pytest.mark.asyncio
async def test_a_dead_sign_in_raises_the_mac_prompt_on_the_attached_apps_without_holding_the_turn(
        authorities, server, monkeypatch):
    authority = await authorities('home')
    home = home_of(authority)
    monkeypatch.setenv('HERMES_HOME', str(home))
    phone = await connect_phone(authority, 'iPhone', kind='ios')
    assert (await phone.call('auth.submit_oauth_tokens', HANDOVER))['result'] == {'ok': True}
    _register()
    token_requests, _ = through_the_provider(server, invalid_grant)
    _expire(home)

    def bot_turn():
        from tools import mcp_tool_handlers as handlers
        handler = handlers._make_tool_handler('upwork', 'search_jobs', 30.0)
        return [json.loads(auth_required.resolve('mcp_upwork_search_jobs', {}, handler({}), lambda: '{}'))
                for _ in range(3)]

    started = time.monotonic()
    results = await asyncio.to_thread(bot_turn)
    assert time.monotonic() - started < 10, 'no wait for the sign-in'
    assert [r.get('code') for r in results] == ['reauth_required'] * 3, results
    assert len(token_requests) == 1 and HermesTokenStorage('upwork', hermes_home=home).reauth_required()
    await _wait_for(lambda: len(_required(phone)) == 1)
    event = _required(phone)[0]
    assert event['service'] == 'mcp:upwork' and event['signin_on'] == 'owner_computer' and event['server'] == 'upwork'
    assert len(_required(phone)) == 1, 'repeated calls do not repeat the prompt'
    assert (await phone.call('auth.submit_oauth_tokens', HANDOVER))['result'] == {'ok': True}
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert not HermesTokenStorage('upwork', hermes_home=home).reauth_required()
