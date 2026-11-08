"""Per-bot computers whose screens run in each bot's own Docker sandbox (the macOS host path).

The Docker daemon is replaced at the process boundary: every ``docker`` argv Hermes runs goes to
``FakeDockerHost``, which keeps containers (mounts, hostname, processes) and answers ``run`` / ``ps`` /
``inspect`` / ``rm`` / ``exec``. A container's Chrome is modelled the way the host sees it: a
``SingletonLock`` symlink (``<container hostname>-<pid>``) appearing in the bind-mounted copy.
"""
from __future__ import annotations

import contextlib
import itertools
import json
import os
import secrets
import shlex
import sqlite3
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tools.bot_desktop import chrome_profile as cp
from tools.bot_desktop import runtime, sandbox_computer, sandbox_host

DOCKER = "/nonexistent/fake-docker"


@dataclass
class Container:
    cid: str
    mounts: dict[str, Path]
    running: bool = True
    screen_up: bool = False
    xdg: bool = False
    chrome: dict[int, str] = field(default_factory=dict)
    copy_at_chrome_start: list[list[str]] = field(default_factory=list)
    execs: list[str] = field(default_factory=list)

    @property
    def hostname(self) -> str:
        return self.cid[:12]

    def host_path(self, container_path: str) -> Path | None:
        for dest, src in self.mounts.items():
            if container_path == dest or container_path.startswith(dest + "/"):
                return src / container_path[len(dest):].lstrip("/")
        return None


class FakeDockerHost:
    def __init__(self, real_run):
        self.real_run = real_run
        self.containers: dict[str, Container] = {}
        self.run_argvs: list[list[str]] = []
        self.next_pid = 100

    def __call__(self, argv, *args, **kwargs):
        if not isinstance(argv, (list, tuple)) or not argv or argv[0] != DOCKER:
            return self.real_run(argv, *args, **kwargs)
        out, rc = self.dispatch(list(argv[1:]))
        text = kwargs.get("text") or kwargs.get("universal_newlines")
        return subprocess.CompletedProcess(argv, rc, out if text else out.encode(), "" if text else b"")

    def dispatch(self, a: list[str]) -> tuple[str, int]:
        cmd = a[0] if a else ""
        if cmd == "run":
            return self.run(a), 0
        if cmd == "ps":
            return self.ps(a), 0
        if cmd == "inspect":
            return self.inspect(a)
        if cmd == "rm":
            gone = self.containers.pop(a[-1], None)
            return ("", 0) if gone else ("", 1)
        if cmd == "exec":
            return self.exec(a[1:])
        return "", 0

    def run(self, a: list[str]) -> str:
        self.run_argvs.append(a)
        cid = secrets.token_hex(32)
        mounts = {}
        for flag, spec in itertools.pairwise(a):
            if flag == "-v":
                src, _, rest = spec.partition(":")
                mounts[rest.split(":")[0]] = Path(src)
        self.containers[cid] = Container(cid, mounts)
        return cid + "\n"

    def add(self, mounts: dict[str, Path], **kw) -> Container:
        c = Container(secrets.token_hex(32), mounts, **kw)
        self.containers[c.cid] = c
        return c

    def ps(self, a: list[str]) -> str:
        filters = [v for f, v in itertools.pairwise(a) if f == "--filter"]
        volume = next((f.split("=", 1)[1] for f in filters if f.startswith("volume=")), None)
        if volume is None:
            return ""
        return "".join(f"{c.cid}\n" for c in self.containers.values() if volume in c.mounts)

    def inspect(self, a: list[str]) -> tuple[str, int]:
        c = self.containers.get(a[-1])
        if c is None:
            return "", 1
        fmt = a[a.index("-f") + 1]
        running = "true" if c.running else "false"
        if "Mounts" in fmt:
            mounts = [{"Source": str(src), "Destination": dest} for dest, src in c.mounts.items()]
            return f"{json.dumps(mounts)} {running}\n", 0
        return running + "\n", 0

    def exec(self, a: list[str]) -> tuple[str, int]:
        while a and a[0].startswith("-"):
            a = a[2:] if a[0] == "-u" else a[1:]
        c = self.containers.get(a[0])
        if c is None or not c.running:
            return "", 1
        argv = a[1:]
        if argv[:2] == ["bash", "-c"] and " exec " in f" {argv[2]}":
            tokens = shlex.split(argv[2])
            argv = tokens[tokens.index("exec") + 1:]
        joined = " ".join(argv)
        c.execs.append(joined)
        if argv[:2] == ["test", "-w"]:
            return "", 0 if c.host_path(argv[2]) is not None else 1
        if argv[:2] == ["id", "-u"]:
            return "1000\n", 0
        if "ms-playwright" in joined:
            return "/opt/pw/chromium-1/chrome-linux/chrome", 0
        if "hermes-chrome-probe" in argv:
            i = argv.index("hermes-chrome-probe")
            host, pid = argv[i + 1], int(argv[i + 2])
            if host != c.hostname:
                return "", 5
            return "", 0 if pid in c.chrome else 1
        if "hermes-orphan-stop" in argv:
            found = c.screen_up or bool(c.chrome)
            c.screen_up = False
            for pid in list(c.chrome):
                self.chrome_exit(c, pid)
            return "", 0 if found else 3
        if "hermes-chrome-stop" in argv:
            for pid in list(c.chrome):
                self.chrome_exit(c, pid)
            return "", 0
        if "hermes-sandbox-browser-stop" in argv:
            pid = int(argv[argv.index("hermes-sandbox-browser-stop") + 1])
            if pid not in c.chrome:
                return "", 4
            self.chrome_exit(c, pid)
            return "", 0
        if "setsid" in joined and "--user-data-dir=" in joined:
            udd = next(t.split("=", 1)[1] for t in shlex.split(argv[-1]) if t.startswith("--user-data-dir="))
            return f"{self.chrome_start(c, udd)} 4242\n", 0
        if "pgrep -f" in joined and "launcher.pid" in joined:
            was = c.screen_up
            c.screen_up = False
            return "", 0 if was else 1
        if "launcher.pid" in joined and "cat " in joined and "/env" in joined:
            return ("DISPLAY=:20\n", 0) if c.screen_up else ("", 1)
        if "/xdg" in joined and "rm -rf" in joined:
            was = c.xdg
            c.xdg = False
            return "", 0 if was else 3
        return "", 0

    def chrome_start(self, c: Container, udd: str) -> int:
        host = c.host_path(udd)
        assert host is not None, f"Chrome started on {udd}, which is not this bot's mounted copy"
        self.next_pid += 1
        pid = self.next_pid
        c.chrome[pid] = udd
        c.copy_at_chrome_start.append(_cookies(host / "Default" / "Cookies"))
        os.symlink(f"{c.hostname}-{pid}", host / "SingletonLock")
        return pid

    def chrome_exit(self, c: Container, pid: int, *, clean: bool = True) -> None:
        udd = c.chrome.pop(pid)
        if clean:
            with contextlib.suppress(OSError):
                (c.host_path(udd) / "SingletonLock").unlink()

    def chrome_of(self, c: Container) -> Path:
        return c.host_path(sandbox_computer.CONTAINER_PROFILE)


def _write_cookies(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.closing(sqlite3.connect(path)) as db:
        db.execute("CREATE TABLE IF NOT EXISTS cookies (v TEXT)")
        db.execute("DELETE FROM cookies")
        db.execute("INSERT INTO cookies VALUES (?)", (value,))
        db.commit()


def _cookies(path: Path) -> list[str]:
    if not path.exists():
        return []
    with contextlib.closing(sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)) as db:
        return [r[0] for r in db.execute("SELECT v FROM cookies")]


@pytest.fixture
def root(tmp_path):
    base = tmp_path / "hermes"
    for name in ("alpha", "beta", "gamma"):
        (base / "profiles" / name / "bot-desktop").mkdir(parents=True)
        (base / "profiles" / name / "config.yaml").write_text("{}\n", encoding="utf-8")
    return base


@contextlib.contextmanager
def bot(root: Path, name: str):
    token = set_hermes_home_override(root / "profiles" / name)
    try:
        yield root / "profiles" / name
    finally:
        reset_hermes_home_override(token)


@pytest.fixture
def docker(monkeypatch):
    from tools.environments import docker as docker_env
    fake = FakeDockerHost(subprocess.run)
    monkeypatch.setattr(subprocess, "run", fake)
    monkeypatch.setattr(docker_env, "find_docker", lambda: DOCKER)
    monkeypatch.setattr(docker_env, "_cgroup_limits_ok", True, raising=False)
    monkeypatch.setattr(sandbox_host, "_ALIVE_CACHE", {})
    monkeypatch.setattr(sandbox_computer, "_reaped_once", True)
    monkeypatch.setenv("TERMINAL_ENV", "docker")
    monkeypatch.delenv("TERMINAL_DOCKER_SHARED_CONTAINER_KEY", raising=False)
    return fake


@pytest.fixture
def computers(root, docker, monkeypatch):
    """Each bot's terminal container, built through the real Docker backend builder in that bot's scope."""
    from tools.terminal_tool_backends import _build_docker_env
    envs = {}
    for name in ("alpha", "beta"):
        with bot(root, name) as home:
            envs[home] = _build_docker_env(image="hermes-sandbox:desktop", cwd="/root", timeout=60,
                                           cc={"docker_orphan_reaper": False}, task_id=f"profile:{name}",
                                           host_cwd=None)
    from hermes_constants import get_hermes_home

    def _env(*, create=True):
        return envs.get(get_hermes_home())

    monkeypatch.setattr(runtime, "_sandbox_env", _env)
    return {home.name: env for home, env in envs.items()}


def _container(docker: FakeDockerHost, env) -> Container:
    return docker.containers[env._container_id]


def _mark_screen_up(docker: FakeDockerHost, env, home: Path) -> None:
    _container(docker, env).screen_up = True
    (home / "bot-desktop" / "sandbox.json").write_text(json.dumps(
        {"display": ":20", "profile": home.name, "backend": "DockerEnvironment",
         "container": env._container_id, "docker": DOCKER}), encoding="utf-8")


def test_two_bots_get_two_containers_with_only_their_copy_and_the_shared_files(root, docker, computers):
    master = root / "bot-computers" / "chrome-master"
    files = root / "bot-computers" / "files"
    assert len(docker.run_argvs) == 2
    for name, argv in zip(("alpha", "beta"), docker.run_argvs):
        other = "beta" if name == "alpha" else "alpha"
        sources = {spec.split(":")[0]: spec.split(":")[1] for flag, spec in itertools.pairwise(argv) if flag == "-v"}
        own_copy = root / "profiles" / name / "bot-desktop" / "browser-profile"
        assert sources.get(str(own_copy)) == sandbox_computer.CONTAINER_PROFILE
        assert sources.get(str(files)) == sandbox_computer.CONTAINER_FILES
        for src in sources:
            path = Path(src)
            assert path != master and master not in path.parents and path not in master.parents
            assert path not in (root, Path.home(), root / "bot-computers")
            assert root / "profiles" / other not in (path, *path.parents), "another bot's data was mounted"
            assert path not in (root / "profiles" / name).parents
    for name, env in computers.items():
        with bot(root, name):
            assert sandbox_host.browser_profile_dir(env) == sandbox_computer.CONTAINER_PROFILE


def test_a_container_shared_across_profiles_gets_no_copy(root, docker, monkeypatch):
    from tools.terminal_tool_backends import _build_docker_env
    monkeypatch.setenv("TERMINAL_DOCKER_SHARED_CONTAINER_KEY", "team")
    with bot(root, "alpha"):
        _build_docker_env(image="hermes-sandbox:desktop", cwd="/root", timeout=60,
                          cc={"docker_orphan_reaper": False, "docker_shared_container_key": "team"},
                          task_id="shared:team", host_cwd=None)
        assert runtime.status().chrome is None and runtime.status().shared_files_path is None
    assert "bot-computer" not in " ".join(docker.run_argvs[0])


def test_each_bots_browser_starts_in_its_own_container_seeded_from_master_and_writes_back_on_exit(
        root, docker, computers):
    from tools import browser_session_sandbox as sbx
    master_cookies = root / "bot-computers" / "chrome-master" / "Default" / "Cookies"
    _write_cookies(master_cookies, "sid=master")
    keys = {}
    for name, env in computers.items():
        with bot(root, name):
            udd = sandbox_host.browser_profile_dir(env)
            keys[name] = sbx._shared_key(env, udd)
            sbx._spawn_owned(env, "pn", udd, keys[name], {"DISPLAY": ":20"})
    assert keys["alpha"] != keys["beta"], "two bots must never share one CDP endpoint"
    for name, env in computers.items():
        c = _container(docker, env)
        assert len(c.chrome) == 1, f"{name}'s Chrome did not start in {name}'s own container"
        assert c.copy_at_chrome_start == [["sid=master"]], "the copy was not refreshed before Chrome started"

    alpha = computers["alpha"]
    _write_cookies(docker.chrome_of(_container(docker, alpha)) / "Default" / "Cookies", "sid=alpha-login")
    with bot(root, "gamma"):
        sbx._stop_launched(keys["alpha"])
    assert not _container(docker, alpha).chrome
    assert _cookies(master_cookies) == ["sid=alpha-login"], "the copy was not written back after Chrome exited"
    assert len(_container(docker, computers["beta"]).chrome) == 1, "another bot's Chrome was stopped"
    sbx._stop_launched(keys["beta"])


def test_no_sync_while_the_containers_chrome_holds_the_copy_and_a_crash_is_reconciled(root, docker, computers):
    from tools import browser_session_sandbox as sbx
    master_cookies = root / "bot-computers" / "chrome-master" / "Default" / "Cookies"
    _write_cookies(master_cookies, "sid=v1")
    env = computers["alpha"]
    c = _container(docker, env)
    with bot(root, "alpha") as home:
        key = sbx._shared_key(env, sandbox_computer.CONTAINER_PROFILE)
        pid = sbx._spawn_owned(env, "pn", sandbox_computer.CONTAINER_PROFILE, key, {"DISPLAY": ":20"})
        copy_cookies = docker.chrome_of(c) / "Default" / "Cookies"
        _write_cookies(copy_cookies, "sid=in-use")
        _write_cookies(master_cookies, "sid=v2")

        sandbox_computer.prepare_launch(env)
        assert sandbox_computer.write_back_after_exit(env, wait=0.0) == []
        runtime.reconcile()
        assert _cookies(copy_cookies) == ["sid=in-use"] and _cookies(master_cookies) == ["sid=v2"]
        assert runtime.status().chrome == runtime.CHROME_RUNNING

        docker.chrome_exit(c, pid, clean=False)
        assert (home / "bot-desktop" / "browser-profile" / "SingletonLock").is_symlink()
        runtime.reconcile()
        assert not (home / "bot-desktop" / "browser-profile" / "SingletonLock").is_symlink()
        assert _cookies(master_cookies) == ["sid=in-use"]
        assert runtime.status().chrome == runtime.CHROME_STOPPED
        runtime.reconcile()
        assert _cookies(master_cookies) == ["sid=in-use"]


def test_the_screen_cap_counts_sandboxed_screens(root, docker, computers, monkeypatch):
    for name, env in computers.items():
        _mark_screen_up(docker, env, root / "profiles" / name)
    gamma_env = object()
    monkeypatch.setattr(runtime, "running_screen_sockets", set)
    with bot(root, "gamma"):
        monkeypatch.setattr(runtime, "max_screens", lambda: 2)
        with pytest.raises(runtime.ScreenCapReached, match="2 bot screens"):
            runtime._refuse_over_cap(None)
        monkeypatch.setattr(runtime, "_sandbox_env", lambda *, create=True: gamma_env)
        monkeypatch.setattr(sandbox_host, "published_env", lambda env, profile: {})
        monkeypatch.setattr(sandbox_host, "start", lambda *a, **k: pytest.fail("started past the cap"))
        with pytest.raises(runtime.ScreenCapReached):
            runtime.start()
        monkeypatch.setattr(runtime, "max_screens", lambda: 3)
        runtime._refuse_over_cap(None)
    _container(docker, computers["beta"]).running = False
    monkeypatch.setattr(sandbox_host, "_ALIVE_CACHE", {})
    with bot(root, "gamma"):
        monkeypatch.setattr(runtime, "max_screens", lambda: 2)
        runtime._refuse_over_cap(None)


def test_idle_stop_closes_the_containers_chrome_and_writes_its_copy_back(root, docker, computers, monkeypatch):
    from tools import browser_session_sandbox as sbx
    master_cookies = root / "bot-computers" / "chrome-master" / "Default" / "Cookies"
    env = computers["alpha"]
    c = _container(docker, env)
    monkeypatch.setattr(runtime, "idle_stop_seconds", lambda: 60.0)
    with bot(root, "alpha") as home:
        _mark_screen_up(docker, env, home)
        sbx._spawn_owned(env, "pn", sandbox_computer.CONTAINER_PROFILE, "k", {"DISPLAY": ":20"})
        _write_cookies(docker.chrome_of(c) / "Default" / "Cookies", "sid=idle-session")
        activity = home / "bot-desktop" / "activity"
        activity.touch()
        old = time.time() - 3600
        os.utime(activity, (old, old))
        assert runtime.stop_if_idle()
        assert not c.screen_up and not c.chrome
        assert not (home / "bot-desktop" / "sandbox.json").exists()
    assert _cookies(master_cookies) == ["sid=idle-session"]
    assert _container(docker, computers["beta"]).running


def test_restart_reconcile_removes_orphan_containers_and_unrecorded_screens(root, docker, computers):
    alpha = _container(docker, computers["alpha"])
    alpha.screen_up = True
    gone_home = root / "profiles" / "ghost"
    (gone_home / "bot-desktop" / "browser-profile").mkdir(parents=True)
    ghost = docker.add({sandbox_computer.CONTAINER_PROFILE: gone_home / "bot-desktop" / "browser-profile"})
    import shutil
    shutil.rmtree(gone_home)
    foreign_copy = root.parent / "elsewhere" / "bot-desktop" / "browser-profile"
    foreign_copy.mkdir(parents=True)
    foreign = docker.add({sandbox_computer.CONTAINER_PROFILE: foreign_copy})
    with bot(root, "alpha"):
        acted = sandbox_computer.reap_orphans()
        again = sandbox_computer.reap_orphans()
    assert ghost.cid not in docker.containers, "the deleted bot's container was left behind"
    assert foreign.cid in docker.containers, "a container of another Hermes root was touched"
    assert computers["beta"]._container_id in docker.containers
    assert set(acted) == {ghost.cid, alpha.cid} and not alpha.screen_up
    assert again == []


def test_reset_wipes_only_this_bots_container_state_and_copy(root, docker, computers):
    files = root / "bot-computers" / "files"
    files.mkdir(parents=True, exist_ok=True)
    (files / "shared.txt").write_text("keep", encoding="utf-8")
    master_cookies = root / "bot-computers" / "chrome-master" / "Default" / "Cookies"
    _write_cookies(master_cookies, "sid=master")
    copies = {}
    for name, env in computers.items():
        with bot(root, name):
            cp.seed(cp.copy_dir())
            _write_cookies(cp.copy_dir() / "Default" / "Cookies", f"sid={name}-unsynced")
            copies[name] = cp.copy_dir()
        _container(docker, env).xdg = True
    with bot(root, "alpha"):
        assert runtime.reset() == ["xdg", "browser-profile"]
        assert runtime.reset() == []
    assert copies["alpha"].is_dir() and not any(copies["alpha"].iterdir())
    assert _cookies(copies["beta"] / "Default" / "Cookies") == ["sid=beta-unsynced"]
    assert _container(docker, computers["beta"]).xdg
    assert _cookies(master_cookies) == ["sid=master"], "reset wrote the discarded copy back to master"
    assert (files / "shared.txt").read_text(encoding="utf-8") == "keep"


def test_status_reports_screen_chrome_sync_and_shared_files_for_a_sandboxed_screen(root, docker, computers):
    from tools import browser_session_sandbox as sbx
    env = computers["alpha"]
    with bot(root, "alpha") as home:
        before = runtime.status().as_dict()
        assert before["placement"] == "terminal:docker"
        assert before["screen"] == "stopped" and before["chrome"] == "stopped"
        assert before["profile_copy_synced_at"] is None
        assert before["shared_files_path"].endswith("bot-computers/files")
        _mark_screen_up(docker, env, home)
        sbx._spawn_owned(env, "pn", sandbox_computer.CONTAINER_PROFILE, "k", {"DISPLAY": ":20"})
        after = runtime.status().as_dict()
    assert after["screen"] == "running" and after["chrome"] == "running"
    assert after["profile_copy_synced_at"] > 0
    with bot(root, "beta"):
        theirs = runtime.status()
    assert theirs.chrome == "stopped" and theirs.shared_files_path == after["shared_files_path"]
