from __future__ import annotations

import contextlib
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tools.bot_desktop import chrome_profile as cp
from tools.bot_desktop import runtime

_PY = getattr(sys, "_base_executable", sys.executable)
_SLEEP = "import time; time.sleep(60)"


@pytest.fixture
def root(tmp_path):
    base = tmp_path / "hermes"
    for name in ("alpha", "beta", "gamma"):
        (base / "profiles" / name / "bot-desktop").mkdir(parents=True)
    return base


@contextlib.contextmanager
def bot(root: Path, name: str):
    token = set_hermes_home_override(root / "profiles" / name)
    try:
        yield root / "profiles" / name
    finally:
        reset_hermes_home_override(token)


@pytest.fixture
def spawn(tmp_path):
    procs: list[subprocess.Popen] = []
    fake_xvnc = tmp_path / "bin" / "Xvnc"
    fake_xvnc.parent.mkdir()
    fake_xvnc.symlink_to(_PY)

    def _spawn(kind: str, target: Path) -> subprocess.Popen:
        argv = ([str(fake_xvnc), "-c", _SLEEP, "-rfbunixpath", str(target)] if kind == "xvnc"
                else [_PY, "-c", _SLEEP, f"--user-data-dir={target}"])
        proc = subprocess.Popen(argv)
        procs.append(proc)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with contextlib.suppress(Exception):
                import psutil
                if str(target) in " ".join(psutil.Process(proc.pid).cmdline()):
                    return proc
            time.sleep(0.05)
        return proc

    yield _spawn
    for proc in procs:
        proc.kill()
        proc.wait()


def _socket(home: Path) -> Path:
    return home / "bot-desktop" / "rfb.sock"


def _cookies(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as db:
        db.execute("CREATE TABLE IF NOT EXISTS cookies (v TEXT)")
        db.execute("DELETE FROM cookies")
        db.execute("INSERT INTO cookies VALUES (?)", (value,))
        db.commit()


def _read(path: Path) -> list[str]:
    with contextlib.closing(sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)) as db:
        return [r[0] for r in db.execute("SELECT v FROM cookies")]


def test_two_bots_get_their_own_screen_state_and_their_own_chrome(root, monkeypatch):
    from tools import browser_session
    monkeypatch.setattr(runtime, "published_env", lambda: {"DISPLAY": ":20"})
    targets = {}
    for name in ("alpha", "beta"):
        with bot(root, name) as home:
            key, kwargs = browser_session._bot_desktop_target()
            targets[name] = (runtime.state_dir(), key, kwargs["user_data_dir"], kwargs.get("prepare"))
            assert runtime.state_dir() == home / "bot-desktop"
    assert targets["alpha"][0] != targets["beta"][0]
    assert targets["alpha"][1] != targets["beta"][1], "one launcher key means one shared Chrome / CDP endpoint"
    assert targets["alpha"][2] != targets["beta"][2]
    assert all(t[3] is not None for t in targets.values()), "a managed copy is seeded from master before launch"


def test_a_pinned_user_data_dir_is_never_synced_with_master(root, monkeypatch, tmp_path):
    from tools import browser_session
    from tools import browser_session_cloud
    monkeypatch.setattr(runtime, "published_env", lambda: {"DISPLAY": ":20"})
    monkeypatch.setattr(browser_session_cloud, "user_data_dir", lambda: str(tmp_path / "pinned"))
    with bot(root, "alpha"):
        _key, kwargs = browser_session._bot_desktop_target()
    assert kwargs["user_data_dir"] == str(tmp_path / "pinned") and "prepare" not in kwargs


@pytest.mark.platforms("posix")
def test_the_screen_cap_counts_every_bots_screen_and_refuses_past_it(root, spawn, monkeypatch):
    for name in ("alpha", "beta"):
        spawn("xvnc", _socket(root / "profiles" / name))
    with bot(root, "gamma") as gamma:
        monkeypatch.setattr(runtime, "max_screens", lambda: 2)
        with pytest.raises(runtime.ScreenCapReached, match="max_screens"):
            runtime._refuse_over_cap(_socket(gamma))
        monkeypatch.setattr(runtime, "max_screens", lambda: 3)
        runtime._refuse_over_cap(_socket(gamma))
        monkeypatch.setattr(runtime, "max_screens", lambda: 0)
        runtime._refuse_over_cap(_socket(gamma))
    with bot(root, "alpha") as alpha:
        monkeypatch.setattr(runtime, "max_screens", lambda: 2)
        runtime._refuse_over_cap(_socket(alpha))


@pytest.mark.platforms("posix")
def test_stop_closes_this_bots_chrome_and_writes_its_copy_back(root, spawn, monkeypatch):
    monkeypatch.setattr(runtime, "is_supported_host", lambda: True)
    with bot(root, "alpha"):
        cp.seed()
        _cookies(cp.copy_dir() / "Default" / "Cookies", "sid=alpha")
        chrome = spawn("chrome", cp.copy_dir())
    with bot(root, "beta"):
        cp.seed()
        other = spawn("chrome", cp.copy_dir())
    with bot(root, "alpha"):
        runtime.stop()
    assert chrome.wait(5) is not None
    assert other.poll() is None, "another bot's Chrome was stopped"
    assert _read(root / "bot-computers" / "chrome-master" / "Default" / "Cookies") == ["sid=alpha"]


@pytest.mark.platforms("posix")
def test_restart_reconcile_reaps_only_this_bots_orphans_and_is_idempotent(root, spawn, monkeypatch):
    monkeypatch.setattr(runtime, "is_supported_host", lambda: True)
    monkeypatch.setattr(runtime, "_X_LOCK_DIR", root / "xlocks")
    alpha, beta = root / "profiles" / "alpha", root / "profiles" / "beta"
    orphan_x = spawn("xvnc", _socket(alpha))
    other_x = spawn("xvnc", _socket(beta))
    with bot(root, "alpha"):
        cp.seed()
        _cookies(cp.copy_dir() / "Default" / "Cookies", "sid=orphaned")
        orphan_chrome = spawn("chrome", cp.copy_dir())
        runtime.reconcile()
        runtime.reconcile()
    assert orphan_x.wait(5) is not None and orphan_chrome.wait(5) is not None
    assert other_x.poll() is None, "another bot's screen was reaped"
    assert _read(root / "bot-computers" / "chrome-master" / "Default" / "Cookies") == ["sid=orphaned"]


def test_reconcile_writes_back_once_a_running_screens_chrome_has_exited(root, monkeypatch):
    monkeypatch.setattr(runtime, "is_supported_host", lambda: True)
    monkeypatch.setattr(runtime, "_launcher_pid", lambda: 4242)
    with bot(root, "alpha"):
        cp.seed()
        _cookies(cp.copy_dir() / "Default" / "Cookies", "sid=closed-by-human")
        runtime.reconcile()
        assert not cp.is_dirty()
    assert _read(root / "bot-computers" / "chrome-master" / "Default" / "Cookies") == ["sid=closed-by-human"]


@pytest.mark.platforms("posix")
def test_status_reports_screen_chrome_sync_and_shared_files(root, spawn):
    with bot(root, "alpha"):
        before = runtime.status()
        assert before.screen == runtime.SCREEN_STOPPED and before.chrome == runtime.CHROME_STOPPED
        assert before.profile_copy_synced_at is None
        cp.seed()
        spawn("chrome", cp.copy_dir())
        after = runtime.status().as_dict()
    assert after["chrome"] == "running" and after["profile_copy_synced_at"] > 0
    assert after["shared_files_path"].endswith("bot-computers/files")
    with bot(root, "beta"):
        theirs = runtime.status()
    assert theirs.chrome == "stopped" and theirs.shared_files_path == after["shared_files_path"]


def test_display_rpcs_reach_only_the_addressed_bot(root, monkeypatch):
    from hermes_constants import get_hermes_home
    from tools.bot_desktop import thumbnail
    from tui_gateway import server
    homes = {name: root / "profiles" / name for name in ("alpha", "beta")}
    monkeypatch.setattr(server, "_profile_home", lambda name: str(homes[name]) if name in homes else None)
    monkeypatch.setattr(thumbnail, "thumbnail_data_url", lambda: f"data:image/jpeg;base64,{get_hermes_home().name}")

    def call(method, profile):
        return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": {"profile": profile}})

    thumbs = {name: call("display.thumbnail", name)["result"]["data_url"] for name in homes}
    assert thumbs == {"alpha": "data:image/jpeg;base64,alpha", "beta": "data:image/jpeg;base64,beta"}
    status = {name: call("display.status", name)["result"] for name in homes}
    assert status["alpha"]["profile_key"] != status["beta"]["profile_key"]
    assert status["alpha"]["shared_files_path"] == status["beta"]["shared_files_path"]
    assert {s["screen"] for s in status.values()} == {"stopped"}
