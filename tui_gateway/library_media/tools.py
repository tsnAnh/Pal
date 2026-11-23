from __future__ import annotations

import contextlib
import os
import subprocess
import threading
from collections.abc import Iterator
from dataclasses import dataclass
from typing import BinaryIO

from hermes_platform.resolver import locate_command
from tui_gateway.contracts.library import LibraryPreviewReason as Reason

PREVIEW_CONCURRENCY = 2
PREVIEW_QUEUE_SECONDS = 5.0
TOOL_TIMEOUT_SECONDS = 10
TOOL_STDOUT_MAX_BYTES = 65_536
_LOCAL_BIN_DIRS = ("/opt/homebrew/bin", "/usr/local/bin")

_slots = threading.BoundedSemaphore(PREVIEW_CONCURRENCY)


class PreviewStopped(Exception):
    def __init__(self, reason: Reason):
        super().__init__(reason.value)
        self.reason = reason


@dataclass(frozen=True, slots=True)
class ToolInput:
    arg: str
    pass_fds: tuple[int, ...]


@contextlib.contextmanager
def preview_slot() -> Iterator[None]:
    if not _slots.acquire(timeout=PREVIEW_QUEUE_SECONDS):
        raise PreviewStopped(Reason.BUSY)
    try:
        yield
    finally:
        _slots.release()


def find_tool(name: str) -> str | None:
    found = locate_command(name, known_dirs=_LOCAL_BIN_DIRS).command
    return found[0] if found else None


def tool_input(handle: BinaryIO, path: str) -> ToolInput:
    """Hand the child the descriptor already vetted (regular file, no symlink followed) instead of the
    path, so a swap after the check cannot redirect it."""
    if os.name == "posix":
        return ToolInput(f"/dev/fd/{handle.fileno()}", (handle.fileno(),))
    return ToolInput(path, ())


def run_tool(argv: list[str], source: ToolInput) -> bytes:
    try:
        done = subprocess.run(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=TOOL_TIMEOUT_SECONDS, shell=False, check=False, pass_fds=source.pass_fds)
    except subprocess.TimeoutExpired as exc:
        raise PreviewStopped(Reason.TIMED_OUT) from exc
    except OSError as exc:
        raise PreviewStopped(Reason.RENDER_FAILED) from exc
    if done.returncode != 0 or len(done.stdout) > TOOL_STDOUT_MAX_BYTES:
        raise PreviewStopped(Reason.RENDER_FAILED)
    return done.stdout
