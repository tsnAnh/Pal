from __future__ import annotations

from collections.abc import Collection, Iterable
from typing import Protocol

from scripts.memory_bench.candidates.blocks import (
    BRIEF_HEADER,
    Brief,
    JokeLedger,
    NotesBlock,
    note_line,
    pack_brief,
    render,
)
from scripts.memory_bench.candidates.note_store import AT_UNITS_PER_DAY, Note, NoteStore, Origin, origin_of
from scripts.memory_bench.candidates.writes import (
    admit,
    age_detail,
    eviction_order,
    expired,
    merged,
    near_duplicate,
    note_from,
)
from scripts.memory_bench.model import (
    STORE_NOTE_CAP,
    BriefRewrite,
    Injection,
    Kind,
    Loss,
    LossReason,
    Place,
    Probe,
    Skip,
    SkipReason,
    TokenCounter,
    Turn,
)

RECALL_LIMIT = 8


class Retriever(Protocol):
    def add(self, note_id: int, text: str) -> None: ...

    def remove(self, note_id: int) -> None: ...

    def rank(self, query: str, note_ids: Collection[int]) -> list[tuple[int, float]]: ...

    def close(self) -> None: ...


class PolicyCandidate:
    def __init__(
        self, store: NoteStore, retriever: Retriever, count_tokens: TokenCounter, threshold: float | None
    ) -> None:
        self._store = store
        self._retriever = retriever
        self._count_tokens = count_tokens
        self._threshold = threshold
        self._briefs: dict[Origin, Brief] = {}
        self._jokes = JokeLedger()
        self._losses: list[Loss] = []
        self._rewrites: list[BriefRewrite] = []

    def write(self, turn: Turn) -> None:
        proposals, refused = admit(turn)
        self._losses.extend(refused)
        for proposal in proposals:
            self._save(note_from(turn, proposal))
            self._enforce_cap(turn.at)

    def _save(self, note: Note) -> None:
        peers = [other for other in self._store.notes() if note.shares_scope(other)]
        duplicates = [other for other in peers if near_duplicate(note.text, other.text)]
        if duplicates:
            note = merged(note, duplicates)
        superseded = [other for other in peers if note.topic and other.topic == note.topic and other not in duplicates]
        for other in duplicates:
            self._drop(other, LossReason.MERGED, note.said_at)
        for other in superseded:
            self._drop(other, LossReason.OVERWRITTEN, note.said_at)
        saved = self._store.insert(note)
        self._retriever.add(saved.id, saved.text)

    def _drop(self, note: Note, reason: LossReason, at: float, detail: str = "") -> None:
        self._store.remove(note.id)
        self._retriever.remove(note.id)
        self._losses.append(Loss(note.text, reason, at, detail))

    def _enforce_cap(self, at: float) -> None:
        notes = self._store.notes()
        for victim in sorted(notes, key=eviction_order)[: max(len(notes) - STORE_NOTE_CAP, 0)]:
            self._drop(victim, LossReason.EVICTED_CAP, at, age_detail(victim, at))

    def end_day(self, day: int) -> None:
        at = day * AT_UNITS_PER_DAY
        for note in self._store.notes():
            if expired(note, day):
                self._drop(note, LossReason.EXPIRED, at, age_detail(note, at))
        notes = self._store.notes()
        origins = {note.origin for note in notes} | set(self._briefs)
        for origin in sorted(origins, key=lambda item: (item[0].value, item[1])):
            self._rewrite_brief(origin, [note for note in notes if note.origin == origin], at)

    def _rewrite_brief(self, origin: Origin, notes: Iterable[Note], at: float) -> None:
        before = self._briefs.get(origin, Brief()).text
        brief = pack_brief(notes, self._count_tokens)
        self._briefs[origin] = brief
        if brief.text != before:
            self._rewrites.append(BriefRewrite(at, Place(*origin), before, brief.text))

    def inject(self, probe: Probe) -> Injection:
        notes = {note.id: note for note in self._store.notes()}
        stored = self._briefs.get(origin_of(probe.place), Brief())
        briefed = [notes[note_id] for note_id in stored.note_ids if note_id in notes]
        brief = render(BRIEF_HEADER, briefed)
        skipped: list[Skip] = []
        eligible: list[Note] = []
        for note in notes.values():
            if not note.visible_at(probe.place):
                skipped.append(Skip(note.text, SkipReason.AUDIENCE))
            elif note.sensitive:
                skipped.append(Skip(note.text, SkipReason.SENSITIVE))
            elif note not in briefed:
                eligible.append(note)
        block = NotesBlock(brief, self._count_tokens)
        facts = [note for note in eligible if note.kind is not Kind.MOMENT]
        for note, score in self._ranked(probe.text, facts):
            reason = SkipReason.BELOW_THRESHOLD if self._too_weak(score) else block.offer(note)
            if reason:
                skipped.append(Skip(note.text, reason, score))
        moments = [note for note in eligible if note.kind is Kind.MOMENT]
        for note, score in self._ranked(probe.text, moments):
            reason = self._offer_joke(block, note, score, probe)
            if reason:
                skipped.append(Skip(note.text, reason, score))
        self._store.mark_used([note.id for note in block.chosen], probe.at)
        return Injection(brief=brief, notes=block.text, skipped=tuple(skipped))

    def _offer_joke(self, block: NotesBlock, note: Note, score: float, probe: Probe) -> SkipReason | None:
        if self._too_weak(score):
            return SkipReason.BELOW_THRESHOLD
        if block.tells_joke or not self._jokes.allows(note, probe):
            return SkipReason.JOKE_POLICY
        reason = block.offer(note)
        if reason is None:
            self._jokes.told(probe)
        return reason

    def _too_weak(self, score: float) -> bool:
        return self._threshold is not None and score < self._threshold

    def _ranked(self, query: str, notes: Iterable[Note]) -> list[tuple[Note, float]]:
        by_id = {note.id: note for note in notes}
        if not by_id:
            return []
        return [(by_id[note_id], score) for note_id, score in self._retriever.rank(query, by_id.keys())]

    def recall(self, query: Probe) -> str:
        here = origin_of(query.place)
        reachable = [
            note
            for note in self._store.notes()
            if note.visible_at(query.place) and (not note.sensitive or note.origin == here)
        ]
        found = [note for note, _ in self._ranked(query.text, reachable)[:RECALL_LIMIT]]
        self._store.mark_used([note.id for note in found], query.at)
        return "\n".join(map(note_line, found))

    def stored_texts(self) -> tuple[str, ...]:
        return tuple(note.text for note in self._store.notes())

    def losses(self) -> tuple[Loss, ...]:
        return tuple(self._losses)

    def brief_rewrites(self) -> tuple[BriefRewrite, ...]:
        return tuple(self._rewrites)

    def close(self) -> None:
        self._retriever.close()
        self._store.close()
