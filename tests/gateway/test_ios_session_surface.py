"""The iPhone creates sessions as its own surface: platform ``ios``, the phone's prompt hint, and none of the
Desktop's client toolsets."""
from types import SimpleNamespace

import pytest

from tests.gateway.test_session_create_tier_cwd import _owner


async def _create(owner, authority, request_id, cwd, **extra):
    from gateway.session_policy import policy_for_source
    response = await owner.dispatch({'id': request_id, 'method': 'session.create', 'params': dict(
        request_id=request_id, cwd=str(cwd), model='m', **extra)})
    if 'error' in response:
        return response['error']['data']['reason']
    live = authority.sessions[response['result']['session_id']]
    return live, policy_for_source(authority.runner, live.source)


@pytest.mark.asyncio
async def test_ios_source_creates_an_ios_platform_session_without_desktop_surface_toolsets(tmp_path, monkeypatch):
    from toolsets import CLIENT_SURFACE_TOOLSETS
    store, _runner, authority, owner = _owner(tmp_path / 'home', monkeypatch, {'model': {'default': 'm'}})
    try:
        _, phone = await _create(owner, authority, 'phone', tmp_path, source='ios')
        _, desktop = await _create(owner, authority, 'desk', tmp_path, source='gui')
        assert (phone.source, phone.platform) == ('ios', 'ios')
        assert (desktop.source, desktop.platform) == ('gui', 'desktop')
        assert not set(phone.toolsets) & CLIENT_SURFACE_TOOLSETS
        assert set(desktop.toolsets) & CLIENT_SURFACE_TOOLSETS
        assert await _create(owner, authority, 'ui', tmp_path, source='ios', toolsets=['desktop_ui']) == 'invalid_params'
        described = (await owner.dispatch({'id': 'd', 'method': 'runtime.describe', 'params': {}}))['result']
        assert 'ios' in described['session_create']['sources'] and 'reach-v1' in described['capabilities']
    finally:
        await owner.close()
        store.close_all_db_handles()


def test_an_ios_session_is_listed_under_its_own_label():
    from gateway.session_policy import STORED_AS_LOCAL, SURFACE_GROUPS, created_surface
    assert created_surface('ios') == 'ios' and 'ios' in STORED_AS_LOCAL and SURFACE_GROUPS['ios'] == {'ios'}


def test_the_ios_prompt_hint_is_phone_shaped_and_names_no_desktop_widgets():
    from agent.system_prompt import platform_hint
    hint = platform_hint(SimpleNamespace(platform='ios', _platform_hint_overrides=None))
    assert 'iPhone' in hint and 'inline Markdown' in hint
    assert '::preview{' not in hint and 'Download and preview buttons' not in hint


def test_a_phone_turn_is_attended_and_not_a_messaging_chat():
    from agent.session_source import is_attended
    from gateway.session_context import NON_MESSAGING_SESSION_SURFACES
    assert is_attended(SimpleNamespace(platform='ios')) is True
    assert 'ios' in NON_MESSAGING_SESSION_SURFACES
