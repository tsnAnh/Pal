#!/usr/bin/env python3
"""Fail when the chat list can scroll or sit sideways.

The chat list scrolls vertically only. Two things keep it there:

* the scrolled content is pinned to the viewport width with ``containerRelativeFrame(.horizontal)`` in
  ``App/ChatView.swift``, so a wide row (table, code, image) can never widen the list; wide content scrolls
  inside its own horizontal ScrollView;
* every programmatic scroll of the list (``ChatView.swift``, ``ChatScrollController.swift``) sets only the vertical axis: ``scrollTo(edge: .top)``,
  ``scrollTo(edge: .bottom)``, ``scrollTo(y:)`` or ``scrollTo(id:, anchor: ChatScrollController.revealAnchor)``
  (an anchor with ``x: 0``). ``scrollTo(x:)``, ``scrollTo(point:)``, a leading or trailing edge and a centred
  anchor carry an x and move the list sideways. A justified exception carries ``chat-scroll: ok`` on the line.

Run: python scripts/ci/check_swift_chat_scroll.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "chat-scroll: ok"
LIST_FILES = ("App/ChatView.swift", "App/Chat/ChatScrollController.swift")
SCROLL_CALL = re.compile(r"\.scrollTo\(")
VERTICAL_ONLY = re.compile(
    r"\.scrollTo\((?:edge: \.(?:top|bottom)\)|y:|id: [^,()]+, anchor: (?:ChatScrollController\.|Self\.)?revealAnchor\))"
)
WIDTH_PIN = "containerRelativeFrame(.horizontal"
FIX = ("Scroll the chat list on the vertical axis only: scrollTo(edge: .top), scrollTo(y:) or scrollTo(id:, anchor: "
       "ChatScrollController.revealAnchor), and keep containerRelativeFrame(.horizontal) on the list content in ChatView.swift.")


def list_files(root: Path) -> list[Path]:
    return [path for path in (root / name for name in LIST_FILES) if path.is_file()]


def scan(root: Path) -> list[str]:
    found = []
    for path in list_files(root):
        rel = path.relative_to(root).as_posix()
        for i, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines()):
            if OPT_OUT in line or not SCROLL_CALL.search(line):
                continue
            if not VERTICAL_ONLY.search(line):
                found.append(f"{rel}:{i + 1}: programmatic scroll that can set an x; use a vertical-only target")
    view = root / "App" / "ChatView.swift"
    if view.is_file() and WIDTH_PIN not in view.read_text(encoding="utf-8-sig"):
        found.append("App/ChatView.swift:1: the list content is not pinned to the viewport width; add containerRelativeFrame(.horizontal)")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat scroll finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
