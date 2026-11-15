"""A question asked in a bot's Bot Chat waits for its owner however long that takes.

Failure cases this file pins:
- the configured ``agent.clarify_timeout`` withdraws a Bot Chat question, so the turn moves on as if
  the owner walked away;
- another session's question stops honouring the configured timeout.
"""
import types

import pytest

from tui_gateway import server, server_requests


@pytest.mark.parametrize('bot_chat, expected', [(True, None), (False, 1)])
def test_a_bot_chat_question_has_no_deadline(monkeypatch, bot_chat, expected):
    monkeypatch.setattr('tools.clarify_gateway.get_clarify_timeout', lambda: 1)
    monkeypatch.setattr(server, '_is_bot_mode_session', lambda _session: bot_chat)
    monkeypatch.setitem(server._sessions, 'sid-bot', {'agent': types.SimpleNamespace()})
    sent = {}

    def fake_send(method, sid, params, *, timeout, qids=None):
        sent['timeout'] = timeout
        return {'answers': {'q0': 'yes'}, 'outcome': 'submitted'}

    monkeypatch.setattr(server_requests, 'send', fake_send)
    questions = [{'qid': 'q0', 'question': 'Ship it?', 'choices': [], 'multi_select': False}]

    assert server._agent_cbs('sid-bot')['clarify_callback'](questions)['outcome'] == 'submitted'
    assert sent['timeout'] == expected
