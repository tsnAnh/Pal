#!/usr/bin/env python3
"""Fail when a chat row sets a width without saying where its content sits.

A width frame with no ``alignment:`` centres its content: ``.frame(maxWidth: .infinity)``, a finite
``.frame(maxWidth: 516)`` or ``bubbleMaxWidth``, or a width-only ``.frame(width: 224)``. In a chat row that is an
accident (a bot row or a file card drifting to the middle on Mac) unless the row is meant to be centred. Every
such frame names its side: ``chatRowFrame(for: .bot)`` leads, ``.user`` trails, ``.system`` centres on purpose
(time separators, chips, notices), or an explicit ``alignment:`` on ``.frame``. A frame that also sets
``height:`` is a fixed-size box around its content (an icon, a tile) and is not a row width. A justified
exception carries ``chat-row-alignment: ok <reason>`` on the line.

Run: python scripts/ci/check_swift_chat_row_alignment.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "chat-row-alignment: ok"
ROW_FILES = (
    "App/Chat/BubbleWidth.swift",
    "App/Chat/ChatRows.swift",
    "App/Chat/AssistantBubble.swift",
    "App/Chat/ClarifyFormCard.swift",
    "App/Chat/ClarifyCards.swift",
    "App/Chat/GeneratedImageRow.swift",
    "App/Chat/RoutineOutputRow.swift",
    "App/Chat/OlderHistoryRow.swift",
    "App/Chat/ChatFileCard.swift",
    "App/Chat/ChatImages.swift",
    "App/Chat/ChatCards.swift",
    "App/Chat/ChatWorkingRow.swift",
    "App/Chat/MarkdownTableView.swift",
    "App/Chat/BotThread/BotThreadView.swift",
    "Packages/PalDesign/Sources/PalDesign/Components/ChatChrome.swift",
)
FRAME_CALL = re.compile(r"\bframe\(")
WIDTH_LIMIT = re.compile(r"\bmaxWidth:|(?<![A-Za-z])width:")
FIXED_WIDTH = re.compile(r"(?<![A-Za-z])width:")
HEIGHT = re.compile(r"\bheight:")
ALIGNMENT = re.compile(r"\balignment:")
FIX = ("Use chatRowFrame(for: ChatSender) (.bot leads, .user trails, .system centres on purpose) or pair the width "
       "with a side: .frame(maxWidth: N, alignment: .leading) / .frame(width: N, alignment: .leading).")


def top_level(args: str) -> str:
    depth = 0
    kept = []
    for char in args:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif depth == 0:
            kept.append(char)
    return "".join(kept)


def frame_arguments(text: str, start: int) -> str:
    depth = 1
    for i in range(start, len(text)):
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        if depth == 0:
            return text[start:i]
    return text[start:]


def scan(root: Path) -> list[str]:
    found = []
    for name in ROW_FILES:
        path = root / name
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8-sig")
        lines = text.splitlines()
        for match in FRAME_CALL.finditer(text):
            args = top_level(frame_arguments(text, match.end()))
            if not WIDTH_LIMIT.search(args) or ALIGNMENT.search(args):
                continue
            if FIXED_WIDTH.search(args) and HEIGHT.search(args) and "maxWidth:" not in args:
                continue
            line = text.count("\n", 0, match.start())
            if OPT_OUT not in lines[line]:
                found.append(f"{name}:{line + 1}: chat row width frame centres by default; use chatRowFrame(for: ChatSender) or add an alignment")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} chat row alignment finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
