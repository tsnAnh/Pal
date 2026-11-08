from __future__ import annotations

from functools import partial
from pathlib import Path

from pydantic import ValidationError

from gateway.reach_presence import slot_of
from hermes_state_runtime import RuntimeStoreError


def _authority_home(authority) -> Path:
    return Path(authority.db.db_path).resolve().parent


async def outcome(connection, ref, params):
    from gateway import reach
    from tui_gateway.contracts.canonical_reach import ReachOutcomeParams
    if not connection.actor.capabilities:
        raise RuntimeStoreError('permission_denied')
    try:
        parsed = ReachOutcomeParams.model_validate(params)
    except ValidationError as exc:
        raise RuntimeStoreError('invalid_params') from exc
    slot = slot_of(connection.transport)
    home = _authority_home(connection.authority)
    recorded = await reach.record_outcome(
        home, parsed.offer_id, reach.Outcome(parsed.outcome), slot.device if slot else None,
        transport=connection.transport)
    return {'recorded': recorded}


def handlers(connection):
    return {'reach.outcome': partial(outcome, connection)}
