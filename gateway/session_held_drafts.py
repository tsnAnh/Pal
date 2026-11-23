import asyncio
from pathlib import Path

from gateway.session_authorities import owner_scope
from persistence.core.errors import AuthorityRefusal
from tools import bot_mode_draft_store
from tools.bot_mode_drafts import profile_is_bot_managed

DRAFT_PROMPT_PREFIX = 'draft:'
_DRAFT_CHOICES = ('once', 'deny')
_REFUSAL_CODE = 4134


class DraftRefusal(AuthorityRefusal):
    def __init__(self, code, message, state):
        super().__init__(code)
        self.wire_code, self.wire_message = _REFUSAL_CODE, message
        self.wire_data = {'state': state}


def is_draft_prompt(prompt_id) -> bool:
    return isinstance(prompt_id, str) and prompt_id.startswith(DRAFT_PROMPT_PREFIX)


def _profile_home(authority):
    home = Path(str(authority.profile_id))
    return home if home.is_absolute() else None


def _managed_cards(authority):
    home = _profile_home(authority)
    return bot_mode_draft_store.pending_cards(home) if profile_is_bot_managed(home) else []


async def pending_cards(authority) -> list[dict]:
    return await asyncio.to_thread(_managed_cards, authority)


def _answer(authority, draft_id, choice, edited_text):
    home = _profile_home(authority)
    with owner_scope(authority, hydrate_secrets=True):
        if not profile_is_bot_managed(home):
            raise bot_mode_draft_store.DraftError('not_found', 'This draft no longer exists.')
        return bot_mode_draft_store.answer(draft_id, choice, edited_text, home=home)


async def respond(connection, ref, params):
    choice, edited_text = params.get('choice'), params.get('edited_text')
    if (set(params) - {'session_id', 'execution_generation', 'prompt_id', 'choice', 'edited_text'}
            or choice not in _DRAFT_CHOICES
            or (edited_text is not None and (not isinstance(edited_text, str) or choice != 'once'))):
        raise AuthorityRefusal('invalid_params')
    authority, actor = connection.authority, connection.actor
    authority.authorize(actor, ref, 'session:approve')
    live = authority.sessions[ref.session_id]
    with live.event_stream.lock:
        if actor not in live.subscribers.values():
            raise AuthorityRefusal('permission_denied')
    prompt_id = params['prompt_id']
    try:
        answered = await asyncio.to_thread(
            _answer, authority, prompt_id[len(DRAFT_PROMPT_PREFIX):], choice, edited_text)
    except bot_mode_draft_store.DraftError as exc:
        raise DraftRefusal(exc.code, exc.message, exc.state) from exc
    return {'status': 'resolved', 'prompt_id': prompt_id, 'state': answered['state']}
