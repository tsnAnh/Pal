from __future__ import annotations

import re
import sqlite3
import unicodedata
from collections.abc import Collection
from pathlib import Path

from hermes_state_session_search import prefix_match_query

MIN_PREFIX_LENGTH = 4
TERM = re.compile(r"\w+(?:[._-]\w+)*")
STOPWORDS = frozenset(
    """
    a about again an and any are as at be been by can could did do does for from had has have he hey hi how i if
    in is it its just may me might my not now of on or our please she should so still that the there these they
    this those to us was we were what when where which who why will with would you your
    anh bạn cái chị cho chưa chứ các có cũng của em giúp gì hãy hả không khi là lên lại mà mình một nha nhé nhỉ
    như nào những này nếu ra rồi sao sẽ thì thế trong tôi và vào vẫn vậy về với à đang đi được đã đó để ạ ơi ở
    """.split()
)


def normalise(text: str) -> str:
    return unicodedata.normalize("NFC", text).casefold()


def strip_diacritics(text: str) -> str:
    decomposed = unicodedata.normalize("NFD", text.replace("đ", "d"))
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def any_of(terms: Collection[str]) -> str:
    return " OR ".join(term if term.isalnum() or term.endswith("*") else f'"{term}"' for term in terms)


def match_expression(query: str) -> str:
    terms = dict.fromkeys(
        term for term in TERM.findall(normalise(query)) if len(term) > 1 and term not in STOPWORDS
    )
    accented = [term for term in terms if strip_diacritics(term) != term]
    plain = [term for term in terms if term not in accented]
    exact = [*accented, *map(strip_diacritics, accented)]
    prefixed = [
        prefix_match_query(term) if len(term) >= MIN_PREFIX_LENGTH and term.isalnum() else term for term in plain
    ]
    return " OR ".join(
        f"{column} : ({any_of(dict.fromkeys(words))})"
        for column, words in (("exact", exact), ("folded", prefixed))
        if words
    )


class FtsRetriever:
    def __init__(self, path: Path) -> None:
        self._db = sqlite3.connect(path, isolation_level=None)
        self._db.execute(
            "CREATE VIRTUAL TABLE notes USING fts5(exact, folded, tokenize = 'unicode61 remove_diacritics 0')"
        )

    def add(self, note_id: int, text: str) -> None:
        exact = normalise(text)
        self._db.execute(
            "INSERT INTO notes (rowid, exact, folded) VALUES (?, ?, ?)", (note_id, exact, strip_diacritics(exact))
        )

    def remove(self, note_id: int) -> None:
        self._db.execute("DELETE FROM notes WHERE rowid = ?", (note_id,))

    def rank(self, query: str, note_ids: Collection[int]) -> list[tuple[int, float]]:
        expression = match_expression(query)
        if not expression:
            return []
        rows = self._db.execute(
            "SELECT rowid, -bm25(notes) FROM notes WHERE notes MATCH ? ORDER BY bm25(notes), rowid DESC",
            (expression,),
        )
        return [(note_id, score) for note_id, score in rows if note_id in note_ids]

    def close(self) -> None:
        self._db.close()
