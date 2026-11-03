from __future__ import annotations

import contextlib
import contextvars
import hashlib
import json
import logging
import os
import re
import secrets
import threading
import time
from pathlib import Path
from typing import Iterable, MutableMapping

logger = logging.getLogger(__name__)

AGENT_TOOL_MARKER_ENV = "HERMES_AGENT_TOOL_CONTEXT"
GRANT_ENV = "HERMES_PROFILE_ADMIN_GRANT"
TURN_ID_ENV = "HERMES_TURN_ID"
GRANT_TTL_SECONDS = 120
DENIED_MESSAGE = "Creating or deleting bots needs your approval in an interactive session."
SHARED_MCP_DENIED_MESSAGE = (
    "Changing or deleting a shared MCP server for every bot needs your approval in an interactive session.")
_DENIED_MESSAGES = {
    "mcp_replace_shared": SHARED_MCP_DENIED_MESSAGE,
    "mcp_remove_everywhere": SHARED_MCP_DENIED_MESSAGE,
    "catalog_migrate": "Migrating or rolling back the shared catalog for every bot needs your approval in an "
        "interactive session.",
}

_TOKEN_RE = re.compile(r"[0-9a-f]{64}")
_CREATING_ACTIONS = frozenset({"create", "import", "install"})
_MAX_SPENT_TOKENS = 64

_scoped_grant: contextvars.ContextVar[str] = contextvars.ContextVar("hermes_profile_admin_grant", default="")
_spent_lock = threading.Lock()
_spent_tokens: dict[str, str] = {}


class ProfileAdminDenied(PermissionError):
    def __init__(self, message: str = DENIED_MESSAGE) -> None:
        super().__init__(message)


def in_agent_context() -> bool:
    if os.environ.get(AGENT_TOOL_MARKER_ENV):
        return True
    from agent.delegation_context import is_delegated_child_process_context
    from tools.approval_context import _is_cron_approval_context
    return (is_delegated_child_process_context() or _is_cron_approval_context()
            or bool((os.environ.get("HERMES_KANBAN_TASK") or "").strip()))


def agent_tool_env(env: MutableMapping[str, str]) -> MutableMapping[str, str]:
    env[AGENT_TOOL_MARKER_ENV] = "1"
    env.pop(GRANT_ENV, None)
    token = _scoped_grant.get()
    if token:
        env[GRANT_ENV] = token
    env.pop(TURN_ID_ENV, None)
    turn_id = tool_turn_id()
    if turn_id:
        env[TURN_ID_ENV] = turn_id
    return env


def tool_turn_id() -> str:
    from agent.delegation_context import is_delegated_child_context
    from tools.approval_context import get_current_turn_id

    if is_delegated_child_context():
        return ""
    return get_current_turn_id()


def leave_agent_context() -> None:
    os.environ.pop(AGENT_TOOL_MARKER_ENV, None)
    os.environ.pop(GRANT_ENV, None)
    os.environ.pop(TURN_ID_ENV, None)


def verified_grant(token: str | None, command: str) -> str:
    if not token:
        return ""
    if _grant_matches_command(token, command):
        return token
    logger.warning("Dropped a profile-admin grant that was not issued for the command being run")
    revoke_grant(token)
    return ""


def bind_grant(token: str | None, command: str) -> contextvars.Token | None:
    token = verified_grant(token, command)
    return _scoped_grant.set(token) if token else None


def unbind_grant(handle: contextvars.Token | None) -> None:
    if handle is not None:
        _scoped_grant.reset(handle)


def _grants_dir() -> Path:
    from hermes_constants import get_shared_root
    return get_shared_root() / "grants"


def _command_digest(command: str) -> str:
    return hashlib.sha256(command.encode("utf-8")).hexdigest()


def _grant_matches_command(token: str, command: str) -> bool:
    if not _TOKEN_RE.fullmatch(token):
        return False
    try:
        data = json.loads((_grants_dir() / token).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.get("command_sha256") == _command_digest(command)


def revoke_grant(token: str) -> None:
    if _TOKEN_RE.fullmatch(token or ""):
        with contextlib.suppress(OSError):
            (_grants_dir() / token).unlink()


def _root_key() -> str:
    from hermes_constants import get_default_hermes_root
    return str(get_default_hermes_root().resolve())


def _purge_stale(directory: Path) -> None:
    cutoff = time.time() - 2 * GRANT_TTL_SECONDS
    for entry in directory.iterdir():
        with contextlib.suppress(OSError):
            if entry.stat().st_mtime < cutoff:
                entry.unlink()


def _subject(name: str | None) -> str:
    return (name or "").strip().lower()


def _grant_bindings(scope: Iterable[tuple[str, str | None]]) -> list[dict]:
    return sorted(
        ({"action": action, "name": None if name is None else _subject(name)} for action, name in scope),
        key=lambda binding: (binding["action"], binding["name"] or ""))


def _grant_covers(bindings: object, action: str, subject: str) -> bool:
    if not isinstance(bindings, list):
        return False
    for binding in bindings:
        if not isinstance(binding, dict) or binding.get("action") != action or "name" not in binding:
            continue
        bound_name = binding["name"]
        if bound_name is None or (isinstance(bound_name, str) and _subject(bound_name) == subject):
            return True
    return False


def mint_grant(command: str, description: str, scope: Iterable[tuple[str, str | None]]) -> str:
    directory = _grants_dir()
    directory.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(OSError):
        os.chmod(directory, 0o700)
    _purge_stale(directory)
    token = secrets.token_hex(32)
    payload = {
        "command_sha256": _command_digest(command),
        "description": description,
        "root": _root_key(),
        "expires_at": time.time() + GRANT_TTL_SECONDS,
        "bindings": _grant_bindings(scope),
    }
    fd = os.open(directory / token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    return token


def _claim_grant(token: str, action: str, subject: str) -> bool:
    if not _TOKEN_RE.fullmatch(token):
        return False
    directory = _grants_dir()
    claimed = directory / f"{token}.{os.getpid()}.{secrets.token_hex(4)}.claimed"
    try:
        os.rename(directory / token, claimed)
    except OSError:
        return False
    try:
        stat = claimed.stat()
        if hasattr(os, "getuid") and (stat.st_uid != os.getuid() or stat.st_mode & 0o077):
            return False
        data = json.loads(claimed.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return False
    finally:
        with contextlib.suppress(OSError):
            claimed.unlink()
    expires_at = data.get("expires_at") if isinstance(data, dict) else None
    return (isinstance(expires_at, (int, float)) and time.time() < expires_at
            and data.get("root") == _root_key()
            and _grant_covers(data.get("bindings"), action, subject))


def _rollback_subject(action: str, subject: str) -> str:
    if action not in _CREATING_ACTIONS or not subject:
        return ""
    from hermes_cli.profiles import get_profile_dir
    try:
        return "" if get_profile_dir(subject).exists() else subject
    except ValueError:
        return ""


def require_profile_admin_grant(action: str, name: str = "") -> None:
    if not in_agent_context():
        return
    token = (os.environ.get(GRANT_ENV) or "").strip()
    subject = _subject(name)
    with _spent_lock:
        if token in _spent_tokens:
            if action == "delete" and subject and _spent_tokens[token] == subject:
                return
            raise ProfileAdminDenied(_DENIED_MESSAGES.get(action, DENIED_MESSAGE))
        if token and _claim_grant(token, action, subject):
            if len(_spent_tokens) >= _MAX_SPENT_TOKENS:
                _spent_tokens.pop(next(iter(_spent_tokens)))
            _spent_tokens[token] = _rollback_subject(action, subject)
            return
    raise ProfileAdminDenied(_DENIED_MESSAGES.get(action, DENIED_MESSAGE))
