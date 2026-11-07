"""A bot-to-bot DM through a real multiplexed ``gateway.run`` daemon, read back over the canonical socket."""
import asyncio
import json
import os
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from websockets.asyncio.client import connect

import hermes_yaml as yaml
from tests.gateway.fixtures.local_recovery_probe import child_env, daemon
from tests.gateway.test_iphone_device_tools_e2e import Phone
from tests.gateway.test_normal_runtime_boot import control
from tests.waiting import async_wait_until

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = Path(os.environ.get('BOT_THREADS_E2E_ARTIFACT', '/tmp/bot-threads-e2e/real-daemon-transcript.json'))
ASK = 'MESSAGE_BETA_PLEASE'
QUESTION = 'ALPHA_TO_BETA: what is your status?'
ANSWER = 'BETA_STATUS_GREEN'


class BotModel(BaseHTTPRequestHandler):
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
        text = next((m.get('content') for m in reversed(messages) if m.get('role') == 'user'), '')
        text = text if isinstance(text, str) else ''.join(p.get('text', '') for p in text)
        names = [t['function']['name'] for t in body.get('tools') or []]
        message, finish = {'role': 'assistant', 'content': 'ok'}, 'stop'
        if messages[-1].get('role') == 'tool':
            message['content'] = 'SENT'
        elif ASK in text and 'message_agent' in names:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{
                'id': 'call_dm_' + uuid.uuid4().hex[:6], 'type': 'function', 'function': {
                    'name': 'message_agent', 'arguments': json.dumps({'target': 'beta', 'message': QUESTION})}}]}
            finish = 'tool_calls'
        elif QUESTION in text:
            message['content'] = ANSWER
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


class Bot(Phone):
    def __init__(self, ws, name, transcript):
        super().__init__(ws)
        self.name, self.transcript = name, transcript

    async def probe(self, method, **params):
        return await super().call(method, **params)

    async def call(self, method, **params):
        entry = {'bot': self.name, 'method': method, 'params': params}
        self.transcript.append(entry)
        try:
            entry['result'] = await super().call(method, **params)
        except AssertionError as exc:
            entry['error'] = str(exc)
            raise
        return entry['result']


def bot_socket(root, home, desc):
    grant = control(root, 'session-ticket', {'profile_id': str(home), 'instance_id': desc['instance_id'],
                                             'purpose': 'interactive'})
    return connect(desc['api_origin'].replace('http:', 'ws:') + '/api/ws',
                   subprotocols=['hermes-gateway-v1', 'hermes-gateway-ticket.' + grant['ticket']])


def prepare(tmp_path, base):
    from hermes_cli.profiles import create_profile, get_profile_dir
    root, user = tmp_path / 'state', tmp_path / 'user'
    root.mkdir(mode=0o700)
    user.mkdir()
    config = {'gateway': {'multiplex_profiles': True},
              'model': {'provider': 'custom', 'default': 'stub', 'base_url': base},
              'auxiliary': {'title_generation': {'enabled': False}}, 'terminal': {'cwd': str(root)}}
    (root / 'config.yaml').write_text(json.dumps(config))
    previous = os.environ.get('HERMES_HOME')
    os.environ['HERMES_HOME'] = str(root)
    try:
        homes = {}
        for name in ('alpha', 'beta'):
            create_profile(name, no_alias=True, no_skills=True)
            homes[name] = get_profile_dir(name)
            (homes[name] / 'config.yaml').write_text(json.dumps(config))
            (homes[name] / 'profile.yaml').write_text(yaml.safe_dump(
                {'ui_meta': {'hermes-bots': {'title': name.title(), 'description': f'{name} bot'}}}))
    finally:
        if previous is None:
            os.environ.pop('HERMES_HOME')
        else:
            os.environ['HERMES_HOME'] = previous
    env = child_env() | dict(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(root), PYTHONPATH=str(ROOT),
                             OPENAI_API_KEY='loopback-only', OPENAI_BASE_URL=base, PYTHONUNBUFFERED='1')
    return root, homes, env


async def eventually(check, what, timeout=90):
    async with asyncio.timeout(timeout):
        while not (value := await check()):
            await asyncio.sleep(0)
    return value


async def drive(root, homes, desc, transcript):
    async with bot_socket(root, homes['alpha'], desc) as alpha_ws, bot_socket(root, homes['beta'], desc) as beta_ws:
        alpha, beta = Bot(alpha_ws, 'alpha', transcript), Bot(beta_ws, 'beta', transcript)
        chat = await alpha.call('session.create', request_id=uuid.uuid4().hex, source='gui', cwd=str(homes['alpha']),
                                title='Bot Chat', hidden=True)
        await alpha.turn(chat['session_id'], ASK)

        async def alpha_answered():
            threads = (await alpha.probe('bot.thread.list'))['threads']
            if not threads:
                return None
            page = await alpha.probe('bot.thread.read', thread_id=threads[0]['thread_id'])
            return page if any(m['part'] == 'reply' for m in page['messages']) else None

        async def beta_answered():
            threads = (await beta.probe('bot.thread.list'))['threads']
            if not threads:
                return None
            page = await beta.probe('bot.thread.read', thread_id=threads[0]['thread_id'])
            return page if any(m['part'] == 'reply' and m['status'] == 'answered' for m in page['messages']) else None

        await eventually(alpha_answered, 'alpha thread carries beta reply')
        await eventually(beta_answered, 'beta thread carries its answer')
        alpha_list = await alpha.call('bot.thread.list')
        thread_id = alpha_list['threads'][0]['thread_id']
        links = await alpha.call('bot.thread.links', session_id=chat['session_id'])
        exchange_id = links['links'][0]['exchange_id']
        alpha_read = await alpha.call('bot.thread.read', thread_id=thread_id, focus=exchange_id)
        beta_list = await beta.call('bot.thread.list')
        beta_thread = beta_list['threads'][0]['thread_id']
        beta_read = await beta.call('bot.thread.read', thread_id=beta_thread)
        await async_wait_until(lambda: alpha.events('bot_threads.changed') and beta.events('bot_threads.changed'),
                               timeout=30, what='bot_threads.changed reached both clients')
        changed = {'alpha': alpha.events('bot_threads.changed'), 'beta': beta.events('bot_threads.changed')}
        transcript.extend({'bot': name, 'event': 'bot_threads.changed', 'frames': frames} for name, frames in changed.items())
        await alpha.close()
        await beta.close()
    return dict(chat=chat, alpha_list=alpha_list, links=links, alpha_read=alpha_read, beta_list=beta_list,
                beta_read=beta_read, changed=changed)


def test_a_bot_dm_is_recorded_and_readable_over_the_canonical_socket_on_both_sides(tmp_path):
    model = ThreadingHTTPServer(('127.0.0.1', 0), BotModel)
    model.requests = []
    thread = threading.Thread(target=model.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{model.server_port}/v1'
    root, homes, env = prepare(tmp_path, base)
    transcript = []
    try:
        with daemon(ROOT, root, env, barrier=False) as (_proc, desc):
            seen = asyncio.run(drive(root, homes, desc, transcript))
    finally:
        model.shutdown()
        model.server_close()
        thread.join(timeout=5)
        ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
        ARTIFACT.write_text(json.dumps({'transcript': transcript}, indent=2, sort_keys=True, default=str))

    alpha_key, beta_key = 'local:alpha', 'local:beta'
    [summary] = seen['alpha_list']['threads']
    assert summary['counterpart']['key'] == beta_key and summary['counterpart']['local_profile'] == 'beta'
    assert summary['message_count'] == 2 and summary['last_sender_key'] == beta_key
    assert summary['last_preview'] == ANSWER

    [link] = seen['links']['links']
    assert link['kind'] == 'messaged' and link['count'] == 2 and link['counterpart']['key'] == beta_key
    assert link['thread_id'] == summary['thread_id'] and len(link['covered_uids']) == 2
    assert seen['links']['truncated'] is False

    sent, answer = seen['alpha_read']['messages']
    assert (sent['part'], sent['sender_key'], sent['text']) == ('message', alpha_key, QUESTION)
    assert (answer['part'], answer['sender_key'], answer['text']) == ('reply', beta_key, ANSWER)
    assert sent['exchange_id'] == answer['exchange_id'] == link['exchange_id'] and link['exchange_id'].startswith('out:')
    assert {sent['status'], answer['status']} == {'answered'}
    assert seen['alpha_read']['focus_index'] == 0
    assert seen['alpha_read']['coverage'] == 'both_sides' and seen['alpha_read']['read_only'] is True
    assert [p['key'] for p in seen['alpha_read']['participants']] == [alpha_key, beta_key]
    assert [p['is_self'] for p in seen['alpha_read']['participants']] == [True, False]

    [inbound] = seen['beta_list']['threads']
    assert inbound['counterpart']['key'] == alpha_key and inbound['counterpart']['local_profile'] == 'alpha'
    assert inbound['message_count'] == 2 and inbound['last_sender_key'] == beta_key
    received, replied = seen['beta_read']['messages']
    assert (received['part'], received['sender_key'], received['text']) == ('message', alpha_key, QUESTION)
    assert (replied['part'], replied['sender_key'], replied['text']) == ('reply', beta_key, ANSWER)
    assert received['exchange_id'] == replied['exchange_id'] and received['exchange_id'].startswith('in:')
    assert received['exchange_id'][3:] == link['exchange_id'][4:], 'both sides key the exchange by one delivery id'
    assert replied['status'] == 'answered'
    assert seen['beta_read']['coverage'] == 'both_sides' and seen['beta_read']['read_only'] is True
    assert [p['key'] for p in seen['beta_read']['participants']] == [beta_key, alpha_key]

    assert seen['changed']['alpha'] and seen['changed']['beta']
