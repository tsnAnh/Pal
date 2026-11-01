"""Routine actions of ``cron.manage`` beyond list/add/remove/pause/resume: run now, run history,
schedule preview and the webhook trigger. Every function runs inside the handler's profile scope and
returns the JSON-ready result; expected refusals are ``{"success": False, ...}``, never exceptions."""

import json
import logging
from typing import Any, Callable

logger = logging.getLogger(__name__)


def _failure(message: str, **extra: Any) -> dict[str, Any]:
    return {"success": False, "error": message, **extra}


def _resolve_job(params: dict) -> tuple[dict | None, dict | None]:
    from cron.jobs import AmbiguousJobReference, resolve_job_ref

    reference = str(params.get("name") or "").strip()
    if not reference:
        return None, _failure("name required", reason="not_found")
    try:
        job = resolve_job_ref(reference)
    except AmbiguousJobReference as exc:
        return None, _failure(str(exc), reason="not_found")
    if job is None:
        return None, _failure("That routine no longer exists.", reason="not_found")
    return job, None


def _profile(params: dict) -> str:
    from hermes_constants import get_hermes_home, profile_name_for_home

    return str(params.get("profile") or "").strip() or profile_name_for_home(get_hermes_home()) or "default"


def run(params: dict) -> dict[str, Any]:
    from tools.cronjob_tools import start_job_run_detached

    job, error = _resolve_job(params)
    if error:
        return {**error, "started": False}
    outcome = start_job_run_detached(job["id"])
    return {"success": bool(outcome.get("started")), **outcome}


def history(params: dict) -> dict[str, Any]:
    from cron.run_history import HISTORY_LIMIT, list_job_runs

    job, error = _resolve_job(params)
    if error:
        return error
    return {"success": True, "job_id": job["id"], "limit": HISTORY_LIMIT, "runs": list_job_runs(job["id"])}


def history_output(params: dict) -> dict[str, Any]:
    from cron.run_history import RunNotFound, read_run_output

    job, error = _resolve_job(params)
    if error:
        return error
    try:
        return {"success": True, **read_run_output(job["id"], str(params.get("run_id") or ""))}
    except RunNotFound as exc:
        return _failure(str(exc), reason="no_output")


def schedule_preview(params: dict) -> dict[str, Any]:
    from cron.schedule_phrases import ScheduleRejected, resolve_routine_schedule

    try:
        return {"success": True, **resolve_routine_schedule(str(params.get("schedule") or ""))}
    except ScheduleRejected as exc:
        return _failure(str(exc), reason=exc.code)


def trigger_status(params: dict) -> dict[str, Any]:
    from hermes_cli.webhook_routine_trigger import routine_trigger_status

    job, error = _resolve_job(params)
    if error:
        return error
    return {"success": True, **routine_trigger_status(_profile(params), job["id"])}


def trigger_issue(params: dict) -> dict[str, Any]:
    from hermes_cli.webhook_routine_trigger import TriggerConflict, TriggerUnavailable, issue_routine_trigger

    job, error = _resolve_job(params)
    if error:
        return error
    try:
        return {"success": True, **issue_routine_trigger(_profile(params), job["id"])}
    except TriggerUnavailable as exc:
        return _failure("A webhook trigger is not available right now.", reason=exc.blocked_by)
    except TriggerConflict:
        return _failure("Another webhook already uses this routine's address.", reason="conflict")


def trigger_remove(params: dict) -> dict[str, Any]:
    from hermes_cli.webhook_routine_trigger import remove_routine_trigger

    job, error = _resolve_job(params)
    if error:
        return error
    return {"success": True, "removed": remove_routine_trigger(_profile(params), job["id"])}


def remove_routine(params: dict, cronjob: Callable[..., str]) -> dict[str, Any]:
    """Remove the routine, then its webhook trigger: a removed routine must not leave a live endpoint
    behind, and a routine whose removal failed keeps its trigger. A trigger failure after a successful
    removal is logged and never undoes the removal."""
    from hermes_cli.webhook_routine_trigger import remove_routine_trigger

    job, _ = _resolve_job(params)
    result = json.loads(cronjob(action="remove", job_id=str(params.get("name") or "")))
    if job is None or not result.get("success"):
        return result
    try:
        remove_routine_trigger(_profile(params), job["id"])
    except Exception:
        logger.warning("Could not remove the webhook trigger of routine %s", job["id"], exc_info=True)
    return result


HANDLERS: dict[str, Callable[[dict], dict[str, Any]]] = {
    "run": run, "history": history, "history_output": history_output, "schedule_preview": schedule_preview,
    "trigger_status": trigger_status, "trigger_issue": trigger_issue, "trigger_remove": trigger_remove}

ROUTINE_ACTIONS = tuple(HANDLERS)
