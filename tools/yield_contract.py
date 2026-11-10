from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any, Optional, Protocol

from tools.interrupt import YieldReason

TERMINAL_JOB_LABEL = "the task"


@dataclass(frozen=True)
class BackgroundJob:
    job_id: str
    label: str
    notifies: bool


@dataclass(frozen=True)
class Yielded:
    job: BackgroundJob
    partial_output: str
    reason: YieldReason
    extra: Mapping[str, Any] = field(default_factory=dict)

    def as_tool_result(self) -> dict[str, Any]:
        return {
            "output": self.partial_output, "exit_code": None, "error": None,
            "status": "yielded_to_background", "session_id": self.job.job_id,
            "notify_on_complete": self.job.notifies, "note": render_yield_note(self.job, self.reason),
            **self.extra,
        }


class Adopter(Protocol):
    def adopt(self, live: Any, partial_output: str, reason: YieldReason) -> Optional[Yielded]: ...


_QUIET = "Do not mention process ids, commands or tools to the owner."

_ARRIVAL = {
    True: "Its result will arrive as a message when it finishes, even after you end this turn.",
    False: ("You will not be told when it finishes; check on it with process(action='poll', "
            "session_id='{job_id}') only if the owner asks."),
}

_NOTES = {
    YieldReason.OWNER_MESSAGE: (
        "The owner just wrote to you, so {label} moved to the background without being stopped and keeps "
        "running as {job_id}. {arrival} Answer the owner now. Do not wait for it or poll it. " + _QUIET
    ),
    YieldReason.BUDGET: (
        "{label_cap} is taking a while and keeps running in the background as {job_id}. {arrival} Tell the "
        "owner in one plain sentence that the work continues in the background, then end your turn unless "
        "you have independent work to do. Do not wait for it or poll it. " + _QUIET
    ),
}


def render_yield_note(job: BackgroundJob, reason: YieldReason) -> str:
    arrival = _ARRIVAL[job.notifies].format(job_id=job.job_id)
    return _NOTES[reason].format(
        label=job.label, label_cap=job.label[:1].upper() + job.label[1:], job_id=job.job_id, arrival=arrival)
