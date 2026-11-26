from __future__ import annotations

import contextlib
import functools
import hashlib
import logging
import mimetypes
import os
import re
import stat
import threading
from collections import OrderedDict
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO
from urllib.parse import unquote

from hermes_constants import (
    get_default_hermes_root,
    get_hermes_home,
    get_real_home,
    get_routing_process_hermes_home,
)
from tools.terminal_scope import build_profile_terminal_scope
from tui_gateway.contracts.library import LibraryAssetKind
from tui_gateway.launch_profile_policy import launch_terminal_backend
from tui_gateway.library_assets import (
    CHUNK_MAX_BYTES,
    DOWNLOAD_MAX_BYTES,
    AssetNotAllowed,
    AssetTooLarge,
    AssetUnavailable,
    OpenedAsset,
)
from tui_gateway.library_media import HEAD_BYTES, is_utf8_text, sniff

try:
    import fcntl
except ImportError:
    fcntl = None

logger = logging.getLogger(__name__)

WORKSPACE_FILE_ROOTS = ("workspace",)
MAX_REFS_PER_MESSAGE = 20
PATH_CHECK_BUDGET = 500
SMALL_BINARY_MAX_BYTES = CHUNK_MAX_BYTES
_REF_REGISTRY_MAX = 20_000
_PATH_MAX_CHARS = 1024

_GONE = "This item is no longer available."
_REFUSED = "This item is not available to download."

_SECRET_FOLDERS = frozenset({
    ".ssh", ".gnupg", ".aws", ".azure", ".gcloud", ".kube", ".docker", ".git", "keychains", "mcp-tokens",
    "private_keys",
})
_SECRET_NAMES = frozenset({"auth.json", "auth.lock"})
_SECRET_SUFFIXES = (
    ".env", ".pem", ".key", ".p12", ".pfx", ".ppk", ".jks", ".keystore", ".keychain", ".keychain-db", ".kdbx",
)
_SECRET_WORDS = (
    r"(?:credentials?|tokens?|secrets?|passwords?|keychains?|api[._ -]?keys?|private[._ -]?keys?|netrc|kubeconfig"
    r"|htpasswd|client_secret.*|id_(?:rsa|dsa|ecdsa|ed25519))")
_SECRET_ENDING_RE = re.compile(rf"(?:.*[._ -])?{_SECRET_WORDS}")
_SECRET_SEGMENT_RE = re.compile(rf"(?<![a-z0-9]){_SECRET_WORDS}(?![a-z0-9])")
_BACKUP_SUFFIX_RE = re.compile(r"(?:\.(?:bak|backup|old|orig|save|copy)|~)+$")
_NOTE_SUFFIXES = (".md", ".markdown", ".txt")
_PRIVATE_KEY_RE = re.compile(rb"-----BEGIN [A-Z0-9 ]{0,64}PRIVATE KEY")
_SCAN_BLOCK_BYTES = 1024 * 1024
_SCAN_OVERLAP_BYTES = 128
_MACOS_DATA_VOLUME = "/System/Volumes/Data"

_OPEN_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)

_FENCE_RE = re.compile(r"^[ \t]*(```|~~~)[^\n]*$.*?(?:^[ \t]*\1[^\n]*$|\Z)", re.MULTILINE | re.DOTALL)
_BARE = r"(?<![\w/.~$}\\-])(?P<bare>(?:file://)?/[^\s`\"'<>|]+)"
_BARE_RE = re.compile(_BARE)
_MENTION_RE = re.compile(
    r"\]\(\s*<(?P<angle>(?:file://)?/[^<>\n]+)>"
    r"|\]\(\s*(?P<link>(?:file://)?/[^)\s]+)"
    r"|`(?P<code>(?:file://)?/[^`\n]+)`"
    "|" + _BARE)
_LINE_SUFFIX_RE = re.compile(r"(?::\d+){1,2}$|#L\d+(?:-L?\d+)?$")
_SENTENCE_MARKS = ".,;:!?*_~…。、，”’»›"
_OPENERS = {")": "(", "]": "[", "}": "{"}


@dataclass(frozen=True, slots=True)
class WorkspaceRoots:
    home: str
    real: tuple[str, ...] = ()
    spellings: tuple[str, ...] = ()
    denied: frozenset[tuple[int, int]] = frozenset()

    def anchor(self, raw: str) -> str | None:
        return next((spelling for spelling in self.spellings if raw.startswith(spelling + os.sep)), None)


@dataclass(frozen=True, slots=True)
class Vetted:
    home: str
    root: str
    path: str
    identity: tuple[int, int]
    size: int
    mtime_ns: int


def _within(path: str, root: str) -> bool:
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def _is_utf8_name(path: str) -> bool:
    try:
        path.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _belongs_to_another_profile(path: str, home: str, hermes_root: str) -> bool:
    if not _within(path, hermes_root):
        return False
    if not _within(path, home):
        return True
    inside = Path(path).relative_to(home).parts
    return home == hermes_root and bool(inside) and inside[0].casefold() == "profiles"


def _on_disk_folder(path: str | os.PathLike) -> str:
    resolved = os.path.realpath(path)
    if not hasattr(fcntl, "F_GETPATH"):
        return resolved
    descriptor = os.open(resolved, _OPEN_FLAGS | os.O_DIRECTORY)
    try:
        named = fcntl.fcntl(descriptor, fcntl.F_GETPATH, bytes(1024))
    finally:
        os.close(descriptor)
    return os.fsdecode(named.partition(b"\0")[0])


def _protected_folder(path: str | os.PathLike) -> str:
    try:
        return _on_disk_folder(path)
    except OSError:
        return os.path.realpath(path)


def _identity(path: str | os.PathLike) -> tuple[int, int] | None:
    try:
        status = os.stat(path)
    except (OSError, ValueError):
        return None
    return status.st_dev, status.st_ino


def _denied_identities() -> frozenset[tuple[int, int]]:
    from gateway.platforms.base import delivery_denied_paths
    return frozenset(filter(None, map(_identity, delivery_denied_paths())))


def _lies_in_denied(path: str, denied: frozenset[tuple[int, int]]) -> bool:
    target = Path(path)
    return any(_identity(step) in denied for step in (target, *target.parents))


def _host_cwd(profile_home: str | os.PathLike) -> str | None:
    overlay = None
    if os.path.realpath(get_routing_process_hermes_home()) == os.path.realpath(profile_home):
        backend = launch_terminal_backend()
        overlay = {"TERMINAL_ENV": backend} if backend else None
    try:
        policy = build_profile_terminal_scope(profile_home, env_overlay=overlay)
    except Exception:
        logger.warning("workspace files are off: the terminal policy of %s cannot be built", profile_home, exc_info=True)
        return None
    if policy.get("TERMINAL_ENV", "local").strip().lower() not in ("", "local"):
        return ""
    return os.path.expanduser(policy.get("TERMINAL_CWD", "").strip())


def workspace_roots(profile_home: str | os.PathLike) -> WorkspaceRoots:
    if not os.path.isabs(profile_home):
        return WorkspaceRoots(str(profile_home))
    home = _protected_folder(profile_home)
    configured = _host_cwd(profile_home)
    if configured is None:
        return WorkspaceRoots(home)
    owner = Path(home)
    default_root = _protected_folder(get_default_hermes_root())
    hermes_roots = {default_root, str(owner.parent.parent if owner.parent.name == "profiles" else owner)}
    never_inside_a_root = {
        home, default_root, _MACOS_DATA_VOLUME,
        _protected_folder(Path.home()), _protected_folder(get_real_home() or Path.home()),
    }
    real: list[str] = []
    spellings: list[str] = []
    for candidate in (*(os.path.join(profile_home, name) for name in WORKSPACE_FILE_ROOTS), configured):
        if not os.path.isabs(candidate) or not os.path.isdir(candidate):
            continue
        try:
            root = _on_disk_folder(candidate)
        except OSError:
            continue
        if any(_within(protected, root) for protected in never_inside_a_root):
            continue
        if any(_belongs_to_another_profile(root, home, hermes_root) for hermes_root in hermes_roots):
            continue
        real.append(root)
        spellings += [os.path.normpath(candidate), root]
    return WorkspaceRoots(home, tuple(dict.fromkeys(real)), tuple(dict.fromkeys(spellings)), _denied_identities())


def _names_a_secret(relative: str) -> bool:
    parts = Path(relative).parts
    if not parts:
        return True
    *folders, name = parts
    if any(folder.startswith(".") for folder in folders):
        return True
    if name.startswith(".") and not name.casefold().endswith(_NOTE_SUFFIXES):
        return True
    originals = [_BACKUP_SUFFIX_RE.sub("", part.casefold()) for part in parts]
    leaf = originals[-1]
    if leaf.startswith(".env") or leaf in _SECRET_NAMES or leaf.endswith(_SECRET_SUFFIXES):
        return True
    if any(_SECRET_ENDING_RE.fullmatch(os.path.splitext(part)[0]) for part in originals):
        return True
    return not leaf.endswith(_NOTE_SUFFIXES) and any(_SECRET_SEGMENT_RE.search(part) for part in originals)


def confine(roots: WorkspaceRoots, raw: str) -> Vetted:
    anchor = roots.anchor(raw)
    if anchor is None:
        raise AssetNotAllowed(_REFUSED)
    try:
        target = os.path.realpath(raw)
    except (OSError, ValueError) as exc:
        raise AssetUnavailable(_GONE) from exc
    root = next((root for root in roots.real if target != root and _within(target, root)), None)
    if (root is None
            or not _is_utf8_name(target)
            or any(part.casefold() in _SECRET_FOLDERS for part in Path(target).parts)
            or _names_a_secret(os.path.relpath(target, root))
            or _names_a_secret(os.path.relpath(os.path.normpath(raw), anchor))
            or _lies_in_denied(target, roots.denied)):
        raise AssetNotAllowed(_REFUSED)
    try:
        status = os.lstat(target)
    except (OSError, ValueError) as exc:
        raise AssetUnavailable(_GONE) from exc
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
        raise AssetNotAllowed(_REFUSED)
    return Vetted(roots.home, root, target, (status.st_dev, status.st_ino), status.st_size, status.st_mtime_ns)


def _open_beneath(root: str, path: str) -> int:
    if os.open not in os.supports_dir_fd:
        return os.open(path, _OPEN_FLAGS)
    *folders, name = Path(os.path.relpath(path, root)).parts
    current = os.open(root, _OPEN_FLAGS | os.O_DIRECTORY)
    try:
        for folder in folders:
            deeper = os.open(folder, _OPEN_FLAGS | os.O_DIRECTORY, dir_fd=current)
            os.close(current)
            current = deeper
        return os.open(name, _OPEN_FLAGS, dir_fd=current)
    finally:
        os.close(current)


def _offered_mime(name: str, head: bytes, size: int) -> str:
    sniffed = sniff(head, name)
    readable = is_utf8_text(head) or (
        sniffed.previewable and sniffed.kind in (LibraryAssetKind.IMAGE, LibraryAssetKind.PDF))
    if not readable and size > SMALL_BINARY_MAX_BYTES:
        raise AssetNotAllowed(_REFUSED)
    return mimetypes.guess_type(name)[0] or sniffed.mime


@contextlib.contextmanager
def _same_file(vetted: Vetted) -> Iterator[tuple[BinaryIO, os.stat_result]]:
    try:
        descriptor = _open_beneath(vetted.root, vetted.path)
    except OSError as exc:
        raise AssetUnavailable(_GONE) from exc
    try:
        status = os.fstat(descriptor)
        if ((status.st_dev, status.st_ino) != vetted.identity
                or not stat.S_ISREG(status.st_mode) or status.st_nlink != 1):
            raise AssetNotAllowed(_REFUSED)
        if (status.st_size, status.st_mtime_ns) != (vetted.size, vetted.mtime_ns):
            raise AssetUnavailable(_GONE)
        handle = os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise
    with handle:
        yield handle, status


@functools.lru_cache(maxsize=4096)
def _holds_a_private_key(vetted: Vetted) -> bool:
    overlap = b""
    with _same_file(vetted) as (handle, _):
        while block := handle.read(_SCAN_BLOCK_BYTES):
            if _PRIVATE_KEY_RE.search(overlap + block):
                return True
            overlap = block[-_SCAN_OVERLAP_BYTES:]
    return False


@contextlib.contextmanager
def open_vetted(vetted: Vetted) -> Iterator[tuple[OpenedAsset, str]]:
    if vetted.size > DOWNLOAD_MAX_BYTES:
        raise AssetTooLarge(vetted.size, DOWNLOAD_MAX_BYTES)
    with _same_file(vetted) as (handle, status):
        path = Path(vetted.path)
        mime = _offered_mime(path.name, handle.read(HEAD_BYTES), status.st_size)
        if _holds_a_private_key(vetted):
            raise AssetNotAllowed(_REFUSED)
        handle.seek(0)
        yield OpenedAsset(path, handle, status), mime


@functools.lru_cache(maxsize=4096)
def _offered_version(vetted: Vetted) -> str | None:
    try:
        with open_vetted(vetted) as (_, mime):
            return mime
    except (AssetNotAllowed, AssetTooLarge):
        return None


_refs: OrderedDict[tuple[str, str], str] = OrderedDict()
_refs_lock = threading.Lock()


def _issue_ref(vetted: Vetted) -> str:
    version = "\0".join((vetted.home, vetted.path, str(vetted.mtime_ns)))
    ref = hashlib.sha256(version.encode("utf-8", "surrogateescape")).hexdigest()[:32]
    with _refs_lock:
        _refs[vetted.home, ref] = vetted.path
        _refs.move_to_end((vetted.home, ref))
        while len(_refs) > _REF_REGISTRY_MAX:
            _refs.popitem(last=False)
    return ref


@contextlib.contextmanager
def open_ref(profile_home: str | os.PathLike, ref: str) -> Iterator[OpenedAsset]:
    roots = workspace_roots(profile_home)
    with _refs_lock:
        path = _refs.get((roots.home, ref))
    if path is None:
        raise AssetUnavailable(_REFUSED)
    vetted = confine(roots, path)
    if vetted.path != path:
        raise AssetNotAllowed(_REFUSED)
    with open_vetted(vetted) as (opened, _):
        yield opened


def _as_path(token: str, *, bare: bool, encoded: bool) -> str:
    if len(token) > _PATH_MAX_CHARS:
        return ""
    if bare:
        while token and (token[-1] in _SENTENCE_MARKS or (
                token[-1] in _OPENERS and token.count(token[-1]) > token.count(_OPENERS[token[-1]]))):
            token = token[:-1]
    token = _LINE_SUFFIX_RE.sub("", token)
    if token.startswith("file://"):
        token, encoded = token.removeprefix("file://"), True
    return unquote(token) if encoded else token


def mentioned_paths(text: str) -> Iterator[str]:
    for match in _MENTION_RE.finditer(_FENCE_RE.sub("\n", text)):
        kind = match.lastgroup
        token = match[kind]
        yield _as_path(token, bare=kind == "bare", encoded=kind in ("angle", "link"))
        if kind == "code" and " " in token:
            for inner in _BARE_RE.finditer(" " + token.partition(" ")[2]):
                yield _as_path(inner["bare"], bare=True, encoded=False)


def _offer(roots: WorkspaceRoots, raw: str) -> tuple[str, dict] | None:
    try:
        vetted = confine(roots, raw)
        mime = _offered_version(vetted)
    except (AssetNotAllowed, AssetUnavailable, OSError):
        return None
    if mime is None:
        return None
    return vetted.path, {
        "ref": _issue_ref(vetted), "name": os.path.basename(vetted.path), "mime": mime, "size": vetted.size}


def annotate_file_refs(messages: list[dict], profile_home: str | os.PathLike | None) -> list[dict]:
    mentioning = [m for m in messages if m.get("role") == "assistant" and "/" in (m.get("text") or "")]
    if not mentioning:
        return messages
    roots = workspace_roots(profile_home or get_hermes_home())
    if not roots.real:
        return messages
    checked: dict[str, tuple[str, dict] | None] = {}
    for message in reversed(mentioning):
        found: dict[str, dict] = {}
        for raw in mentioned_paths(message["text"]):
            if len(found) >= MAX_REFS_PER_MESSAGE:
                break
            if roots.anchor(raw) is None:
                continue
            if raw not in checked:
                if len(checked) >= PATH_CHECK_BUDGET:
                    continue
                checked[raw] = _offer(roots, raw)
            if (offer := checked[raw]) is not None:
                found.setdefault(offer[0], offer[1])
        if found:
            message["file_refs"] = list(found.values())
    return messages
