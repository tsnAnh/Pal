"""Time-driven work of ProcessRegistry: heartbeats, overdue-process reaping, listing retention."""

import logging
import threading
import time
from contextvars import copy_context
from dataclasses import dataclass

from tools.process_registry_notifications import heartbeat_output_tail

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class InternalProcessPolicy:
    """Marks a spawn as Hermes plumbing: hidden from user-facing process surfaces, never stoppable
    from them, and reaped when it outlives ``max_lifetime_seconds``. ``expiry_output`` is what the
    reaped process's completion carries, so its owner sees a failure rather than a bare kill."""
    max_lifetime_seconds: float
    expiry_output: str = ""


class ProcessTimerMixin:
    """One daemon thread serves every heartbeat session and lifetime-bounded process: reader threads
    block on the pipe and cannot keep time, and a per-process timer would leak a thread per job. The
    subclass supplies ``_lock``, ``_running``, ``_clock``, ``completion_queue`` and ``kill_process``."""

    def arm_heartbeat(self, session, seconds: int) -> int:
        """Enable periodic heartbeat events for ``session``; returns the effective interval."""
        from tools import process_registry as facade

        seconds = max(int(seconds), facade.HEARTBEAT_MIN_SECONDS)
        session.heartbeat_seconds = seconds
        session._heartbeat_last = time.time()
        # The output baseline stays at spawn (field default 0), never here: the spawn call
        # arms the heartbeat only after its bookkeeping, and a fast-starting process has
        # already written its first lines by then. Those lines belong to the first heartbeat.
        self._ensure_background_thread()
        return seconds

    def _ensure_background_thread(self) -> None:
        with self._lock:
            if self._heartbeat_thread is not None and self._heartbeat_thread.is_alive():
                return
            self._heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop, name="process-heartbeat", daemon=True)
            self._heartbeat_thread.start()

    def _heartbeat_loop(self) -> None:
        from tools import process_registry as facade

        while True:
            time.sleep(facade.HEARTBEAT_TICK_SECONDS)
            try:
                self.reap_overdue()
            except Exception:
                logger.warning("overdue-process sweep failed", exc_info=True)
            now = time.time()
            with self._lock:
                due = [s for s in self._running.values()
                       if s.heartbeat_seconds > 0 and not s.exited
                       and now - s._heartbeat_last >= s.heartbeat_seconds]
            for session in due:
                self._emit_heartbeat(session, now)

    def _emit_heartbeat(self, session, now: float) -> None:
        """Queue a heartbeat carrying the output since the last one. A tick with nothing new is
        skipped outright: every queued event costs the owner a full model turn, and "still running,
        no output" is already visible on the process surfaces (status stack, /agents dock)."""
        from tools.process_registry import _redact_process_result

        session._heartbeat_last = now
        with session._lock:
            delta = session.total_output_chars - session._heartbeat_total_at_last
            output = session.output_buffer[-delta:] if delta > 0 else ""
            session._heartbeat_total_at_last = session.total_output_chars
        if not output:
            return
        output, omitted = heartbeat_output_tail(output)
        session._heartbeat_seq += 1
        notification = {
            **self._watch_event_base(session),
            "type": "heartbeat",
            "seq": session._heartbeat_seq,
            "interval": session.heartbeat_seconds,
            "elapsed": int(now - session.started_at) if session.started_at else 0,
            "output": output,
            "omitted": omitted,
            "started_at": session.started_at,
        }
        _redact_process_result(notification)
        self.completion_queue.put(notification)

    @staticmethod
    def _listing_expired(session, now: float) -> bool:
        """A finished entry past ``FINISHED_LISTING_RETENTION_SECONDS``, unless its notice is still due."""
        from tools import process_registry as facade
        from tools.process_registry_awaiting import retained_for_delivery

        if not session.exited or retained_for_delivery(session):
            return False
        return now - (session.exited_at or session.started_at) > facade.FINISHED_LISTING_RETENTION_SECONDS

    def reap_overdue(self) -> list[str]:
        """Kill running processes past their ``max_lifetime_seconds``; their completion carries
        ``lifetime_expiry_output``. Returns the ids it stopped. The kill runs in the spawning
        context, so a sweep on the shared timer thread (or any caller's list) still acts as the owning profile."""
        now = self._clock()
        with self._lock:
            overdue = [s for s in self._running.values()
                       if s.max_lifetime_seconds > 0 and not s.exited
                       and now - s.started_at > s.max_lifetime_seconds]
        reaped = []
        for session in overdue:
            if session.lifetime_expiry_output:
                session.append_output_if_running(f"\n{session.lifetime_expiry_output}")
            scope = session._scope.copy() if session._scope is not None else copy_context()
            result = scope.run(self.kill_process, session.id, source="lifetime_exceeded", consume_output=False)
            if result.get("status") in {"killed", "already_exited"}:
                reaped.append(session.id)
        return reaped
