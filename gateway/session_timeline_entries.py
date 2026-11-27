import json
from collections import Counter
from dataclasses import dataclass, replace
from enum import Enum

from gateway.device_messages import APPROVAL_DENIED
from gateway.display_markers import owner_display_text
from gateway.proactive_scorecard.patterns import asks_owner
from gateway.response_filters import INTERNAL_NOTIFICATION_DISPLAY_KIND, PRODUCER_NOTICE_DISPLAY_KINDS
from session_rules.turns import flatten_message_text, user_originated_turn_view
from tools import mcp_action_gate, tainted_turn_gate
from tools.bot_dm_wire import split_sender_stamp

RENDERED_TOOLS = frozenset({'image_generate', 'clarify', 'manage_connections'})
_COPIED_KEYS = ('timestamp', 'row_id', 'display_kind', 'display_metadata', 'file_refs')
_OWNER_TOOLS = frozenset({'clarify', 'manage_connections'})
_NOTICE_PREFIXES = ('[IMPORTANT: Background process ', '[Background process ', '[ASYNC DELEGATION ')
_GATE_STATUSES = frozenset({'approval_required', 'blocked'})
_GATE_CODES = frozenset({
    'approval_required', APPROVAL_DENIED, mcp_action_gate.APPROVAL_UNAVAILABLE, mcp_action_gate.ACTION_DENIED,
    mcp_action_gate.ACTION_REFUSED, mcp_action_gate.APPROVAL_MISMATCH, mcp_action_gate.GATE_FAILED,
    tainted_turn_gate.OWNER_DENIED, tainted_turn_gate.GATE_FAILED, tainted_turn_gate.OWNER_UNREACHABLE,
})
_JOINED_LISTS = ('tools', 'file_refs')
_TEXT_PARTS = frozenset({'text', 'output_text'})


def _row_key(row, row_id):
    uid = row.get('message_uid')
    if isinstance(uid, str) and uid:
        return uid
    return f'r:{row_id}'


class _Units:
    def __init__(self, rows, live_ids):
        self.rows = {row['_row_id']: row for row in rows if row.get('_row_id') is not None}
        self.tool_rows = {(row.get('tool_call_id'), row.get('timestamp')): row
                          for row in rows if row.get('role') == 'tool'}
        self.live_ids = live_ids
        self.units = []
        self.turn = None
        self.callers = {}
        self.orphan_sources = {}

    def source_row_id(self, unit):
        return unit.get('row_id', self.orphan_sources.get(id(unit)))

    def _entry(self, message, role):
        row_id = message.get('row_id')
        entry = {'id': _row_key(self.rows.get(row_id, {}), row_id), 'role': role, 'text': message.get('text') or ''}
        entry.update((key, message[key]) for key in _COPIED_KEYS if message.get(key) is not None)
        if row_id is not None and row_id not in self.live_ids:
            entry['archived'] = True
        return entry

    def user(self, message):
        self.turn, self.callers = None, {}
        self.units.append(self._entry(message, 'user'))

    def assistant(self, message):
        unit = self._entry(message, 'assistant')
        reasoning = message.get('reasoning') or message.get('reasoning_content')
        if isinstance(reasoning, str) and reasoning:
            unit['reasoning'] = reasoning
        unit['tools'] = []
        for call in self.rows.get(message.get('row_id'), {}).get('tool_calls') or ():
            if isinstance(call, dict) and call.get('id'):
                self.callers[call['id']] = unit
        self.turn = unit
        self.units.append(unit)

    def tool(self, message):
        call_id = message.get('tool_call_id') or ''
        row = self.tool_rows.get((message.get('tool_call_id'), message.get('timestamp')), {})
        unit = self.callers.get(call_id) or self.turn
        if unit is None:
            unit = {'id': _row_key(row, row.get('_row_id')), 'role': 'assistant', 'text': '', 'tools': []}
            if message.get('timestamp') is not None:
                unit['timestamp'] = message['timestamp']
            self.turn = unit
            self.units.append(unit)
            self.orphan_sources[id(unit)] = row.get('_row_id')
        name = message.get('name') or 'tool'
        tool = {'call_id': call_id, 'name': name}
        if message.get('context'):
            tool['context'] = message['context']
        if name in RENDERED_TOOLS:
            if message.get('args'):
                tool['args'] = message['args']
            tool['result'] = row.get('content')
        unit['tools'].append(tool)

    def system(self, message):
        return None


def _paints(entry):
    tools = entry.get('tools') or ()
    return entry['role'] == 'user' or bool(entry['text'].strip()) or any(t['name'] in RENDERED_TOOLS for t in tools)


def _finished(entry):
    if not entry.get('tools'):
        entry.pop('tools', None)
    return entry


def _unique(entries):
    seen = Counter()
    for entry in entries:
        repeat = seen[entry['id']]
        seen[entry['id']] += 1
        if repeat:
            entry['id'] = f"{entry['id']}#{repeat}"
    return entries


class Opener(Enum):
    OPENING = 'opening'
    OWNER = 'owner'
    NOTICE = 'notice'
    OTHER = 'other'


@dataclass(frozen=True, slots=True)
class _Turn:
    opener: Opener
    needs_owner: bool
    last_reply_row: int | None
    last_reply_calls_tools: bool


@dataclass(frozen=True, slots=True)
class _Reply:
    entry: dict
    source_row: int | None
    turn: int | None
    joinable: bool


@dataclass(frozen=True, slots=True)
class _Head:
    position: int
    reply: _Reply


def opener_of(row):
    from gateway.session_controls import model_only
    kind = row.get('display_kind')
    if kind in PRODUCER_NOTICE_DISPLAY_KINDS or (
            kind == INTERNAL_NOTIFICATION_DISPLAY_KIND
            and flatten_message_text(row.get('content')).startswith(_NOTICE_PREFIXES)):
        return Opener.NOTICE
    typed = None if model_only(row) else user_originated_turn_view(row)
    if typed is None:
        return Opener.OTHER
    content = typed.get('content')
    words = flatten_message_text(content) or ('[attachment]' if content else '')
    shown = owner_display_text('user', words)
    return Opener.OWNER if shown is not None and split_sender_stamp(shown) is None else Opener.OTHER


def _reports_gate(content):
    if not isinstance(content, str):
        return False
    try:
        result, _ = json.JSONDecoder().raw_decode(content.lstrip())
    except ValueError:
        return False
    if not isinstance(result, dict):
        return False
    status, code, error = (result.get(key) for key in ('status', 'code', 'error'))
    return ((isinstance(status, str) and status in _GATE_STATUSES)
            or (isinstance(code, str) and code in _GATE_CODES)
            or (isinstance(error, str) and error.startswith('BLOCKED')))


def _row_needs_owner(row):
    if row.get('role') == 'tool':
        return row.get('tool_name') in _OWNER_TOOLS or _reports_gate(row.get('content'))
    return any((call.get('function') or {}).get('name') in _OWNER_TOOLS
               for call in row.get('tool_calls') or () if isinstance(call, dict))


def _turn(opener, rows):
    last = next((row for row in reversed(rows) if row.get('role') == 'assistant'), {})
    return _Turn(opener, any(map(_row_needs_owner, rows)), last.get('_row_id'), bool(last.get('tool_calls')))


def _turn_marks(rows):
    openers, members, turn_of = [Opener.OPENING], [[]], {}
    for row in rows:
        if row.get('role') == 'user':
            openers.append(opener_of(row))
            members.append([])
        members[-1].append(row)
        if row.get('_row_id') is not None:
            turn_of[row['_row_id']] = len(members) - 1
    return tuple(map(_turn, openers, members)), turn_of


def _reply(entry, source_row, rows_by_id, turns, turn_of):
    turn = turn_of.get(source_row)
    joinable = (turn is not None and not turns[turn].needs_owner and not entry.get('display_kind')
                and not rows_by_id.get(source_row, {}).get('display_kind') and not asks_owner(entry['text']))
    return _Reply(entry, source_row, turn, joinable)


def _same_ask(turns, earlier, later):
    if earlier == later:
        return True
    if any(turn.opener is not Opener.NOTICE for turn in turns[earlier + 1:later + 1]):
        return False
    root = earlier
    while turns[root].opener is Opener.NOTICE:
        root -= 1
    return turns[root].opener in (Opener.OWNER, Opener.OPENING)


def _settled(reply, turns, painted):
    if reply.turn == 0 or reply.turn != len(turns) - 1:
        return True
    turn = turns[reply.turn]
    return (painted[reply.turn] == 1 and reply.source_row == turn.last_reply_row
            and not turn.last_reply_calls_tools)


def _continues(head, reply, turns, painted):
    return (head.joinable and reply.joinable
            and head.entry.get('archived') == reply.entry.get('archived')
            and _same_ask(turns, head.turn, reply.turn)
            and _settled(reply, turns, painted))


def _absorb(into, entry):
    joined = dict(into)
    for key in ('text', 'reasoning'):
        if parts := [part for part in (into.get(key), entry.get(key)) if part]:
            joined[key] = '\n\n'.join(parts)
    for key in _JOINED_LISTS:
        if items := [*into.get(key, ()), *entry.get(key, ())]:
            joined[key] = items
    if entry.get('row_id') is not None:
        joined['row_id'] = entry['row_id']
    return joined


def _spaced_parts(row):
    content = row.get('content')
    if row.get('role') != 'assistant' or not isinstance(content, list) or not all(
            isinstance(part, dict) and part.get('type') in _TEXT_PARTS and isinstance(part.get('text'), str)
            for part in content):
        return row
    return {**row, 'content': '\n\n'.join(words for part in content if (words := part['text'].strip('\n')))}


def _projected(rows, live_ids, profile_home):
    from gateway.session_controls import visible_projection
    units = _Units(rows, live_ids)
    for message in visible_projection(rows, profile_home):
        getattr(units, message['role'])(message)
    painted = [(units.source_row_id(unit), _finished(unit)) for unit in units.units if _paints(unit)]
    _unique([entry for _, entry in painted])
    return painted


def reply_entries(rows, live_ids, profile_home):
    return [entry for _, entry in _projected(rows, live_ids, profile_home)]


def timeline_entries(rows, live_ids, profile_home):
    rows = [_spaced_parts(row) for row in rows]
    turns, turn_of = _turn_marks(rows)
    rows_by_id = {row['_row_id']: row for row in rows if row.get('_row_id') is not None}
    items = [_reply(entry, source, rows_by_id, turns, turn_of) if entry['role'] == 'assistant' else entry
             for source, entry in _projected(rows, live_ids, profile_home)]
    painted = Counter(item.turn for item in items if isinstance(item, _Reply))
    entries, head = [], None
    for item in items:
        if not isinstance(item, _Reply):
            entries.append(item)
        elif head is not None and _continues(head.reply, item, turns, painted):
            entries[head.position] = _absorb(entries[head.position], item.entry)
            head = _Head(head.position, replace(item, entry=entries[head.position]))
        else:
            head = _Head(len(entries), item)
            entries.append(item.entry)
    return entries
