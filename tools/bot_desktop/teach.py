"""Teach a bot a skill by demonstration: start / stop / status of the profile's recording and its draft.

The owner demonstrates while holding the Bot Desktop lease (``lease``); this module only starts a recording
for the viewer that holds it. A stopped recording becomes a disabled draft skill and the prompt that asks the
bot to write it (``teach_draft``). Everything is scoped to the current profile (``get_hermes_home``).
"""

from __future__ import annotations

import time
import uuid
from typing import Any, Optional

from hermes_constants import get_hermes_home
from tools.bot_desktop import browser, lease, runtime, teach_capture, teach_draft, teach_log


class TeachError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def unavailable_reason() -> Optional[str]:
    """Why this profile cannot record a demonstration, or None: the screen must be a gateway-host desktop with
    a Chromium whose DevTools endpoint the gateway can reach (not one inside a terminal sandbox)."""
    if not runtime.is_supported_host():
        return "unsupported"
    if runtime.in_sandbox():
        return "sandbox"
    return None if browser.executable() else "no_browser"


def _pending() -> Optional[dict[str, Any]]:
    meta = teach_draft.pending_meta()
    if meta is None:
        return None
    ready = teach_draft.settle(meta) is not None
    return {"teach_id": meta["teach_id"], "skill_name": meta["skill_name"], "event_count": meta.get("event_count", 0),
            "truncated": bool(meta.get("truncated")),
            "state": teach_draft.STATE_READY if ready else teach_draft.STATE_DRAFTING}


def status() -> dict[str, Any]:
    reason = unavailable_reason()
    recorder = teach_capture.active(get_hermes_home())
    snap = recorder.snapshot() if recorder else None
    return {"available": reason is None, "reason": reason, "max_seconds": teach_capture.MAX_SECONDS,
            "now": time.time(), "recording": bool(snap and snap["recording"]), "capture": snap["capture"] if snap else "idle",
            "ended": snap["ended"] if snap else None, "teach_id": snap["teach_id"] if snap else None,
            "started_at": snap["started_at"] if snap else None, "deadline_at": snap["deadline_at"] if snap else None,
            "event_count": snap["event_count"] if snap else 0, "truncated": bool(snap and snap["truncated"]),
            "pending": _pending()}


def start(viewer_id: str) -> dict[str, Any]:
    """Begin recording for the viewer that holds the lease. Refused: no browser here, a recording or an unresolved
    draft already exists, or the caller is not the one in control (the demonstration must be the person's)."""
    if (reason := unavailable_reason()) is not None:
        raise TeachError("unavailable", f"teaching is not available on this screen ({reason})")
    home = get_hermes_home()
    if teach_capture.active(home) is not None:
        raise TeachError("recording_in_progress", "a recording is already in progress for this bot")
    if teach_draft.pending_meta() is not None:
        raise TeachError("draft_pending", "review or discard the previous draft first")
    if not lease.viewer_may_send_input(viewer_id):
        raise TeachError("not_in_control", "take control of the screen before teaching a skill")
    teach_log.purge_orphans()
    log = teach_log.TeachLog(f"teach-{uuid.uuid4().hex[:12]}")
    recorder = teach_capture.TeachRecorder(home=home, viewer_id=viewer_id, log=log,
                                           discover=teach_capture.default_discover(str(browser.profile_dir())))
    if not teach_capture.begin(home, recorder):
        log.delete()
        raise TeachError("recording_in_progress", "a recording is already in progress for this bot")
    recorder.start()
    return status()


def stop(*, discard: bool = False) -> dict[str, Any]:
    """End the recording. Result: ``{teach_id, skill_name, event_count, truncated, prompt}`` for a draft to ask
    the bot for, or ``{empty: True}`` when nothing was recorded (or ``discard``): then the log is deleted."""
    home = get_hermes_home()
    recorder = teach_capture.take(home)
    if recorder is None:
        raise TeachError("not_recording", "no recording is in progress for this bot")
    snap = recorder.stop()
    if discard or snap["event_count"] == 0:
        recorder.log.delete()
        return {"empty": True, "reason": snap["ended"]}
    meta = teach_draft.create_draft(recorder.log)
    return {"empty": False, "reason": snap["ended"], "teach_id": meta["teach_id"], "skill_name": meta["skill_name"],
            "event_count": meta["event_count"], "truncated": meta["truncated"],
            "prompt": teach_draft.build_prompt(meta["teach_id"])}
