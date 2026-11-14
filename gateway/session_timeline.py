import asyncio
import base64
import binascii
import hashlib
import json
import threading
from collections import OrderedDict
from dataclasses import dataclass
from functools import partial

from gateway.session_busy_controls import authorize
from hermes_state_runtime import RuntimeStoreError

TIMELINE_FIELDS = frozenset({'session_id', 'profile', 'before', 'limit'})
DEFAULT_LIMIT = 40
MAX_LIMIT = 100
PAGE_BYTES = 2 * 1024 * 1024
_CURSOR_TAG = 'tl1.'
_CURSOR_MAX_CHARS = 512
_CACHE_SESSIONS = 16
_CACHE_BYTES = 32 * 1024 * 1024


@dataclass(frozen=True)
class Timeline:
    revision: str
    entries: tuple
    index: dict
    sizes: tuple
    size: int


class _TimelineCache:
    def __init__(self, sessions, budget):
        self._sessions, self._budget = sessions, budget
        self._items = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key, revision):
        with self._lock:
            timeline = self._items.get(key)
            if timeline is None or timeline.revision != revision:
                return None
            self._items.move_to_end(key)
            return timeline

    def put(self, key, timeline):
        with self._lock:
            self._items.pop(key, None)
            if timeline.size > self._budget:
                return
            self._items[key] = timeline
            while len(self._items) > self._sessions or sum(t.size for t in self._items.values()) > self._budget:
                self._items.popitem(last=False)


_CACHE = _TimelineCache(_CACHE_SESSIONS, _CACHE_BYTES)


def handlers(connection):
    return {'session.timeline': partial(timeline, connection)}


def _revision(db, target):
    mark = db.conversation_revision(target, include_ancestors=True)
    return hashlib.sha256(repr(mark).encode()).hexdigest()[:24]


def _display_rows(db, target):
    from hermes_state import SessionResumeTooLargeError
    live = db.get_messages_as_conversation(target, include_row_ids=True)
    live_ids = {row['_row_id'] for row in live}
    try:
        db.assert_resume_safe(target)
    except SessionResumeTooLargeError:
        return live, live_ids
    return db.get_messages_as_conversation(
        target, include_ancestors=True, include_compacted=True, include_row_ids=True), live_ids


def load_timeline(profile_id, db, target, profile_home):
    revision = _revision(db, target)
    key = (str(profile_id), target)
    cached = _CACHE.get(key, revision)
    if cached is not None:
        return cached
    from gateway.session_timeline_entries import timeline_entries
    entries = tuple(timeline_entries(*_display_rows(db, target), profile_home))
    sizes = tuple(len(json.dumps(entry, default=str)) + 2 for entry in entries)
    built = Timeline(revision, entries, {entry['id']: n for n, entry in enumerate(entries)}, sizes, sum(sizes))
    _CACHE.put(key, built)
    return built


def encode_cursor(entry_id):
    return _CURSOR_TAG + base64.urlsafe_b64encode(entry_id.encode()).decode().rstrip('=')


def _decode_cursor(cursor):
    if not cursor.startswith(_CURSOR_TAG) or len(cursor) > _CURSOR_MAX_CHARS:
        raise RuntimeStoreError('invalid_params', field='before')
    body = cursor[len(_CURSOR_TAG):]
    try:
        return base64.b64decode(body + '=' * (-len(body) % 4), altchars=b'-_', validate=True).decode()
    except (binascii.Error, ValueError):
        raise RuntimeStoreError('invalid_params', field='before') from None


def page(built, before, limit):
    end = len(built.entries) if before is None else built.index.get(_decode_cursor(before))
    if end is None:
        raise RuntimeStoreError('cursor_stale', field='before',
                                detail='the cursor entry left the transcript (rewind or undo); reload the latest page')
    start, floor, total = end, max(0, end - limit), 0
    while start > floor and (total == 0 or total + built.sizes[start - 1] <= PAGE_BYTES):
        total += built.sizes[start - 1]
        start -= 1
    return {'entries': list(built.entries[start:end]),
            'older': encode_cursor(built.entries[start]['id']) if start else None,
            'revision': built.revision}


def _strict_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def valid_limit(limit):
    return _strict_int(limit) and 1 <= limit <= MAX_LIMIT


async def read_page(authority, ref, before, limit):
    from gateway.session_local_recovery import transcript_target
    target = transcript_target(authority, ref)
    read = partial(load_timeline, authority.profile_id, authority.db, target, authority.profile_id)
    built = await asyncio.to_thread(authority.unless_deleted, ref, read)
    return page(built, before, limit)


async def timeline(connection, ref, params):
    before, limit = params.get('before'), params.get('limit', DEFAULT_LIMIT)
    if (set(params) - TIMELINE_FIELDS or not isinstance(ref.session_id, str) or not ref.session_id
            or not valid_limit(limit) or not (before is None or isinstance(before, str))):
        raise RuntimeStoreError('invalid_params')
    authorize(connection, ref, params, 'session:read')
    return await read_page(connection.authority, ref, before, limit)
