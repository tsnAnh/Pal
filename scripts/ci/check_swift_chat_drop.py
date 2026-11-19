#!/usr/bin/env python3
"""Fail when the Mac chat pane has more than one file and image drop target.

Dropping images and files into a bot chat goes through ONE target: the shared
``attachmentIntake(intake:)`` modifier (``App/Platform/AttachmentIntake.swift``) applied once
to the whole chat pane in ``ChatView.swift``. Two nested targets fight over the same drag
and drop on different handler paths, so the chat pane files (``ChatView.swift``, ``Chat/*.swift``,
the Mac chat shell ``Mac/MacChat.swift`` and ``Mac/MacShell.swift``) may not call ``.onDrop(`` or
``.dropDestination(`` themselves, and may call ``attachmentIntake(`` at most once in total. Paste
is not a drop target: ``attachmentPaste(`` stays on the composer. A justified exception carries
``drop-target: ok`` on the line.

Run: python scripts/ci/check_swift_chat_drop.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "drop-target: ok"
PANE_FILES = ("App/ChatView.swift", "App/Mac/MacChat.swift", "App/Mac/MacShell.swift")
PANE_DIRS = ("App/Chat",)
RAW_TARGET = re.compile(r"\.(?:onDrop|dropDestination)\(")
SHARED_CALL = re.compile(r"(?<![A-Za-z0-9_])\.attachmentIntake\(")
FIX = ("Keep one drop target: apply the shared attachmentIntake(intake:) modifier once, to the whole chat pane in "
       "ChatView.swift, and remove the other. Composer paste uses attachmentPaste(intake:).")


def pane_files(root: Path) -> list[Path]:
    files = [root / name for name in PANE_FILES]
    for directory in PANE_DIRS:
        files += sorted((root / directory).rglob("*.swift"))
    return [path for path in files if path.is_file()]


def scan(root: Path) -> list[str]:
    found = []
    shared: list[str] = []
    for path in pane_files(root):
        rel = path.relative_to(root).as_posix()
        for i, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines()):
            if OPT_OUT in line:
                continue
            if RAW_TARGET.search(line):
                found.append(f"{rel}:{i + 1}: second drop target in the chat pane; use the shared attachmentIntake modifier")
            elif SHARED_CALL.search(line):
                shared.append(f"{rel}:{i + 1}")
    if len(shared) > 1:
        found += [f"{place}: attachmentIntake( applied {len(shared)} times in the chat pane; apply the shared modifier once"
                  for place in shared]
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat drop target finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
