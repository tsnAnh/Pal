import json
import logging
import time

import pytest
import pytest_asyncio

from gateway import diag_ledger, diag_trace
from tests.gateway.bots_harness import FULL, bots_state, install_state
from tests.gateway.devices_harness import call
from tui_gateway import server

install = pytest.fixture(install_state)
bots = pytest_asyncio.fixture(bots_state)

SECRET = 'fake-token-do-not-use'
REFUSED = ('chat.install.status', {'profile': 'alpha', 'provider_id': 'slack', 'workspace': SECRET})


async def traced(connection, method, params, trace=None):
    frame = {'id': 1, 'method': method, 'params': params}
    if trace is not None:
        frame['trace'] = trace
    return await connection.dispatch(frame)


async def recent(bots, **params):
    response = await call(bots.connect('default', host=True, capabilities=FULL), 'diag.recent', params)
    assert 'result' in response, response
    return response['result']['faults']


@pytest.mark.asyncio
async def test_a_refused_bot_call_carries_its_trace_and_lands_in_the_ledger(bots, caplog):
    caplog.set_level(logging.DEBUG)
    responses = [await traced(bots.connect('alpha'), *REFUSED, trace='7f3k2m9a')]
    error = responses[0]['error']
    assert responses[0]['trace'] == '7f3k2m9a'
    assert error['data']['trace'] == '7f3k2m9a' and error['data']['reason'] == 'owner_only'
    assert error['data']['gateway_version'] == diag_trace.gateway_version()
    faults = await recent(bots)
    responses.append({'faults': faults})
    [row] = [f for f in faults if f['trace'] == '7f3k2m9a']
    assert row['method'] == 'chat.install.status' and row['reason'] == 'owner_only' and row['scope'] == 'profile'
    assert row['params_shape'] == 'profile:string,provider_id:string,workspace:string'
    rows = diag_ledger.recent(minutes=10, limit=200)
    for blob in (json.dumps(rows), json.dumps(responses), caplog.text):
        assert SECRET not in blob


@pytest.mark.asyncio
async def test_a_call_without_a_trace_gets_one_and_a_malformed_trace_is_replaced(bots):
    missing = await traced(bots.connect('alpha'), *REFUSED)
    assert diag_trace.is_trace(missing['trace']) and len(missing['trace']) == 8
    bad = 'UPPER-and-way-too-long-trace'
    replaced = await traced(bots.connect('alpha'), *REFUSED, trace=bad)
    assert replaced['trace'] != bad and diag_trace.is_trace(replaced['trace'])
    assert bad not in json.dumps(replaced) and bad not in json.dumps(await recent(bots))


@pytest.mark.asyncio
async def test_diag_recent_is_owner_only_newest_first_and_filtered(bots):
    for trace in ('aaa1', 'aaa2'):
        await traced(bots.connect('alpha'), *REFUSED, trace=trace)
    denied = await call(bots.connect('alpha'), 'diag.recent', {})
    assert denied['error']['data']['reason'] == 'owner_only', denied
    faults = await recent(bots, method='chat.install.status')
    assert [f['trace'] for f in faults][:2] == ['aaa2', 'aaa1']
    assert all(f['method'] == 'chat.install.status' for f in faults)
    assert await recent(bots, method='chat.spaces.list') == []
    diag_ledger.record(diag_ledger.Fault(ts=time.time() - 3600, trace='old1', method='m', code=1, reason='internal'))
    assert 'old1' not in [f['trace'] for f in await recent(bots, minutes=10)]
    assert 'old1' in [f['trace'] for f in await recent(bots, minutes=120)]


@pytest.mark.asyncio
async def test_diag_report_validates_and_stores_a_trace_the_gateway_never_saw(bots):
    owner = bots.connect('default', host=True, capabilities=FULL)
    good = {'trace': 'zz9client', 'source': 'transport', 'reason': 'timeout', 'method': 'chat.install.status'}
    assert (await call(owner, 'diag.report', good))['result'] == {'recorded': True}
    [row] = [f for f in await recent(bots) if f['trace'] == 'zz9client']
    assert row['source'] == 'transport' and row['reason'] == 'timeout' and row['code'] is None
    for bad in ({'source': 'gateway'}, {'reason': 'nope'}, {'method': 'no.such.method'}, {'trace': 'BAD!'},
                {'extra': 1}):
        refused = await call(owner, 'diag.report', {**good, **bad})
        assert refused['error']['data']['reason'] == 'invalid_params', (bad, refused)
    assert (await call(bots.connect('alpha'), 'diag.report', good))['error']['data']['reason'] == 'owner_only'


def test_a_handler_exception_writes_an_internal_row_and_logs_carry_the_trace(install, monkeypatch, caplog):
    log = logging.getLogger('tests.diag')

    def boom(rid, params):
        log.warning('inside the handler')
        raise RuntimeError(SECRET)

    monkeypatch.setitem(server._methods, 'test.diag.boom', boom)
    caplog.set_level(logging.DEBUG)
    log.warning('outside any request')
    with pytest.raises(RuntimeError):
        server.dispatch({'id': 1, 'method': 'test.diag.boom', 'params': {'token': SECRET}, 'trace': 'boom1'})
    [row] = diag_ledger.recent(minutes=10, limit=10, method='test.diag.boom')
    assert row['trace'] == 'boom1' and row['reason'] == 'internal' and row['params_shape'] == 'token:string'
    assert SECRET not in json.dumps(row)
    lines = {r.getMessage() for r in caplog.records if r.name == 'tests.diag'}
    assert lines == {'trace=boom1 inside the handler', 'outside any request'}


def test_the_legacy_dispatcher_echoes_the_trace_and_adds_a_reason(install):
    response = server.dispatch({'id': 1, 'method': 'no.such.method', 'params': {}, 'trace': 'leg1'})
    assert response['trace'] == 'leg1'
    assert response['error']['data'] == {'reason': 'not_implemented', 'trace': 'leg1',
                                         'gateway_version': diag_trace.gateway_version()}
    assert response['error']['code'] == -32601


def test_retention_and_the_row_cap_prune_on_write(install, monkeypatch):
    monkeypatch.setattr(diag_ledger, 'MAX_ROWS', 3)
    now = time.time()
    diag_ledger.record(diag_ledger.Fault(ts=now - diag_ledger.RETENTION_SECONDS - 5, trace='stale', method='m',
                                         code=1, reason='internal'))
    for index in range(5):
        diag_ledger.record(diag_ledger.Fault(ts=now + index, trace=f't{index}', method='m', code=1,
                                             reason='internal'))
    traces = [r['trace'] for r in diag_ledger.recent(minutes=10080, limit=200, now=now + 10)]
    assert traces == ['t4', 't3', 't2']
