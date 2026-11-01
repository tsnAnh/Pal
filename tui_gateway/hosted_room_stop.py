"""Explicit Stop for a hosted room: member turns are cancelled by the driver; this ends what a plain turn
interrupt leaves alive (background processes, async delegations) and the Bot Chat turns the members
handed work to, so "Stop now" leaves nothing of the room running."""

from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any

from tui_gateway.hosted_room_driver import ROOM_SESSION_SOURCE, room_session_title

logger = logging.getLogger(__name__)


def _member_session_id(service, room_id: str, member: Mapping[str, Any]) -> str | None:
    target = member.get("target") or {}
    if target.get("kind", "local") != "local":
        return None
    resolved = service.rpc.resolve_exact(
        profile=str(member["profile"]), title=room_session_title(room_id), source=ROOM_SESSION_SOURCE)
    return str(resolved["session_id"]) if resolved and resolved.get("session_id") else None


def _live_records(server, durable_id: str) -> list[tuple[str, dict]]:
    with server._sessions_lock:
        return [
            (sid, record) for sid, record in server._sessions.items()
            if durable_id in {str(record.get("session_key") or ""),
                              str(getattr(record.get("agent"), "session_id", "") or "")}]


def _kill_session_processes(session_keys: set[str], owners: set[str]) -> int:
    from tools.process_registry import process_registry
    with process_registry._lock:
        ids = [
            proc.id for proc in process_registry._running.values()
            if not proc.exited and proc.session_key in session_keys
            and (proc.owner_task_id or proc.task_id) in owners]
    return sum(
        process_registry.kill_process(pid, source="room.stop", consume_output=False).get("status")
        in {"killed", "already_exited"} for pid in ids)


def stop_session_work(durable_id: str, live: list[tuple[str, dict]], *, reason: str) -> dict[str, int]:
    """Explicit-stop one local session's leftovers and the handoffs it started."""
    from tools.async_delegation import interrupt_for_session
    from tools.bot_handoff_ledger import take_handoffs
    from tools.bot_live_delivery import authority_stop

    keys = {durable_id} | {str(record.get("session_key") or "") for _, record in live}
    owners = {durable_id} | {str(getattr(record.get("agent"), "session_id", "") or "") for _, record in live}
    keys.discard("")
    owners.discard("")
    selectors = [(str(record.get("session_key") or durable_id), sid) for sid, record in live] or [(durable_id, "")]
    delegations = sum(
        interrupt_for_session(session_key=key, origin_ui_session_id=sid, parent_session_id=durable_id, reason=reason)
        for key, sid in selectors)
    processes = _kill_session_processes(keys, owners)
    handoffs = 0
    for handoff in take_handoffs(owners | keys):
        try:
            authority_stop(handoff["profile_home"], {"id": handoff["delivery_id"], "profile": handoff["profile"]})
            handoffs += 1
        except Exception:
            logger.warning("room stop: handoff %s could not be stopped", handoff["delivery_id"], exc_info=True)
    return {"delegations": delegations, "processes": processes, "handoffs": handoffs}


def stop_room_member_work(service, room_id: str, *, reason: str = "room_stop") -> dict[str, int]:
    totals = {"delegations": 0, "processes": 0, "handoffs": 0}
    for member in service._room(room_id)["members"]:
        try:
            durable_id = _member_session_id(service, room_id, member)
            if durable_id is None:
                continue
            counts = stop_session_work(
                durable_id, _live_records(service.server, durable_id), reason=reason)
        except Exception:
            logger.warning("room stop: member %s work could not be stopped", member.get("member_id"), exc_info=True)
            continue
        for key, value in counts.items():
            totals[key] += value
    return totals
