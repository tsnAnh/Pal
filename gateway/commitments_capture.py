from __future__ import annotations

import hashlib
import json
import logging
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from types import MappingProxyType

from gateway import commitments as ledger
from gateway.commitments import Actor, Details, Route, State
from gateway.session_context import get_session_env
from tools.daemon_pool import DaemonThreadPoolExecutor

logger = logging.getLogger(__name__)

_ROUTE_ENV = {
    "platform": "HERMES_SESSION_PLATFORM", "chat_id": "HERMES_SESSION_CHAT_ID",
    "thread_id": "HERMES_SESSION_THREAD_ID", "chat_type": "HERMES_SESSION_CHAT_TYPE",
    "session_key": "HERMES_SESSION_KEY", "session_id": "HERMES_SESSION_ID",
}
_executor = DaemonThreadPoolExecutor(max_workers=1, thread_name_prefix="promise-capture")


class Kind(StrEnum):
    DELEGATION = "delegation"
    CRON = "cron"
    MESSAGE = "message"


@dataclass(frozen=True, slots=True)
class Subject:
    kind: Kind
    ref: str
    label: str

    @property
    def key(self) -> str:
        return f"{self.kind.value}:{self.ref}"


def current_route() -> Route:
    return Route(**{field: get_session_env(env) or None for field, env in _ROUTE_ENV.items()})


def current_profile() -> str:
    from hermes_cli.profiles import current_profile_name
    return get_session_env("HERMES_SESSION_PROFILE") or current_profile_name("default") or "default"


def _refs(value) -> list[str]:
    return [item for item in value if isinstance(item, str) and item] if isinstance(value, list) else []


def _delegation(args: dict, result: dict) -> list[Subject]:
    if result.get("status") != "dispatched" or result.get("mode") != "background":
        return []
    units = [unit.get("delegation_id") for unit in result.get("units") or () if isinstance(unit, dict)]
    return [Subject(Kind.DELEGATION, ref, f"Delegated task {ref}")
            for ref in _refs(units or [result.get("delegation_id")])]


def _cron(args: dict, result: dict) -> list[Subject]:
    job_id = result.get("job_id")
    if result.get("success") is not True or not isinstance(job_id, str) or not job_id:
        return []
    name = result.get("name")
    return [Subject(Kind.CRON, job_id, f"Scheduled job {name if isinstance(name, str) and name else job_id}")]


def _message(args: dict, result: dict) -> list[Subject]:
    acks = [result, *(ack for ack in result.get("fan_out") or () if isinstance(ack, dict))]
    return [Subject(Kind.MESSAGE, ack["process_id"], f"Message to {ack.get('to') or 'a teammate'}")
            for ack in acks if isinstance(ack.get("process_id"), str) and ack["process_id"]
            and "error" not in ack and ack.get("expects_reply") is not False]


@dataclass(frozen=True, slots=True)
class Rule:
    promising: Callable[[dict], bool]
    subjects: Callable[[dict, dict], list[Subject]]


_RULES: Mapping[str, Rule] = MappingProxyType({
    "delegate_task": Rule(lambda args: bool(args.get("background")), _delegation),
    "cronjob_manage": Rule(lambda args: args.get("action") == "create" and not args.get("paused"), _cron),
    "message_agent": Rule(
        lambda args: not args.get("cancel") and str(args.get("expects_reply", True)).strip().lower()
        not in ("false", "0", "no"), _message),
})


def promises_outliving_turn(name: str, arguments: dict) -> bool:
    rule = _RULES.get(name)
    return rule is not None and rule.promising(arguments)


def _loads(raw) -> dict:
    if isinstance(raw, dict):
        return raw
    try:
        parsed = json.loads(raw) if isinstance(raw, (str, bytes)) else None
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _turn_calls(messages: list[dict]) -> Iterable[tuple[str, dict, dict]]:
    last_user = max((i for i, m in enumerate(messages) if isinstance(m, dict) and m.get("role") == "user"), default=-1)
    calls: dict[str, tuple[str, dict]] = {}
    for message in messages[last_user + 1:]:
        if not isinstance(message, dict):
            continue
        if message.get("role") == "assistant":
            for call in message.get("tool_calls") or ():
                function = call.get("function") or {}
                calls[str(call.get("id"))] = (str(function.get("name") or ""), _loads(function.get("arguments")))
        elif message.get("role") == "tool" and (made := calls.get(str(message.get("tool_call_id")))):
            yield made[0], made[1], _loads(message.get("content"))


@dataclass(frozen=True, slots=True)
class Capture:
    home: Path
    profile: str
    route: Route
    owner_requested: bool
    subjects: tuple[Subject, ...]


def plan(messages: list[dict], *, owner_requested: bool) -> Capture | None:
    """The promises this turn's tool calls left running, or None when it left none or the model recorded its own
    (a `commitment` promise is the override: auto-capture then stands down for the whole turn)."""
    from hermes_constants import get_hermes_home
    subjects: dict[str, Subject] = {}
    for name, args, result in _turn_calls(messages):
        if name == "commitment" and args.get("action") == "promise" and "error" not in result:
            return None
        if (rule := _RULES.get(name)) and rule.promising(args):
            subjects.update((subject.key, subject) for subject in rule.subjects(args, result))
    if not subjects:
        return None
    return Capture(get_hermes_home(), current_profile(), current_route(), owner_requested, tuple(subjects.values()))


def _event_key(verb: str, subject_key: str) -> str:
    return hashlib.sha256(f"auto-{verb}\x1f{subject_key}".encode()).hexdigest()


def record(capture: Capture, now: float) -> int:
    recorded = 0
    for subject in capture.subjects:
        made = ledger.promise(
            capture.home, event_key=_event_key("promise", subject.key), profile=capture.profile, text=subject.label,
            owner_requested=capture.owner_requested, due_at=None, route=capture.route, now=now, actor=Actor.AUTO,
            subject=subject.key)
        recorded += not made.replayed
    return recorded


def _record_guarded(capture: Capture) -> None:
    try:
        record(capture, time.time())
    except Exception as exc:
        logger.warning("Promise capture failed (%s); the turn is unaffected", type(exc).__name__, exc_info=True)


def submit(capture: Capture) -> None:
    _executor.submit(_record_guarded, capture)


def settle(home, subject_key: str, evidence: str, now: float) -> bool:
    found = ledger.find_by_event_key(home, _event_key("promise", subject_key))
    if found is None or found.state in ledger.TERMINAL_STATES:
        return False
    ledger.transition(home, found.id, event_key=_event_key("settle", subject_key), expected_rev=found.rev,
                      to=State.DONE, details=Details(evidence=evidence), actor=Actor.AUTO, now=now)
    return True


def _settled_subject(evt: dict) -> tuple[Subject, str] | None:
    from tools.process_registry_notifications import delegation_wakes_parent
    kind = evt.get("type", "completion")
    if kind == "async_delegation":
        ref = evt.get("delegation_id")
        if (evt.get("task_failure_notice") or evt.get("role") == "cron_run" or delegation_wakes_parent(evt)
                or not isinstance(ref, str) or not ref):
            return None
        return Subject(Kind.DELEGATION, ref, ""), "The delegated task finished."
    ref = evt.get("session_id")
    if kind == "completion" and isinstance(ref, str) and ref and evt.get("exit_code") == 0 \
            and str(evt.get("output") or "").strip():
        return Subject(Kind.MESSAGE, ref, ""), "The reply arrived."
    return None


def settle_from_event(evt: dict) -> None:
    try:
        if (found := _settled_subject(evt)) is not None:
            from hermes_constants import get_hermes_home
            settle(get_hermes_home(), found[0].key, found[1], time.time())
    except Exception as exc:
        logger.warning("Promise settlement failed (%s)", type(exc).__name__, exc_info=True)


def settle_cron_runs(home, now: float) -> int:
    """A scheduled job's promise is kept once the job has run; the cron store is where that is recorded."""
    from cron.jobs import load_jobs
    open_jobs = ledger.open_with_subject(home, f"{Kind.CRON.value}:")
    if not open_jobs:
        return 0
    ran = {job.get("id") for job in load_jobs() if job.get("last_run_at")}
    return sum(settle(home, subject, "The job ran.", now)
               for _commitment, subject in open_jobs if subject.partition(":")[2] in ran)
