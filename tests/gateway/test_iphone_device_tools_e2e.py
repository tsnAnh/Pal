import asyncio
import json
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from tests.gateway.fixtures.local_recovery_probe import child_env, daemon, websocket
from tests.waiting import async_wait_until

ROOT = Path(__file__).resolve().parents[2]
DEVICE_ID = 'e2e-iphone-' + uuid.uuid4().hex[:8]
TOOL_CALLS = {
    'CONTACTS_PLEASE': ('call_contacts', {'action': 'contacts.search', 'args': {'query': 'Sam'}}),
    'ADD_EVENT_PLEASE': ('call_event', {'action': 'calendar.add_event', 'args': {
        'title': 'Dentist', 'start': '2026-11-12T15:00:00+07:00'}}),
}
PHONE_ANSWERS = {
    'contacts.search': {'contacts': [{'id': 'c1', 'name': 'Sam Rivera', 'phones': ['+1 555 0100']}]},
    'calendar.add_event': {'event': {'id': 'e1', 'title': 'Dentist', 'start': '2026-11-12T15:00:00+07:00'}},
}


class IphoneModel(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.reply({'object': 'list', 'data': [{'id': 'stub', 'object': 'model'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = body.get('messages') or []
        if not messages:
            return self.reply({'error': {'message': 'empty'}}, 400)
        self.server.requests.append(body)
        last = messages[-1]
        message = {'role': 'assistant', 'content': 'ok'}
        finish = 'stop'
        text = next((m.get('content') for m in reversed(messages) if m.get('role') == 'user'), '')
        text = text if isinstance(text, str) else ''.join(p.get('text', '') for p in text)
        marker = next((m for m in TOOL_CALLS if m in text), None)
        names = [t['function']['name'] for t in body.get('tools') or []]
        if last.get('role') == 'tool':
            message['content'] = 'RESULT ' + str(last.get('content'))
        elif marker and 'iphone' in names:
            call_id, arguments = TOOL_CALLS[marker]
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': call_id + '_' + uuid.uuid4().hex[:6], 'type': 'function',
                'function': {'name': 'iphone', 'arguments': json.dumps(arguments)}}]}
            finish = 'tool_calls'
        elif marker:
            message['content'] = 'NO_IPHONE_TOOL'
        if body.get('stream'):
            return self.stream(message, finish)
        self.reply({'id': 'c', 'object': 'chat.completion', 'model': 'stub', 'choices': [{
            'index': 0, 'message': message, 'finish_reason': finish}],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15}})

    def stream(self, message, finish):
        delta = dict(message)
        if message.get('tool_calls'):
            delta['tool_calls'] = [{'index': 0, **call} for call in message['tool_calls']]
        data = ('data: ' + json.dumps({'id': 'c', 'object': 'chat.completion.chunk', 'model': 'stub', 'choices': [{
            'index': 0, 'delta': delta, 'finish_reason': finish}]}) + '\n\ndata: [DONE]\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def reply(self, payload, status=200):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Phone:
    def __init__(self, ws, *, answers=True):
        self.ws, self.answers = ws, answers
        self.approval_choices: list[str] = []
        self.approvals: list[dict] = []
        self.frames: list[dict] = []
        self.requests: list[dict] = []
        self.pending: dict = {}
        self.ids = 0
        self.task = asyncio.create_task(self.pump())

    async def pump(self):
        async for raw in self.ws:
            frame = json.loads(raw)
            if 'method' not in frame and frame.get('id') in self.pending:
                self.pending.pop(frame['id']).set_result(frame)
                continue
            self.frames.append(frame)
            params = frame.get('params') or {}
            if params.get('type') == 'approval.request':
                prompt = params.get('payload') or params
                self.approvals.append(prompt)
                asyncio.create_task(self.call(
                    'approval.respond', session_id=params['session_id'],
                    execution_generation=prompt['execution_generation'], prompt_id=prompt['prompt_id'],
                    choice=self.approval_choices.pop(0) if self.approval_choices else 'deny'))
            if params.get('type') == 'device.tool.request':
                self.requests.append(params['payload'])
                if self.answers:
                    asyncio.create_task(self.answer(params['payload']))

    async def answer(self, request):
        result = PHONE_ANSWERS[request['action']]
        await self.call('device.tool.respond', request_id=request['request_id'], ok=True, result=result)

    async def call(self, method, **params):
        self.ids += 1
        rid = f'{method}-{self.ids}'
        self.pending[rid] = asyncio.get_running_loop().create_future()
        await self.ws.send(json.dumps({'jsonrpc': '2.0', 'id': rid, 'method': method, 'params': params}))
        async with asyncio.timeout(30):
            reply = await self.pending[rid]
        assert 'result' in reply, (method, reply)
        return reply['result']

    def events(self, type_):
        return [f['params'] for f in self.frames if (f.get('params') or {}).get('type') == type_]

    async def turn(self, session_id, text):
        mark = len(self.frames)
        await self.call('prompt.submit', session_id=session_id, submission_id=uuid.uuid4().hex, text=text)
        await async_wait_until(lambda: any((f.get('params') or {}).get('type') == 'message.complete'
                                           for f in self.frames[mark:]), timeout=90, what=f'turn {text}')

    async def close(self):
        await self.ws.close()
        await asyncio.gather(self.task, return_exceptions=True)


def tool_messages(request):
    return [m['content'] for m in request['messages'] if m.get('role') == 'tool']


def tools_of(request):
    return json.dumps(request.get('tools'), sort_keys=True)


def test_model_calls_the_iphone_through_a_real_daemon_and_a_websocket_phone(tmp_path):
    home, user = tmp_path / 'state', tmp_path / 'user'
    home.mkdir(mode=0o700)
    user.mkdir()
    model = ThreadingHTTPServer(('127.0.0.1', 0), IphoneModel)
    model.requests = []
    thread = threading.Thread(target=model.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{model.server_port}/v1'
    (home / 'config.yaml').write_text(json.dumps({
        'gateway': {'multiplex_profiles': False},
        'model': {'provider': 'custom', 'default': 'stub', 'base_url': base},
        'auxiliary': {'title_generation': {'enabled': False}},
        'terminal': {'cwd': str(home)},
        'iphone': {'timeout_seconds': 20},
    }))
    env = child_env() | dict(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(ROOT),
                             OPENAI_API_KEY='loopback-only', OPENAI_BASE_URL=base, PYTHONUNBUFFERED='1')
    report = {}

    async def drive(desc):
        async with websocket(home, desc) as ws:
            phone = Phone(ws)
            hello = await phone.call('client.hello', kind='ios', device_id=DEVICE_ID, label='E2E iPhone',
                                     app_version='1.0', accepts_offers=False, device_tools=True, attention='foreground')
            assert hello['recorded'] is True
            connectors = await phone.call('device_connectors.list')
            assert {c['state'] for c in connectors['connectors']} == {'ask'}
            await phone.call('device_connectors.set', id='contacts', state='allowed')
            created = await phone.call('session.create', request_id=uuid.uuid4().hex, source='ios', cwd=str(home))
            session_id = created['session_id']

            await phone.turn(session_id, 'CONTACTS_PLEASE')
            report['contacts_request'] = phone.requests[0]
            phone.approval_choices = ['deny', 'once']
            await phone.turn(session_id, 'ADD_EVENT_PLEASE')
            report['after_denied_requests'] = [r['action'] for r in phone.requests]
            await phone.turn(session_id, 'ADD_EVENT_PLEASE')
            report['after_approved_requests'] = [r['action'] for r in phone.requests]
            report['event_request'] = phone.requests[1]
            report['approvals'] = phone.approvals
            await phone.close()
        return session_id

    async def offline_turn(desc, session_id):
        async with websocket(home, desc) as ws:
            phone = Phone(ws, answers=False)
            await phone.call('session.resume', session_id=session_id)
            await phone.turn(session_id, 'CONTACTS_PLEASE')
            report['offline_requests'] = len(phone.requests)
            await phone.close()

    try:
        with daemon(ROOT, home, env, barrier=False) as (_proc, desc):
            session_id = asyncio.run(drive(desc))
            asyncio.run(offline_turn(desc, session_id))
    finally:
        model.shutdown()
        model.server_close()
        thread.join(timeout=5)

    requests = model.requests
    with_tools = [r for r in requests if r.get('tools')]
    contacts_result = next(m for r in requests for m in tool_messages(r) if 'contacts.search' in m)
    denied = {m for r in requests for m in tool_messages(r) if 'approval_denied' in m}
    offline = {m for r in requests for m in tool_messages(r) if 'phone_offline' in m}
    report['contacts_result'] = json.loads(contacts_result)

    assert 'iphone' in [t['function']['name'] for t in requests[0]['tools']]
    assert len({tools_of(r) for r in with_tools}) == 1, 'the tool list never changed across connect, disconnect and reconnect'
    assert report['contacts_request']['action'] == 'contacts.search'
    assert report['contacts_request']['args'] == {'query': 'Sam', 'limit': 10}
    assert report['contacts_request']['needs_consent'] is False and report['contacts_request']['session_id']
    assert report['contacts_result']['untrusted_content'] is True
    assert report['contacts_result']['data']['contacts'][0]['name'] == 'Sam Rivera'
    assert report['after_denied_requests'] == ['contacts.search'], 'a denied write is never dispatched'
    assert len(denied) == 1
    assert report['after_approved_requests'] == ['contacts.search', 'calendar.add_event']
    assert report['event_request']['needs_consent'] is True
    assert len(report['approvals']) == 2 and all('Dentist' in json.dumps(a) for a in report['approvals'])
    assert report['offline_requests'] == 0 and len(offline) == 1
