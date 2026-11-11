import pytest

from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner


@pytest.mark.asyncio
async def test_only_iphone_app_sessions_carry_the_iphone_toolset(tmp_path, monkeypatch):
    store, _runner, authority, owner = _owner(tmp_path / 'home', monkeypatch, {'model': {'default': 'm'}})
    try:
        _, phone = await _create(owner, authority, 'phone', tmp_path, source='ios')
        _, desktop = await _create(owner, authority, 'desk', tmp_path, source='gui')
        _, terminal = await _create(owner, authority, 'tui', tmp_path, source='tui')
        assert 'iphone' in phone.toolsets
        assert 'iphone' not in desktop.toolsets and 'iphone' not in terminal.toolsets
    finally:
        await owner.close()
        store.close_all_db_handles()


def test_the_resolver_folds_iphone_into_ios_only_and_honours_a_disabled_toolset():
    from gateway.session_policy import _resolve_toolsets
    assert 'iphone' in _resolve_toolsets({}, {}, 'ios', False)
    assert 'iphone' not in _resolve_toolsets({}, {'agent': {'disabled_toolsets': ['iphone']}}, 'ios', False)
    assert 'iphone' not in _resolve_toolsets({}, {}, 'gui', False)
    assert 'iphone' not in _resolve_toolsets({'toolsets': ['web']}, {}, 'ios', False)


def test_other_surfaces_drop_the_iphone_tool_whatever_their_toolsets_resolve_to():
    from toolsets import session_platform_tool_drops
    import tools.iphone_tool
    assert 'iphone' in session_platform_tool_drops('telegram')
    assert 'iphone' in session_platform_tool_drops('desktop')
    assert 'iphone' not in session_platform_tool_drops('ios')


def test_the_iphone_tool_belongs_to_a_toolset_and_to_no_default_bundle():
    from toolsets import TOOLSETS, resolve_toolset
    assert sorted(resolve_toolset('iphone')) == ['device', 'devices_list', 'iphone']
    assert all(not {'iphone', 'device', 'devices_list'} & set(resolve_toolset(name)) for name in TOOLSETS if name.startswith('hermes-'))
