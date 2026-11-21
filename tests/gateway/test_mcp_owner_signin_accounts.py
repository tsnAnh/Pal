import asyncio
import json
from urllib.parse import parse_qs, urlencode, urlsplit

import hermes_yaml as yaml
import pytest

from gateway import auth_flows, auth_prompts
from hermes_cli.config import get_env_value
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tests.gateway.test_mcp_owner_signin import HANDOVER
from tests.tools.mcp_accounts_double import AccountsDouble, follow_authorization, write_servers
from tools import auth_required
from tools.mcp_oauth import HermesTokenStorage
from tools.registry import tool_error

pytest_plugins = ('tests.gateway.device_tools_harness',)


@pytest.fixture(autouse=True)
def clean_registry():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


def _accounts(authority):
    config = yaml.safe_load((home_of(authority) / 'config.yaml').read_text())
    return list(config['mcp_servers']['upwork']['accounts'])


def _files(authority, account):
    folder = home_of(authority) / 'mcp-tokens' / 'accounts' / 'upwork'
    return sorted(p.name for p in folder.glob(f'{account}.*')) if folder.exists() else []


def _reauth_account(alias):
    return tool_error('MCP server needs re-authentication.', needs_reauth=True, server=f'upwork@{alias}')


async def _prompt(authority, phone, alias):
    task = asyncio.ensure_future(_in_home(home_of(authority), lambda: auth_required.resolve(
        'mcp_upwork_x', {}, _reauth_account(alias), lambda: json.dumps({'ok': True}))))
    await _wait_for(lambda: any(e['service'] == f'mcp:upwork:{alias}' for e in _required(phone)))
    return task


@pytest.mark.asyncio
async def test_a_hand_over_for_one_account_lands_under_it_and_ends_only_its_own_request(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    assert (await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': 'mcp:upwork:default'}))['result'] == {'ok': True}
    assert (await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': 'mcp:upwork:work'}))['result'] == {'ok': True}
    default_wait, work_wait = await _prompt(authority, phone, 'default'), await _prompt(authority, phone, 'work')

    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': 'mcp:upwork:work', 'access_token': 'at-work-2'})

    assert reply['result'] == {'ok': True}
    assert json.loads(await work_wait) == {'ok': True} and not default_wait.done()
    assert _accounts(authority) == ['default', 'work']
    assert _files(authority, 'work') == ['work.client.json', 'work.json', 'work.meta.json']
    stored = json.loads((home_of(authority) / 'mcp-tokens' / 'accounts' / 'upwork' / 'work.json').read_text())
    assert stored['access_token'] == 'at-work-2'
    default_stored = json.loads((home_of(authority) / 'mcp-tokens' / 'accounts' / 'upwork' / 'default.json').read_text())
    assert default_stored['access_token'] == HANDOVER['access_token']
    await phone.call('auth.decline', {'request_id': next(
        e['request_id'] for e in _required(phone) if e['service'] == 'mcp:upwork:default')})
    await default_wait


@pytest.mark.asyncio
async def test_a_hand_over_from_an_older_app_ends_the_default_accounts_waiting_request(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    assert (await phone.call('auth.submit_oauth_tokens', HANDOVER))['result'] == {'ok': True}
    assert _accounts(authority) == ['default']
    waiting = await _prompt(authority, phone, 'default')

    reply = await phone.call('auth.submit_oauth_tokens', HANDOVER)

    assert reply['result'] == {'ok': True} and json.loads(await waiting) == {'ok': True}
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    assert _accounts(authority) == ['default']


@pytest.mark.asyncio
async def test_a_hand_over_that_names_no_account_is_refused_while_several_exist_and_stores_nothing(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    for alias in ('default', 'work'):
        await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': f'mcp:upwork:{alias}'})
    before = (home_of(authority) / 'mcp-tokens' / 'accounts' / 'upwork' / 'work.json').read_bytes()

    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'access_token': 'at-nobody'})

    assert reply['result'] == {'ok': False, 'reason': 'account_required'}
    assert (home_of(authority) / 'mcp-tokens' / 'accounts' / 'upwork' / 'work.json').read_bytes() == before
    assert _accounts(authority) == ['default', 'work']


@pytest.mark.asyncio
@pytest.mark.parametrize('service', ['mcp:upwork:Work', 'mcp:upwork:-x', 'mcp:upwork:a:b', 'mcp:upwork:'])
async def test_a_service_with_an_invalid_account_name_is_refused_before_anything_is_stored(authorities, service):
    authority = await authorities('home')
    phone = await connect_phone(authority)

    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': service})

    assert 'error' in reply and 'result' not in reply
    assert not (home_of(authority) / 'mcp-tokens').exists() or _files(authority, 'work') == []


@pytest.mark.asyncio
async def test_a_connector_that_cannot_hold_accounts_refuses_one(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)

    reply = await phone.call('auth.submit_oauth_tokens', {**HANDOVER, 'service': 'mcp:acme:work'})

    assert reply['result'] == {'ok': False, 'reason': 'not_oauth_service'}


@pytest.mark.asyncio
async def test_an_account_whose_key_is_missing_gets_a_key_entry_flow_that_stores_under_its_own_variable(authorities):
    authority = await authorities('home')
    home = home_of(authority)
    (home / 'config.yaml').write_text(yaml.safe_dump({'mcp_servers': {'github': {
        'url': 'https://api.githubcopilot.com/mcp/', 'transport': 'http', 'enabled': True,
        'headers': {'Authorization': 'Bearer ${MCP_GITHUB_API_KEY}'},
        'accounts': {'default': {}, 'work': {'api_key_env': 'MCP_GITHUB__WORK_API_KEY'}}}}}))

    flow = auth_flows.flow_for(home, 'mcp:github:work')
    await _in_home(home, lambda: asyncio.run(flow.begin()))

    assert flow.kind == 'api_key' and flow.server == 'github'
    assert await _in_home(home, lambda: asyncio.run(flow.store('ghp_work_key')))
    assert await _in_home(home, lambda: get_env_value('MCP_GITHUB__WORK_API_KEY')) == 'ghp_work_key'
    assert await _in_home(home, lambda: get_env_value('MCP_GITHUB_API_KEY')) in (None, '')


@pytest.mark.asyncio
async def test_an_oauth_account_gets_a_paste_flow_whose_tokens_land_under_that_account(authorities):
    authority = await authorities('home')
    home = home_of(authority)
    with AccountsDouble() as double:
        write_servers(home, double, 'linear', ['default', 'work'])
        double.sign_in_as('work')
        flow = auth_flows.flow_for(home, 'mcp:linear:work')

        await flow.begin()

        assert flow.kind == 'oauth_paste' and flow.server == 'linear'
        query = parse_qs(urlsplit(flow.verification_uri).query)
        assert query['prompt'] == ['select_account login']
        landed = await asyncio.to_thread(follow_authorization, flow.verification_uri)
        pasted = f"{query['redirect_uri'][0]}?{urlencode(landed)}"
        assert await flow.callback(pasted) == ('stored', None)
        assert await flow.wait() is True
        storage = HermesTokenStorage('linear@work', hermes_home=home)
        assert double.account_by_token[(await storage.get_tokens()).access_token] == 'work'
        assert not HermesTokenStorage('linear@default', hermes_home=home).has_cached_tokens()


@pytest.mark.asyncio
async def test_an_account_that_no_longer_exists_falls_back_to_a_manual_flow(authorities):
    authority = await authorities('home')
    home = home_of(authority)
    with AccountsDouble() as double:
        write_servers(home, double, 'linear', ['default'])
        flow = auth_flows.flow_for(home, 'mcp:linear:ghost')

        await flow.begin()

        assert flow.kind == 'manual'
