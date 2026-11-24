#!/usr/bin/env python3
"""Fail when the Mac chat pane has more than one file and image drop target, or a silent drop failure.

Dropping images and files into a bot chat goes through ONE target per platform. On macOS it is the AppKit
``AttachmentDropView`` (``App/Platform/AttachmentDropView.swift``), installed once by the shared
``attachmentIntake(intake:)`` modifier (``App/Platform/AttachmentIntake.swift``), applied once to the whole chat
pane in ``ChatView.swift``. Two nested targets fight over the same drag on different handler paths, so:

* the chat pane files (``ChatView.swift``, ``Chat/*.swift``, ``Mac/MacChat.swift``, ``Mac/MacShell.swift``) may not
  call ``.onDrop(`` or ``.dropDestination(`` themselves, and may call ``attachmentIntake(`` at most once in total;
* ``AttachmentIntake.swift`` may not use ``.onDrop(`` or ``.dropDestination(`` either, and installs
  ``AttachmentDropAnchor(`` exactly once;
* no App file registers for drag types (``registerForDraggedTypes(``) except ``AttachmentDropView.swift`` and an
  ``override func registerForDraggedTypes`` that opts a child view out, and none swaps a view's class
  (``object_setClass(``, the removed ``ComposerDragForwarding``);
* a failed load is never silent: ``AttachmentDropView.swift`` hands every drop to ``AttachmentIntake.receive(``
  and builds no ``DropBatch(`` itself, and ``AttachmentIntake.swift`` records ``failures.append(.unreadable)`` and
  always calls ``intake(batch)``.

Paste is not a drop target: ``attachmentPaste(`` stays on the composer. A justified exception carries
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
REGISTRATION = re.compile(r"(?<!func )\bregisterForDraggedTypes\(")
CLASS_SWAP = re.compile(r"\bobject_setClass\(|\bComposerDragForwarding\b")
ANCHOR = re.compile(r"(?<![A-Za-z0-9_])AttachmentDropAnchor\(")
INTAKE_FILE = "App/Platform/AttachmentIntake.swift"
DROP_VIEW_FILE = "App/Platform/AttachmentDropView.swift"
FIX = ("Keep one drop target: apply the shared attachmentIntake(intake:) modifier once, to the whole chat pane in "
       "ChatView.swift, and remove the other. Composer paste uses attachmentPaste(intake:).")


def pane_files(root: Path) -> list[Path]:
    files = [root / name for name in PANE_FILES]
    for directory in PANE_DIRS:
        files += sorted((root / directory).rglob("*.swift"))
    return [path for path in files if path.is_file()]


def _lines(path: Path) -> list[tuple[int, str]]:
    return [(i + 1, line) for i, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines()) if OPT_OUT not in line]


def scan_core(root: Path) -> list[str]:
    intake, view = root / INTAKE_FILE, root / DROP_VIEW_FILE
    if not (root / "App" / "Platform").is_dir():
        return []
    found = []
    anchors = []
    for path in sorted((root / "App").rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        for number, line in _lines(path):
            if CLASS_SWAP.search(line):
                found.append(f"{rel}:{number}: runtime class swap of a drag destination; use the AttachmentDropView target")
            if rel != DROP_VIEW_FILE and REGISTRATION.search(line):
                found.append(f"{rel}:{number}: registers for drag types; the only drop target is AttachmentDropView")
            if rel == INTAKE_FILE and RAW_TARGET.search(line):
                found.append(f"{rel}:{number}: SwiftUI drop target next to AttachmentDropView; keep one target per platform")
            if rel != DROP_VIEW_FILE and ANCHOR.search(line):
                anchors.append(f"{rel}:{number}")
    if len(anchors) != 1 or not anchors[0].startswith(INTAKE_FILE + ":"):
        found.append(f"{INTAKE_FILE}: AttachmentDropAnchor( must be installed exactly once, by the attachmentIntake modifier "
                     f"(found {anchors or 'none'})")
    view_text = view.read_text(encoding="utf-8-sig") if view.is_file() else ""
    intake_text = intake.read_text(encoding="utf-8-sig") if intake.is_file() else ""
    if "AttachmentIntake.receive(" not in view_text:
        found.append(f"{DROP_VIEW_FILE}: a drop must reach AttachmentIntake.receive( so a failed load shows the notice")
    if re.search(r"\bDropBatch\(", view_text):
        found.append(f"{DROP_VIEW_FILE}: builds a DropBatch itself; load through AttachmentIntake.receive( so failures are reported")
    if "failures.append(.unreadable)" not in intake_text or "intake(batch)" not in intake_text:
        found.append(f"{INTAKE_FILE}: a failed load must append .unreadable and still call intake(batch) with it, never drop silently")
    return found


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
    return found + scan_core(root)


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
