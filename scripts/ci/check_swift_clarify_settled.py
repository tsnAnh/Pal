#!/usr/bin/env python3
"""Fail when a settled clarify card renders more than the question and the chosen rows.

An answered card collapses to the bold question and only the chosen row(s). A view named like a settled
or answered clarify card, and the ``.clarifyAnswered`` branch of ``ClarifyRowContent``, may not draw the
unchosen options, the A/B/C letters, the Something-else input, a button or the live cards.

Run: python scripts/ci/check_swift_clarify_settled.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

APP_DIR = "App"
SETTLED_VIEW = re.compile(r"\bstruct\s+(\w*Clarify\w*(?:Answered|Settled)\w*)\b")
ANSWERED_BRANCH = re.compile(r"case\s+\.clarifyAnswered\b")
NEXT_BRANCH = re.compile(r"\n\s*case\s+\.|\n\s*default\s*:")
FORBIDDEN = re.compile(
    r"\bClarifyBadge\b|\bClarifyRow(?:Shell)?\s*\(|\bClarifyRow\.letter\b|\bClarifyInputRow\b|\bClarifyOpenField\b"
    r"|\bClarifyCard\s*\(|\bClarifyFormCard\s*\(|\bButton\s*[({]|\.choices\b|\bchoices\b|clarifyChoice"
)
FIX = ("A settled card shows the question as a bold title and only the chosen row(s): drop the unchosen options, "
       "letters, hint text and buttons from it. Draw it with ClarifySettledCard.")


def block_end(text: str, start: int) -> int:
    depth = 0
    opened = False
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
            opened = True
        elif text[index] == "}":
            depth -= 1
            if opened and depth == 0:
                return index + 1
    return len(text)


def report(text: str, rel: str, start: int, end: int, label: str) -> list[str]:
    first = text.count("\n", 0, start) + 1
    found = []
    for offset, line in enumerate(text[start:end].splitlines()):
        match = FORBIDDEN.search(line)
        if match:
            found.append(f"{rel}:{first + offset}: {label} draws {match.group().strip()}")
    return found


def scan(root: Path) -> list[str]:
    found = []
    for path in sorted((root / APP_DIR).rglob("*.swift")):
        text = path.read_text(encoding="utf-8-sig")
        rel = path.relative_to(root).as_posix()
        for match in SETTLED_VIEW.finditer(text):
            found += report(text, rel, match.start(), block_end(text, match.start()), f"struct {match.group(1)}")
        for match in ANSWERED_BRANCH.finditer(text):
            following = NEXT_BRANCH.search(text, match.end())
            found += report(text, rel, match.start(), following.start() if following else len(text), "the clarifyAnswered branch")
    return sorted(set(found))


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} settled clarify card finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
