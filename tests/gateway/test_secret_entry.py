import asyncio
import json
import logging
import os
import stat
import uuid
from pathlib import Path

import pytest

from gateway import auth_flows, auth_prompts
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _in_home, _required, _wait_for
from tools import auth_required
from tools.registry import tool_error

pytest_plugins = ('tests.gateway.device_tools_harness',)

ACME = {'url': 'https://acme.example/mcp', 'headers': {'Authorization': 'Bearer ${MCP_ACME_API_KEY}'}}
HEADER = {'url': 'https://acme.example/mcp', 'headers': {'X-Api-Token': '${ACME_TOKEN}'}}
TWO_HEADERS = {'url': 'https://acme.example/mcp', 'headers': {'X-A': '${ACME_A}', 'X-B': '${ACME_B}'}}


@pytest.fixture(autouse=True)
def clean_registry():
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


@pytest.fixture
def canary():
    return f'CANARY-{uuid.uuid4()}'


def _servers(monkeypatch, servers):
    monkeypatch.setattr('hermes_cli.mcp_config._get_mcp_servers', lambda config=None: servers)


def _reauth(server):
    return tool_error('MCP server needs re-authentication.', needs_reauth=True, server=server)


def _env_text(home: Path) -> str:
    path = home / '.env'
    return path.read_text() if path.exists() else ''


def _files_without_env(home: Path) -> bytes:
    blobs = []
    for path in sorted(home.rglob('*')):
        if path.is_file() and path.name != '.env':
            blobs.append(path.read_bytes())
    return b'\n'.join(blobs)


async def _begin(authority, phone, server='acme'):
    retries = []

    def retry():
        retries.append(1)
        return json.dumps({'ok': True})

    task = asyncio.ensure_future(_in_home(
        home_of(authority), lambda: auth_required.resolve('mcp_acme_x', {}, _reauth(server), retry)))
    before = len(_required(phone))
    await _wait_for(lambda: len(_required(phone)) == before + 1)
    return task, _required(phone)[-1], retries


async def _submit(phone, request_id, value):
    reply = await phone.call('auth.submit_credential', {'request_id': request_id, 'value': value})
    return reply['result']['outcome'] if 'result' in reply else reply


def _blob(*parts) -> str:
    return '\n'.join(p if isinstance(p, str) else json.dumps(p, default=str) for p in parts)


@pytest.mark.asyncio
async def test_canary_reaches_only_the_credential_store_on_the_full_path(authorities, monkeypatch, caplog, capsys, canary):
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, retries = await _begin(authority, phone)
    assert event['flow'] == 'api_key' and event['server'] == 'acme'
    assert await _submit(phone, event['request_id'], f' Bearer {canary}\n') == 'stored'
    result = await task
    assert json.loads(result) == {'ok': True} and retries == [1]
    home = home_of(authority)
    assert f'MCP_ACME_API_KEY={canary}' in _env_text(home)
    assert not stat.S_IMODE(os.stat(home / '.env').st_mode) & 0o077
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    out = capsys.readouterr()
    outside_store = _blob(phone.frames, result, caplog.text, out.out, out.err)
    assert canary not in outside_store
    assert canary.encode() not in _files_without_env(home)
    assert 'Bearer' not in _env_text(home)


@pytest.mark.asyncio
async def test_header_credential_is_stored_under_the_single_referenced_variable(authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': HEADER})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    assert event['flow'] == 'header'
    assert await _submit(phone, event['request_id'], canary) == 'stored'
    assert json.loads(await task) == {'ok': True}
    assert f'ACME_TOKEN={canary}' in _env_text(home_of(authority))
    assert canary not in _blob(phone.frames, caplog.text)


@pytest.mark.asyncio
async def test_a_multi_field_header_connector_gets_no_box(authorities, monkeypatch):
    _servers(monkeypatch, {'acme': TWO_HEADERS})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    assert event['flow'] == 'manual'
    assert await _submit(phone, event['request_id'], 'x') == 'rejected'
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_oauth_and_device_code_requests_reject_a_credential(authorities, monkeypatch, canary):
    _servers(monkeypatch, {'acme': {'url': 'https://acme.example/mcp', 'auth': 'oauth'}})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    assert event['flow'] == 'oauth'
    assert await _submit(phone, event['request_id'], canary) == 'rejected'
    assert canary not in _env_text(home_of(authority))
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_unknown_request_id_is_rejected_and_stores_nothing(authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    assert await _submit(phone, 'f' * 32, canary) == 'rejected'
    assert canary not in _env_text(home_of(authority)) + caplog.text + _blob(phone.frames)
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_another_users_connection_cannot_answer(authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    stranger_authority = await authorities('other')
    stranger = await connect_phone(stranger_authority, label='iPad')
    task, event, _ = await _begin(authority, phone)
    assert await _submit(stranger, event['request_id'], canary) == 'rejected'
    assert canary not in _env_text(home_of(authority)) + _env_text(home_of(stranger_authority))
    assert canary not in caplog.text + _blob(phone.frames, stranger.frames)
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_the_secret_lands_in_the_requesting_profile_home_whatever_the_ambient_home(authorities, monkeypatch, canary):
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    other = home_of(authority).parent / 'other-profile'
    other.mkdir()
    task, event, _ = await _begin(authority, phone)
    token = set_hermes_home_override(other)
    try:
        outcome = await auth_prompts.submit_credential(authority, event['request_id'], canary)
    finally:
        reset_hermes_home_override(token)
    assert outcome is auth_prompts.CredentialOutcome.STORED
    assert canary in _env_text(home_of(authority)) and canary not in _env_text(other)
    await task


@pytest.mark.asyncio
async def test_duplicate_submit_first_wins(authorities, monkeypatch, canary):
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    first = canary
    second = f'CANARY-{uuid.uuid4()}'
    assert await _submit(phone, event['request_id'], first) == 'stored'
    assert await _submit(phone, event['request_id'], second) == 'rejected'
    await task
    env = _env_text(home_of(authority))
    assert first in env and second not in env


@pytest.mark.asyncio
async def test_concurrent_duplicate_submits_store_exactly_one(authorities, monkeypatch):
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    saved = []
    gate = asyncio.Event()

    async def slow_save(env_var, text):
        saved.append(text)
        await gate.wait()

    monkeypatch.setattr(auth_flows, 'save_credential', slow_save)
    first = asyncio.ensure_future(_submit(phone, event['request_id'], 'first-value'))
    await _wait_for(lambda: len(saved) == 1)
    assert await _submit(phone, event['request_id'], 'second-value') == 'rejected'
    gate.set()
    assert await first == 'stored'
    await task
    assert saved == ['first-value']


@pytest.mark.asyncio
async def test_expired_request_clears_and_rejects_a_late_answer(authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    monkeypatch.setattr(auth_prompts, 'SIGNIN_TIMEOUT_SECONDS', 0.2)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    await _wait_for(lambda: phone.events('auth.resolved'))
    assert phone.events('auth.resolved')[-1]['outcome'] == 'timed_out'
    assert await _submit(phone, event['request_id'], canary) == 'rejected'
    assert canary not in _env_text(home_of(authority)) + caplog.text
    result = json.loads(await task)
    assert result['error_type'] if 'error_type' in result else result.get('error')


@pytest.mark.asyncio
async def test_cancel_stores_nothing_and_the_decline_cooldown_applies(authorities, monkeypatch, canary):
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, retries = await _begin(authority, phone)
    assert (await phone.call('auth.decline', {'request_id': event['request_id']}))['result']['recorded'] is True
    result = json.loads(await task)
    assert result['error_type'] == 'auth_declined' and retries == []
    assert await _submit(phone, event['request_id'], canary) == 'rejected'
    assert canary not in _env_text(home_of(authority))
    again = await _in_home(home_of(authority),
                           lambda: auth_required.resolve('mcp_acme_x', {}, _reauth('acme'), lambda: '{}'))
    assert json.loads(again)['error_type'] == 'auth_declined'
    assert len(_required(phone)) == 1


@pytest.mark.asyncio
async def test_store_failure_reports_failed_leaks_nothing_and_stays_retryable(authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    real = auth_flows.save_credential

    async def broken(env_var, text):
        raise OSError(f'disk full while writing {text} to {env_var}')

    monkeypatch.setattr(auth_flows, 'save_credential', broken)
    assert await _submit(phone, event['request_id'], canary) == 'failed'
    assert canary not in _env_text(home_of(authority)) + caplog.text + _blob(phone.frames)
    assert not phone.events('auth.resolved')
    monkeypatch.setattr(auth_flows, 'save_credential', real)
    assert await _submit(phone, event['request_id'], canary) == 'stored'
    assert json.loads(await task) == {'ok': True}
    assert f'MCP_ACME_API_KEY={canary}' in _env_text(home_of(authority))


@pytest.mark.asyncio
@pytest.mark.parametrize('value', ['   ', 'Bearer', 'café-☃-CANARY', 'two\nlines'])
async def test_values_that_cannot_be_a_credential_fail_without_echo(authorities, monkeypatch, capsys, value):
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    task, event, _ = await _begin(authority, phone)
    assert await _submit(phone, event['request_id'], value) == 'failed'
    out = capsys.readouterr()
    assert 'CANARY' not in out.out + out.err and 'MCP_ACME_API_KEY' not in _env_text(home_of(authority))
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task


@pytest.mark.asyncio
async def test_malformed_submit_is_refused_without_echoing_the_value(authorities, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    bad_id = await phone.call('auth.submit_credential', {'request_id': 'x', 'value': canary})
    extra = await phone.call('auth.submit_credential', {'request_id': 'a' * 16, 'value': canary, 'profile': 'p', 'x': 1})
    assert 'error' in bad_id and 'error' in extra
    assert canary not in _blob(bad_id, extra, caplog.text)


@pytest.mark.asyncio
async def test_submit_needs_the_control_capability(authorities, monkeypatch, caplog, canary):
    from gateway.session_controls import AuthorityConnection
    caplog.set_level(logging.DEBUG)
    _servers(monkeypatch, {'acme': ACME})
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reader = await connect_phone(authority, label='Watch')
    reader.connection = AuthorityConnection(authority, reader, {'user_id': 'owner', 'capabilities': ['session:read']})
    task, event, _ = await _begin(authority, phone)
    reply = await reader.call('auth.submit_credential', {'request_id': event['request_id'], 'value': canary})
    assert reply['error']['message'] == 'permission_denied'
    assert canary not in _env_text(home_of(authority)) + caplog.text + _blob(reply)
    await phone.call('auth.decline', {'request_id': event['request_id']})
    await task
