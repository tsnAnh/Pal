"""ACP permission bridging for Hermes owner-decision consents (outbound sends, payments, spend limits)."""

from __future__ import annotations

import asyncio
import logging
from concurrent.futures import TimeoutError as FutureTimeout
from itertools import count
from typing import Callable

from acp.schema import AllowedOutcome, PermissionOption

logger = logging.getLogger(__name__)

_OPTION_ID_TO_HERMES = {"allow_once": "once", "deny": "deny"}

_PERMISSION_REQUEST_IDS = count(1)


def _build_permission_options() -> list[PermissionOption]:
    return [PermissionOption(option_id="allow_once", kind="allow_once", name="Allow once"),
            PermissionOption(option_id="deny", kind="reject_once", name="Deny")]


def _build_permission_tool_call(command: str, description: str):
    """Return the ``ToolCallUpdate`` (not ``ToolCallStart``) payload attached to a
    permission request; unique ``perm-check-N`` ids keep concurrent requests apart."""
    import acp as _acp

    content_text = f"{description}\n$ {command}" if description else f"$ {command}"
    return _acp.update_tool_call(
        f"perm-check-{next(_PERMISSION_REQUEST_IDS)}", title=f"{description}: {command}" if description else command,
        kind="execute", status="pending", content=[_acp.tool_content(_acp.text_block(content_text))],
        raw_input={"command": command, "description": description},
    )


def _map_outcome_to_hermes(outcome: object, *, allowed_option_ids: set[str]) -> str:
    """Map an ACP permission outcome into Hermes approval strings."""
    if not isinstance(outcome, AllowedOutcome):
        return "deny"
    if outcome.option_id not in allowed_option_ids:
        logger.warning("Permission request returned unknown option_id: %s", outcome.option_id)
        return "deny"
    return _OPTION_ID_TO_HERMES.get(outcome.option_id, "deny")


def await_permission(
    request_permission_fn: Callable, loop: asyncio.AbstractEventLoop, session_id: str, *,
    tool_call, options: list[PermissionOption], timeout: float, what: str,
    send_update: Callable[[object], None] | None = None,
) -> tuple[object | None, bool]:
    """Schedule ``request_permission`` on ``loop`` from a worker thread and block for the answer.
    Returns ``(response, timed_out)``; ``(None, False)`` when scheduling or the request failed.

    Clients materialise the request's ``tool_call`` as a pending bubble, so once the answer is
    in, ``send_update`` (when given) closes it: ``completed`` for an allow, ``failed`` otherwise."""
    from agent.async_utils import safe_schedule_threadsafe

    coro = request_permission_fn(session_id=session_id, tool_call=tool_call, options=options)
    future = safe_schedule_threadsafe(coro, loop, logger=logger, log_message=f"{what}: failed to schedule on loop")
    if future is None:
        return None, False
    response, timed_out = None, False
    try:
        response = future.result(timeout=timeout)
    except FutureTimeout:
        future.cancel()
        logger.warning("%s timed out after %ss", what, timeout)
        timed_out = True
    except Exception as exc:
        future.cancel()
        logger.warning("%s failed: %s", what, exc)
    if send_update is not None:
        import acp as _acp

        # Duck-typed like the callers' own allow checks (``outcome == "selected"`` is the wire
        # discriminator), so the bubble's terminal status always matches the decision taken.
        outcome = getattr(response, "outcome", None)
        allowed = getattr(outcome, "outcome", None) == "selected" and any(
            option.option_id == getattr(outcome, "option_id", None) and option.kind.startswith("allow")
            for option in options
        )
        send_update(_acp.update_tool_call(tool_call.tool_call_id, status="completed" if allowed else "failed"))
    return response, timed_out


def resolve_permission_timeout(timeout: float | None) -> float:
    """``None`` is the user's ``approvals.timeout``, the same knob every other consent surface follows."""
    if timeout is not None:
        return float(timeout)
    from tools.approval_context import _get_approval_timeout

    return float(_get_approval_timeout())


def make_approval_callback(request_permission_fn: Callable, loop: asyncio.AbstractEventLoop,
                           session_id: str, timeout: float | None = None,
                           send_update: Callable[[object], None] | None = None) -> Callable[..., str]:
    """Return a Hermes consent callback (``command, description, **kw``) that bridges to the ACP
    connection's ``request_permission`` coroutine on ``loop``; auto-denies after ``timeout`` s."""

    def _callback(command: str, description: str, **_: object) -> str:
        options = _build_permission_options()
        response, timed_out = await_permission(
            request_permission_fn, loop, session_id, tool_call=_build_permission_tool_call(command, description),
            options=options, timeout=resolve_permission_timeout(timeout), what="Permission request",
            send_update=send_update,
        )
        if timed_out:
            # Distinct from an explicit deny: no user response.
            return "timeout"
        if response is None:
            return "deny"
        return _map_outcome_to_hermes(response.outcome, allowed_option_ids={option.option_id for option in options})

    return _callback
