from __future__ import annotations

import hashlib
import os
import shutil
from pathlib import Path

VOLATILE_FILES = frozenset({".usage.json", ".curator_state"})
VOLATILE_DIRS = (".locks", ".hub/index-cache")
_CHUNK = 1 << 20


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def link_target(path: Path) -> str:
    return os.path.abspath(os.path.join(path.parent, os.readlink(path)))


def entry_digest(path: Path) -> str:
    if path.is_symlink():
        return f"link:{link_target(path)}"
    return file_digest(path)


def is_volatile(rel: str) -> bool:
    return rel in VOLATILE_FILES or any(rel == d or rel.startswith(f"{d}/") for d in VOLATILE_DIRS)


def tree_snapshot(root: Path, *, skip_volatile: bool = True) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    if not root.is_dir():
        return snapshot
    for current, dirs, files in os.walk(root, followlinks=False):
        base = Path(current)
        rel_base = base.relative_to(root).as_posix()
        for name in sorted([*dirs, *files]):
            path = base / name
            rel = name if rel_base == "." else f"{rel_base}/{name}"
            if skip_volatile and is_volatile(rel):
                continue
            if path.is_symlink() or not path.is_dir():
                snapshot[rel] = entry_digest(path)
            else:
                snapshot.setdefault(f"{rel}/", "dir")
    return snapshot


def copy_entry(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dest.unlink(missing_ok=True)
        os.symlink(link_target(src), dest)
    elif src.is_dir():
        copy_tree(src, dest)
    else:
        shutil.copy2(src, dest)


def copy_tree(src: Path, dest: Path, *, overwrite: bool = True) -> None:
    for current, dirs, files in os.walk(src, followlinks=False):
        base = Path(current)
        target = dest / base.relative_to(src)
        target.mkdir(parents=True, exist_ok=True)
        for name in [*dirs, *files]:
            path, out = base / name, target / name
            if not overwrite and (out.exists() or out.is_symlink()):
                continue
            if path.is_symlink():
                out.unlink(missing_ok=True)
                os.symlink(link_target(path), out)
            elif path.is_file():
                shutil.copy2(path, out)


def tree_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_dir():
        return entry_digest(path)
    return hashlib.sha256(repr(sorted(tree_snapshot(path, skip_volatile=False).items())).encode()).hexdigest()


def carry_tree(src: Path, dest: Path, taken: dict[str, str], owner: str) -> dict[str, str]:
    published: dict[str, str] = {}
    if not src.is_dir():
        return published
    for child in sorted(src.iterdir()):
        digest = tree_digest(child)
        final = child.name
        counter = 2
        while final in taken and taken[final] != digest:
            final = f"{owner}-{child.name}" if counter == 2 else f"{owner}-{counter}-{child.name}"
            counter += 1
        if final not in taken:
            copy_entry(child, dest / final)
            taken[final] = digest
        if (dest / final).is_symlink() or not (dest / final).is_dir():
            published[final] = entry_digest(dest / final)
        else:
            published.update({f"{final}/{rel}": d for rel, d in tree_snapshot(dest / final, skip_volatile=False).items()
                              if not rel.endswith("/")})
    return published


def is_cache_name(name: str) -> bool:
    return name in ("__pycache__", ".DS_Store") or name.endswith((".pyc", ".pyo"))


def remove_matching(live: Path, reference: Path, rel: str, leftovers: list[str]) -> None:
    if is_cache_name(live.name):
        remove_volatile(live)
        return
    if live.is_symlink():
        if reference.is_symlink() and link_target(live) == link_target(reference):
            live.unlink()
        else:
            leftovers.append(rel)
        return
    if live.is_dir():
        for child in sorted(live.iterdir()):
            remove_matching(child, reference / child.name, f"{rel}/{child.name}", leftovers)
        try:
            live.rmdir()
        except OSError:
            pass
        return
    if live.exists():
        if reference.is_file() and not reference.is_symlink() and file_digest(live) == file_digest(reference):
            live.unlink()
        else:
            leftovers.append(rel)


def remove_volatile(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path, ignore_errors=True)


def prune_empty_parents(path: Path, stop: Path) -> None:
    parent = path.parent
    while parent != stop and parent.is_dir() and not any(parent.iterdir()):
        parent.rmdir()
        parent = parent.parent
