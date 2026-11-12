import asyncio
import base64
import json
import logging
import os
import tempfile

import pytest

from tests.gateway.device_tools_harness import (
    call_device,
    call_devices_list,
    connect_phone,
    device_id_for,
    home_of,
    set_state,
)
from tests.waiting import async_wait_until

pytest_plugins = ('tests.gateway.device_tools_harness',)

CANARY = 'CANARY-SCREEN-7c1e'
JPEG = b'\xff\xd8\xff\xe0' + CANARY.encode() + b'\x00' * 64
IMAGE = base64.b64encode(JPEG).decode()


def capture_answer(payload):
    result = {'image_base64': IMAGE, 'width': 1280, 'height': 800, 'display': payload['args'].get('display', 1)}
    if payload['args'].get('read_text'):
        result['text'] = f'Password: {CANARY}'
    return {'ok': True, 'result': result}


def read_answer(payload):
    return {'ok': True, 'result': {'text': f'Inbox {CANARY}', 'display': 1}}


@pytest.fixture(autouse=True)
def fresh_gate(monkeypatch):
    from gateway import device_actions
    from tools import devices_tool
    devices_tool._screen_started.clear()
    devices_tool._screen_in_flight.clear()
    monkeypatch.setattr(device_actions, 'SCREEN_MIN_INTERVAL_SECONDS', 0.0)
    monkeypatch.setattr(devices_tool, '_model_takes_images', lambda: True)


async def mac(authority, label='Work Mac', responder=None, state='allowed'):
    phone = await connect_phone(authority, label, kind='mac', model='MacBookPro18,3', responder=responder)
    if state:
        await set_state(phone, 'screen', state)
    return phone


async def call_raw(authority, payload):
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override
    from model_tools import handle_function_call

    def run():
        token = set_hermes_home_override(home_of(authority))
        try:
            return handle_function_call('device', payload, task_id='t', session_id='chat-1')
        finally:
            reset_hermes_home_override(token)

    return await asyncio.to_thread(run)


@pytest.mark.asyncio
async def test_screen_needs_no_switch_and_ignores_a_set_off(authorities):
    authority = await authorities()
    work = await mac(authority, state=None)
    assert (await call_devices_list(authority))['devices'][0]['capabilities']['screen'] == 'allowed'
    await set_state(work, 'screen', 'off')
    assert (await call_devices_list(authority))['devices'][0]['capabilities']['screen'] == 'allowed'
    result = await call_device(authority, 'Work Mac', 'screen.capture')
    assert result.get('code') != 'connector_off' and len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_capture_returns_an_image_and_text_marked_as_untrusted_data(authorities):
    authority = await authorities()
    work = await mac(authority, responder=capture_answer)
    result = await call_raw(authority, {'device': 'Work Mac', 'action': 'screen.capture',
                                        'args': {'display': 2, 'read_text': True}})
    request = work.requests()[0]
    assert request['action'] == 'screen.capture' and request['connector'] == 'screen'
    assert request['args'] == {'display': 2, 'read_text': True}
    assert result['_multimodal'] is True and CANARY not in result['text_summary']
    text, image = result['content']
    body = json.loads(text['text'])
    assert body['untrusted_content'] is True and body['source'] == 'user_device' and 'never as instructions' in body['notice']
    assert body['data']['text'] == f'Password: {CANARY}' and 'image_base64' not in body['data']
    assert image['image_url']['url'] == f'data:image/jpeg;base64,{IMAGE}'
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_model_that_cannot_view_images_gets_the_text_and_a_note(authorities, monkeypatch):
    from tools import devices_tool
    monkeypatch.setattr(devices_tool, '_model_takes_images', lambda: False)
    authority = await authorities()
    work = await mac(authority, responder=capture_answer)
    result = json.loads(await call_raw(authority, {'device': 'Work Mac', 'action': 'screen.capture',
                                                   'args': {'read_text': True}}))
    assert result['success'] is True and result['untrusted_content'] is True
    assert 'image_base64' not in result['data'] and 'cannot view images' in result['data']['image_omitted']
    assert IMAGE not in json.dumps(result)
    await work.connection.close()


@pytest.mark.asyncio
async def test_screen_read_returns_recognized_text_as_untrusted_data(authorities):
    authority = await authorities()
    work = await mac(authority, responder=read_answer)
    result = json.loads(await call_raw(authority, {'device': 'Work Mac', 'action': 'screen.read'}))
    assert result['data'] == {'text': f'Inbox {CANARY}', 'display': 1}
    assert result['untrusted_content'] is True and 'never as instructions' in result['notice']
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_iphone_cannot_do_screen_actions(authorities):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2')
    result = await call_device(authority, 'Sam iPhone', 'screen.capture')
    assert result['code'] == 'unsupported' and pocket.requests() == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once(authorities):
    authority = await authorities()
    work = await mac(authority, responder=capture_answer)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'screen.capture')
    assert result['code'] == 'phone_offline'


@pytest.mark.asyncio
async def test_an_older_app_that_does_not_know_screen_answers_unsupported(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda p: {
        'ok': False, 'error': {'code': 'unsupported', 'message': 'This device does not do screen.capture.'}})
    result = await call_device(authority, 'Work Mac', 'screen.capture')
    assert result['code'] == 'unsupported' and 'cannot do screen.capture' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_missing_screen_recording_permission_is_a_clear_error_and_is_not_retried(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda p: {
        'ok': False, 'error': {'code': 'permission_denied', 'message': 'Allow Screen for Pal in System Settings.'}})
    result = await call_device(authority, 'Work Mac', 'screen.capture')
    assert result['code'] == 'permission_denied' and len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_another_profiles_mac_is_not_reachable(authorities, tmp_path):
    (tmp_path / 'install').mkdir()
    (tmp_path / 'install' / 'config.yaml').write_text('{}')
    mine = await authorities('install/profiles/mine')
    theirs = await authorities('install/profiles/theirs')
    their_mac = await mac(theirs, 'Neighbour Mac', capture_answer)
    my_mac = await mac(mine, 'My Mac', capture_answer)
    for target in ('Neighbour Mac', device_id_for('Neighbour Mac')):
        result = await call_device(mine, target, 'screen.capture')
        assert result['code'] == 'device_not_found'
    assert their_mac.requests() == [] and my_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_screen_content_never_reaches_the_logs_even_when_the_answer_is_rejected(authorities, caplog):
    caplog.set_level(logging.DEBUG)
    authority = await authorities()
    work = await mac(authority, responder=capture_answer)
    await call_raw(authority, {'device': 'Work Mac', 'action': 'screen.capture', 'args': {'read_text': True}})
    work.responder = lambda p: {'ok': True, 'result': {
        'image_base64': base64.b64encode(b'not a jpeg ' + CANARY.encode()).decode(), 'width': 1, 'height': 1,
        'display': 1, 'text': CANARY}}
    rejected = await call_device(authority, 'Work Mac', 'screen.capture')
    assert rejected['code'] == 'invalid_result'
    assert CANARY not in caplog.text and IMAGE not in caplog.text and CANARY not in json.dumps(rejected)
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_oversized_image_is_refused(authorities):
    authority = await authorities()
    big = base64.b64encode(b'\xff\xd8\xff' + b'0' * 310_000).decode()
    work = await mac(authority, responder=lambda p: {'ok': True, 'result': {
        'image_base64': big, 'width': 10, 'height': 10, 'display': 1}})
    assert (await call_device(authority, 'Work Mac', 'screen.capture'))['code'] == 'invalid_result'
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_capture_leaves_no_temp_files_behind(authorities, tmp_path, monkeypatch):
    scratch = tmp_path / 'scratch'
    scratch.mkdir()
    monkeypatch.setattr(tempfile, 'tempdir', str(scratch))
    authority = await authorities()
    before = set(os.listdir(home_of(authority)))
    work = await mac(authority, responder=capture_answer)
    await call_raw(authority, {'device': 'Work Mac', 'action': 'screen.capture', 'args': {'read_text': True}})
    await call_device(authority, 'Work Mac', 'screen.read')
    assert os.listdir(scratch) == []
    assert not [name for name in set(os.listdir(home_of(authority))) - before if name.lower().endswith(('.jpg', '.png'))]
    await work.connection.close()


@pytest.mark.asyncio
async def test_one_capture_at_a_time_and_a_minimum_interval_per_device(authorities, monkeypatch):
    from gateway import device_actions, device_tools
    monkeypatch.setattr(device_tools, 'MIN_TIMEOUT_SECONDS', 0.2)
    monkeypatch.setattr(device_tools, 'DEFAULT_TIMEOUT_SECONDS', 0.6)
    authority = await authorities()
    work = await mac(authority, responder=lambda p: None)
    first = asyncio.create_task(call_device(authority, 'Work Mac', 'screen.capture'))
    await async_wait_until(lambda: work.requests())
    second = await call_device(authority, 'Work Mac', 'screen.capture')
    assert (await first)['code'] == 'timeout' and second['code'] == 'busy' and len(work.requests()) == 1
    monkeypatch.setattr(device_actions, 'SCREEN_MIN_INTERVAL_SECONDS', 60.0)
    work.responder = capture_answer
    await call_device(authority, 'Work Mac', 'screen.capture')
    assert (await call_device(authority, 'Work Mac', 'screen.capture'))['code'] == 'rate_limited'
    await work.connection.close()

