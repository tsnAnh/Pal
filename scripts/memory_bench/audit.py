from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass

from scripts.memory_bench.model import Event, Probe, Source, Turn, fold

Uses = tuple[tuple[Turn, bool], ...]
NoteIndex = tuple[tuple[str, Uses], ...]


@dataclass(frozen=True)
class Exposure:
    audience: int = 0
    sensitive: int = 0


def index_notes(events: Iterable[Event]) -> NoteIndex:
    found: dict[str, list[tuple[Turn, bool]]] = {}
    for event in events:
        if isinstance(event, Turn):
            for proposal in event.proposals:
                found.setdefault(fold(proposal.text), []).append((event, proposal.sensitive))
    return tuple((text, tuple(uses)) for text, uses in found.items())


def same_origin(turn: Turn, probe: Probe) -> bool:
    return (turn.place.source, turn.place.channel) == (probe.place.source, probe.place.channel)


def allowed(turn: Turn, probe: Probe) -> bool:
    return (turn.owner and turn.place.source is Source.PAL_APP) or same_origin(turn, probe)


def exposure(index: NoteIndex, text: str, probe: Probe, injected: bool) -> Exposure:
    haystack = fold(text)
    present = [uses for note, uses in index if note in haystack]
    return Exposure(
        sum(not any(allowed(turn, probe) for turn, _ in uses) for uses in present),
        sum(
            any(sensitive for _, sensitive in uses)
            and (injected or not any(sensitive and same_origin(turn, probe) for turn, sensitive in uses))
            for uses in present
        ),
    )
