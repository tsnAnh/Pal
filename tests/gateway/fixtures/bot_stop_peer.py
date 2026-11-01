"""Production daemon: an explicit Stop of one Bot Chat delivery (running, then queued) over real WebSockets."""
import asyncio
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sqlite3
import sys
import threading

from automation_peer import Model
from local_recovery_probe import daemon, websocket, rpc
from tests.waiting import async_wait_until


def probe(base):
    root = Path(__file__).resolve().parents[3]
    home, user = base / 'state', base / 'user'
    home.mkdir(); user.mkdir()
    model = ThreadingHTTPServer(('127.0.0.1', 0), Model)
    model.requests = []
    model.blocked, model.release = threading.Event(), threading.Event()
    threading.Thread(target=model.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{model.server_port}/v1'
    (home / 'config.yaml').write_text(json.dumps({'gateway': {'multiplex_profiles': False},
        'model': {'provider': 'custom', 'default': 'local-fixture', 'base_url': url},
        'auxiliary': {'title_generation': {'enabled': False}}}))
    env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TZ', 'TIRITH_ENABLED') if k in os.environ}
    env.update(HOME=str(user), USERPROFILE=str(user), HERMES_HOME=str(home), PYTHONPATH=str(root),
               OPENAI_API_KEY='loopback-only', OPENAI_BASE_URL=url)

    def rows():
        with sqlite3.connect(f'file:{home / "state.db"}?mode=ro', uri=True) as db:
            db.row_factory = sqlite3.Row
            return [dict(r) for r in db.execute('SELECT * FROM session_admissions ORDER BY seq')]

    def row_for(text):
        return next((r for r in rows() if text in r['payload_json']), None)

    async def wait(predicate):
        await async_wait_until(predicate, timeout=30, interval=.05)

    def params(key, text):
        return {'id': key * 32, 'profile': 'default', 'message': f'[Message from @sender] {text}',
                'author': {'id': 'bot:peer/sender', 'name': 'Sender', 'is_bot': True}}

    async def run(desc):
        async with websocket(home, desc) as ws:
            created = await rpc(ws, 'session.create', request_id='bot', source='gui', toolsets=[], cwd=str(home))
            sid = created['result']['session_id']
            renamed = await rpc(ws, 'session.mutate', session_id=sid, request_id='name',
                expected_revision=created['result']['revision'], operation='rename', payload={'title': 'Bot Chat'})
            assert 'result' in renamed, renamed
            running, queued = params('a', 'HOLD_AUTOMATION running'), params('b', 'queued behind the hold')
            assert 'result' in await rpc(ws, 'bot_relay.deliver', **running)
            assert await asyncio.to_thread(model.blocked.wait, 30)
            assert 'result' in await rpc(ws, 'bot_relay.deliver', **queued)
            await wait(lambda: (row_for('queued behind') or {}).get('status') == 'queued')

            unknown = await rpc(ws, 'bot_relay.stop', id='f' * 32, profile='default')
            assert unknown['result']['status'] == 'not_found' and unknown['result']['stopped'] is False, unknown
            wrong = await rpc(ws, 'bot_relay.stop', id='a' * 32, profile='wrong-profile')
            assert wrong['error']['message'] == 'profile_mismatch', wrong

            stopped_queued = await rpc(ws, 'bot_relay.stop', id='b' * 32, profile='default')
            assert stopped_queued['result'] == {'status': 'cancelled', 'stopped': True, 'handoffs': 0}, stopped_queued
            assert row_for('queued behind')['outcome'] == 'cancelled', row_for('queued behind')

            stopped_running = await rpc(ws, 'bot_relay.stop', id='a' * 32, profile='default')
            assert stopped_running['result']['status'] == 'interrupted', stopped_running
            assert stopped_running['result']['stopped'] is True, stopped_running
            model.release.set()
            await wait(lambda: row_for('HOLD_AUTOMATION')['status'] == 'terminal')
            assert row_for('HOLD_AUTOMATION')['outcome'] != 'completed', row_for('HOLD_AUTOMATION')

            again = await rpc(ws, 'bot_relay.stop', id='a' * 32, profile='default')
            assert again['result']['status'] == 'finished' and again['result']['stopped'] is False, again
        print(json.dumps({'ledger': [{k: r[k] for k in ('status', 'outcome')} for r in rows()]}))

    try:
        with daemon(root, home, env, barrier=False) as (_proc, desc):
            try:
                asyncio.run(run(desc))
            except BaseException:
                print((home / 'restart.log').read_text()[-10000:], file=sys.stderr)
                raise
    finally:
        model.release.set(); model.shutdown(); model.server_close()


if __name__ == '__main__':
    probe(Path(sys.argv[1]))
