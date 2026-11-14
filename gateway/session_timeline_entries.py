from collections import Counter

RENDERED_TOOLS = frozenset({'image_generate', 'clarify'})
_COPIED_KEYS = ('timestamp', 'row_id', 'display_kind', 'display_metadata')


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


def timeline_entries(rows, live_ids, profile_home):
    from gateway.session_controls import visible_projection
    units = _Units(rows, live_ids)
    for message in visible_projection(rows, profile_home, image_urls=False):
        getattr(units, message['role'])(message)
    return _unique([_finished(entry) for entry in units.units if _paints(entry)])
