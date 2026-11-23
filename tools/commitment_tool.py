import hashlib
import time
import uuid
from datetime import UTC, datetime

from gateway import commitments as ledger
from gateway import commitments_wake
from gateway.commitments import Actor, Details, Refused, RefusalCode, Route, State
from gateway.session_context import get_session_env
from hermes_cli.profiles import current_profile_name
from hermes_constants import get_hermes_home
from tools.approval_context import get_current_approval_session_id, get_current_tool_call_id, get_current_turn_id
from tools.registry import registry, tool_error, tool_result

_UPDATE_TARGETS = tuple(s for s in State if s is not State.OPEN and s not in ledger.TERMINAL_STATES)
_CLOSE_TARGETS = tuple(s for s in State if s in ledger.TERMINAL_STATES)
_TARGETS = {"update": frozenset(_UPDATE_TARGETS), "close": frozenset(_CLOSE_TARGETS)}
_ROUTE_ENV = {
    "platform": "HERMES_SESSION_PLATFORM", "chat_id": "HERMES_SESSION_CHAT_ID",
    "thread_id": "HERMES_SESSION_THREAD_ID", "chat_type": "HERMES_SESSION_CHAT_TYPE",
    "session_key": "HERMES_SESSION_KEY", "session_id": "HERMES_SESSION_ID",
}
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
        "action": {"type": "string", "enum": ["promise", "update", "close", "list"],
                   "description": "promise records a new promise, update moves it along, close finishes or drops "
                                  "it, list shows the open ones."},
        "id": {"type": "string", "description": "Commitment id (update and close)."},
        "text": {"type": "string", "description": "What you promised, in one plain sentence (promise)."},
        "owner_requested": {"type": "boolean", "description": "true when your owner asked for it, false when you "
                                                              "offered it (promise)."},
        "due": {"type": "string", "description": "ISO 8601 date-time with offset by which it is due (promise)."},
        "state": {"type": "string", "enum": [s.value for s in (*_UPDATE_TARGETS, *_CLOSE_TARGETS)],
                  "description": f"Target state. update takes {update_states}; close takes {close_states}."},
        "note": {"type": "string", "description": "Short progress note."},
        "next_step": {"type": "string", "description": "Your prepared next step."},
        "blocker_what": {"type": "string", "description": "What blocks it."},
        "blocker_who": {"type": "string", "description": "Who can unblock it."},
        "evidence": {"type": "string", "description": "Proof it is done: a link, a result, a sent message."},
        "reason": {"type": "string", "description": "Why it is dropped."},
        "by": {"type": "string", "enum": [a.value for a in Actor],
               "description": "Who dropped it; required when abandoning."},
        "expected_rev": {"type": "integer", "description": "Revision you last saw; defaults to the current one."},
    }
    return {
        "name": "commitment",
        "description": "Record and track promises to your owner that outlive this turn. " + _lifecycle(),
        "parameters": {"type": "object", "properties": properties, "required": ["action"]},
    }


COMMITMENT_SCHEMA = build_schema()


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


def _route() -> Route:
    return Route(**{field: get_session_env(env) or None for field, env in _ROUTE_ENV.items()})


def _profile() -> str:
    return get_session_env("HERMES_SESSION_PROFILE") or current_profile_name("default") or "default"


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
    made = ledger.promise(get_hermes_home(), event_key=_event_key("promise", ""), profile=_profile(),
                          text=_required(args, "text"), owner_requested=owner_requested, due_at=_due(args),
                          route=_route(), now=now, next_step=_text(args, "next_step"))
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
        return Actor(by)
    except ValueError:
        raise Refused(RefusalCode.INVALID, "by is not a known actor.") from None


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


_ACTIONS = {
    "promise": _promise,
    "update": lambda args, now: _move(args, now, "update"),
    "close": lambda args, now: _move(args, now, "close"),
    "list": _list,
}


def commitment_tool(args: dict) -> str:
    action = args.get("action")
    if action not in _ACTIONS:
        return tool_error("action must be promise, update, close or list.", code=RefusalCode.INVALID.value)
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
