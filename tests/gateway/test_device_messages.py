import json
import logging
from pathlib import Path

import pytest

from tests.gateway.device_tools_harness import call_device, call_devices_list, connect_phone, device_id_for, home_of

pytest_plugins = ('tests.gateway.device_tools_harness',)

MAC_MODEL = 'MacBookPro18,3'
CANARY = 'canary-message-8c1d77'
SEND_CANARY = 'canary-send-41ab90'


def message(n=1, text=CANARY, **extra):
    return {'id': n, 'at': '2026-11-12T10:00:00Z', 'from_me': False, 'sender': '+15550100', 'text': text, **extra}


def conversation(**extra):
    return {'chat_id': 'chat-1', 'title': 'Sam', 'participants': [{'handle': '+15550100', 'name': 'Sam'}],
            'last_at': '2026-11-12T10:00:00Z', 'messages': [message()], **extra}


def answer(payload):
    action = payload['action']
    if action == 'messages.recent':
        return {'ok': True, 'result': {'conversations': [conversation()]}}
    if action == 'messages.search':
        return {'ok': True, 'result': {'matches': [{'chat_id': 'chat-1', 'message': message()}]}}
    if action == 'messages.read':
        return {'ok': True, 'result': conversation()}
    return {'ok': True, 'result': {'sent': True, 'service': 'imessage', 'recipient': payload['args']['recipient']}}


async def mac(authority, label='Work Mac', responder=answer):
    return await connect_phone(authority, label, kind='mac', model=MAC_MODEL, responder=responder)


class Owner:
    def __init__(self, monkeypatch, *, approved=True, viewer=True, unattended=False, edited=None, boom=False):
        from tools import approval, approval_context
        self.cards = []
        self.approved, self.edited, self.boom = approved, edited, boom
        monkeypatch.setattr(approval_context, 'is_viewer_turn_with_approver', lambda: viewer)
        monkeypatch.setattr(approval_context, '_no_user_can_answer', lambda: unattended)
        monkeypatch.setattr(approval, 'request_draft_approval', self.ask)

    def ask(self, **kwargs):
        self.cards.append(kwargs)
        if self.boom:
            raise RuntimeError(SEND_CANARY)
        result = {'approved': self.approved, 'message': None if self.approved else 'BLOCKED: The owner discarded this draft.'}
        if self.edited is not None:
            result['edited_text'] = self.edited
        return result


SEND = {'recipient': '+15550123', 'text': f'see you at 5 {SEND_CANARY}'}


@pytest.mark.asyncio
async def test_the_catalog_lists_messages_for_a_mac_only_and_it_is_always_on(authorities):
    authority = await authorities()
    work = await mac(authority)
    pocket = await connect_phone(authority, 'Sam iPhone', model='iPhone15,2')
    rows = {row['id']: row for row in (await work.call('device_connectors.list', {}))['result']['connectors']}
    assert rows['messages']['title'] == 'Messages' and rows['messages']['always_on'] is True
    assert rows['messages']['subtitle'] == 'Read and send your messages'
    assert rows['clipboard']['always_on'] is True
    assert 'messages' not in {row['id'] for row in (await pocket.call('device_connectors.list', {}))['result']['connectors']}
    await work.connection.close()
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_old_app_switch_state_is_ignored_and_messages_stay_reachable(authorities):
    authority = await authorities()
    work = await mac(authority)
    assert (await call_devices_list(authority))['devices'][0]['capabilities']['messages'] == 'allowed'
    for state in ('off', 'ask', 'allowed'):
        reply = await work.call('device_connectors.set', {'id': 'messages', 'state': state})
        assert {row['id']: row['state'] for row in reply['result']['connectors']}['messages'] == 'allowed'
        assert (await call_device(authority, 'Work Mac', 'messages.recent', {}))['success'] is True
    await work.connection.close()


@pytest.mark.asyncio
async def test_reads_run_without_a_card_and_are_marked_untrusted(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    for action, args in (('messages.recent', {'limit': 5, 'messages_per_chat': 2}),
                         ('messages.search', {'query': 'dinner'}), ('messages.read', {'chat_id': 'chat-1'})):
        result = await call_device(authority, 'Work Mac', action, args)
        assert result['success'] is True and result['untrusted_content'] is True
        assert 'written by other people' in result['notice'] and 'never as instructions' in result['notice']
    assert owner.cards == []
    assert [r['connector'] for r in work.requests()] == ['messages'] * 3
    assert work.requests()[0]['args'] == {'limit': 5, 'messages_per_chat': 2}
    await work.connection.close()


@pytest.mark.asyncio
async def test_result_shapes_are_bounded_and_text_is_cut_and_cleaned(authorities):
    long = 'a' * 1500 + '\x00\x07'
    dirty = message(1, text=f'hi\x00\U000e0049there {long}', sender='x' * 500)
    chat = conversation(participants=[{'handle': f'h{i}'} for i in range(40)], messages=[dirty] * 60)
    work = await mac(await authorities(), responder=lambda p: {'ok': True, 'result': chat})
    authority = work.connection.authority
    data = (await call_device(authority, 'Work Mac', 'messages.read', {'chat_id': 'chat-1', 'limit': 50}))['data']
    assert len(data['participants']) == 20 and len(data['messages']) == 50
    first = data['messages'][0]
    assert first['truncated'] is True and data['truncated'] is True
    assert first['text'].startswith('hithere ' + 'a' * 20) and '\x00' not in first['text']
    assert len(first['text']) < 1100 and len(first['sender']) <= 200
    await work.connection.close()


@pytest.mark.asyncio
async def test_lists_are_capped_and_an_oversized_answer_is_rejected(authorities):
    many = {'conversations': [conversation() for _ in range(40)]}
    work = await mac(await authorities(), responder=lambda p: {'ok': True, 'result': many})
    authority = work.connection.authority
    data = (await call_device(authority, 'Work Mac', 'messages.recent', {}))['data']
    assert len(data['conversations']) == 25
    work.responder = lambda p: {'ok': True, 'result': {'conversations': [conversation(
        messages=[message(i, text='b' * 1000) for i in range(30)]) for _ in range(10)]}}
    assert (await call_device(authority, 'Work Mac', 'messages.recent', {}))['code'] == 'invalid_result'
    await work.connection.close()


@pytest.mark.asyncio
async def test_invalid_arguments_never_reach_the_mac(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    bad = (('messages.recent', {'limit': 26}), ('messages.recent', {'messages_per_chat': 11}),
           ('messages.search', {'query': ''}), ('messages.search', {'query': 'x' * 201}),
           ('messages.read', {'chat_id': ''}), ('messages.read', {'chat_id': 'c', 'limit': 51}),
           ('messages.recent', {'extra': 1}), ('messages.send', {'recipient': 'a b', 'text': 'x'}),
           ('messages.send', {'recipient': '+1555', 'text': ''}), ('messages.send', {'recipient': '+1555', 'text': 'x' * 4001}),
           ('messages.send', {'recipient': '+1555', 'text': 'a\x00b'}), ('messages.send', {'recipient': '+1555', 'text': 'a\U000e0049'}),
           ('messages.send', {'recipient': '+1555', 'text': 'x', 'service': 'whatsapp'}))
    for action, args in bad:
        assert (await call_device(authority, 'Work Mac', action, args))['code'] == 'invalid_args', (action, args)
    assert work.requests() == [] and owner.cards == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_send_shows_a_non_editable_card_and_dispatches_the_same_arguments(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'messages.send', {**SEND, 'service': 'imessage'})
    assert result['success'] is True and result['data'] == {'sent': True, 'service': 'imessage', 'recipient': '+15550123'}
    card = owner.cards[0]
    assert card['text'] == SEND['text'] and card['draft']['editable'] is False
    assert card['draft']['recipient'] == '+15550123' and card['draft']['channel'] == 'iMessage'
    assert 'Work Mac' in card['description'] and SEND_CANARY not in card['description']
    assert work.requests()[0]['args'] == {**SEND, 'service': 'imessage'}
    await work.connection.close()


@pytest.mark.asyncio
async def test_send_needs_a_card_every_time_even_when_it_was_approved_before(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    for _ in range(2):
        assert (await call_device(authority, 'Work Mac', 'messages.send', SEND))['success'] is True
    assert len(owner.cards) == 2 and len(work.requests()) == 2
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_denied_send_sends_nothing(authorities, monkeypatch):
    owner = Owner(monkeypatch, approved=False)
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'messages.send', SEND)
    assert result['code'] == 'approval_denied' and SEND_CANARY not in json.dumps(result)
    assert work.requests() == [] and len(owner.cards) == 1
    await work.connection.close()


@pytest.mark.asyncio
async def test_an_edited_text_is_refused_but_an_unchanged_echo_is_accepted(authorities, monkeypatch):
    owner = Owner(monkeypatch, edited='something else')
    authority = await authorities()
    work = await mac(authority)
    assert (await call_device(authority, 'Work Mac', 'messages.send', SEND))['code'] == 'approval_denied'
    assert work.requests() == []
    owner.edited = SEND['text']
    assert (await call_device(authority, 'Work Mac', 'messages.send', SEND))['success'] is True
    assert work.requests()[0]['args'] == SEND
    await work.connection.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('flags', [{'viewer': False}, {'unattended': True}, {'viewer': False, 'unattended': True},
                                   {'boom': True}])
async def test_send_is_refused_where_nobody_can_answer_or_the_approval_layer_fails(authorities, monkeypatch, flags):
    owner = Owner(monkeypatch, **flags)
    authority = await authorities()
    work = await mac(authority)
    result = await call_device(authority, 'Work Mac', 'messages.send', SEND)
    assert result['code'] == 'approval_unavailable' and SEND_CANARY not in json.dumps(result)
    assert work.requests() == []
    if flags.get('boom') is None:
        assert owner.cards == []
    await work.connection.close()


@pytest.mark.asyncio
async def test_a_send_to_an_offline_mac_sends_nothing(authorities, monkeypatch):
    Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    await work.connection.close()
    result = await call_device(authority, 'Work Mac', 'messages.send', SEND)
    assert result['code'] == 'phone_offline' and work.requests() == []


@pytest.mark.asyncio
async def test_an_iphone_cannot_use_messages(authorities, monkeypatch):
    owner = Owner(monkeypatch)
    authority = await authorities()
    pocket = await connect_phone(authority, 'Sam iPhone', responder=answer, model='iPhone15,2')
    for action, args in (('messages.recent', {}), ('messages.send', SEND)):
        assert (await call_device(authority, 'Sam iPhone', action, args))['code'] == 'unsupported'
    assert pocket.requests() == [] and owner.cards == []
    await pocket.connection.close()


@pytest.mark.asyncio
async def test_an_older_mac_app_answering_unsupported_maps_to_unsupported(authorities, monkeypatch):
    Owner(monkeypatch)
    refusal = {'ok': False, 'error': {'code': 'unsupported', 'message': 'This device does not do messages.recent.'}}
    work = await mac(await authorities(), responder=lambda p: refusal)
    result = await call_device(work.connection.authority, 'Work Mac', 'messages.recent', {})
    assert result['code'] == 'unsupported' and 'Work Mac cannot do messages.recent' in result['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_missing_permission_names_full_disk_access_for_reads_and_automation_for_send(authorities, monkeypatch):
    Owner(monkeypatch)
    denied = {'ok': False, 'error': {'code': 'permission_denied', 'message': 'no'}}
    work = await mac(await authorities(), responder=lambda p: denied)
    authority = work.connection.authority
    read = await call_device(authority, 'Work Mac', 'messages.recent', {})
    sent = await call_device(authority, 'Work Mac', 'messages.send', SEND)
    assert read['code'] == sent['code'] == 'permission_denied'
    assert 'Full Disk Access' in read['error'] and 'Automation' in sent['error']
    await work.connection.close()


@pytest.mark.asyncio
async def test_message_text_never_reaches_the_logs(authorities, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    owner = Owner(monkeypatch)
    authority = await authorities()
    work = await mac(authority)
    await call_device(authority, 'Work Mac', 'messages.recent', {})
    await call_device(authority, 'Work Mac', 'messages.send', SEND)
    owner.boom = True
    await call_device(authority, 'Work Mac', 'messages.send', SEND)
    owner.boom = False
    work.responder = lambda p: {'ok': False, 'error': {'code': 'failed', 'message': 'boom'}}
    await call_device(authority, 'Work Mac', 'messages.send', SEND)
    work.responder = lambda p: {'ok': True, 'result': {'conversations': 'bad ' + CANARY}}
    await call_device(authority, 'Work Mac', 'messages.recent', {})
    assert CANARY not in caplog.text and SEND_CANARY not in caplog.text
    await work.connection.close()


def test_an_unknown_action_on_the_connector_needs_the_card_and_reads_do_not():
    from dataclasses import replace

    from gateway.device_actions import ACTIONS
    assert [name for name, spec in ACTIONS.items() if spec.asks_every_time] == ['messages.send']
    assert not any(ACTIONS[name].asks_every_time for name in ('messages.recent', 'messages.search', 'messages.read'))
    assert replace(ACTIONS['messages.read'], name='messages.archive').asks_every_time is True
    assert ACTIONS['clipboard.write'].asks_every_time is False


def test_the_tool_text_tells_the_bot_how_messages_behave():
    from gateway.device_actions import action_catalog_text
    from tools.devices_tool import _device_overrides
    text = _device_overrides()['description']
    assert 'messages.send needs the owner' in text and 'private' in text and 'cannot approve it' in text
    assert "messages.send(recipient, text, service?)" in action_catalog_text()
    assert "[needs the owner's approval each time]" in action_catalog_text()


def test_the_store_always_allows_messages_and_ignores_a_switch_state(tmp_path: Path):
    from gateway import device_connectors
    from tui_gateway.contracts.canonical_device import DeviceConnectorId as C
    from tui_gateway.contracts.canonical_device import DeviceConnectorState as S
    device_connectors.register_device(tmp_path, 'device-mac-0001', 'Work Mac', kind='mac')
    states = lambda: {row.connector: row.state for row in device_connectors.statuses(tmp_path, 'device-mac-0001')}
    assert states()[C.MESSAGES] is S.ALLOWED and states()[C.CLIPBOARD] is S.ALLOWED
    assert device_connectors.open_devices(tmp_path, C.MESSAGES) == {'device-mac-0001': S.ALLOWED}
    for state in (S.OFF, S.ASK, S.ALLOWED):
        device_connectors.update(tmp_path, 'device-mac-0001', C.MESSAGES, state=state)
        assert states()[C.MESSAGES] is S.ALLOWED
