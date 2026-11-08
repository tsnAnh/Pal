"""A bot's computer when its screen runs inside the profile's Docker terminal sandbox.

Every bot keeps one container (its terminal sandbox, which also hosts its screen). Two host directories
are bind-mounted into it and nothing else of the Hermes root: the machine's shared files area at
``CONTAINER_FILES`` and this bot's own Chrome profile copy at ``CONTAINER_PROFILE``, which the container's
Chrome uses as its ``--user-data-dir``. The master profile never enters a container: ``chrome_profile``
refreshes the copy from master on the host before that Chrome starts and writes it back after it exits.
A Chrome inside the container is seen through the ``SingletonLock`` it leaves in the mounted copy (written
under the container's hostname); only the container can say whether that lock is stale.
"""
from __future__ import annotations

import contextlib
import json
import logging
import shutil
import sqlite3
import subprocess
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from hermes_constants import get_default_hermes_root, get_hermes_home, named_profile_is_deleted
from tools.bot_desktop import chrome_profile

logger = logging.getLogger(__name__)

CONTAINER_ROOT = "/bot-computer"
CONTAINER_FILES = f"{CONTAINER_ROOT}/files"
CONTAINER_PROFILE = f"{CONTAINER_ROOT}/browser-profile"
_CHROME_EXIT_GRACE_S = 5.0
_DOCKER_TIMEOUT_S = 15
_STALE, _ALIVE, _UNKNOWN = "stale", "alive", "unknown"


class UnsafeMount(RuntimeError):
    pass


@dataclass(frozen=True)
class MountedContainer:
    container_id: str
    copy_source: Path
    running: bool


def enabled() -> bool:
    """This profile's screen is placed in a Docker sandbox of its own (not a container shared across
    profiles by ``terminal.docker_shared_container_key``, where one copy cannot belong to one bot)."""
    from tools.bot_desktop import placement
    where = placement.resolve()
    if where.where != placement.TERMINAL or where.backend != "docker":
        return False
    from tools.terminal_tool import _get_env_config
    return not str(_get_env_config().get("docker_shared_container_key") or "").strip()


def _checked_dir(path: Path) -> Path:
    if path.is_symlink():
        raise UnsafeMount(f"{path} is a symlink; a bot's container only gets real directories")
    if ":" in str(path) or "," in str(path):
        raise UnsafeMount(f"{path} cannot be bind-mounted: its path holds ':' or ','")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    master = chrome_profile.master_dir().resolve()
    real = path.resolve()
    if real == master or master in real.parents or real in master.parents:
        raise UnsafeMount(f"{path} overlaps the master Chrome profile, which never enters a container")
    return path


def docker_volumes() -> list[str]:
    """``-v`` specs for this profile's terminal container: the shared files area and this bot's copy."""
    if not enabled():
        return []
    try:
        files = _checked_dir(chrome_profile.shared_files_dir())
        state = chrome_profile.copy_dir().parent
        if state.is_symlink():
            raise UnsafeMount(f"{state} is a symlink; a bot's container only gets real directories")
        copy = _checked_dir(chrome_profile.copy_dir())
    except (OSError, UnsafeMount) as exc:
        logger.warning("Bot Computer: the container starts without its Chrome copy and shared files: %s", exc)
        return []
    return [f"{files}:{CONTAINER_FILES}", f"{copy}:{CONTAINER_PROFILE}"]


def mounted(env: Any) -> bool:
    """``env`` is this profile's container and carries this bot's copy (its run args are the mounts it was
    created with; the reuse fingerprint keeps a re-attached container to the same ones)."""
    args = getattr(env, "_all_run_args", None) or ()
    return f"{chrome_profile.copy_dir()}:{CONTAINER_PROFILE}" in args


def active(env: Any) -> bool:
    """The container's Chrome runs on the mounted copy: mounted, and writable by the desktop user (a host
    whose uid the container user cannot write as keeps Chrome on the container's own profile)."""
    if env is None or not mounted(env):
        return False
    cached = getattr(env, "_bd_copy_writable", None)
    if cached is not None:
        return cached
    from tools.bot_desktop import sandbox_host
    from tools.environments import streams
    proc = streams.run_in(env, ["test", "-w", CONTAINER_PROFILE], user=sandbox_host._user_for(env), timeout=15)
    writable = proc.returncode == 0
    if not writable:
        logger.warning("Bot Computer: %s is not writable by the container's desktop user; its Chrome keeps the "
                       "container's own profile", CONTAINER_PROFILE)
    env._bd_copy_writable = writable
    return writable


_PROBE = ('h=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname); [ "$h" = "$1" ] || exit 5; '
          '[ -d /proc/"$2" ] || exit 1; '
          'tr "\\0" "\\n" < /proc/"$2"/cmdline 2>/dev/null | grep -qx -- "--user-data-dir=$3" || exit 1; exit 0')


_PROBE_STATES = {0: _ALIVE, 1: _STALE, 5: _STALE}


def _lock_state(env: Any) -> str:
    """Whether the Chrome named by the copy's lock still runs: asked of ``env``'s container, then of every
    other running container mounting this copy (after a restart nothing is registered in this process)."""
    from tools.browser_launcher import singleton_owner
    from tools.environments import streams
    owner = singleton_owner(str(chrome_profile.copy_dir()))
    if owner is None:
        return _STALE
    probe = ["bash", "-c", _PROBE, "hermes-chrome-probe", owner[0], str(owner[1]), CONTAINER_PROFILE]
    if env is not None:
        try:
            proc = streams.run_in(env, probe, timeout=15)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
            logger.debug("Bot Computer: Chrome lock probe failed: %s", exc)
            return _UNKNOWN
        if proc.returncode != 5:
            return _PROBE_STATES.get(proc.returncode, _UNKNOWN)
    others = _containers_mounting(chrome_profile.copy_dir())
    if others is None:
        return _UNKNOWN
    own = getattr(env, "_container_id", None)
    for container in others:
        if not container.running or container.container_id == own:
            continue
        proc = _docker("exec", container.container_id, *probe)
        state = _PROBE_STATES.get(proc.returncode, _UNKNOWN) if proc is not None else _UNKNOWN
        if state != _STALE:
            return state
    return _STALE


def release_stale_lock(env: Any) -> bool:
    """True when no Chrome holds this bot's copy any more (a stale lock left by a crashed or killed Chrome,
    or a container that is gone, is removed); False while the container's Chrome holds it or the container
    cannot answer."""
    from tools.browser_launcher import foreign_holder
    copy = chrome_profile.copy_dir()
    if foreign_holder(str(copy)) is None:
        return True
    if _lock_state(env) != _STALE:
        return False
    chrome_profile.clear_singletons(copy)
    return True


def prepare_launch(env: Any) -> None:
    """Refresh this bot's copy from master before the container's Chrome starts on it. Never while a Chrome
    holds it; a failed refresh starts Chrome on the last copy (``chrome_profile.prepare_launch``)."""
    from tools.browser_launcher import shared_profile_lock
    copy = chrome_profile.copy_dir()
    with shared_profile_lock(str(copy)):
        if release_stale_lock(env):
            chrome_profile.prepare_launch(copy)


def _sync_idle_copy(env: Any, *, refresh: bool) -> list[str]:
    from tools.browser_launcher import shared_profile_lock
    copy = chrome_profile.copy_dir()
    if not copy.is_dir():
        return []
    with shared_profile_lock(str(copy)):
        if not release_stale_lock(env) or chrome_profile.chrome_running(copy):
            return []
        try:
            if chrome_profile.is_dirty(copy):
                return chrome_profile.write_back(copy)
            if refresh and chrome_profile.master_changed_since(chrome_profile.synced_at()):
                chrome_profile.seed(copy)
        except (OSError, sqlite3.Error, chrome_profile.ChromeRunning) as exc:
            logger.warning("Bot Computer: profile copy sync deferred: %s", exc)
    return []


def write_back_after_exit(env: Any, *, wait: float = _CHROME_EXIT_GRACE_S) -> list[str]:
    """Write the copy back once the container's Chrome let go of it (its lock gone or proven stale)."""
    from agent.deadline import poll_until
    from tools.browser_launcher import foreign_holder
    copy = chrome_profile.copy_dir()
    poll_until(lambda: foreign_holder(str(copy)) is None, wait, 0.25)
    return _sync_idle_copy(env, refresh=False)


_STOP_CHROME = (
    'pids=$(pgrep -f -- "--user-data-dir=$1" 2>/dev/null); [ -n "$pids" ] || exit 0; '
    'kill -TERM $pids 2>/dev/null; for _ in $(seq 1 $2); do sleep 0.25; '
    'pgrep -f -- "--user-data-dir=$1" >/dev/null 2>&1 || exit 0; done; '
    'kill -KILL $(pgrep -f -- "--user-data-dir=$1") 2>/dev/null; exit 0'
)


def stop_chrome(env: Any) -> None:
    from tools.bot_desktop import sandbox_host
    from tools.environments import streams
    try:
        streams.run_in(env, ["bash", "-c", _STOP_CHROME, "hermes-chrome-stop", CONTAINER_PROFILE,
                             str(int(_CHROME_EXIT_GRACE_S / 0.25))], user=sandbox_host._user_for(env), timeout=30)
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        logger.warning("Bot Computer: could not stop the container's Chrome: %s", exc)


def shutdown(env: Any, *, write: bool) -> None:
    """Screen stop: close the container's Chrome on this bot's copy, then write the copy back."""
    if env is not None and active(env):
        stop_chrome(env)
    if write:
        write_back_after_exit(env, wait=0.0)
    else:
        release_stale_lock(env)


def reconcile(env: Any, *, screen_up: bool) -> None:
    """Fallback for Chrome exits nobody saw (a human closing it in the dock, a crash): write a finished
    copy back, and while the screen is up keep the idle copy fresh from master so a dock launch starts
    from current data."""
    if not chrome_profile.copy_dir().is_dir():
        return
    _sync_idle_copy(env, refresh=screen_up)


def reset_copy() -> list[str]:
    """Empty this bot's copy in place (the directory stays: it is the source of the container's bind mount).
    Refused by the caller while a Chrome holds it."""
    copy = chrome_profile.copy_dir()
    removed: list[str] = []
    if copy.is_dir() and any(copy.iterdir()):
        for entry in copy.iterdir():
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry)
            else:
                entry.unlink()
        removed.append("browser-profile")
    return removed


def status_fields() -> dict[str, object]:
    if not enabled():
        return {}
    copy = chrome_profile.copy_dir()
    from tools.bot_desktop import runtime
    return {
        "chrome": runtime.CHROME_RUNNING if chrome_profile.chrome_running(copy) else runtime.CHROME_STOPPED,
        "profile_copy_synced_at": chrome_profile.synced_at(),
        "shared_files_path": chrome_profile.display_path(chrome_profile.shared_files_dir()),
    }


def _hermes_root() -> Path:
    return get_default_hermes_root(home=get_hermes_home())


def machine_homes() -> list[Path]:
    root = _hermes_root()
    homes = [root]
    with contextlib.suppress(OSError):
        homes.extend(d for d in sorted((root / "profiles").iterdir())
                     if d.is_dir() and not d.is_symlink() and not named_profile_is_deleted(d))
    return homes


def running_sandbox_screens(*, exclude: Optional[Path] = None) -> int:
    """Sandboxed screens up on this machine, by each profile's start marker and its container's state."""
    from tools.bot_desktop import sandbox_host
    count = 0
    for home in machine_homes():
        if exclude is not None and home.resolve() == exclude.resolve():
            continue
        try:
            marker = json.loads((home / "bot-desktop" / "sandbox.json").read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        if isinstance(marker, dict) and marker and sandbox_host.marker_sandbox_alive(marker):
            count += 1
    return count


def _docker(*args: str) -> Optional[subprocess.CompletedProcess]:
    from tools.environments.docker import find_docker
    exe = find_docker()
    if exe is None:
        return None
    try:
        return subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=_DOCKER_TIMEOUT_S,
                              check=False, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.debug("Bot Computer: docker %s failed: %s", args[:1], exc)
        return subprocess.CompletedProcess([exe, *args], -1, "", str(exc))


def _mounted_containers() -> Optional[list[MountedContainer]]:
    """Hermes containers carrying a bot copy; [] without a docker CLI, None when docker cannot answer."""
    listed = _docker("ps", "-a", "-q", "--no-trunc", "--filter", "label=hermes-agent=1",
                     "--filter", f"volume={CONTAINER_PROFILE}")
    if listed is None:
        return []
    if listed.returncode != 0:
        logger.debug("Bot Computer: docker ps failed: %s", (listed.stderr or "")[-300:])
        return None
    found: list[MountedContainer] = []
    for cid in listed.stdout.split():
        inspected = _docker("inspect", "-f", "{{json .Mounts}} {{.State.Running}}", cid)
        if inspected is None or inspected.returncode != 0:
            continue
        mounts_json, _, running = inspected.stdout.strip().rpartition(" ")
        try:
            mounts = json.loads(mounts_json)
        except ValueError:
            continue
        for mount in mounts if isinstance(mounts, list) else []:
            if isinstance(mount, dict) and mount.get("Destination") == CONTAINER_PROFILE and mount.get("Source"):
                found.append(MountedContainer(cid, Path(mount["Source"]), running == "true"))
    return found


def _containers_mounting(copy: Path) -> Optional[list[MountedContainer]]:
    containers = _mounted_containers()
    if containers is None:
        return None
    target = copy.resolve()
    return [c for c in containers if c.copy_source.resolve() == target]


def _owning_home(copy_source: Path) -> Optional[Path]:
    if copy_source.name != "browser-profile" or copy_source.parent.name != "bot-desktop":
        return None
    home = copy_source.parent.parent.resolve()
    root = _hermes_root().resolve()
    if home == root or home.parent == root / "profiles":
        return home
    return None


def _exec_as_desktop_user(container_id: str, script: str, *args: str) -> Optional[subprocess.CompletedProcess]:
    from tools.bot_desktop import sandbox_host
    proc = _docker("exec", "-u", sandbox_host.DESKTOP_USER, container_id, "bash", "-c", script, *args)
    if proc is not None and proc.returncode in (125, 126) and "user" in (proc.stderr or "").lower():
        proc = _docker("exec", container_id, "bash", "-c", script, *args)
    return proc


_NOTHING_TO_STOP_RC = 3
_STOP_ORPHAN_SCREENS = (
    'found=; for f in "$1"/hermes-bot-desktop/*/launcher.pid; do [ -s "$f" ] || continue; p=$(cat "$f"); '
    '[ -n "$p" ] && kill -0 "$p" 2>/dev/null && { found=1; kill -TERM -- -"$p" 2>/dev/null; }; rm -f "$f"; done; '
    'pids=$(pgrep -f -- "--user-data-dir=$2" 2>/dev/null); '
    '[ -z "$pids" ] || { found=1; kill -TERM $pids 2>/dev/null; }; '
    f'[ -n "$found" ] || exit {_NOTHING_TO_STOP_RC}'
)


def reap_orphans() -> list[str]:
    """Restart reconcile across the machine's bot containers. A container whose bot is gone (profile deleted
    or tombstoned, its copy removed) is removed; a running container of a live bot that has no screen
    recorded loses the screen processes and Chrome it still runs. Only containers carrying a bot copy of
    THIS Hermes root are considered. Returns the ids acted on."""
    from tools.bot_desktop import runtime
    acted: list[str] = []
    for container in _mounted_containers() or []:
        home = _owning_home(container.copy_source)
        if home is None:
            continue
        gone = (not container.copy_source.is_dir() or not home.is_dir()
                or (home != _hermes_root().resolve() and named_profile_is_deleted(home)))
        if gone:
            removed = _docker("rm", "-f", container.container_id)
            if removed is not None and removed.returncode == 0:
                logger.info("Bot Computer: removed container %s of a bot that no longer exists",
                            container.container_id[:12])
                acted.append(container.container_id)
            continue
        if not container.running or (home / "bot-desktop" / "sandbox.json").exists():
            continue
        with runtime._flocked(home / "bot-desktop" / "start.lock"):
            if (home / "bot-desktop" / "sandbox.json").exists():
                continue
            stopped = _exec_as_desktop_user(container.container_id, _STOP_ORPHAN_SCREENS, "hermes-orphan-stop",
                                            "/tmp", CONTAINER_PROFILE)  # no-tmp: ok — sandbox-side temp dir
        if stopped is not None and stopped.returncode == 0:
            logger.info("Bot Computer: stopped an unrecorded screen in container %s", container.container_id[:12])
            acted.append(container.container_id)
    return acted


_reaped_once = False
_reap_lock = threading.Lock()


def reap_orphans_once() -> None:
    """The first reconcile of a process sweeps once, off the caller's thread: a wedged Docker daemon answers
    each call only at its timeout, which must not stall the display watcher."""
    global _reaped_once
    with _reap_lock:
        if _reaped_once:
            return
        _reaped_once = True
    from agent.memory_provider import spawn_context_thread
    spawn_context_thread(_reap_logged, name="bot-computer-orphan-sweep").start()


def _reap_logged() -> None:
    try:
        reap_orphans()
    except Exception:
        logger.warning("Bot Computer: orphan container sweep failed", exc_info=True)
