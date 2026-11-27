from __future__ import annotations

import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from evals.brevity import measure
from evals.intent.fixture import HOUR, call, result, say, seed_session


def _notice(text: str, kind: str) -> dict:
    return say("user", text, display_kind=kind)


def _finished(process: str) -> dict:
    return _notice(f"[IMPORTANT: Background process {process} completed normally (exit code 0).\n"
                   "Command: make check\nOutput:\nok]", "process_complete")


SESSIONS: tuple[tuple[str, list[dict]], ...] = (
    ("report", [
        say("user", "Check the release and report back"),
        say("assistant", "Release report:\n- Build passed\n- Documentation is updated\n- One flaky test is left"),
        _finished("proc_report"),
        say("assistant", "I opened a new thread to follow the flaky test."),
    ]),
    ("blocks", [
        say("user", "Fix the typo on the landing page"),
        call("b1", "terminal", {"command": "grep typo page"}, "Looking at the landing page."),
        result("b1", "terminal", {"output": "found", "exit_code": 0}),
        say("assistant", "The typo is fixed."),
        say("user", "thanks a lot"),
        say("assistant", "You are welcome."),
    ]),
    ("silent", [
        say("user", "Run the test suite"),
        say("assistant", "The tests are running."),
        _finished("proc_silent"),
        say("assistant", "[SILENT]"),
    ]),
    ("question", [
        say("user", "Deploy the preview build"),
        say("assistant", "The deploy has started."),
        _finished("proc_question"),
        say("assistant", "The deploy failed on a timeout. Should I retry it?"),
    ]),
    ("delegation", [
        say("user", "Review the pending change"),
        say("assistant", "Two reviewers are working on it."),
        _notice("[ASYNC DELEGATION BATCH COMPLETE — d1]\nTwo subagents finished.", "async_delegation_complete"),
        say("assistant", "Both reviewers approved the change."),
    ]),
    ("bot-dm", [
        say("user", "Watch the support queue"),
        say("assistant", "Watching the support queue now."),
        say("user", "Message from 🤖 Atlas (@atlas): status please"),
        say("assistant", "The support queue is empty."),
    ]),
    ("cron", [
        say("user", "Remind me about the morning digest"),
        say("assistant", "The reminder is set."),
        say("user", '[Cronjob "digest"] run the digest now'),
        say("assistant", "Digest: three pull requests are open."),
    ]),
)


def seed(home: Path, now: float) -> None:
    for index, (session_id, messages) in enumerate(SESSIONS):
        seed_session(home, session_id, "telegram", messages, at=now - (len(SESSIONS) - index) * HOUR,
                     chat_type="dm")


def main(argv: Sequence[str] | None = None) -> int:
    now = time.time()
    with tempfile.TemporaryDirectory(prefix="hermes-eval-") as home:
        seed(Path(home), now)
        report = measure.measure([("fixture", Path(home))], days=1, now=now)
    print(measure.render(report, json_only="--json" in (sys.argv[1:] if argv is None else argv)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
