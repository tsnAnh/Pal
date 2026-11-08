from __future__ import annotations

import contextlib
import os
import sqlite3
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tools.bot_desktop import chrome_profile as cp

_SLEEPER = [getattr(sys, "_base_executable", sys.executable), "-c", "import time; time.sleep(60)"]


@pytest.fixture
def root(tmp_path):
    base = tmp_path / "hermes"
    for name in ("alpha", "beta"):
        (base / "profiles" / name).mkdir(parents=True)
    return base


@contextlib.contextmanager
def bot(root: Path, name: str):
    token = set_hermes_home_override(root / "profiles" / name)
    try:
        yield cp.copy_dir()
    finally:
        reset_hermes_home_override(token)


def write_cookies(path: Path, *values: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("CREATE TABLE IF NOT EXISTS cookies (v TEXT)")
        db.execute("DELETE FROM cookies")
        db.executemany("INSERT INTO cookies VALUES (?)", [(v,) for v in values])
        db.commit()


def read_cookies(path: Path) -> list[str]:
    with contextlib.closing(sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)) as db:
        return [row[0] for row in db.execute("SELECT v FROM cookies ORDER BY v")]


def browse(copy: Path, *, cookies=None, bookmarks=None, local_storage=None) -> None:
    if cookies is not None:
        write_cookies(copy / "Default" / "Cookies", *cookies)
    if bookmarks is not None:
        (copy / "Default").mkdir(parents=True, exist_ok=True)
        (copy / "Default" / "Bookmarks").write_text(bookmarks)
    if local_storage is not None:
        leveldb = copy / "Default" / "Local Storage" / "leveldb"
        leveldb.mkdir(parents=True, exist_ok=True)
        for name, body in local_storage.items():
            (leveldb / name).write_text(body)


@contextlib.contextmanager
def chrome_on(udd: Path):
    proc = subprocess.Popen([*_SLEEPER, f"--user-data-dir={udd}"])
    try:
        yield proc
    finally:
        proc.kill()
        proc.wait()


def test_master_and_copies_live_where_status_says(root):
    with bot(root, "alpha") as a:
        assert cp.master_dir() == root / "bot-computers" / "chrome-master"
        assert cp.shared_files_dir() == root / "bot-computers" / "files"
        assert a == root / "profiles" / "alpha" / "bot-desktop" / "browser-profile"
    with bot(root, "beta") as b:
        assert b != a and cp.master_dir() == root / "bot-computers" / "chrome-master"


def test_exit_writes_back_and_the_next_start_of_another_bot_is_seeded(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=alpha"], bookmarks="alpha-marks")
        assert cp.write_back() == ["Default/Bookmarks", "Default/Cookies"]
    with bot(root, "beta") as b:
        assert set(cp.seed()) == {"Default/Bookmarks", "Default/Cookies"}
        assert read_cookies(b / "Default" / "Cookies") == ["sid=alpha"]
        assert (b / "Default" / "Bookmarks").read_text() == "alpha-marks"
        assert cp.synced_at() is not None


def test_write_back_is_idempotent(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=1"])
        assert cp.write_back() == ["Default/Cookies"]
        assert cp.write_back() == []
        assert not cp.is_dirty()


def test_last_writer_wins_per_file_and_untouched_files_are_not_clobbered(root):
    with bot(root, "alpha") as a:
        cp.seed()
    with bot(root, "beta") as b:
        cp.seed()
    with bot(root, "alpha") as a:
        browse(a, cookies=["sid=alpha"], bookmarks="alpha-marks")
        cp.write_back()
    with bot(root, "beta") as b:
        browse(b, cookies=["sid=beta"])
        cp.write_back()
    master = root / "bot-computers" / "chrome-master"
    assert read_cookies(master / "Default" / "Cookies") == ["sid=beta"]
    assert (master / "Default" / "Bookmarks").read_text() == "alpha-marks"


def test_concurrent_exits_serialize_on_the_master_lock(root, monkeypatch):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=alpha"])
    with bot(root, "beta") as b:
        cp.seed()
        browse(b, cookies=["sid=beta"])
    inside, overlap = threading.Lock(), []
    real_install = cp._install

    def guarded(item, src, dst):
        if not inside.acquire(blocking=False):
            overlap.append(item.rel)
            return real_install(item, src, dst)
        try:
            threading.Event().wait(0.2)  # health: allow HX013 -- the window a second exit must not enter is the behaviour under test
            return real_install(item, src, dst)
        finally:
            inside.release()

    monkeypatch.setattr(cp, "_install", guarded)

    def exit_bot(name):
        with bot(root, name):
            cp.write_back()

    threads = [threading.Thread(target=exit_bot, args=(n,)) for n in ("alpha", "beta")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert overlap == []
    assert read_cookies(root / "bot-computers" / "chrome-master" / "Default" / "Cookies") in (["sid=alpha"], ["sid=beta"])


def test_locks_caches_and_singletons_never_reach_master_or_copy(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=1"], local_storage={"000003.log": "data", "LOCK": "", "LOG": "x"})
        for junk in ("SingletonLock", "SingletonSocket", "Default/Cache/data_0", "Default/GPUCache/index",
                     "Default/Code Cache/js/x"):
            (a / junk).parent.mkdir(parents=True, exist_ok=True)
            (a / junk).write_text("junk")
        cp.write_back()
    master = root / "bot-computers" / "chrome-master"
    found = {p.relative_to(master).as_posix() for p in master.rglob("*") if p.is_file()}
    assert found == {"Default/Cookies", "Default/Local Storage/leveldb/000003.log"}
    with bot(root, "beta") as b:
        b.mkdir(parents=True)
        os.symlink("otherhost-999", b / "SingletonLock")
        cp.seed()
        assert not (b / "SingletonLock").is_symlink()
        assert not (b / "Default" / "Local Storage" / "leveldb" / "LOCK").exists()


def test_a_running_chrome_blocks_seed_and_write_back(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=live"])
        with chrome_on(a):
            with pytest.raises(cp.ChromeRunning):
                cp.write_back()
            with pytest.raises(cp.ChromeRunning):
                cp.seed()
            assert cp.write_back_if_idle() == []
        assert cp.write_back_if_idle() == ["Default/Cookies"]


def test_a_chrome_on_master_is_refused(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=1"])
        with chrome_on(root / "bot-computers" / "chrome-master"):
            with pytest.raises(cp.ChromeRunning):
                cp.write_back()


def test_a_pending_write_back_survives_a_crash_and_lands_before_the_next_seed(root):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=unsynced"])
        cp.seed()
        assert read_cookies(a / "Default" / "Cookies") == ["sid=unsynced"]
    assert read_cookies(root / "bot-computers" / "chrome-master" / "Default" / "Cookies") == ["sid=unsynced"]


def test_crash_mid_file_write_back_leaves_master_all_old(root, monkeypatch):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=old"], bookmarks="old")
        cp.write_back()
        browse(a, cookies=["sid=new"], bookmarks="new")
        real_replace = os.replace
        calls = []

        def crash_on_second(src, dst):
            calls.append(dst)
            if len(calls) == 2:
                raise KeyboardInterrupt("power cut")
            return real_replace(src, dst)

        monkeypatch.setattr(cp.os, "replace", crash_on_second)
        with pytest.raises(KeyboardInterrupt):
            cp.write_back()
        monkeypatch.setattr(cp.os, "replace", real_replace)
    master = root / "bot-computers" / "chrome-master"
    assert (master / "Default" / "Bookmarks").read_text() == "new"
    assert read_cookies(master / "Default" / "Cookies") == ["sid=old"]
    assert not [p for p in master.rglob(".*hermes-*")]
    with bot(root, "alpha"):
        assert "Default/Cookies" in cp.write_back()
    assert read_cookies(master / "Default" / "Cookies") == ["sid=new"]


@pytest.mark.parametrize("crash_after_renames, expected", [(1, "old"), (2, "new")])
def test_crash_mid_tree_swap_recovers_to_all_old_or_all_new(root, monkeypatch, crash_after_renames, expected):
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, local_storage={"000001.ldb": "old-1", "MANIFEST-1": "old-m"})
        cp.write_back()
        browse(a, local_storage={"000001.ldb": "new-1", "MANIFEST-1": "new-m"})
        real_rename, real_rmtree = os.rename, cp.shutil.rmtree
        calls = []

        def rename(src, dst):
            real_rename(src, dst)
            calls.append(dst)
            if len(calls) == crash_after_renames:
                raise KeyboardInterrupt("power cut")

        monkeypatch.setattr(cp.os, "rename", rename)
        monkeypatch.setattr(cp.shutil, "rmtree", lambda *a, **k: None)
        with pytest.raises(KeyboardInterrupt):
            cp.write_back()
        monkeypatch.setattr(cp.os, "rename", real_rename)
        monkeypatch.setattr(cp.shutil, "rmtree", real_rmtree)
    master = root / "bot-computers" / "chrome-master"
    cp.recover(master)
    leveldb = master / "Default" / "Local Storage" / "leveldb"
    assert {(leveldb / n).read_text() for n in ("000001.ldb", "MANIFEST-1")} == {f"{expected}-1", f"{expected}-m"}
    assert not [p for p in (master / "Default").iterdir() if ".hermes-" in p.name]


def test_reset_wipes_only_this_bots_copy_and_next_start_reseeds(root, monkeypatch):
    from tools.bot_desktop import runtime
    monkeypatch.setattr(runtime, "is_supported_host", lambda: True)
    monkeypatch.setattr(runtime, "stop", lambda **kw: False)
    monkeypatch.setattr(runtime, "is_running", lambda: False)
    monkeypatch.setattr(runtime.placement, "resolve", lambda: runtime.placement.Placement("gateway", "local"))
    with bot(root, "alpha") as a:
        cp.seed()
        browse(a, cookies=["sid=master"])
        cp.write_back()
    with bot(root, "beta") as b:
        cp.seed()
        browse(b, cookies=["sid=beta-unsynced"])
    shared = root / "bot-computers" / "files"
    shared.mkdir(parents=True)
    (shared / "report.txt").write_text("keep")
    with bot(root, "alpha") as a:
        browse(a, cookies=["sid=alpha-broken"])
        assert sorted(runtime.reset()) == ["browser-profile"]
        assert not a.exists()
    master = root / "bot-computers" / "chrome-master"
    assert read_cookies(master / "Default" / "Cookies") == ["sid=master"]
    assert (shared / "report.txt").read_text() == "keep"
    with bot(root, "beta") as b:
        assert read_cookies(b / "Default" / "Cookies") == ["sid=beta-unsynced"]
    with bot(root, "alpha") as a:
        cp.seed()
        assert read_cookies(a / "Default" / "Cookies") == ["sid=master"]
