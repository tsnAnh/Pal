from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType

from gateway import commitments as ledger
from gateway import reach, reach_log
from gateway.commitments import Actor, Commitment, State
from gateway.reach_policy import Messaging
from gateway.reach_routes import NON_MESSAGING_SOURCES
from hermes_constants import get_hermes_home

logger = logging.getLogger(__name__)

DOMAIN = "commitments"
SCRIPT_NAME = "commitments_wake.py"
JOB_NAME = "Promise follow-through"
SCHEDULE = "every 15m"
REPORT_WINDOW_SECONDS = 7 * 24 * 60 * 60
_PROMISE_REV = 1
WAKE_PROMPT = (
    "The promises listed above are past due. Work on each one now. Then record what happened with the "
    "`commitment` tool: update it with your progress, mark it blocked with what blocks it, who can unblock it "
    "and the next step you prepared, or close it as done with evidence. When a step needs your owner's "
    "approval, do not work around it: mark the promise blocked on your owner with that step prepared as the "
    "next step. Your owner hears about finished, blocked, overdue and stuck promises without a message from "
    "you, so end with a one-line note for the log."
)


class ReportKind(StrEnum):
    DONE = "done"
    BLOCKED = "blocked"
    OVERDUE = "overdue"
    STUCK = "stuck"
    ABANDONED = "abandoned"


_REPORTED_WHEN: Mapping[ReportKind, Callable[[Commitment, float], bool]] = MappingProxyType({
    ReportKind.DONE: lambda c, now: c.state is State.DONE,
    ReportKind.BLOCKED: lambda c, now: c.state is State.BLOCKED,
    ReportKind.OVERDUE: lambda c, now: c.overdue(now),
    ReportKind.STUCK: lambda c, now: c.stuck(now),
    ReportKind.ABANDONED: lambda c, now: c.state is State.ABANDONED and c.abandoned_by is Actor.BOT,
})
_TITLES: Mapping[ReportKind, str] = MappingProxyType({
    ReportKind.DONE: "Done", ReportKind.BLOCKED: "Blocked", ReportKind.OVERDUE: "Overdue",
    ReportKind.STUCK: "Stuck", ReportKind.ABANDONED: "Dropped",
})


def _stamp(timestamp: float) -> str:
    from hermes_time import get_timezone
    return datetime.fromtimestamp(timestamp, tz=get_timezone()).strftime("%Y-%m-%d %H:%M")


def _next_step(c: Commitment) -> str:
    return f"Next step ready: {c.next_step}" if c.next_step else "No next step recorded."


_BODIES: Mapping[ReportKind, Callable[[Commitment], str]] = MappingProxyType({
    ReportKind.DONE: lambda c: f"Evidence: {c.evidence}",
    ReportKind.BLOCKED: lambda c: f"Blocked by {c.blocker_what}. {c.blocker_who} can unblock it. {_next_step(c)}",
    ReportKind.OVERDUE: lambda c: f"It was due {_stamp(c.due_at)}. {_next_step(c)}",
    ReportKind.STUCK: lambda c: f"No progress since {_stamp(c.updated_at)}. {_next_step(c)}",
    ReportKind.ABANDONED: lambda c: f"Reason: {c.reason}",
})


@dataclass(frozen=True, slots=True)
class Report:
    commitment: Commitment
    kind: ReportKind

    @property
    def producer_key(self) -> str:
        rev = _PROMISE_REV if self.kind is ReportKind.OVERDUE else self.commitment.rev
        return f"commit:{self.commitment.id}:{self.kind.value}:{rev}"

    def offer(self) -> reach.Offer:
        c = self.commitment
        route = c.route
        local = route.platform == "local" and bool(route.chat_id)
        messaging = bool(route.platform and route.chat_id) and route.platform not in NON_MESSAGING_SOURCES
        return reach.Offer(
            producer_key=self.producer_key, domain=DOMAIN, kind=reach.OfferKind.NOTIFY,
            consent=reach.Consent.REQUESTED if c.owner_requested else reach.Consent.INITIATED,
            title=f"{_TITLES[self.kind]}: {c.promise}", body=_BODIES[self.kind](c),
            lane=reach.DurableLane(session_id=route.chat_id) if local else None,
            chat=Messaging(platform=route.platform, chat_id=route.chat_id, thread_id=route.thread_id,
                           origin="promise") if messaging else None)


def pending_reports(home, now: float) -> list[Report]:
    found = [Report(c, kind) for c in ledger.list_for_follow_up(home, closed_since=now - REPORT_WINDOW_SECONDS)
             for kind, applies in _REPORTED_WHEN.items() if applies(c, now)]
    known = reach_log.known_producer_keys(home, [report.producer_key for report in found])
    return [report for report in found if report.producer_key not in known]


def offers_due(home, now: float) -> list[reach.Offer]:
    return [report.offer() for report in pending_reports(home, now)]


def report_due(home) -> int:
    home = Path(home)
    if not (home / "scripts" / SCRIPT_NAME).is_file():
        return 0
    write_gate_script(home)
    due = offers_due(home, time.time())
    for item in due:
        reach.offer_threadsafe(home, item, wait=False)
    return len(due)


def _needs_work(c: Commitment, now: float) -> bool:
    return c.state is not State.BLOCKED and c.overdue(now) and not c.stuck(now)


def gate(home, now: float) -> str:
    due = [c for c in ledger.list_for_follow_up(home, closed_since=now) if _needs_work(c, now)]
    if not due:
        return json.dumps({"wakeAgent": False})
    lines = ["Past-due promises:"]
    for c in due:
        ledger.record_check(home, c.id)
        lines.append(f"- {c.id} (rev {c.rev}, {c.state.value}, due {_stamp(c.due_at)}): {c.promise}"
                     + (f" | next step: {c.next_step}" if c.next_step else ""))
    lines.append(json.dumps({"wakeAgent": True}))
    return "\n".join(lines)


def gate_main() -> int:
    print(gate(get_hermes_home(), time.time()))
    return 0


def _gate_script() -> str:
    from hermes_cli._startup_fast import project_root_str
    return (f"import sys\n\nsys.path.insert(0, {project_root_str()!r})\n\n"
            "from gateway.commitments_wake import gate_main\n\nraise SystemExit(gate_main())\n")


def write_gate_script(home) -> Path:
    from utils import atomic_write_text
    path = Path(home) / "scripts" / SCRIPT_NAME
    body = _gate_script()
    if not path.is_file() or path.read_text(encoding="utf-8-sig") != body:
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write_text(path, body)
    return path


def ensure_job() -> str | None:
    from tools.hosted_tool_policy import host_feature_refusal
    if refusal := host_feature_refusal("cron_scripts", "Promise follow-through"):
        return refusal
    from cron.job_provenance import CREATED_BY_AGENT
    from cron.jobs import _jobs_lock, create_job, load_jobs
    try:
        write_gate_script(get_hermes_home())
        with _jobs_lock():
            if not any(job.get("script") == SCRIPT_NAME for job in load_jobs()):
                create_job(prompt=WAKE_PROMPT, schedule=SCHEDULE, name=JOB_NAME, script=SCRIPT_NAME,
                           deliver="local", created_by=CREATED_BY_AGENT)
    except (OSError, ValueError) as exc:
        logger.warning("Promise follow-through job not scheduled", exc_info=True)
        return f"The follow-up check could not be scheduled ({type(exc).__name__}); the promise is recorded."
    return None
