#!/usr/bin/env python3
"""Fail when a chat card asks the owner to Allow or Deny a connector.

An installed connector turns on without a question and one that is not installed yet asks through the
question form (Install and set up / Not now), so no card under ``App/Chat`` may carry an Allow, Allow once,
Don't allow or Deny label, and ``ConnectionDecision`` has no ``.allow`` or ``.deny`` case. A card that
cannot move yet is listed in ``ALLOWLIST`` with its reason.

Run: python scripts/ci/check_swift_connection_card.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ALLOWLIST = {
    "App/Chat/ChatDeskCardView.swift": "held-draft approval for an outbound Slack send; the held-draft-approval-ui unit moves it to the question form",
}
CARD_DIR = "App/Chat"
APP_DIRS = ("App", "Packages")
LABEL = re.compile(r"\"(?:Allow(?: once| always)?|Don[’']t allow|Deny)\"")
DECISION = re.compile(r"\bConnectionDecision\.(?:allow|deny)\b|connection(?:Allow|Deny)-")
DECISION_CASE = re.compile(r"\bcase\s+(?:allow|deny)\b")
DECISION_FILE = "Packages/PalKit/Sources/PalChat/ConnectionCard.swift"
FIX = ("Remove the Allow / Deny label: an installed connector turns on silently and a new one asks through the "
       "question form. A card that cannot move yet goes in ALLOWLIST with its reason.")


def swift_files(root: Path, base: str) -> list[Path]:
    return sorted(path for path in (root / base).rglob("*.swift") if ".build" not in path.parts)


def scan(root: Path) -> list[str]:
    found = []
    for path in swift_files(root, CARD_DIR):
        rel = path.relative_to(root).as_posix()
        if rel in ALLOWLIST:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            if LABEL.search(line):
                found.append(f"{rel}:{number}: chat card button or label says Allow or Deny")
    for base in APP_DIRS:
        for path in swift_files(root, base):
            text = path.read_text(encoding="utf-8-sig")
            rel = path.relative_to(root).as_posix()
            patterns = (DECISION, DECISION_CASE) if rel == DECISION_FILE else (DECISION,)
            for match in (m for pattern in patterns for m in pattern.finditer(text)):
                number = text.count("\n", 0, match.start()) + 1
                found.append(f"{rel}:{number}: connection decision allow or deny: {match.group().strip()}")
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} connector Allow / Deny finding(s). {FIX}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
