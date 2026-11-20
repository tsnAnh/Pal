#!/usr/bin/env python3
"""Fail when an iOS SwiftUI drag can claim a touch that belongs to a scroll view.

On iOS 18 and later a SwiftUI ``DragGesture`` attached to content inside a ScrollView or List (with ``.gesture``,
``.simultaneousGesture`` or ``.highPriorityGesture``) takes part in the touch from its first point, and the scroll
view's own pan no longer starts reliably. Swipe to reply on every chat bubble did exactly that and the iPhone chat list
stopped scrolling vertically. A row drag goes through ``ScrollSafePan`` (PalDesign): a UIKit pan whose delegate begins
only for the direction the row owns, so every other touch fails it at once and the scroll view's pan wins.

The check reads the iOS build of ``App/`` and ``Packages/PalDesign/Sources`` (lines inside ``#if os(macOS)`` are
skipped) and reports each ``DragGesture(``, ``.simultaneousGesture(`` and ``.highPriorityGesture(``. A drag on a
surface no scroll view hosts (a modal sheet, a banner) carries ``scroll-gesture: ok`` on the line.

Run: python scripts/ci/check_swift_scroll_gesture.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_chat_scroll import active_lines

OPT_OUT = "scroll-gesture: ok"
ROOTS = ("App", "Packages/PalDesign/Sources")
CLAIMER = re.compile(r"\bDragGesture\(|\.simultaneousGesture\(|\.highPriorityGesture\(")
FIX = ("Attach a row drag on iOS through ScrollSafePan (PalDesign) with a begin predicate for the direction the row owns, "
       "so the scroll view's pan wins every other touch. A drag on a surface no scroll view hosts carries "
       f"'{OPT_OUT}' on the line.")


def swift_files(root: Path) -> list[Path]:
    return sorted(path for name in ROOTS for path in (root / name).rglob("*.swift"))


def scan(root: Path) -> list[str]:
    found = []
    for path in swift_files(root):
        rel = path.relative_to(root).as_posix()
        for number, line in active_lines(path.read_text(encoding="utf-8-sig"), "iOS"):
            if OPT_OUT in line or line.lstrip().startswith("//"):
                continue
            match = CLAIMER.search(line)
            if match:
                found.append(f"{rel}:{number}: {match.group(0).strip('.(')} can take the touch from a scroll view on iOS; use ScrollSafePan")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} scroll gesture finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
