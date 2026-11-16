"""Isolated end-to-end probe: coordinator lifecycle through the real CLI, then native reads over the real ticket WebSocket.

    python -m tests.gateway.kanban_native_read_probe [--keep]

Everything lives in one temporary directory: a disposable ``HERMES_HOME`` and Kanban root, an
``external`` board, and the named profile ``projbot`` bound by environment. No model, default-profile
agent, production board, credential or shared gateway is touched; the gateway it starts is private to
this run and is stopped on exit. Prints one JSON receipt; exit 0 means every assertion held.
"""
import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from tests.gateway.kanban_native_read_support import (
    ROOT, isolated_env, native_socket, running_gateway, write_gateway_config,
)

PROFILE = 'projbot'
BOARD = 'ops'


def _cli(env, *args, check=True):
    done = subprocess.run([sys.executable, '-m', 'hermes_cli.main', 'kanban', *args], cwd=ROOT, env=env,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=False)
    if check and done.returncode:
        raise AssertionError(f'kanban {args}: rc={done.returncode}\n{done.stdout}\n{done.stderr}')
    return done


def _lifecycle(env, scratch: Path) -> dict:
    """Board, governed card, dispatcher pass, claim, refused completion, evidence, one completion."""
    env = {**env, 'HERMES_PROFILE_NAME': PROFILE}
    _cli(env, 'boards', 'create', BOARD, '--dispatch-mode', 'external')
    board = ['--board', BOARD]
    card = json.loads(_cli(env, *board, 'create', 'probe card', '--assignee', PROFILE,
                           '--outcome-contract', '{"kind":"built_artifact"}', '--json').stdout)['id']
    dispatch = json.loads(_cli(env, *board, 'dispatch', '--json').stdout)
    assert dispatch['spawned'] == [] and dispatch['crashed'] == [], dispatch
    claim = json.loads(_cli(env, *board, 'claim', card, '--session', 'probe-session', '--json').stdout)
    run_id = claim['run_id']
    refused = _cli(env, *board, 'complete', card, '--run-id', str(run_id), '--result', 'no evidence', check=False)
    assert refused.returncode != 0, 'completion without evidence must be refused'
    artifact = scratch / 'probe-app.zip'
    artifact.write_bytes(b'probe-build-bytes')
    _cli(env, *board, 'attach', card, str(artifact))
    for kind, payload in (('execution_ref', {'session_id': 'probe-session', 'runtime': 'probe'}),
                          ('artifact_built', {'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(), 'name': artifact.name})):
        _cli(env, *board, 'evidence', 'add', card, '--run-id', str(run_id), '--kind', kind, '--json', json.dumps(payload))
    _cli(env, *board, 'complete', card, '--run-id', str(run_id), '--result', 'built')
    again = _cli(env, *board, 'complete', card, '--run-id', str(run_id), '--result', 'built again', check=False)
    return {'card': card, 'run_id': run_id, 'dispatch_spawned': len(dispatch['spawned']),
            'refused_without_evidence': refused.returncode != 0, 'second_completion_rc': again.returncode}


async def _read(home: Path, descriptor: dict, lifecycle: dict) -> dict:
    card, run_id = lifecycle['card'], lifecycle['run_id']
    async with native_socket(home, descriptor) as ws:
        boards = {b['scope']['board']: b for b in (await ws.result('kanban.boards.list'))['boards']}
        assert boards[BOARD]['dispatch_mode'] == 'external' and boards[BOARD]['task_counts'] == {'done': 1}, boards
        snap = await ws.result('kanban.board.snapshot', board=BOARD)
        assert [c['task_id'] for c in snap['cards']] == [card] and snap['cards'][0]['status'] == 'done'
        detail = (await ws.result('kanban.card.get', board=BOARD, task_id=card))['detail']
        evidence = (await ws.result('kanban.evidence.list', board=BOARD, task_id=card))['evidence']
        assert [e['kind'] for e in evidence] == ['execution_ref', 'artifact_built'] == [e['kind'] for e in detail['evidence']]
        assert {(e['producer_profile'], e['producer_session'], e['run_id']) for e in evidence} == {(PROFILE, 'probe-session', run_id)}
        verification = detail['outcome_verification']
        assert verification['state'] == 'verified' and verification['verification'] == 'independent', verification
        assert detail['ci_acceptance']['state'] == 'unknown' and detail['execution']['runs'][0]['executor'] == 'external'
        replay = await ws.result('kanban.events.since', board=BOARD, cursor=_cursor_zero(snap['cursor']), limit=500)
        kinds = [e['kind'] for e in replay['events']]
        assert kinds.count('completed') == 1 and 'outcome_refused' in kinds and 'outcome_verified' in kinds, kinds
        assert 'spawned' not in kinds and 'claimed' in kinds, kinds
        assert (await ws.result('kanban.events.since', board=BOARD, cursor=snap['cursor']))['events'] == []
        wire = json.dumps([boards, snap, detail, evidence, replay])
        assert str(home) not in wire and 'claim_lock' not in wire and 'external:' + PROFILE + ':' not in wire
        return {'event_kinds': kinds, 'verification': verification['verification'], 'evidence_kinds': [e['kind'] for e in evidence],
                'ci_acceptance': detail['ci_acceptance']['state']}


def _cursor_zero(cursor: str) -> str:
    from hermes_cli import kanban_native_read as read
    gateway_id, slug, generation, _event_id, _count = read._decode_cursor(cursor)
    return read.encode_cursor(gateway_id, slug, generation, 0, 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--keep', action='store_true', help='keep the temporary directory')
    keep = parser.parse_args().keep
    base = Path(tempfile.mkdtemp(prefix='kanban-native-read-probe-'))
    try:
        home, user, kanban_home, scratch = base / 'state', base / 'user', base / 'kanban-root', base / 'scratch'
        for path in (user, kanban_home, scratch):
            path.mkdir()
        home.mkdir(mode=0o700)
        write_gateway_config(home)
        env = isolated_env(home, user, kanban_home)
        lifecycle = _lifecycle(env, scratch)
        with running_gateway(home, env) as descriptor:
            read = asyncio.run(_read(home, descriptor, lifecycle))
        print(json.dumps({'probe': 'kanban-native-read', 'ok': True, **lifecycle, **read}, sort_keys=True))
        return 0
    finally:
        if keep:
            print(f'kept {base}', file=sys.stderr)
        else:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
