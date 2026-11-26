from __future__ import annotations

import sqlite3
from collections.abc import Collection
from dataclasses import dataclass, fields, replace
from enum import Enum
from pathlib import Path

from scripts.memory_bench.model import Kind, Place, Source

AT_UNITS_PER_DAY = 1.0

Origin = tuple[Source, str]


class Scope(Enum):
    ANYWHERE = "anywhere"
    CHANNEL = "channel"


def origin_of(place: Place) -> Origin:
    return place.source, place.channel


@dataclass(frozen=True)
class Note:
    kind: Kind
    text: str
    speaker: str
    source: Source
    channel: str
    thread: str
    said_at: float
    scope: Scope
    topic: str
    salience: float
    sensitive: bool = False
    last_used: float | None = None
    uses: int = 0
    id: int = 0

    @property
    def origin(self) -> Origin:
        return self.source, self.channel

    @property
    def last_touched(self) -> float:
        return self.said_at if self.last_used is None else max(self.said_at, self.last_used)

    def visible_at(self, place: Place) -> bool:
        return self.scope is Scope.ANYWHERE or self.origin == origin_of(place)

    def shares_scope(self, other: Note) -> bool:
        return self.scope is other.scope and (self.scope is Scope.ANYWHERE or self.origin == other.origin)


COLUMNS = tuple(column.name for column in fields(Note) if column.name != "id")


def _to_row(note: Note) -> tuple[object, ...]:
    values = (getattr(note, column) for column in COLUMNS)
    return tuple(value.value if isinstance(value, Enum) else value for value in values)


def _from_row(row: sqlite3.Row) -> Note:
    values = dict(row)
    return Note(
        **{
            **values,
            "kind": Kind(values["kind"]),
            "source": Source(values["source"]),
            "scope": Scope(values["scope"]),
            "sensitive": bool(values["sensitive"]),
        }
    )


class NoteStore:
    def __init__(self, path: Path) -> None:
        self._db = sqlite3.connect(path, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._db.execute(f"CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, {', '.join(COLUMNS)})")

    def insert(self, note: Note) -> Note:
        marks = ", ".join("?" for _ in COLUMNS)
        cursor = self._db.execute(f"INSERT INTO notes ({', '.join(COLUMNS)}) VALUES ({marks})", _to_row(note))
        return replace(note, id=cursor.lastrowid)

    def remove(self, note_id: int) -> None:
        self._db.execute("DELETE FROM notes WHERE id = ?", (note_id,))

    def notes(self) -> tuple[Note, ...]:
        return tuple(_from_row(row) for row in self._db.execute("SELECT * FROM notes ORDER BY id"))

    def mark_used(self, note_ids: Collection[int], at: float) -> None:
        self._db.executemany(
            "UPDATE notes SET uses = uses + 1, last_used = ? WHERE id = ?", [(at, note_id) for note_id in note_ids]
        )

    def close(self) -> None:
        self._db.close()
