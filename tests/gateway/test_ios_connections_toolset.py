import pytest

from tests.gateway.test_ios_session_surface import _create
from tests.gateway.test_session_create_tier_cwd import _owner


def offered_tools(authority, policy, session_id):
    import model_tools
    from gateway.session_policy import policy_turn_toolsets
    from toolsets import session_disabled_toolsets
    enabled = policy_turn_toolsets(authority, policy, {}, session_id)
    disabled = session_disabled_toolsets(None, policy.platform, enabled=enabled)
    definitions = model_tools.get_tool_definitions(
        enabled_toolsets=enabled, disabled_toolsets=disabled, quiet_mode=True, skip_tool_search_assembly=True)
    return {tool['function']['name'] for tool in definitions or []}


@pytest.mark.asyncio
async def test_a_pal_session_is_never_offered_manage_connections_while_every_other_surface_keeps_it(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    store, _runner, authority, owner = _owner(tmp_path / 'home', monkeypatch, {'model': {'default': 'm'}})
    try:
        offers = {}
        for name, source in (('phone', 'ios'), ('desk', 'gui'), ('term', 'cli')):
            live, policy = await _create(owner, authority, name, tmp_path, source=source)
            offers[name] = offered_tools(authority, policy, live.source.chat_id)
        assert 'manage_connections' not in offers['phone']
        assert 'manage_connections' in offers['desk'] and 'manage_connections' in offers['term']
        assert 'terminal' in offers['phone']
    finally:
        await owner.close()
        store.close_all_db_handles()


def test_a_pal_agent_drops_manage_connections_even_when_its_toolsets_name_connections():
    import model_tools
    from toolsets import session_disabled_toolsets
    disabled = session_disabled_toolsets(None, 'ios', enabled=['connections', 'terminal'])
    names = {tool['function']['name'] for tool in model_tools.get_tool_definitions(
        enabled_toolsets=['connections', 'terminal'], disabled_toolsets=disabled, quiet_mode=True,
        skip_tool_search_assembly=True) or []}
    assert 'manage_connections' not in names and 'terminal' in names
    assert 'manage_connections' in {tool['function']['name'] for tool in model_tools.get_tool_definitions(
        enabled_toolsets=['connections', 'terminal'], disabled_toolsets=session_disabled_toolsets(None, 'cli'),
        quiet_mode=True, skip_tool_search_assembly=True) or []}
