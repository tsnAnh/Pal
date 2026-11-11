import json
import logging
import uuid

import pytest

from gateway import auth_prompts
from hermes_cli.web_routers import oauth
from tests.gateway.device_tools_harness import connect_phone, home_of
from tests.gateway.test_auth_prompts import _wait_for

pytest_plugins = ('tests.gateway.device_tools_harness',)


@pytest.fixture(autouse=True)
def clean_registry(monkeypatch):
    for var in ('DEEPSEEK_API_KEY', 'XAI_API_KEY'):
        monkeypatch.delenv(var, raising=False)
    yield
    auth_prompts._active.clear()
    auth_prompts._by_id.clear()
    auth_prompts._declined_until.clear()


@pytest.fixture
def canary():
    return f'CANARY-{uuid.uuid4()}'


def _env_text(home):
    path = home / '.env'
    return path.read_text() if path.exists() else ''


def _files_without_env(home):
    return b'\n'.join(p.read_bytes() for p in sorted(home.rglob('*')) if p.is_file() and p.name != '.env')


def _blob(*parts):
    return '\n'.join(p if isinstance(p, str) else json.dumps(p, default=str) for p in parts)


async def _begin(phone, provider):
    reply = await phone.call('auth.begin', {'service': f'provider:{provider}'})
    return reply['result']


async def _submit(phone, request_id, value):
    reply = await phone.call('auth.submit_credential', {'request_id': request_id, 'value': value})
    return reply['result']['outcome'] if 'result' in reply else reply


@pytest.mark.asyncio
async def test_begin_opens_the_masked_key_prompt_and_stores_only_in_the_env(authorities, caplog, capsys, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    started = await _begin(phone, 'deepseek')
    assert started['outcome'] == 'started'
    await _wait_for(lambda: phone.events('auth.required'))
    event = phone.events('auth.required')[-1]
    assert event['request_id'] == started['request_id'] and event['service'] == 'provider:deepseek'
    assert event['flow'] == 'api_key' and event['reason'] == 'missing' and event['service_name'] == 'Deepseek'
    assert await _submit(phone, event['request_id'], f' {canary}\n') == 'stored'
    await _wait_for(lambda: phone.events('auth.resolved'))
    assert phone.events('auth.resolved')[-1]['outcome'] == 'signed_in'
    home = home_of(authority)
    assert f'DEEPSEEK_API_KEY={canary}' in _env_text(home)
    out = capsys.readouterr()
    assert canary not in _blob(phone.frames, caplog.text, out.out, out.err)
    assert canary.encode() not in _files_without_env(home)


@pytest.mark.asyncio
async def test_replacing_a_key_overwrites_it(authorities, canary):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    old = f'CANARY-{uuid.uuid4()}'
    for value in (old, canary):
        started = await _begin(phone, 'deepseek')
        assert await _submit(phone, started['request_id'], value) == 'stored'
        await _wait_for(lambda: not auth_prompts._active)
    text = _env_text(home_of(authority))
    assert f'DEEPSEEK_API_KEY={canary}' in text and old not in text


@pytest.mark.asyncio
async def test_a_value_that_cannot_be_a_key_fails_and_keeps_the_old_one(authorities, canary):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    first = await _begin(phone, 'deepseek')
    assert await _submit(phone, first['request_id'], canary) == 'stored'
    await _wait_for(lambda: not auth_prompts._active)
    second = await _begin(phone, 'deepseek')
    for bad in ('   ', 'café-key', 'two\nlines'):
        assert await _submit(phone, second['request_id'], bad) == 'failed'
    assert f'DEEPSEEK_API_KEY={canary}' in _env_text(home_of(authority))
    await phone.call('auth.decline', {'request_id': second['request_id']})


@pytest.mark.asyncio
async def test_a_store_error_fails_without_echoing_the_secret_and_keeps_the_old_value(
        authorities, monkeypatch, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    first = await _begin(phone, 'deepseek')
    assert await _submit(phone, first['request_id'], canary) == 'stored'
    await _wait_for(lambda: not auth_prompts._active)
    from hermes_cli import model_provider_control as control
    fresh = f'CANARY-{uuid.uuid4()}'

    def boom(provider_id, text):
        raise OSError(f'disk full while writing {text}')
    monkeypatch.setattr(control, 'store_api_key', boom)
    second = await _begin(phone, 'deepseek')
    assert await _submit(phone, second['request_id'], fresh) == 'failed'
    assert f'DEEPSEEK_API_KEY={canary}' in _env_text(home_of(authority))
    assert fresh not in _blob(phone.frames, caplog.text) + _env_text(home_of(authority))
    await phone.call('auth.decline', {'request_id': second['request_id']})


@pytest.mark.asyncio
async def test_unsupported_and_unknown_providers_open_no_prompt(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    for provider in ('bedrock', 'qwen-oauth', 'ghost'):
        result = await _begin(phone, provider)
        assert result['outcome'] == 'unsupported' and result['reason'] and not result.get('request_id')
    assert phone.events('auth.required') == [] and not auth_prompts._active


@pytest.mark.asyncio
async def test_an_invalid_service_is_rejected_by_the_contract(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    reply = await phone.call('auth.begin', {'service': 'mcp:acme'})
    assert 'error' in reply


@pytest.mark.asyncio
async def test_a_second_begin_reuses_the_open_request(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    first = await _begin(phone, 'deepseek')
    second = await _begin(phone, 'deepseek')
    assert first['request_id'] == second['request_id'] and len(auth_prompts._by_id) == 1
    await phone.call('auth.decline', {'request_id': first['request_id']})


@pytest.mark.asyncio
async def test_declining_ends_the_request_and_stores_nothing(authorities):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    started = await _begin(phone, 'deepseek')
    await phone.call('auth.decline', {'request_id': started['request_id']})
    await _wait_for(lambda: phone.events('auth.resolved'))
    assert phone.events('auth.resolved')[-1]['outcome'] == 'declined'
    assert 'DEEPSEEK_API_KEY' not in _env_text(home_of(authority))
    again = await _begin(phone, 'deepseek')
    assert again['outcome'] == 'started'
    await phone.call('auth.decline', {'request_id': again['request_id']})


@pytest.mark.asyncio
async def test_another_users_connection_cannot_answer_the_prompt(authorities, caplog, canary):
    caplog.set_level(logging.DEBUG)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    other_authority = await authorities('other')
    stranger = await connect_phone(other_authority, label='iPad')
    started = await _begin(phone, 'deepseek')
    assert await _submit(stranger, started['request_id'], canary) == 'rejected'
    assert canary not in _env_text(home_of(authority)) + _env_text(home_of(other_authority)) + caplog.text
    await phone.call('auth.decline', {'request_id': started['request_id']})


@pytest.mark.asyncio
async def test_account_wide_logins_are_refused_outside_the_main_profile(authorities, monkeypatch):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    monkeypatch.setattr('hermes_constants.profile_name_for_home', lambda home: 'scout')
    result = await _begin(phone, 'nous')
    assert result['outcome'] == 'refused' and 'main profile' in result['reason']
    assert not auth_prompts._active
    assert (await _begin(phone, 'deepseek'))['outcome'] == 'started'


def _fake_device_flow(monkeypatch, sessions):
    async def start(provider_id, profile):
        session = {'status': 'pending', 'provider': provider_id, 'created_at': 0, 'error_message': None}
        sessions['s1'] = session
        oauth._oauth_sessions['s1'] = session
        return {'session_id': 's1', 'flow': 'device_code', 'user_code': 'ABCD-1234',
                'verification_url': 'https://login.example.test/device', 'expires_in': 600, 'poll_interval': 1}
    monkeypatch.setattr(oauth, '_start_device_code_flow', start)
    monkeypatch.setattr('gateway.auth_flows.ProviderDeviceFlow.POLL_SECONDS', 0.02)


@pytest.mark.asyncio
async def test_a_device_code_provider_shows_the_code_and_signs_in(authorities, monkeypatch):
    sessions = {}
    _fake_device_flow(monkeypatch, sessions)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    assert (await _begin(phone, 'openai-codex'))['outcome'] == 'started'
    await _wait_for(lambda: phone.events('auth.required'))
    event = phone.events('auth.required')[-1]
    assert event['flow'] == 'device_code' and event['user_code'] == 'ABCD-1234'
    assert event['verification_uri'] == 'https://login.example.test/device' and event['expires_in'] == 600
    sessions['s1']['status'] = 'approved'
    await _wait_for(lambda: phone.events('auth.resolved'))
    resolved = phone.events('auth.resolved')[-1]
    assert resolved['outcome'] == 'signed_in' and resolved.get('reason') is None


@pytest.mark.asyncio
@pytest.mark.parametrize('status,words', [('denied', 'declined'), ('expired', 'expired')])
async def test_a_failed_device_code_sign_in_explains_why(authorities, monkeypatch, status, words):
    sessions = {}
    _fake_device_flow(monkeypatch, sessions)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    await _begin(phone, 'openai-codex')
    await _wait_for(lambda: phone.events('auth.required'))
    sessions['s1']['status'] = status
    await _wait_for(lambda: phone.events('auth.resolved'))
    resolved = phone.events('auth.resolved')[-1]
    assert resolved['outcome'] == 'failed' and words in resolved['reason']


@pytest.mark.asyncio
async def test_a_provider_error_is_shown_redacted(authorities, monkeypatch, canary):
    sessions = {}
    _fake_device_flow(monkeypatch, sessions)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    await _begin(phone, 'openai-codex')
    await _wait_for(lambda: phone.events('auth.required'))
    sessions['s1'].update(status='error', error_message=f'Provider said no. Authorization: Bearer sk-{canary}')
    await _wait_for(lambda: phone.events('auth.resolved'))
    resolved = phone.events('auth.resolved')[-1]
    assert resolved['outcome'] == 'failed' and 'Provider said no' in resolved['reason']
    assert canary not in resolved['reason']


@pytest.mark.asyncio
async def test_declining_a_device_code_sign_in_cancels_the_session(authorities, monkeypatch):
    sessions = {}
    _fake_device_flow(monkeypatch, sessions)
    authority = await authorities('home')
    phone = await connect_phone(authority)
    started = await _begin(phone, 'openai-codex')
    await _wait_for(lambda: phone.events('auth.required'))
    await phone.call('auth.decline', {'request_id': started['request_id']})
    await _wait_for(lambda: sessions['s1'].get('cancelled'))
    assert 's1' not in oauth._oauth_sessions


@pytest.mark.asyncio
async def test_an_empty_or_oversized_value_is_refused_by_the_contract(authorities, canary):
    authority = await authorities('home')
    phone = await connect_phone(authority)
    started = await _begin(phone, 'deepseek')
    for bad in ('', 'x' * 5000):
        assert 'error' in await _submit(phone, started['request_id'], bad)
    assert 'DEEPSEEK_API_KEY' not in _env_text(home_of(authority))
    await phone.call('auth.decline', {'request_id': started['request_id']})


def test_swift_decodes_every_wire_value_of_the_contract():
    from pathlib import Path
    from tui_gateway.contracts import model_providers as wire
    from tui_gateway.contracts.canonical_auth import AuthBeginOutcome
    swift = (Path(__file__).resolve().parents[2]
             / 'apps/ios/Packages/PalKit/Sources/PalBotProfile/ModelProviders.swift').read_text()
    values = {item.value for enum in (wire.ModelProviderKind, wire.ModelProviderState, wire.ModelProviderScope,
                                      wire.ModelProviderRemoveOutcome, wire.ModelProviderBaseUrlOutcome)
              for item in enum}
    values |= {item.value for item in AuthBeginOutcome if item.value != 'unavailable'}
    missing = {value for value in values - {'failed'} if f'"{value}"' not in swift}
    assert not missing, missing
