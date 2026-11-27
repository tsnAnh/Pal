from __future__ import annotations

from collections.abc import Sequence
from dataclasses import replace

from scripts.memory_bench.candidates.note_store import AT_UNITS_PER_DAY, Note, Scope
from scripts.memory_bench.model import (
    ADMIT_MIN_SALIENCE,
    EXPIRE_AFTER_DAYS,
    EXPIRE_BELOW_SALIENCE,
    MAX_WRITES_PER_TURN,
    Loss,
    LossReason,
    Proposal,
    Source,
    Turn,
    fold,
)

NEAR_DUPLICATE_JACCARD = 0.8


def admit(turn: Turn) -> tuple[list[Proposal], list[Loss]]:
    admissible = [index for index, item in enumerate(turn.proposals) if item.salience >= ADMIT_MIN_SALIENCE]
    ranked = sorted(admissible, key=lambda index: -turn.proposals[index].salience)
    kept = set(ranked[:MAX_WRITES_PER_TURN])
    losses = [
        Loss(item.text, LossReason.WRITE_LIMIT if index in admissible else LossReason.ADMISSION, turn.at)
        for index, item in enumerate(turn.proposals)
        if index not in kept
    ]
    return [item for index, item in enumerate(turn.proposals) if index in kept], losses


def note_from(turn: Turn, proposal: Proposal) -> Note:
    speaks_everywhere = turn.owner and turn.place.source is Source.PAL_APP
    return Note(
        kind=proposal.kind,
        text=proposal.text,
        speaker=turn.speaker,
        source=turn.place.source,
        channel=turn.place.channel,
        thread=turn.place.thread,
        said_at=turn.at,
        scope=Scope.ANYWHERE if speaks_everywhere else Scope.CHANNEL,
        topic=proposal.topic,
        salience=proposal.salience,
        sensitive=proposal.sensitive,
    )


def near_duplicate(first: str, second: str) -> bool:
    left, right = set(fold(first).split()), set(fold(second).split())
    union = left | right
    return bool(union) and len(left & right) / len(union) >= NEAR_DUPLICATE_JACCARD


def merged(newer: Note, older: Sequence[Note]) -> Note:
    everything = (newer, *older)
    used_at = [note.last_used for note in older if note.last_used is not None]
    return replace(
        newer,
        salience=max(note.salience for note in everything),
        sensitive=any(note.sensitive for note in everything),
        uses=max((note.uses for note in older), default=0),
        last_used=max(used_at, default=None),
    )


def calendar_day(at: float) -> int:
    return int(at // AT_UNITS_PER_DAY)


def expired(note: Note, day: int) -> bool:
    return (
        note.uses == 0
        and note.salience < EXPIRE_BELOW_SALIENCE
        and day - calendar_day(note.said_at) >= EXPIRE_AFTER_DAYS
    )


def eviction_order(note: Note) -> tuple[bool, float, float, int]:
    return note.uses > 0, note.salience, note.last_touched, note.id


def age_detail(note: Note, at: float) -> str:
    return f"salience={note.salience:.2f} age_days={(at - note.said_at) / AT_UNITS_PER_DAY:.1f}"
