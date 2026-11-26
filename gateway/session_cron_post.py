from __future__ import annotations

from dataclasses import dataclass
from functools import partial

from persistence.core.errors import AuthorityRefusal

CRON_DELIVERY_KEY = 'cron_delivery'
_TEXT_LIMIT = 1024 * 1024
_FIELD_LIMITS = {'job_id': 256, 'execution_id': 256, 'name': 200, 'text': _TEXT_LIMIT}
_ANCHOR = ('[Scheduled task "{name}" ran. The next message is its output, which the user has already '
           'received. The user did not type this.]')


@dataclass(frozen=True, slots=True)
class CronPost:
    job_id: str
    execution_id: str
    name: str
    text: str
    category: str = 'result'

    @property
    def anchor(self) -> str:
        return _ANCHOR.format(name=self.name)

    @property
    def display_metadata(self) -> dict:
        marker = {CRON_DELIVERY_KEY: {'job_id': self.job_id, 'execution_id': self.execution_id}}
        return {**marker, **({'notification_category': 'diagnostic'} if self.category == 'diagnostic' else {})}


def cron_delivery_metadata(delivery) -> dict:
    if delivery is None:
        return {}
    if (not isinstance(delivery, dict) or set(delivery) != set(_FIELD_LIMITS)
            or not all(isinstance(delivery[key], str) and delivery[key].strip() and len(delivery[key]) <= limit
                       for key, limit in _FIELD_LIMITS.items())):
        raise AuthorityRefusal('invalid_params')
    return {CRON_DELIVERY_KEY: dict(delivery)}


def _legacy_name(routine) -> str:
    from cron.job_title import readable_job_name
    return readable_job_name(str((routine or {}).get('job_name') or ''))


def record_delivery(record) -> dict | None:
    if delivery := record.get(CRON_DELIVERY_KEY):
        return delivery
    if routine := record.get('routine'):
        key = record['delivery_id']
        return {'job_id': key, 'execution_id': key, 'name': _legacy_name(routine), 'text': routine['text']}
    return None


def cron_post(payload) -> CronPost | None:
    from gateway.response_filters import ROUTINE_OUTPUT_DISPLAY_KIND
    descriptor = (payload or {}).get('local_automation_v1') or {}
    category = descriptor.get('notification_category', 'result')
    if delivery := descriptor.get(CRON_DELIVERY_KEY):
        return CronPost(**delivery, category=category)
    if descriptor.get('display_kind') != ROUTINE_OUTPUT_DISPLAY_KIND:
        return None
    identity = descriptor['identity']
    return CronPost(identity, identity, _legacy_name(descriptor.get('routine')), descriptor['display_text'], category)


def write_cron_post(store, session_id: str, post: CronPost):
    return store.messages.append_cron_delivery(session_id, post.anchor, post.text, post.display_metadata)


async def post_cron_delivery(authority, ref, row) -> str | None:
    post = cron_post(row['payload'])
    if post is None:
        return None
    from gateway.session_persistence import authority_persistence
    from gateway.session_runtime_workers import tracked_write
    from gateway.session_viewer_close import _physical_target
    target = _physical_target(authority, ref.session_id)
    written = await tracked_write(authority, partial(write_cron_post, authority_persistence(authority), target, post))
    refresh = getattr(authority.runner, '_refresh_agent_cache_message_count', None)
    if refresh is not None:
        await refresh(authority.sessions[ref.session_id].route, target)
    reply = '' if written is None else post.text
    result = {'final_response': reply, 'messages': []}
    if written is not None:
        result['persisted_turn'] = {
            'row_ids': [written.row_id], 'complete': False, 'final_assistant_row_id': written.row_id,
            'final_assistant_message_uid': written.message_uid}
    authority.pending_results[row['admission_id']] = {'result': result, 'usage': {}}
    return reply
