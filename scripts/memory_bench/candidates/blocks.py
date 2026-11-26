from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass

from scripts.memory_bench.candidates.note_store import AT_UNITS_PER_DAY, Note
from scripts.memory_bench.model import (
    BRIEF_TOKEN_CAP,
    JOKE_CONVERSATION_COOLDOWN_DAYS,
    JOKE_NOTE_COOLDOWN_DAYS,
    MAX_INJECTED_NOTES,
    NOTES_TOKEN_CAP,
    TOTAL_TOKEN_CAP,
    Injection,
    Kind,
    Probe,
    SkipReason,
    TokenCounter,
)

BRIEF_HEADER = "Channel brief:"
NOTES_HEADER = "Relevant memory notes:"


def note_line(note: Note) -> str:
    return f"- {note.speaker}: {note.text}"


def render(header: str, notes: Sequence[Note]) -> str:
    return "\n".join((header, *map(note_line, notes))) if notes else ""


@dataclass(frozen=True)
class Brief:
    note_ids: tuple[int, ...] = ()
    text: str = ""


def pack_brief(notes: Iterable[Note], count_tokens: TokenCounter) -> Brief:
    ranked = sorted(
        (note for note in notes if note.kind is Kind.WORK and not note.sensitive),
        key=lambda note: (-note.salience, -note.said_at, -note.id),
    )
    chosen: list[Note] = []
    for note in ranked:
        if count_tokens(render(BRIEF_HEADER, [*chosen, note])) <= BRIEF_TOKEN_CAP:
            chosen.append(note)
    return Brief(tuple(note.id for note in chosen), render(BRIEF_HEADER, chosen))


class NotesBlock:
    def __init__(self, brief: str, count_tokens: TokenCounter) -> None:
        self._brief = brief
        self._count_tokens = count_tokens
        self.chosen: list[Note] = []

    @property
    def text(self) -> str:
        return render(NOTES_HEADER, self.chosen)

    @property
    def tells_joke(self) -> bool:
        return any(note.kind is Kind.MOMENT for note in self.chosen)

    def offer(self, note: Note) -> SkipReason | None:
        if len(self.chosen) >= MAX_INJECTED_NOTES:
            return SkipReason.SLOTS
        block = render(NOTES_HEADER, [*self.chosen, note])
        total = Injection(brief=self._brief, notes=block).text
        if self._count_tokens(block) > NOTES_TOKEN_CAP or self._count_tokens(total) > TOTAL_TOKEN_CAP:
            return SkipReason.BUDGET
        self.chosen.append(note)
        return None


class JokeLedger:
    def __init__(self) -> None:
        self._last_told: dict[tuple[str, str, str], float] = {}

    def allows(self, note: Note, probe: Probe) -> bool:
        if probe.incident:
            return False
        last = self._last_told.get(self._conversation(probe))
        if last is not None and probe.at - last < JOKE_CONVERSATION_COOLDOWN_DAYS * AT_UNITS_PER_DAY:
            return False
        since = note.said_at if note.last_used is None else note.last_used
        return probe.at - since >= JOKE_NOTE_COOLDOWN_DAYS * AT_UNITS_PER_DAY

    def told(self, probe: Probe) -> None:
        self._last_told[self._conversation(probe)] = probe.at

    def _conversation(self, probe: Probe) -> tuple[str, str, str]:
        return probe.place.source.value, probe.place.channel, probe.place.thread
