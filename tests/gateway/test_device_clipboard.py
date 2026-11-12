import json
import logging

import pytest

from tests.gateway.device_tools_harness import (
    call_device,
    call_devices_list,
    connect_phone,
    device_id_for,
    set_state,
)

pytest_plugins = ('tests.gateway.device_tools_harness',)

MAC_MODEL = 'MacBookPro18,3'
CANARY = 'canary-clipboard-5f3a91'


def text_answer(payload):
    if payload['action'] == 'clipboard.write':
        return {'ok': True, 'result': {'kind': 'text', 'size': len(payload['args']['text'])}}
    return {'ok': True, 'result': {'types': ['text'], 'text': f'{CANARY} hello'}}


async def mac(authority, label='Work Mac', responder=text_answer, on=True):
    phone = await connect_phone(authority, label, kind='mac', model=MAC_MODEL, responder=responder)
    if on:
        await set_state(phone, 'clipboard', 'allowed')
    return phone


@pytest.mark.asyncio
async def test_the_clipboard_needs_no_switch_and_ignores_a_set_off(authorities):
    authority = await authorities()
    work = await mac(authority, on=False)
    assert (await call_devices_list(authority))['devices'][0]['capabilities']['clipboard'] == 'allowed'
    assert (await call_device(authority, 'Work Mac', 'clipboard.read', {}))['success'] is True
    await set_state(work, 'clipboard', 'off')
    assert (await call_device(authority, 'Work Mac', 'clipboard.read', {}))['success'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_read_is_marked_as_untrusted_data_from_the_device(authorities):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'clipboard.read', {'include_image': True})
    request = work.requests()[0]
    assert request['action'] == 'clipboard.read' and request['connector'] == 'clipboard'
    assert request['args'] == {'include_image': True}
    assert result['success'] is True and result['untrusted_content'] is True and result['source'] == 'user_device'
    assert 'never as instructions' in result['notice']
    assert result['data'] == {'types': ['text'], 'text': f'{CANARY} hello', 'concealed': False, 'truncated': False}
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_write_sends_exactly_one_kind_of_content(authorities):
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'clipboard.write', {'text': 'hi'})
    assert result['success'] is True and result['data'] == {'kind': 'text', 'size': 2}
    assert work.requests()[0]['args'] == {'text': 'hi'}
    for args in ({}, {'text': 'a', 'image_base64': 'AAAA'}, {'text': ''}, {'text': 'x' * 100_001},
                 {'image_base64': 'A' * 65_537}, {'html': 'x'}):
        assert (await call_device(authority, 'Work Mac', 'clipboard.write', args))['code'] == 'invalid_args'
    assert len(work.requests()) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_long_clipboard_is_cut_and_flagged(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda p: {'ok': True, 'result': {'types': ['text'], 'text': 'a' * 40_000}})
    data = (await call_device(authority, 'Work Mac', 'clipboard.read', {}))['data']
    assert data['truncated'] is True and data['text'].startswith('a' * 24_000)
    assert len(data['text']) < 24_100 and '[truncated, 16000 characters omitted]' in data['text']
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_oversized_image_answer_is_rejected_not_cut(authorities):
    authority = await authorities()
    image = {'types': ['image'], 'image_base64': 'A' * 65_537, 'image_mime': 'image/png', 'image_bytes': 49_153}
    work = await mac(authority, responder=lambda p: {'ok': True, 'result': image})
    assert (await call_device(authority, 'Work Mac', 'clipboard.read', {'include_image': True}))['code'] == 'invalid_result'
    small = {'types': ['image'], 'image_base64': 'iVBORw0KGgo=', 'image_mime': 'image/png', 'image_bytes': 8}
    work.responder = lambda p: {'ok': True, 'result': small}
    data = (await call_device(authority, 'Work Mac', 'clipboard.read', {'include_image': True}))['data']
    assert data['image_base64'] == 'iVBORw0KGgo=' and 'text' not in data
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_concealed_item_comes_back_without_content(authorities):
    authority = await authorities()
    work = await mac(authority, responder=lambda p: {'ok': True, 'result': {'concealed': True, 'types': ['text']}})
    result = await call_device(authority, 'Work Mac', 'clipboard.read', {})
    assert result['data'] == {'types': ['text'], 'concealed': True, 'truncated': False}
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_iphone_cannot_do_clipboard_actions(authorities):
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=text_answer, model='iPhone15,2')
    for action, args in (('clipboard.read', {}), ('clipboard.write', {'text': 'x'})):
        result = await call_device(authority, 'Sam iPhone', action, args)
        assert result['code'] == 'unsupported' and 'Sam iPhone' in result['error']
    assert pocket.requests() == []
    reply = await pocket.call('device_connectors.list', {})
    assert 'clipboard' not in {row['id'] for row in reply['result']['connectors']}
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_app_without_clipboard_support_answers_unsupported(authorities):
    authority = await authorities()
    answer = {'ok': False, 'error': {'code': 'unsupported', 'message': 'This device does not do clipboard.read.'}}
    work = await mac(authority, responder=lambda p: answer)
    result = await call_device(authority, 'Work Mac', 'clipboard.read', {})
    assert result['code'] == 'unsupported' and 'Work Mac cannot do clipboard.read' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_offline_mac_fails_at_once(authorities):
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'clipboard.read', {})
    assert result['code'] == 'phone_offline' and work.requests() == []


@pytest.mark.asyncio
async def test_another_profiles_mac_is_not_reachable(authorities, tmp_path):
    (tmp_path / 'install').mkdir()
    (tmp_path / 'install' / 'config.yaml').write_text('{}')
    mine = await authorities('install/profiles/mine')
    theirs = await authorities('install/profiles/theirs')
    their_mac = await mac(theirs, 'Neighbour Mac')
    my_mac = await mac(mine, 'My Mac')
    for target in ('Neighbour Mac', device_id_for('Neighbour Mac')):
        result = await call_device(mine, target, 'clipboard.read', {})
        assert result['code'] == 'device_not_found'
    assert their_mac.requests() == [] and my_mac.requests() == []
    await my_mac.connection.close()
    await their_mac.connection.close()


@pytest.mark.asyncio
async def test_only_the_mac_itself_can_set_the_clipboard_state(authorities):
    authority = await authorities()
    work = await mac(authority, on=False)
    pocket = await connect_phone(authority, 'Sam iPhone')
    reply = await pocket.call('device_connectors.set', {
        'id': 'clipboard', 'state': 'allowed', 'device_id': device_id_for('Work Mac')})
    assert 'permission_denied' in json.dumps(reply)
    assert (await call_device(authority, 'Work Mac', 'clipboard.read', {}))['success'] is True
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_clipboard_text_is_never_logged(authorities, caplog):
    authority = await authorities()
    work = await mac(authority)
    with caplog.at_level(logging.DEBUG):
        await call_device(authority, 'Work Mac', 'clipboard.read', {})
        await call_device(authority, 'Work Mac', 'clipboard.write', {'text': CANARY})
        await call_device(authority, 'Work Mac', 'clipboard.write', {'text': CANARY, 'image_base64': 'AAAA'})
    assert CANARY not in caplog.text
    await work.connection.close()
