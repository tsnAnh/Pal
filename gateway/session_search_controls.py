import asyncio
import re
from functools import partial

from gateway.session_busy_controls import authorize_profile
from hermes_state_runtime import RuntimeStoreError

QUERY_MAX = 200
LIMIT_DEFAULT = 20
LIMIT_MAX = 50
SNIPPET_MAX = 240

_MARKERS = re.compile(r'>>>|<<<')
_TAGS = re.compile(r'</?[A-Za-z][^<>]*>')
_SPACE = re.compile(r'\s+')


def _plain(snippet):
    return _SPACE.sub(' ', _TAGS.sub(' ', _MARKERS.sub('', snippet or ''))).strip()[:SNIPPET_MAX]


def _hit(row):
    timestamp = row.get('timestamp')
    return {'session_id': row.get('lineage_root') or row['session_id'], 'resolved_id': row['session_id'],
            'title': row.get('title') or None, 'snippet': _plain(row.get('snippet')), 'role': row.get('role'),
            'timestamp': float(timestamp) if isinstance(timestamp, (int, float)) else None,
            'profile': row['profile']}


def _search(authority, query, limit):
    from hermes_state_session_search import search_sessions
    from hermes_state import SessionDB
    from hermes_state_sessions import INTERNAL_LISTING_SOURCES
    rows = search_sessions(authority.db, query, limit=limit, profile=authority.db._own_profile_name() or 'default',
                           exclude_sources=list(INTERNAL_LISTING_SOURCES), include_hidden=False,
                           visible_hidden_title=SessionDB.CANONICAL_BOT_CHAT_TITLE)
    return [_hit(row) for row in rows]


def _validated(params):
    query, limit = params.get('query'), params.get('limit', LIMIT_DEFAULT)
    if type(query) is not str or type(limit) is not int or set(params) - {'query', 'limit', 'profile'}:
        raise RuntimeStoreError('invalid_params')
    query = query.strip()
    if not 1 <= len(query) <= QUERY_MAX:
        raise RuntimeStoreError('invalid_params', field='query')
    return query, max(1, min(limit, LIMIT_MAX))


async def search(connection, ref, params):
    authorize_profile(connection, params, 'session:read')
    query, limit = _validated(params)
    return {'results': await asyncio.to_thread(_search, connection.authority, query, limit)}


def handlers(connection):
    return {'session.search': partial(search, connection)}
