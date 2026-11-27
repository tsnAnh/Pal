from __future__ import annotations

import json
import sys
import tempfile
import time
from collections.abc import Sequence
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from evals.intent import baseline
from persistence.conversation.messages import NewMessage
from persistence.conversation.sessions import NewSession
from persistence_assembly import open_persistence, profile_scope

HOUR = 3600.0
NOTE_QUESTION = "When should the note go out?"
NOTE_CHOICES = ("Publish today", "Wait until Monday")
LIST_QUESTION = "Do you want me to send it to the team list?"


def say(role: str, content: str = "", **extra) -> dict:
    return {"role": role, "content": content, **extra}


def call(call_id: str, name: str, arguments: dict, content: str = "") -> dict:
    return say("assistant", content, tool_calls=[
        {"id": call_id, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}])


def result(call_id: str, name: str, payload: dict) -> dict:
    return say("tool", json.dumps(payload), tool_call_id=call_id, tool_name=name)


def answered(call_id: str) -> dict:
    return result(call_id, "clarify", {"responses": [{"status": "answered"}], "outcome": "submitted"})


def ask(call_id: str, *questions: dict) -> dict:
    return call(call_id, "clarify", {"questions": list(questions)}, "Details are above.")


def seed_session(home: Path, session_id: str, source: str, messages: Sequence[dict], *, at: float,
                 end_reason: str | None = None, **fields) -> None:
    with open_persistence(profile_scope(home=home), eager=True) as store:
        store.sessions.create(NewSession(session_id=session_id, source=source, **fields))
        for index, message in enumerate(messages):
            store.messages.append(session_id, NewMessage.from_live({**message, "timestamp": at + index}))
        if end_reason is not None:
            store.sessions.end(session_id, end_reason)


def _launch_note() -> list[dict]:
    return [
        say("user", "Write the launch note for the new release and keep it short"),
        call("a1", "write_file", {"path": "note.md", "content": "draft"}),
        result("a1", "write_file", {"bytes_written": 5}),
        say("assistant", f"Here is the first draft of the launch note.\n{LIST_QUESTION}"),
        say("user", "no, I meant a draft for the blog, not an email"),
        say("assistant", "To confirm: you want a blog draft and no email."),
        call("a2", "patch", {"path": "note.md"}),
        result("a2", "patch", {"success": True}),
        say("assistant", "The blog draft is saved."),
        say("user", "good, now publish it"),
        ask("a3", {"question": NOTE_QUESTION, "choices": list(NOTE_CHOICES)}),
        answered("a3"),
        say("assistant", "Done."),
    ]


def _weekly_report() -> list[dict]:
    return [
        say("user", "Set up the weekly report"),
        call("b1", "cronjob_manage", {"action": "create", "schedule": "0 9 * * 1", "prompt": "report"}),
        result("b1", "cronjob_manage", {"success": True}),
        say("assistant", "Scheduled. Which day should it arrive?\n1. Monday\n2. Friday"),
        say("user", "Friday"),
        call("b2", "send_message", {"target": "slack:#team", "message": "Report moves to Friday"}),
        result("b2", "send_message", {"success": True}),
        say("assistant", "Sent."),
        say("user", "sai rồi, ý anh là gửi cho nhóm khác"),
        ask("b3", {"question": "Which group should get it?", "default": "the core group"}),
        answered("b3"),
        say("assistant", "Understood."),
        say("user", "Message from 🤖 Ops (@ops): status of the report?"),
        say("assistant", "Which report do you mean?"),
        say("user", "[IMPORTANT: the build finished]", display_kind="process_complete"),
        say("assistant", "The build finished. Do you want me to open the log?"),
    ]


def _publish_again() -> list[dict]:
    return [
        say("user", "publish the note"),
        ask("c0", {"question": "x" * 500}),
        result("c0", "clarify", {"error": "questions[0] is too long"}),
        ask("c1", {"question": NOTE_QUESTION, "choices": list(NOTE_CHOICES)},
            {"question": "Send the notice now?", "choices": ["Send", "Cancel"], "recommend": False,
             "send": {"tool": "send_message", "arguments": {"target": "slack:#team", "message": "notice"},
                      "choice": "Send"}}),
        answered("c1"),
        say("assistant", LIST_QUESTION),
        say("user", "run the check again"),
        call("c2", "terminal", {"command": "make check"}),
        result("c2", "terminal", {"exit_code": 0}),
        say("assistant", "Checked."),
        say("user", "and send it"),
        say("assistant", LIST_QUESTION),
    ]


def seed(home: Path, now: float) -> None:
    seed_session(home, "launch", "telegram", _launch_note(), at=now - 30 * HOUR, chat_type="dm")
    seed_session(home, "weekly", "desktop", _weekly_report(), at=now - 20 * HOUR)
    seed_session(home, "publish", "cli", _publish_again(), at=now - 10 * HOUR)


def main(argv: Sequence[str] | None = None) -> int:
    now = time.time()
    with tempfile.TemporaryDirectory(prefix="intent-baseline-") as home:
        seed(Path(home), now)
        report = baseline.measure([("fixture", Path(home))], days=14, now=now)
    print(baseline.render(report, json_only="--json" in (sys.argv[1:] if argv is None else argv)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
