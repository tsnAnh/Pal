from __future__ import annotations

import unicodedata
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Protocol

TOTAL_TOKEN_CAP = 700
BRIEF_TOKEN_CAP = 300
NOTES_TOKEN_CAP = 400
MAX_INJECTED_NOTES = 4
MAX_WRITES_PER_TURN = 2
STORE_NOTE_CAP = 500
ADMIT_MIN_SALIENCE = 0.3
EXPIRE_BELOW_SALIENCE = 0.5
EXPIRE_AFTER_DAYS = 14
JOKE_NOTE_COOLDOWN_DAYS = 7
JOKE_CONVERSATION_COOLDOWN_DAYS = 1
VIETNAMESE_WORD_SHARE = 0.4

TokenCounter = Callable[[str], int]


class Kind(Enum):
    WORK = "work"
    PREF = "pref"
    MOMENT = "moment"


class Source(Enum):
    SLACK = "slack"
    PAL_APP = "pal_app"


class ItemKind(Enum):
    FACT = "fact"
    DECISION = "decision"
    COMMITMENT = "commitment"
    PREFERENCE = "preference"
    JOKE = "joke"


class ForbiddenReason(Enum):
    SUPERSEDED = "superseded"
    WRONG_AUDIENCE = "wrong_audience"
    SENSITIVE = "sensitive"
    TOO_RECENT = "too_recent"
    INCIDENT = "incident"
    EXPIRED = "expired"
    IRRELEVANT = "irrelevant"


class Category(Enum):
    NEEDED = "needed"
    JOKE = "joke"
    MUST_NOT = "must_not"
    IRRELEVANT = "irrelevant"
    LONG_THREAD = "long_thread"
    DUPLICATE = "duplicate"
    EXPIRY = "expiry"


class Split(Enum):
    DEV = "dev"
    TEST = "test"


class SalienceMode(Enum):
    INFORMATIVE = "informative"
    NOISY = "noisy"
    FLAT = "flat"


class Load(Enum):
    TYPICAL = "typical"
    AT_CAP = "at_cap"


class LossReason(Enum):
    REJECTED_FULL = "rejected_full"
    WRITE_LIMIT = "write_limit"
    ADMISSION = "admission"
    MERGED = "merged"
    OVERWRITTEN = "topic_overwrite"
    EXPIRED = "expired"
    EVICTED_CAP = "evicted_store_cap"
    PRUNED = "pruned_for_room"


class SkipReason(Enum):
    BELOW_THRESHOLD = "below_threshold"
    SLOTS = "note_slots"
    BUDGET = "token_budget"
    AUDIENCE = "audience"
    SENSITIVE = "sensitive"
    JOKE_POLICY = "joke_policy"


@dataclass(frozen=True)
class Place:
    source: Source
    channel: str
    thread: str = ""


@dataclass(frozen=True)
class Proposal:
    key: str
    kind: Kind
    text: str
    topic: str
    salience: float
    sensitive: bool = False


@dataclass(frozen=True)
class Turn:
    at: float
    place: Place
    speaker: str
    text: str
    owner: bool = False
    proposals: tuple[Proposal, ...] = ()


@dataclass(frozen=True)
class Probe:
    at: float
    place: Place
    speaker: str
    text: str
    owner: bool = False
    incident: bool = False


Event = Turn | Probe


@dataclass(frozen=True)
class Item:
    id: str
    kind: ItemKind
    markers: tuple[str, ...]


@dataclass(frozen=True)
class Forbidden:
    id: str
    reason: ForbiddenReason
    markers: tuple[str, ...]


@dataclass(frozen=True)
class Scenario:
    id: str
    category: Category
    split: Split
    covers: str
    history: tuple[Event, ...]
    probe: Probe
    expected: tuple[Item, ...]
    forbidden: tuple[Forbidden, ...]
    token_ceiling: int


@dataclass(frozen=True)
class Question:
    probe: Probe
    item: Item
    said_at: float
    forbidden: tuple[Forbidden, ...] = ()


@dataclass(frozen=True)
class History:
    turns: tuple[Turn, ...]
    questions: tuple[Question, ...]
    last_day: int


@dataclass(frozen=True)
class Skip:
    text: str
    reason: SkipReason
    score: float | None = None


@dataclass(frozen=True)
class Injection:
    brief: str = ""
    notes: str = ""
    snapshot: str = ""
    skipped: tuple[Skip, ...] = ()

    @property
    def text(self) -> str:
        return "\n\n".join(part for part in (self.snapshot, self.brief, self.notes) if part)


@dataclass(frozen=True)
class Loss:
    text: str
    reason: LossReason
    at: float
    detail: str = ""


@dataclass(frozen=True)
class BriefRewrite:
    at: float
    place: Place
    before: str
    after: str


class Candidate(Protocol):
    def write(self, turn: Turn) -> None: ...

    def end_day(self, day: int) -> None: ...

    def inject(self, probe: Probe) -> Injection: ...

    def recall(self, query: Probe) -> str: ...

    def stored_texts(self) -> tuple[str, ...]: ...

    def losses(self) -> tuple[Loss, ...]: ...

    def brief_rewrites(self) -> tuple[BriefRewrite, ...]: ...

    def close(self) -> None: ...


class Builder(Protocol):
    def __call__(self, workdir: Path, count_tokens: TokenCounter, threshold: float | None) -> Candidate: ...


@dataclass(frozen=True)
class CandidateSpec:
    name: str
    description: str
    build: Builder
    unavailable: Callable[[], str | None] = lambda: None
    threshold_grid: tuple[float, ...] = field(default=())


def fold(text: str) -> str:
    return " ".join(unicodedata.normalize("NFC", text).casefold().split())


def vietnamese(text: str) -> bool:
    words = text.casefold().split()
    marked = sum("đ" in word or any(map(unicodedata.combining, unicodedata.normalize("NFD", word))) for word in words)
    return marked >= VIETNAMESE_WORD_SHARE * len(words)


def mentions(text: str, markers: Iterable[str]) -> bool:
    haystack = fold(text)
    return all(fold(marker) in haystack for marker in markers)
