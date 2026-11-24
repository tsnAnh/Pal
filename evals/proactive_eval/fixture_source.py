from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path

from gateway.proactive_scorecard.mining import AskItem, Message, MinedSession
from gateway.proactive_scorecard.rubric import Label

FIXTURE_PATH = Path(__file__).with_name("fixtures") / "synthetic_sessions.jsonl"


def _load_ask(raw) -> AskItem:
    if isinstance(raw, str):
        return AskItem(raw)
    return AskItem(raw["question"], tuple(raw.get("choices") or ()), raw.get("recommend") is not False)


def _load_message(raw: dict) -> Message:
    truth = raw.get("truth")
    return Message(raw["role"], raw.get("text", ""), float(raw["ts"]), tuple(_load_ask(a) for a in raw.get("clarify") or ()),
                   Label(truth) if truth else None)


class FixtureSource:
    def __init__(self, path: Path = FIXTURE_PATH, bot: str | None = None) -> None:
        self._path, self._bot = path, bot

    def sessions(self, since: float | None, until: float | None) -> Iterator[MinedSession]:
        for line in self._path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            raw = json.loads(line)
            if self._bot is not None and raw["bot"] != self._bot:
                continue
            started = float(raw["started_at"])
            if (since is not None and started < since) or (until is not None and started >= until):
                continue
            yield MinedSession(raw["bot"], started, tuple(_load_message(m) for m in raw["messages"]))

    def bots(self) -> tuple[str, ...]:
        names = {json.loads(line)["bot"] for line in self._path.read_text(encoding="utf-8").splitlines() if line.strip()}
        return tuple(sorted(names))
