import sqlite3

import hermes_state_library
from hermes_state import SessionDB
from hermes_state_library import LibraryIndex


def _store(tmp_path, count):
    db = SessionDB(tmp_path / "state.db")
    db.create_session("s1", "cli")
    for index in range(count):
        db.append_message("s1", "user", f"https://resume{index}.example.com/", timestamp=1_700_000_000 + index)
    return db


def _all(index, db):
    items, more = index.page(db, kind=None, limit=200, before_us=None)
    assert not more
    return [(item.id, item.title, item.order_us) for item in items]


def test_a_budget_cut_backfill_resumes_without_gaps_or_duplicates(tmp_path, monkeypatch):
    monkeypatch.setattr(hermes_state_library, "SCAN_CHUNK_ROWS", 4)
    db = _store(tmp_path, 25)
    index = LibraryIndex(tmp_path)
    runs = 0
    while not index.refresh(db, budget_s=0):
        runs += 1
        assert runs < 50
    assert runs >= 5
    resumed = _all(index, db)
    assert len(resumed) == 25

    fresh = LibraryIndex(tmp_path / "other-home")
    assert fresh.refresh(db)
    assert _all(fresh, db) == resumed
    assert index.refresh(db) and _all(index, db) == resumed
    db.close()


def test_refresh_never_writes_to_the_message_store(tmp_path):
    db = _store(tmp_path, 3)
    db.close()
    path = tmp_path / "state.db"
    with sqlite3.connect(path) as conn:
        before = conn.execute("SELECT name FROM sqlite_master ORDER BY name").fetchall()
    reader = SessionDB(path, read_only=True)
    assert LibraryIndex(tmp_path).refresh(reader)
    reader.close()
    with sqlite3.connect(path) as conn:
        assert conn.execute("SELECT name FROM sqlite_master ORDER BY name").fetchall() == before


def test_an_index_of_another_format_is_rebuilt_not_trusted(tmp_path):
    db = _store(tmp_path, 3)
    index = LibraryIndex(tmp_path)
    assert index.refresh(db)
    with sqlite3.connect(index.path) as conn:
        conn.execute("PRAGMA user_version = 0")
        conn.execute("DELETE FROM items")
    assert index.refresh(db)
    assert len(_all(index, db)) == 3
    db.close()
