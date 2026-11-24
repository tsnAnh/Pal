import hashlib
import time
import uuid
from datetime import UTC, datetime

from gateway import commitments as ledger
from gateway import commitments_wake
from gateway.autonomy import ActionClass
from gateway.commitments import Actor, Details, Refused, RefusalCode, State, Trigger
from gateway.commitments_capture import current_profile, current_route
from hermes_constants import get_hermes_home
from tools.approval_context import get_current_approval_session_id, get_current_tool_call_id, get_current_turn_id
from tools.registry import registry, tool_error, tool_result

_UPDATE_TARGETS = tuple(s for s in State if s is not State.OPEN and s not in ledger.TERMINAL_STATES)
_CLOSE_TARGETS = tuple(s for s in State if s in ledger.TERMINAL_STATES)
_TARGETS = {"update": frozenset(_UPDATE_TARGETS), "close": frozenset(_CLOSE_TARGETS)}
_MODEL_ACTORS = tuple(a for a in Actor if a is not Actor.AUTO)
_DETAIL_FIELDS = ("note", "next_step", "blocker_what", "blocker_who", "evidence", "reason")


def _lifecycle() -> str:
    moves = []
    for state in State:
        targets = [dst.value for src, dst in sorted(ledger.EDGES, key=lambda e: list(State).index(e[1])) if src is state]
        if targets:
            moves.append(f"{state.value} to {', '.join(targets)}")
    needs = [f"{state.value} needs {', '.join(fields)}" for state, fields in ledger.REQUIRED_FIELDS.items()]
    return f"Moves: {'; '.join(moves)}. Required: {'; '.join(needs)}."


def build_schema() -> dict:
    update_states = ", ".join(s.value for s in _UPDATE_TARGETS)
    close_states = ", ".join(s.value for s in _CLOSE_TARGETS)
    properties = {
        "action": {"type": "string", "enum": list(_ACTIONS),
                   "description": "promise records a new promise, update moves it along, close finishes or drops "
                                  "it, list shows the open ones. Standing duties (primary bot only): "
                                  "propose_mandate suggests one, accept (only when your owner asked in this turn), "
                                  "pause, resume and dismiss move it, list_mandates shows them."},
        "id": {"type": "string", "description": "Commitment id (update, close, accept, pause, resume, dismiss)."},
        "text": {"type": "string", "description": "What you promised, or the standing duty, in one plain sentence "
                                                  "(promise, propose_mandate)."},
        "owner_requested": {"type": "boolean", "description": "true when your owner asked for it in this turn, false "
                                                              "when you offered it (promise, propose_mandate, and the moves of a duty)."},
        "trigger": {"type": "string", "enum": [t.value for t in Trigger],
                    "description": "The event that starts the duty (propose_mandate)."},
        "action_class": {"type": "string", "enum": [a.value for a in ActionClass],
                         "description": "What kind of action the duty takes (propose_mandate)."},
        "done_when": {"type": "string", "description": "When the duty counts as done each time it fires "
                                                       "(propose_mandate)."},
        "due": {"type": "string", "description": "ISO 8601 date-time with offset by which it is due (promise)."},
        "state": {"type": "string", "enum": [s.value for s in (*_UPDATE_TARGETS, *_CLOSE_TARGETS)],
                  "description": f"Target state. update takes {update_states}; close takes {close_states}."},
        "note": {"type": "string", "description": "Short progress note."},
        "next_step": {"type": "string", "description": "Your prepared next step."},
        "blocker_what": {"type": "string", "description": "What blocks it."},
        "blocker_who": {"type": "string", "description": "Who can unblock it."},
        "evidence": {"type": "string", "description": "Proof it is done: a link, a result, a sent message."},
        "reason": {"type": "string", "description": "Why it is dropped or dismissed."},
        "by": {"type": "string", "enum": [a.value for a in _MODEL_ACTORS],
               "description": "Who dropped it; required when abandoning."},
        "expected_rev": {"type": "integer", "description": "Revision you last saw; defaults to the current one."},
    }
    return {
        "name": "commitment",
        "description": "Record and track promises to your owner that outlive this turn. " + _lifecycle()
                       + " Standing duties: a proposal becomes an active mandate only when your owner accepts it.",
        "parameters": {"type": "object", "properties": properties, "required": ["action"]},
    }



def _text(args: dict, name: str) -> str | None:
    value = args.get(name)
    return value.strip() or None if isinstance(value, str) else None


def _required(args: dict, name: str) -> str:
    if (value := _text(args, name)) is None:
        raise Refused(RefusalCode.INVALID, f"{name} is required.")
    return value


def _due(args: dict) -> float | None:
    raw = _text(args, "due")
    if raw is None:
        return None
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        raise Refused(RefusalCode.INVALID, "due must be an ISO 8601 date-time with an offset.") from None
    if parsed.tzinfo is None:
        raise Refused(RefusalCode.INVALID, "due must carry a UTC offset.")
    return parsed.timestamp()


def _event_key(action: str, commitment_id: str) -> str:
    session, turn, call = get_current_approval_session_id(), get_current_turn_id(), get_current_tool_call_id()
    if not (session and turn and call):
        return uuid.uuid4().hex
    return hashlib.sha256("\x1f".join((session, turn, call, action, commitment_id)).encode()).hexdigest()


def _iso(timestamp: float | None) -> str | None:
    return datetime.fromtimestamp(timestamp, tz=UTC).isoformat() if timestamp is not None else None


def _promise(args: dict, now: float) -> dict:
    owner_requested = args.get("owner_requested")
    if not isinstance(owner_requested, bool):
        raise Refused(RefusalCode.INVALID, "owner_requested is required: true when your owner asked, else false.")
    made = ledger.promise(get_hermes_home(), event_key=_event_key("promise", ""), profile=current_profile(),
                          text=_required(args, "text"), owner_requested=owner_requested, due_at=_due(args),
                          route=current_route(), now=now, next_step=_text(args, "next_step"))
    follow_up_error = commitments_wake.ensure_job()
    return {"id": made.commitment_id, "state": made.to_state.value, "rev": made.rev,
            **({"replayed": True} if made.replayed else {}),
            **({"follow_up_error": follow_up_error} if follow_up_error else {})}


def _target(args: dict, action: str) -> State:
    try:
        to = State(_required(args, "state"))
    except ValueError:
        raise Refused(RefusalCode.INVALID, "state is not a known state.") from None
    if to not in _TARGETS[action]:
        allowed = ", ".join(s.value for s in sorted(_TARGETS[action], key=list(State).index))
        raise Refused(RefusalCode.INVALID, f"{action} takes state {allowed}.")
    return to


def _actor(args: dict, to: State) -> Actor:
    by = _text(args, "by")
    if by is None:
        if to is State.ABANDONED:
            raise Refused(RefusalCode.MISSING_FIELDS, "Abandoning needs: by.")
        return Actor.BOT
    try:
        actor = Actor(by)
    except ValueError:
        raise Refused(RefusalCode.INVALID, "by is not a known actor.") from None
    if actor not in _MODEL_ACTORS:
        raise Refused(RefusalCode.INVALID, "by is not a known actor.")
    return actor


def _expected_rev(args: dict, home, commitment_id: str) -> int:
    given = args.get("expected_rev")
    if given is not None:
        if isinstance(given, bool) or not isinstance(given, int):
            raise Refused(RefusalCode.INVALID, "expected_rev must be an integer.")
        return given
    current = ledger.get(home, commitment_id)
    if current is None:
        raise Refused(RefusalCode.UNKNOWN, f"No commitment {commitment_id!r}.")
    return current.rev


def _move(args: dict, now: float, action: str) -> dict:
    home = get_hermes_home()
    commitment_id = _required(args, "id")
    to = _target(args, action)
    actor = _actor(args, to)
    moved = ledger.transition(
        home, commitment_id, event_key=_event_key(action, commitment_id),
        expected_rev=_expected_rev(args, home, commitment_id), to=to,
        details=Details(**{name: _text(args, name) for name in _DETAIL_FIELDS}), actor=actor, now=now)
    return {"id": moved.commitment_id, "from": moved.from_state.value, "to": moved.to_state.value, "rev": moved.rev,
            **({"replayed": True} if moved.replayed else {})}


def _item(row: ledger.Commitment, now: float) -> dict:
    item = {"id": row.id, "promise": row.promise, "state": row.state.value, "rev": row.rev, "due": _iso(row.due_at),
            "overdue": row.overdue(now), "stuck": row.stuck(now), "next_step": row.next_step}
    if row.state is State.BLOCKED:
        item["blocker"] = {"what": row.blocker_what, "who": row.blocker_who}
    return item


def _list(args: dict, now: float) -> dict:
    return {"commitments": [_item(row, now) for row in ledger.list_active(get_hermes_home())]}


def _duty(row: ledger.Commitment) -> dict:
    return {"id": row.id, "duty": row.promise, "standing": row.standing.value, "rev": row.rev,
            "trigger": row.trigger.value, "action_class": row.action_class.value, "done_when": row.done_when,
            "hits": row.hits, "dismissed": row.dismissed, "last_fired": _iso(row.last_fired)}


def _propose_mandate(args: dict, now: float) -> dict:
    owner_requested = args.get("owner_requested")
    if not isinstance(owner_requested, bool):
        raise Refused(RefusalCode.INVALID, "owner_requested is required: true when your owner asked, else false.")
    made = ledger.propose_mandate(
        get_hermes_home(), event_key=_event_key("propose_mandate", ""), profile=current_profile(),
        text=_required(args, "text"), trigger=_text(args, "trigger"), action_class=_text(args, "action_class"),
        done_when=_required(args, "done_when"), owner_requested=owner_requested, route=current_route(), now=now)
    return {"id": made.commitment_id, "standing": ledger.Standing.PROPOSED.value, "rev": made.rev,
            **({"replayed": True} if made.replayed else {})}


def _duty_move(move):
    def run(args: dict, now: float) -> dict:
        home = get_hermes_home()
        commitment_id = _required(args, "id")
        asked = args.get("owner_requested") is True
        if move is ledger.accept and not asked:
            raise Refused(RefusalCode.OWNER_ONLY, "Only your owner accepts a proposal: call accept when an owner "
                                                  "message in this turn asked for it, with owner_requested true.")
        moved = move(home, commitment_id, event_key=_event_key(move.__name__, commitment_id),
                     expected_rev=_expected_rev(args, home, commitment_id),
                     actor=Actor.OWNER if asked else Actor.BOT, now=now, reason=_text(args, "reason"))
        return {**_duty(ledger.get(home, commitment_id)), **({"replayed": True} if moved.replayed else {})}
    return run


def _list_mandates(args: dict, now: float) -> dict:
    return {"mandates": [_duty(row) for row in ledger.list_mandates(get_hermes_home())]}


def _primary_only(handler):
    def run(args: dict, now: float) -> dict:
        ledger.require_primary(current_profile())
        return handler(args, now)
    return run


_ACTIONS = {
    "promise": _promise,
    "update": lambda args, now: _move(args, now, "update"),
    "close": lambda args, now: _move(args, now, "close"),
    "list": _list,
    "propose_mandate": _primary_only(_propose_mandate),
    "accept": _primary_only(_duty_move(ledger.accept)),
    "pause": _primary_only(_duty_move(ledger.pause)),
    "resume": _primary_only(_duty_move(ledger.resume)),
    "dismiss": _primary_only(_duty_move(ledger.dismiss)),
    "list_mandates": _primary_only(_list_mandates),
}
COMMITMENT_SCHEMA = build_schema()


def commitment_tool(args: dict) -> str:
    action = args.get("action")
    if action not in _ACTIONS:
        return tool_error(f"action must be one of {', '.join(_ACTIONS)}.", code=RefusalCode.INVALID.value)
    try:
        return tool_result(_ACTIONS[action](args, time.time()))
    except Refused as refused:
        return tool_error(refused.message, code=refused.code.value)


registry.register(
    name="commitment",
    toolset="commitment",
    schema=COMMITMENT_SCHEMA,
    handler=lambda args, **kw: commitment_tool(args),
    check_fn=lambda: True,
    emoji="🤝",
)
