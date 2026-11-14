import asyncio
from functools import partial

from gateway.session_busy_controls import authorize
from hermes_state_runtime import RuntimeStoreError

PAGE_FIELDS = frozenset({'session_id', 'profile', 'before_row_id', 'limit'})
MAX_PAGE_LIMIT = 200


def handlers(connection):
    return {'session.history.page': partial(history_page, connection)}


def window(rows, limit):
    older = max(0, len(rows) - limit)
    return rows[older:], older


def rows_before(rows, before_row_id):
    for index, row in enumerate(rows):
        if row.get('row_id') == before_row_id:
            return rows[:index]
    return [row for row in rows if isinstance(row.get('row_id'), int) and row['row_id'] < before_row_id]


def _strict_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


async def history_page(connection, ref, params):
    if set(params) - PAGE_FIELDS or not isinstance(ref.session_id, str) or not ref.session_id:
        raise RuntimeStoreError('invalid_params')
    before, limit = params.get('before_row_id'), params.get('limit')
    if not (_strict_int(before) and _strict_int(limit) and 1 <= limit <= MAX_PAGE_LIMIT):
        raise RuntimeStoreError('invalid_params')
    authorize(connection, ref, params, 'session:read')
    authority = connection.authority
    from gateway.session_local_recovery import local_history
    history = await asyncio.to_thread(authority.unless_deleted, ref, partial(local_history, authority, ref))
    messages, older = window(rows_before(list(history), before), limit)
    return {'messages': messages, 'older_messages': older}
