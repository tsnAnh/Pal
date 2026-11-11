import secrets

import pytest
import pytest_asyncio

from gateway.session_connectors_controls import ACCOUNT_OWNED_VERBS
from gateway.session_legacy_bridge import handlers as bridge_handlers
from hermes_cli.primary_profile import primary_profile_name
from hermes_cli.profiles import get_profile_dir
from tests.gateway.bots_harness import FULL, READ, bots_state, call, config_of, failure, install_state
from tui_gateway.contracts.canonical_bridge import BRIDGED, HANDLER_VALIDATED
from tui_gateway.contracts.registry import CANONICAL_METHODS, METHODS

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)


def test_every_bridged_verb_reuses_the_sidecar_wire_on_the_canonical_catalog():
    for name in set(BRIDGED) - HANDLER_VALIDATED:
        assert CANONICAL_METHODS[name].params is METHODS[name].params, name
        assert CANONICAL_METHODS[name].result is METHODS[name].result, name


@pytest.mark.asyncio
async def test_the_authority_serves_exactly_the_declared_bridge(bots):
    served = set(bridge_handlers(bots.connect()))
    assert served | set(ACCOUNT_OWNED_VERBS) == set(BRIDGED) | {'profiles.set_primary'}
    assert not (served - {'profiles.set_primary'}) & set(ACCOUNT_OWNED_VERBS)


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params,keys', [
    ('permissions.get', {}, {'auto_review', 'approval_mode', 'ask', 'allow'}),
    ('library.list', {}, {'items', 'next_before', 'index_complete'}),
    ('account.subscriptions', {}, {'subscriptions'}),
    ('cron.manage', {}, {'success'}),
    ('cron.manage', {'action': 'history'}, {'success'}),
])
async def test_a_read_grant_gets_the_sidecar_answer_for_every_read_verb(bots, method, params, keys):
    response = await call(bots.connect(capabilities=READ), method, params)
    assert 'error' not in response, response
    assert keys <= set(response['result']), response
    CANONICAL_METHODS[method].result.model_validate(response['result'])


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params', [
    ('permissions.set_auto_review', {'enabled': False}),
    ('permissions.rules.add', {'list': 'ask', 'text': 'ask before deleting files'}),
    ('cron.manage', {'action': 'add', 'schedule': 'every 1h', 'prompt': 'ping'}),
    ('cron.manage', {'action': 'run', 'name': 'whatever'}),
    ('shared_metrics.set', {'enabled': False}),
    ('bot_mode.about_you.set', {'name': 'Sam'}),
    ('profiles.create', {'name': 'gamma'}),
])
async def test_a_control_verb_refuses_a_read_only_grant_and_changes_nothing(bots, method, params):
    before = config_of(bots.root)
    response = await call(bots.connect(capabilities=READ), method, params)
    assert failure(response)['message'] == 'permission_denied'
    assert config_of(bots.root) == before
    assert not (bots.root / 'profiles' / 'gamma').exists()


@pytest.mark.asyncio
async def test_a_grant_without_read_cannot_read(bots):
    response = await call(bots.connect(capabilities=['session:control']), 'permissions.get', {})
    assert failure(response)['message'] == 'permission_denied'


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params,field', [
    ('permissions.get', {'bogus': 1}, 'bogus'),
    ('library.list', {'limit': 'many'}, 'limit'),
    ('profiles.rename', {'name': 'alpha', 'new_name': 'x', 'extra': True}, 'extra'),
    ('vault.add', {'secret': 'hunter2', 'sneaky': 1}, 'sneaky'),
    ('connectors.catalog', {'owner': {'type': 'account'}}, 'owner'),
])
async def test_an_unknown_or_mistyped_key_is_refused_before_the_sidecar_runs(bots, method, params, field):
    response = await call(bots.connect(), method, params)
    error = failure(response)
    assert error['data']['reason'] == 'invalid_params' and field in error['data']['fields'], response
    assert 'hunter2' not in str(response)


@pytest.mark.asyncio
async def test_a_cron_action_is_authorized_by_what_it_does(bots):
    reader = bots.connect(capabilities=READ)
    assert 'error' not in await call(reader, 'cron.manage', {'action': 'schedule_preview', 'schedule': 'every 1h'})
    assert failure(await call(reader, 'cron.manage', {'action': 'pause', 'name': 'x'}))['message'] == 'permission_denied'
    refused = failure(await call(bots.connect(), 'cron.manage', {'action': 'trigger_issue', 'name': 'x'}))
    assert refused['data']['reason'] == 'invalid_params' and refused['data']['field'] == 'action'


@pytest.mark.asyncio
async def test_skills_only_lists_and_never_installs_over_the_socket(bots):
    connection = bots.connect()
    assert 'error' not in await call(connection, 'skills.manage', {'action': 'list'})
    refused = failure(await call(connection, 'skills.manage', {'action': 'install', 'query': 'anything'}))
    assert refused['data']['field'] == 'action'


@pytest.mark.asyncio
async def test_a_control_grant_adds_and_removes_a_catalog_mcp_server_in_its_own_profile(bots):
    connection = bots.connect('alpha')
    added = await call(connection, 'mcp.servers.add', {'name': 'airtable', 'preset': 'airtable'})
    assert 'error' not in added, added
    CANONICAL_METHODS['mcp.servers.add'].result.model_validate(added['result'])
    assert 'airtable' in (config_of(get_profile_dir('alpha')).get('mcp_servers') or {})
    assert 'airtable' not in (config_of(bots.root).get('mcp_servers') or {})
    removed = await call(connection, 'mcp.servers.remove', {'name': 'airtable'})
    assert removed['result']['removed'] is True, removed
    assert 'airtable' not in (config_of(get_profile_dir('alpha')).get('mcp_servers') or {})


@pytest.mark.asyncio
@pytest.mark.parametrize('params', [
    {'name': 'evil', 'config': {'command': 'sh', 'args': ['-c', 'touch /tmp/owned']}},
    {'name': 'evil', 'preset': 'airtable', 'config': {'command': 'sh'}},
    {'name': 'evil', 'config': {'url': 'https://example.invalid/mcp', 'command': 'sh'}},
    {'name': 'evil', 'config': {'url': 'https://example.invalid/mcp', 'args': ['-c', 'id']}},
    {'name': 'evil', 'config': {'url': 'https://example.invalid/mcp', 'env': {'A': 'b'}}},
    {'name': 'evil', 'config': {'url': 'https://example.invalid/mcp', 'headers': {'X-Key': 'literal'}}},
    {'name': 'evil', 'config': {'transport': 'http'}},
    {'name': 'evil', 'preset': '  '},
])
async def test_the_socket_never_adds_a_command_or_an_unvetted_custom_config(bots, params):
    before = config_of(get_profile_dir('alpha'))
    refused = failure(await call(bots.connect('alpha'), 'mcp.servers.add', params))
    assert refused['data']['reason'] == 'invalid_params' and refused['data']['field'] == 'config', refused
    assert config_of(get_profile_dir('alpha')) == before


@pytest.mark.asyncio
async def test_the_socket_adds_updates_and_removes_a_url_server_with_secret_headers_kept_out_of_config(bots):
    connection, home = bots.connect('alpha'), get_profile_dir('alpha')
    key = secrets.token_urlsafe(18)
    added = await call(connection, 'mcp.servers.add', {
        'name': 'notes', 'config': {'url': 'https://example.invalid/mcp', 'transport': 'http'},
        'headers': {'X-Api-Key': key}, 'client_id': 'pal-client'})
    assert 'error' not in added, added
    CANONICAL_METHODS['mcp.servers.add'].result.model_validate(added['result'])
    saved = (config_of(home).get('mcp_servers') or {})['notes']
    assert saved['url'] == 'https://example.invalid/mcp' and saved['oauth'] == {'client_id': 'pal-client'}
    assert saved['headers'] == {'X-Api-Key': '${MCP_NOTES_HDR_X_API_KEY}'}
    assert key not in (home / 'config.yaml').read_text() and key not in str(added)
    assert 'notes' not in (config_of(bots.root).get('mcp_servers') or {})

    updated = await call(connection, 'mcp.servers.update', {
        'name': 'notes', 'config': {'url': 'https://example.invalid/v2'}, 'headers': {'X-Api-Key': None}})
    assert 'error' not in updated, updated
    assert (config_of(home)['mcp_servers']['notes'])['url'] == 'https://example.invalid/v2'
    moved = failure(await call(connection, 'mcp.servers.update', {
        'name': 'notes', 'config': {'url': 'https://elsewhere.invalid/mcp'}, 'headers': {'X-Api-Key': None}}), 4063)
    assert moved['message'] == 're-enter headers for the new address'
    smuggled = failure(await call(connection, 'mcp.servers.update', {
        'name': 'notes', 'config': {'url': 'https://example.invalid/v2', 'command': 'sh'}}))
    assert smuggled['data']['reason'] == 'invalid_params'
    removed = await call(connection, 'mcp.servers.remove', {'name': 'notes'})
    assert removed['result']['removed'] is True, removed
    assert 'MCP_NOTES_HDR_X_API_KEY' not in ((home / '.env').read_text() if (home / '.env').exists() else '')


@pytest.mark.asyncio
async def test_a_read_grant_cannot_change_the_mcp_servers_a_bot_has(bots):
    before = config_of(get_profile_dir('alpha'))
    reader = bots.connect('alpha', capabilities=READ)
    for method, params in (('mcp.servers.add', {'name': 'airtable', 'preset': 'airtable'}),
                           ('mcp.servers.remove', {'name': 'airtable'}),
                           ('mcp.servers.set_api_key', {'name': 'airtable', 'value': 'secret-value'}),
                           ('mcp.servers.oauth.callback', {'name': 'airtable', 'session_id': 'flow', 'code': 'c', 'state': 's'})):
        assert failure(await call(reader, method, params))['message'] == 'permission_denied', method
    assert config_of(get_profile_dir('alpha')) == before


@pytest.mark.asyncio
async def test_hosted_connector_accounts_are_served_and_removing_one_needs_control(bots):
    reader = bots.connect(capabilities=READ)
    assert (await call(reader, 'connectors.accounts', {})).get('error', {}).get('code') != -32601
    removal = {'connection_id': 'ca_1'}
    assert failure(await call(reader, 'connectors.accounts.remove', removal))['message'] == 'permission_denied'
    assert (await call(bots.connect(), 'connectors.accounts.remove', removal)).get('error', {}).get('code') != -32601


@pytest.mark.asyncio
async def test_a_routed_write_lands_in_the_owning_profiles_home_only(bots):
    connection = bots.connect(host=True)
    changed = await call(connection, 'permissions.set_auto_review', {'profile': 'alpha', 'enabled': False})
    assert 'error' not in changed, changed
    assert (await call(connection, 'permissions.get', {'profile': 'alpha'}))['result']['auto_review'] is False
    assert (await call(connection, 'permissions.get', {}))['result']['auto_review'] is True
    assert (await call(connection, 'permissions.get', {'profile': 'beta'}))['result']['auto_review'] is True
    assert config_of(get_profile_dir('alpha')) != config_of(get_profile_dir('beta'))
    assert 'auto_review' not in str(config_of(bots.root))


@pytest.mark.asyncio
async def test_a_profile_bound_grant_cannot_reach_another_profile(bots):
    connection = bots.connect('alpha')
    assert failure(await call(connection, 'permissions.get', {'profile': 'beta'}))['message'] == 'profile_mismatch'
    assert failure(await call(connection, 'profiles.configure', {'name': 'beta', 'description': 'x'}),
                   )['message'] == 'profile_mismatch'
    assert failure(await call(connection, 'profiles.rename', {'name': 'beta', 'new_name': 'gamma'}),
                   )['message'] == 'permission_denied'
    assert failure(await call(connection, 'profiles.create', {'name': 'gamma'}))['message'] == 'permission_denied'
    assert failure(await call(connection, 'profiles.set_primary', {'name': 'beta'}))['message'] == 'permission_denied'
    assert get_profile_dir('beta').is_dir() and primary_profile_name() == 'default'


@pytest.mark.asyncio
async def test_the_sidecars_refusal_keeps_its_code_message_and_data(bots):
    response = await call(bots.connect(), 'permissions.rules.remove', {'id': '  '})
    error = failure(response, 5320)
    assert error['message'] and error['data']['code'] == 'invalid_id', response


@pytest.mark.asyncio
async def test_a_slack_connect_never_echoes_or_logs_the_tokens(bots, monkeypatch, caplog):
    from hermes_cli.web_routers import messaging
    saved = {}
    monkeypatch.setattr(messaging, '_apply_platform_update',
                        lambda platform, entry, rules, env, remove, enabled: saved.update(env))
    monkeypatch.setattr(messaging, '_notify_multiplexer_hot_serve', lambda profile: True)
    params = {'bot_token': 'xoxb-SECRET-bot', 'app_token': 'xapp-SECRET-app'}
    response = await call(bots.connect(), 'messaging.slack.connect', params)
    assert 'error' not in response, response
    assert saved['SLACK_BOT_TOKEN'] == 'xoxb-SECRET-bot'
    assert 'SECRET' not in str(response) and 'SECRET' not in caplog.text
    refused = await call(bots.connect(capabilities=READ), 'messaging.slack.connect', params)
    assert 'SECRET' not in str(refused) and 'SECRET' not in caplog.text


@pytest.mark.asyncio
async def test_account_owned_connector_calls_are_served_not_unknown(bots):
    connection = bots.connect()
    unknown = await call(connection, 'connectors.operation.status', {'owner': {'type': 'account'}, 'op_id': 'nope'})
    assert unknown['error']['code'] != -32601, unknown
    reader = bots.connect(capabilities=READ)
    wake = failure(await call(reader, 'connectors.operation.wake', {'owner': {'type': 'account'}, 'op_id': 'nope'}))
    assert wake['message'] == 'permission_denied'
    listed = failure(await call(connection, 'connectors.list', {'owner': {'type': 'session', 'session_id': 's'}}))
    assert listed['data']['field'] == 'owner'


@pytest.mark.asyncio
async def test_an_unserved_method_is_still_unknown(bots):
    assert (await call(bots.connect(), 'vault.source.set', {}))['error']['code'] == -32601


@pytest.mark.asyncio
async def test_choosing_the_primary_bot_over_the_socket_validates_and_protects_it(bots):
    connection = bots.connect()
    chosen = await call(connection, 'profiles.set_primary', {'name': 'Alpha'})
    assert chosen['result'] == {'ok': True, 'name': 'alpha'}
    assert config_of(bots.root)['bot_mode']['primary_profile'] == 'alpha'
    refused = failure(await call(connection, 'profiles.delete', {'name': 'alpha'}), 4102)
    assert 'primary' in refused['message'] and get_profile_dir('alpha').is_dir()
    assert failure(await call(connection, 'profiles.set_primary', {'name': 'ghost'}))['message'] == 'not_found'
    assert failure(await call(connection, 'profiles.set_primary', {'name': '  '}))['message'] == 'invalid_params'
    unknown = failure(await call(connection, 'profiles.set_primary', {'name': 'beta', 'copy': True}))
    assert 'copy' in unknown['data']['fields']
    assert primary_profile_name() == 'alpha'
    reader = bots.connect(capabilities=READ)
    assert failure(await call(reader, 'profiles.set_primary', {'name': 'beta'}))['message'] == 'permission_denied'
    assert primary_profile_name() == 'alpha'


@pytest.mark.asyncio
async def test_the_iphone_connector_verbs_follow_the_same_scopes(bots):
    device = {'device_id': 'phone-0000-0001'}
    assert failure(await call(bots.connect(capabilities=['session:control']), 'device_connectors.list', device),
                   )['message'] == 'permission_denied'
    toggle = {**device, 'id': 'contacts', 'state': 'allowed'}
    assert failure(await call(bots.connect(capabilities=READ), 'device_connectors.set', toggle),
                   )['message'] == 'permission_denied'
    assert failure(await call(bots.connect(), 'device_connectors.list', device))['message'] == 'not_found'


@pytest.mark.asyncio
@pytest.mark.parametrize('method,params', [
    ('messaging.whatsapp.pair.start', {'mode': 'bot'}),
    ('messaging.whatsapp.pair.status', {'pairing_id': 'x'}),
    ('messaging.whatsapp.pair.cancel', {'pairing_id': 'x'}),
    ('messaging.whatsapp.pair.apply', {'pairing_id': 'x'}),
    ('messaging.whatsapp.unpair', {}),
    ('messaging.whatsapp.configure', {'mode': 'bot'}),
    ('messaging.whatsapp_cloud.connect', {'phone_number_id': '1', 'access_token': 'CANARY-NOT-A-REAL-TOKEN'}),
])
async def test_whatsapp_pairing_needs_control_and_stays_inside_the_granted_bot(bots, method, params):
    assert failure(await call(bots.connect(capabilities=READ), method, params))['message'] == 'permission_denied'
    bound = failure(await call(bots.connect('alpha'), method, {**params, 'profile': 'beta'}))
    assert bound['message'] == 'profile_mismatch'
