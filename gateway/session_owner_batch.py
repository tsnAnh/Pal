import asyncio
import logging
from functools import partial
from itertools import takewhile

from gateway.session_persistence import authority_persistence
from gateway.session_queued_controls import _register, _unregister, steer_blocker
from persistence.core.errors import AuthorityRefusal

logger = logging.getLogger(__name__)


def _batchable(authority, row):
    from gateway.session_absorb import is_owner_input
    payload = {key: value for key, value in row['payload'].items() if key != 'attachments_v1'}
    return is_owner_input(row['payload']) and steer_blocker(
        authority, {**row, 'status': 'queued', 'payload': payload}, any_source=True) is None


async def fold_queued_owner_input(authority, ref, live, row):
    from gateway.session_absorb import is_bot_chat
    if not (_batchable(authority, row) and await is_bot_chat(authority, ref.session_id)):
        return row
    sid, generation = ref.session_id, row['generation']
    admissions = authority_persistence(authority).admissions
    from gateway.session_authority import admission_row
    from gateway.session_runtime_workers import tracked_write
    waiting = [admission_row(record) for record in await asyncio.to_thread(admissions.list, session_id=sid)]
    followers = list(takewhile(partial(_batchable, authority),
                               (waiting_row for waiting_row in waiting if waiting_row['status'] == 'queued')))
    folded = []
    try:
        for follower in followers:
            admission_id = follower['admission_id']
            with live.event_stream.lock:
                _register(authority, sid, generation, admission_id)
            try:
                _, fresh = await tracked_write(authority, partial(
                    admissions.steer, epoch=authority.epoch, admission_id=admission_id, generation=generation))
            except AuthorityRefusal as refusal:
                with live.event_stream.lock:
                    _unregister(authority, sid, generation, admission_id)
                if refusal.reason == 'admission_started':
                    continue
                raise
            if fresh:
                folded.append(follower)
        if not folded:
            return row
        with live.event_stream.lock:
            for follower in folded:
                authority.steer_transfers[sid][1][follower['admission_id']] = True
    except Exception:
        logger.exception('Session %s: queued owner input was not folded into the claimed turn', sid)
        return row
    authority._publish_pending(ref)
    payload = {**row['payload'], 'text': '\n'.join(item['payload']['text'] for item in (row, *folded))}
    attached = [item['payload']['attachments_v1'] for item in (row, *folded) if 'attachments_v1' in item['payload']]
    if len(attached) > (1 if 'attachments_v1' in row['payload'] else 0):
        payload['attachments_v1'] = {'media': [media for part in attached for media in part['media']],
                                     'media_types': [kind for part in attached for kind in part['media_types']]}
    return {**row, 'payload': payload}
