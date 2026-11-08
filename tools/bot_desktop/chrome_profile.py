from __future__ import annotations

import argparse
import contextlib
import enum
import hashlib
import json
import logging
import os
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence

from hermes_constants import get_default_hermes_root, get_hermes_home
from tools.bot_desktop import runtime

logger = logging.getLogger(__name__)


class Kind(enum.Enum):
    FILE = "file"
    SQLITE = "sqlite"
    TREE = "tree"


@dataclass(frozen=True)
class Item:
    rel: str
    kind: Kind


DURABLE: tuple[Item, ...] = (
    Item("Local State", Kind.FILE),
    Item("Default/Preferences", Kind.FILE),
    Item("Default/Secure Preferences", Kind.FILE),
    Item("Default/Bookmarks", Kind.FILE),
    Item("Default/Cookies", Kind.SQLITE),
    Item("Default/Network/Cookies", Kind.SQLITE),
    Item("Default/Login Data", Kind.SQLITE),
    Item("Default/Login Data For Account", Kind.SQLITE),
    Item("Default/Web Data", Kind.SQLITE),
    Item("Default/Local Storage", Kind.TREE),
    Item("Default/IndexedDB", Kind.TREE),
)

_SQLITE_SIDECARS = ("-journal", "-wal", "-shm")
_TREE_SKIP = frozenset({"LOCK", "LOG", "LOG.old"})
_SINGLETONS = ("SingletonLock", "SingletonSocket", "SingletonCookie", "DevToolsActivePort")
_TMP, _NEW, _OLD = ".hermes-tmp-", ".hermes-new-", ".hermes-old-"
MANIFEST = ".hermes-copy.json"
_CHROME_EXIT_GRACE_S = 5.0


class ChromeRunning(RuntimeError):
    pass


@dataclass
class Manifest:
    fingerprints: dict[str, str] = field(default_factory=dict)
    synced_at: Optional[float] = None


def computers_root() -> Path:
    return get_default_hermes_root(home=get_hermes_home()) / "bot-computers"


def master_dir() -> Path:
    return computers_root() / "chrome-master"


def shared_files_dir() -> Path:
    return computers_root() / "files"


def copy_dir() -> Path:
    return runtime.state_dir() / "browser-profile"


def is_managed_copy(user_data_dir: str | Path) -> bool:
    return os.path.realpath(user_data_dir) == os.path.realpath(copy_dir())


def display_path(path: Path) -> str:
    try:
        return "~/" + path.relative_to(Path.home()).as_posix()
    except ValueError:
        return path.as_posix()


def ensure_shared_files_dir() -> Path:
    path = shared_files_dir()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def chrome_running(udd: Path) -> bool:
    from tools.browser_launcher import chromium_running_on
    return chromium_running_on(str(udd))


def _read_manifest(copy: Path) -> Manifest:
    try:
        raw = json.loads((copy / MANIFEST).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return Manifest()
    prints = raw.get("fingerprints") if isinstance(raw, dict) else None
    synced = raw.get("synced_at") if isinstance(raw, dict) else None
    return Manifest(
        fingerprints={str(k): str(v) for k, v in prints.items()} if isinstance(prints, dict) else {},
        synced_at=float(synced) if isinstance(synced, (int, float)) and not isinstance(synced, bool) else None,
    )


def _write_manifest(copy: Path, manifest: Manifest) -> None:
    _write_atomic(copy / MANIFEST, json.dumps({"fingerprints": manifest.fingerprints,
                                                "synced_at": manifest.synced_at}).encode())


def synced_at() -> Optional[float]:
    return _read_manifest(copy_dir()).synced_at


def _tree_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink() and not _tree_skipped(p.name))


def _tree_skipped(name: str) -> bool:
    return name in _TREE_SKIP or name.startswith(".hermes-")


def _fingerprint(path: Path, kind: Kind) -> Optional[str]:
    if kind is Kind.TREE:
        if not path.is_dir():
            return None
        digest = hashlib.sha256()
        for f in _tree_files(path):
            st = f.stat()
            digest.update(f"{f.relative_to(path).as_posix()}\0{st.st_size}\0{st.st_mtime_ns}\n".encode())
        return digest.hexdigest()
    try:
        st = path.stat()
    except OSError:
        return None
    if not path.is_file():
        return None
    parts = [f"{st.st_size}:{st.st_mtime_ns}"]
    if kind is Kind.SQLITE:
        for side in _SQLITE_SIDECARS:
            with contextlib.suppress(OSError):
                s = path.with_name(path.name + side).stat()
                parts.append(f"{side}{s.st_size}:{s.st_mtime_ns}")
    return "|".join(parts)


def _fingerprints(base: Path) -> dict[str, str]:
    return {item.rel: fp for item in DURABLE if (fp := _fingerprint(base / item.rel, item.kind)) is not None}


def _fsync_file(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _fsync_dir(path: Path) -> None:
    if os.name == "nt":
        return
    with contextlib.suppress(OSError):
        _fsync_file(path)


def _scratch(dst: Path, marker: str) -> Path:
    return dst.with_name(f".{dst.name}{marker}{secrets.token_hex(4)}")


def _write_atomic(dst: Path, data: bytes) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _scratch(dst, _TMP)
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, dst)
    finally:
        tmp.unlink(missing_ok=True)
    _fsync_dir(dst.parent)


def _sqlite_backup(src: Path, dst: Path) -> None:
    with contextlib.closing(sqlite3.connect(str(src), timeout=5.0)) as source:
        with contextlib.closing(sqlite3.connect(str(dst), timeout=0.0)) as out:
            source.backup(out)


def _install_file(src: Path, dst: Path, kind: Kind) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = _scratch(dst, _TMP)
    try:
        if kind is Kind.SQLITE:
            _sqlite_backup(src, tmp)
        else:
            shutil.copy2(src, tmp)
        _fsync_file(tmp)
        if kind is Kind.SQLITE:
            for side in _SQLITE_SIDECARS:
                dst.with_name(dst.name + side).unlink(missing_ok=True)
        os.replace(tmp, dst)
    finally:
        tmp.unlink(missing_ok=True)
        if kind is Kind.SQLITE:
            for side in _SQLITE_SIDECARS:
                tmp.with_name(tmp.name + side).unlink(missing_ok=True)
    _fsync_dir(dst.parent)


def _install_tree(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    new, old = _scratch(dst, _NEW), _scratch(dst, _OLD)
    try:
        shutil.copytree(src, new, symlinks=False, ignore_dangling_symlinks=True,
                        ignore=lambda _d, names: [n for n in names if _tree_skipped(n)])
        for f in _tree_files(new):
            _fsync_file(f)
        if dst.exists():
            os.rename(dst, old)
        os.rename(new, dst)
    finally:
        shutil.rmtree(new, ignore_errors=True)
    shutil.rmtree(old, ignore_errors=True)
    _fsync_dir(dst.parent)


def _install(item: Item, src: Path, dst: Path) -> None:
    if item.kind is Kind.TREE:
        _install_tree(src, dst)
    else:
        _install_file(src, dst, item.kind)


def recover(base: Path) -> None:
    for parent in {(base / item.rel).parent for item in DURABLE}:
        try:
            entries = list(parent.iterdir())
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if not name.startswith("."):
                continue
            for marker in (_OLD, _NEW, _TMP):
                at = name.find(marker)
                if at <= 0:
                    continue
                target = parent / name[1:at]
                if marker == _OLD and not target.exists():
                    os.rename(entry, target)
                elif entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry, ignore_errors=True)
                else:
                    entry.unlink(missing_ok=True)
                break


@contextlib.contextmanager
def _master_locked():
    root = computers_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    master = master_dir()
    with runtime._flocked(root / "chrome-master.lock"):
        if chrome_running(master):
            raise ChromeRunning("a Chrome is running on the master profile; Hermes never syncs a live master")
        master.mkdir(exist_ok=True, mode=0o700)
        recover(master)
        yield master


def _refuse_if_running(copy: Path) -> None:
    if chrome_running(copy):
        raise ChromeRunning("this bot's Chrome is still running on its profile copy")


def is_dirty(copy: Optional[Path] = None) -> bool:
    copy = copy or copy_dir()
    if not copy.is_dir():
        return False
    recorded = _read_manifest(copy).fingerprints
    return any(fp != recorded.get(rel) for rel, fp in _fingerprints(copy).items())


def write_back(copy: Optional[Path] = None) -> list[str]:
    copy = copy or copy_dir()
    if not copy.is_dir():
        return []
    _refuse_if_running(copy)
    recover(copy)
    recorded = _read_manifest(copy).fingerprints
    written: list[str] = []
    with _master_locked() as master:
        for item in DURABLE:
            src = copy / item.rel
            fp = _fingerprint(src, item.kind)
            if fp is None or fp == recorded.get(item.rel):
                continue
            _install(item, src, master / item.rel)
            written.append(item.rel)
        _write_manifest(copy, Manifest(fingerprints=_fingerprints(copy), synced_at=time.time()))
    if written:
        logger.info("Bot Computer: wrote %s back to the master Chrome profile", ", ".join(written))
    return written


def seed(copy: Optional[Path] = None) -> list[str]:
    copy = copy or copy_dir()
    _refuse_if_running(copy)
    copy.mkdir(parents=True, exist_ok=True, mode=0o700)
    recover(copy)
    if is_dirty(copy):
        write_back(copy)
    refreshed: list[str] = []
    with _master_locked() as master:
        for item in DURABLE:
            src = master / item.rel
            if _fingerprint(src, item.kind) is None:
                continue
            _install(item, src, copy / item.rel)
            refreshed.append(item.rel)
        for name in _SINGLETONS:
            with contextlib.suppress(OSError):
                (copy / name).unlink()
        _write_manifest(copy, Manifest(fingerprints=_fingerprints(copy), synced_at=time.time()))
    return refreshed


def prepare_launch(copy: Path) -> Optional[str]:
    try:
        seed(copy)
    except (OSError, sqlite3.Error, ChromeRunning) as exc:
        logger.warning("Bot Computer: Chrome starts on its last copy; master refresh failed: %s", exc)
    return None


def write_back_if_idle(copy: Optional[Path] = None) -> list[str]:
    from tools.browser_launcher import shared_profile_lock
    copy = copy or copy_dir()
    if not is_dirty(copy):
        return []
    with shared_profile_lock(str(copy)):
        if chrome_running(copy):
            return []
        try:
            return write_back(copy)
        except (OSError, sqlite3.Error, ChromeRunning) as exc:
            logger.warning("Bot Computer: master write-back deferred: %s", exc)
            return []


def stop_chrome(copy: Optional[Path] = None) -> bool:
    import psutil
    from tools.browser_launcher import chromium_pid_on
    copy = copy or copy_dir()
    pid = chromium_pid_on(str(copy))
    if pid is None:
        return False
    try:
        proc = psutil.Process(pid)
        proc.terminate()
        proc.wait(_CHROME_EXIT_GRACE_S)
    except psutil.TimeoutExpired:
        with contextlib.suppress(psutil.Error):
            proc.kill()
            proc.wait(2.0)
    except psutil.Error:
        pass
    return True


def shutdown(*, write: bool = True) -> list[str]:
    copy = copy_dir()
    stop_chrome(copy)
    return write_back_if_idle(copy) if write else []


def run_dock_browser(argv: Sequence[str]) -> int:
    from agent.deadline import poll_until
    from tools.browser_launcher import shared_profile_lock
    copy = copy_dir()
    with shared_profile_lock(str(copy)):
        if not chrome_running(copy):
            prepare_launch(copy)
        proc = subprocess.Popen(list(argv), stdin=subprocess.DEVNULL)
        poll_until(lambda: proc.poll() is not None or (copy / "SingletonLock").is_symlink(), 10.0, 0.1)
    code = proc.wait()  # health: allow HX006 -- the dock browser runs as long as the human keeps it open
    write_back_if_idle(copy)
    return code


def main(args: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="bot-computer-chrome")
    sub = parser.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run")
    run.add_argument("argv", nargs=argparse.REMAINDER)
    ns = parser.parse_args(args)
    argv = ns.argv[1:] if ns.argv[:1] == ["--"] else ns.argv
    if not argv:
        parser.error("run needs a browser command after --")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s bot-computer-chrome %(message)s")
    return run_dock_browser(argv)


if __name__ == "__main__":
    sys.exit(main())
