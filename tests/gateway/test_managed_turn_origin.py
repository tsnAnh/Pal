"""The server-stamped turn origin crosses the managed-worker bootstrap validated, one turn only."""
import json
from types import SimpleNamespace

import pytest

from tests.gateway.test_managed_turn_contract import assignment

IPHONE = {'kind': 'ios', 'label': 'iPhone', 'same_host': False}


def _frame(tmp_path, monkeypatch, surface):
    from agent.managed_worker import validate_bootstrap
    from gateway.session_managed_worker import _bootstrap
    _frame_plain, (authority, ref, row, policy, scope) = assignment(tmp_path, monkeypatch)
    return validate_bootstrap(json.loads(json.dumps(_bootstrap(
        authority, ref, {'payload': {**row['payload'], 'surface_v1': surface}}, policy, scope)))), _frame_plain


def test_origin_reaches_the_child_agent_for_its_own_turn_only(tmp_path, monkeypatch):
    from gateway.session_kanban import run_worker_turns
    framed, plain = _frame(tmp_path, monkeypatch, {'origin': IPHONE})
    seen = []
    agent = SimpleNamespace(valid_tool_names=set(), run_conversation=lambda text, **kw: seen.append(
        agent._client_origin) or {'final_response': 'ok'})
    run_worker_turns(agent, framed, [])
    run_worker_turns(agent, plain, [])
    assert seen == [IPHONE, None]


@pytest.mark.parametrize('origin', [
    {'kind': 'toaster', 'label': 'iPhone', 'same_host': False},
    {'kind': 'ios', 'label': 'x' * 41, 'same_host': False},
    {'kind': 'ios', 'label': 'iPhone', 'same_host': 'no'},
    {'kind': 'ios', 'label': 'iPhone', 'same_host': False, 'device_id': 'dev-12345678'},
])
def test_child_refuses_a_forged_origin(tmp_path, monkeypatch, origin):
    from gateway.session_kanban import run_worker_turns
    framed, _plain = _frame(tmp_path, monkeypatch, {'origin': IPHONE})
    request = json.loads(framed['policy']['request_json'])
    request['turn_v1']['surface_v1'] = {'origin': origin}
    forged = {**framed, 'policy': {**framed['policy'], 'request_json': json.dumps(request)}}
    agent = SimpleNamespace(valid_tool_names=set(), run_conversation=lambda text, **kw: pytest.fail('ran'))
    with pytest.raises(ValueError, match='invalid_managed_worker_bootstrap'):
        run_worker_turns(agent, forged, [])
