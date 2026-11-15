"""Runtime markers stored in chat rows never reach a person: the timeline, ``session.resume`` and roster previews.

Failure cases this file pins:
- a bare silence marker (``NO_REPLY``, ``[SILENT]``, a translated form) paints as an assistant bubble;
- a closing silence marker stays on a real reply;
- a ``[System:`` gateway notice or an ``[IMPORTANT: MCP servers have been reloaded`` note paints as a user bubble;
- a Discord routing note, a notify-only DM's ``[no reply needed]`` lead or a DM's appended bot-reply rule
  shows inside the message a person reads;
- a roster preview shows any of the above instead of the newest row a person can read;
- prose that merely mentions a marker is hidden or rewritten.
"""
import pytest

from tools.bot_dm_wire import BOT_REPLY_RULE

STAMP = 'Message from 🤖 Scout (@scout): '
MENTION = 'Reply NO_REPLY when there is nothing to add.'

CASES = [
    ('assistant', 'NO_REPLY', None),
    ('assistant', '[SILENT]', None),
    ('assistant', '静默', None),
    ('assistant', 'Paris.\n\nNO_REPLY', 'Paris.'),
    ('assistant', MENTION, MENTION),
    ('user', '[System: The active model for this chat has changed to m2.]', None),
    ('user', '[IMPORTANT: MCP servers have been reloaded. 2 MCP tool(s) now available. The tool list for this '
             'conversation has been updated accordingly.]', None),
    ('user', '[Triggering message id: `42` — use as `message_id` for reply/react/pin via the discord tools.]\n'
             'hello there', 'hello there'),
    ('user', f'{STAMP}[no reply needed] build is green', f'{STAMP}build is green'),
    ('user', f'{STAMP}is the build green?\n\n{BOT_REPLY_RULE}', f'{STAMP}is the build green?'),
    ('user', 'What does [no reply needed] mean in a DM?', 'What does [no reply needed] mean in a DM?'),
    ('user', 'Should a [System: note] ever show?', 'Should a [System: note] ever show?'),
]


@pytest.fixture
def db(tmp_path):
    from hermes_state import SessionDB
    store = SessionDB(tmp_path / 'state.db')
    store.create_session('s1', source='tui')
    yield store
    store.close()


def _seed(db, role, stored):
    db.append_message('s1', 'user' if role == 'assistant' else 'assistant', 'before')
    db.append_message('s1', role, stored)


@pytest.mark.parametrize('role, stored, shown', CASES)
def test_the_timeline_shows_a_row_as_a_person_reads_it(db, tmp_path, role, stored, shown):
    from gateway.session_timeline import load_timeline
    _seed(db, role, stored)
    entries = list(load_timeline(str(tmp_path), db, 's1', None).entries)
    assert [e['text'] for e in entries if e['role'] == role and e['text'] != 'before'] == ([shown] if shown else [])


@pytest.mark.parametrize('role, stored, shown', CASES)
def test_resume_messages_show_a_row_as_a_person_reads_it(role, stored, shown):
    from tui_gateway.server import _history_to_messages
    messages = _history_to_messages([{'role': role, 'content': stored}])
    assert [m['text'] for m in messages if m['role'] == role] == ([shown] if shown else [])


@pytest.mark.parametrize('role, stored, shown', CASES)
def test_a_roster_preview_shows_the_newest_row_a_person_reads(db, role, stored, shown):
    from tui_gateway.methods_profiles import _latest_message_preview
    _seed(db, role, stored)
    expected = ' '.join((shown or 'before').split())
    assert _latest_message_preview(db, 's1') == (expected[:80] + '...' if len(expected) > 80 else expected)
