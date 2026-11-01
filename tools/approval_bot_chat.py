import threading

from tools import approval_context

BOT_CHAT_SCOPE = "bot_chat"

_lock = threading.Lock()
_MAX_SESSIONS = 256
_denied: dict[str, tuple[str, frozenset[str]]] = {}


def choices(*, allow_permanent: bool) -> list[str]:
    return ["once", "always", "deny"] if allow_permanent else ["once", "deny"]


def coerce_choice(choice):
    if approval_context.is_bot_chat_turn() and choice == "session":
        return "once"
    return choice


def hold_denial(session_key: str, pattern_keys: list[str]) -> None:
    turn_id = approval_context.get_current_turn_id()
    if not approval_context.is_bot_chat_turn() or not session_key or not turn_id or not pattern_keys:
        return
    with _lock:
        previous_turn, previous_keys = _denied.pop(session_key, ("", frozenset()))
        keys = previous_keys if previous_turn == turn_id else frozenset()
        _denied[session_key] = (turn_id, keys | frozenset(pattern_keys))
        while len(_denied) > _MAX_SESSIONS:
            _denied.pop(next(iter(_denied)))


def denial_held(session_key: str, pattern_keys: list[str]) -> bool:
    turn_id = approval_context.get_current_turn_id()
    if not approval_context.is_bot_chat_turn() or not session_key or not turn_id:
        return False
    with _lock:
        held_turn, held_keys = _denied.get(session_key, ("", frozenset()))
    return held_turn == turn_id and any(key in held_keys for key in pattern_keys)


def clear(session_key: str) -> None:
    with _lock:
        _denied.pop(session_key, None)
