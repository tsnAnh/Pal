#!/usr/bin/env python3
"""Fail when a Pal surface background takes a bot accent.

Window, sidebar, chat, list, sheet, settings and inspector backgrounds come from the
neutral palette only. A bot accent may colour small shapes (an avatar, a primary
button, a chip, a selection, bubble ink), drawn as ``.background(accent, in: Capsule())``
or a shape ``.fill``. A finding is a surface modifier (``.background(``,
``.containerBackground(``, ``.presentationBackground(``, ``.listRowBackground(``,
``.toolbarBackground(``, ``.tint(``) or a ``PalPalette(`` construction that names a
bot accent on the same line without clipping it to a shape, or any palette
``tinted(toward:`` call. A justified exception carries ``bot-tint: ok`` on the line.

Run: python scripts/ci/check_swift_bot_tint.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "bot-tint: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
ACCENT = re.compile(r"\b(?:botAccent|chatAccent|BotAccent|accentBot|accentHex)\b|\.accent\b")
SURFACE = re.compile(
    r"\.(?:background|containerBackground|presentationBackground|listRowBackground|toolbarBackground|tint)\("
    r"|(?<![A-Za-z0-9_])PalPalette\("
)
SHAPE_CLIP = re.compile(r"\bin:\s*\.?[A-Z]?[A-Za-z]*(?:Capsule|Circle|Rectangle|RoundedRectangle|Ellipse|capsule|circle)\b")
PALETTE_TINT = re.compile(r"\btinted\(toward:")


def violations(path: Path, source: str) -> list[str]:
    found = []
    for i, line in enumerate(source.splitlines()):
        if OPT_OUT in line:
            continue
        if PALETTE_TINT.search(line):
            found.append(f"{path}:{i + 1}: palette tinted toward a bot accent")
        elif SURFACE.search(line) and ACCENT.search(line) and not SHAPE_CLIP.search(line):
            found.append(f"{path}:{i + 1}: surface background takes a bot accent")
    return found


def scan(root: Path) -> list[str]:
    found = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} bot tint finding(s). Paint surfaces from the neutral palette (PalTokens / "
              "theme.palette); keep a bot accent to a shape-clipped avatar, button, chip or selection. "
              f'For a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
