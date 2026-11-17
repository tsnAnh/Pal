"""Read-only Kanban reads for the native owner socket: session:read on its own profile, no new capability, no payload-selected profile/path, absent boards never bootstrapped."""
import asyncio
from functools import partial

from gateway.session_busy_controls import authorize_profile
from hermes_cli import kanban_native_read as read
from hermes_state_runtime import RuntimeStoreError
from tui_gateway.contracts import canonical_kanban as wire

_ABSENT = {'absent': 'board_absent', 'archived': 'board_archived'}


def handlers(connection):
    return {name: partial(op, connection) for name, op in {
        'kanban.boards.list': list_boards, 'kanban.board.snapshot': board_snapshot,
        'kanban.card.get': card_get, 'kanban.evidence.list': evidence_list,
        'kanban.events.since': events_since}.items()}


def _remote_operator(connection) -> bool:
    from gateway.session_identity import is_authenticated_identity
    capabilities = connection.actor.capabilities
    return ('session:operator' in capabilities and 'session:read' in capabilities
            and is_authenticated_identity(getattr(connection, '_identity', None)))


def _gateway(connection, params) -> str:
    if not (connection.native_owner or _remote_operator(connection)):
        raise RuntimeStoreError('permission_denied')
    authorize_profile(connection, params, 'session:read')
    gateway_id = connection.authority.instance_id
    if params.get('gateway_id') not in (None, gateway_id):
        raise RuntimeStoreError('gateway_mismatch', field='gateway_id')
    return gateway_id


def _text(params, key, *, optional=False):
    value = params.get(key)
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or len(value) > 200:
        raise RuntimeStoreError('invalid_params', field=key)
    return value


def _limit(params):
    limit = params.get('limit')
    if limit is not None and (type(limit) is not int or limit < 1):
        raise RuntimeStoreError('invalid_params', field='limit')
    return read.clamp_limit(limit)


def _run_id(params):
    run_id = params.get('run_id')
    if run_id is not None and (type(run_id) is not int or run_id < 0):
        raise RuntimeStoreError('invalid_params', field='run_id')
    return run_id


def _board(connection, params):
    gateway_id = _gateway(connection, params)
    slug = _text(params, 'board')
    try:
        slug = read._kb()._require_slug(slug)
    except ValueError:
        raise RuntimeStoreError('invalid_params', field='board') from None
    return gateway_id, slug


async def list_boards(connection, ref, params):
    gateway_id = _gateway(connection, params)
    boards = await asyncio.to_thread(read.list_boards, gateway_id)
    return wire.KanbanBoardsListResult.model_validate({'gateway_id': gateway_id, 'boards': boards, 'boards_seen': len(boards)}).model_dump(mode='json')


def _guarded(slug, model, work, absent):
    try:
        with read.open_board(slug) as (conn, meta, generation):
            answer = work(conn, meta, generation)
    except read.BoardUnavailable as exc:
        answer = absent(_ABSENT[exc.state])
    return model.model_validate(answer).model_dump(mode='json')


async def board_snapshot(connection, ref, params):
    gateway_id, slug = _board(connection, params)
    limit, token = _limit(params), _text(params, 'page_token', optional=True)
    where = read.scope(gateway_id, slug)

    def work(conn, meta, generation):
        try:
            page = read.snapshot(conn, gateway_id, slug, generation, limit, token)
        except read.SnapshotRequired as exc:
            return {'state': 'snapshot_required', 'scope': where, 'reason': exc.reason}
        return {'state': 'present', 'scope': where, 'board': read.board_row(gateway_id, meta, read.status_counts(conn)), **page}
    return await asyncio.to_thread(_guarded, slug, wire.KanbanSnapshotResult, work,
                                   lambda state: {'state': state, 'scope': where})


async def card_get(connection, ref, params):
    gateway_id, slug = _board(connection, params)
    task_id = _text(params, 'task_id')

    def work(conn, meta, generation):
        detail = read.card_detail(conn, gateway_id, slug, generation, task_id)
        return {'state': 'present' if detail else 'card_absent', 'scope': read.scope(gateway_id, slug), 'detail': detail}
    return await asyncio.to_thread(_guarded, slug, wire.KanbanCardResult, work,
                                   lambda state: {'state': state, 'scope': read.scope(gateway_id, slug), 'detail': None})


async def evidence_list(connection, ref, params):
    gateway_id, slug = _board(connection, params)
    task_id, run_id = _text(params, 'task_id'), _run_id(params)

    def work(conn, meta, generation):
        found = read.task_exists(conn, task_id)
        return {'state': 'present' if found else 'card_absent', 'scope': read.scope(gateway_id, slug),
                'card_id': read.card_id(gateway_id, slug, task_id) if found else None,
                'evidence': read.evidence_rows(conn, task_id, run_id) if found else []}
    return await asyncio.to_thread(_guarded, slug, wire.KanbanEvidenceResult, work,
                                   lambda state: {'state': state, 'scope': read.scope(gateway_id, slug),
                                                  'card_id': None, 'evidence': []})


async def events_since(connection, ref, params):
    gateway_id, slug = _board(connection, params)
    cursor, task_id = _text(params, 'cursor', optional=True), _text(params, 'task_id', optional=True)
    limit = _limit(params)
    where = read.scope(gateway_id, slug)

    def work(conn, meta, generation):
        if cursor is None:
            return {'state': 'snapshot_required', 'scope': where, 'reason': 'cursor_required'}
        try:
            after, count = read.resolve_cursor(conn, cursor, gateway_id, slug, generation)
            if task_id is not None and not read.task_exists(conn, task_id):
                return {'state': 'card_absent', 'scope': where}
            page = read.events_page(conn, gateway_id, slug, after, count, limit, task_id)
        except read.SnapshotRequired as exc:
            return {'state': 'snapshot_required', 'scope': where, 'reason': exc.reason}
        return {'state': 'ok', 'scope': where, 'events': page['events'], 'has_more': page['has_more'],
                'cursor': read.encode_cursor(gateway_id, slug, generation, page['position'], page['count'])}
    return await asyncio.to_thread(_guarded, slug, wire.KanbanEventsResult, work, lambda state: {'state': state, 'scope': where})
