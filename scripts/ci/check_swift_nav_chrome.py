#!/usr/bin/env python3
"""Fail when Pal Swift code draws its own back or close button.

The Pal apps use the system back and close controls, one way out per screen: the
NavigationStack back, a ``ToolbarItem(placement: .cancellationAction)`` or a
``Button(role: .close)``. A custom one is a ``Button`` whose label is
``Image(systemName: "chevron.left")`` or ``Image(systemName: "xmark")`` and whose
accessibility label or identifier names it a back or close. An in-content dismiss,
a clear-search glyph (``xmark.circle.fill``) or any other glyph does not match. A
justified exception carries ``nav-chrome: ok`` on the Button or Image line.

Run: python scripts/ci/check_swift_nav_chrome.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "nav-chrome: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
GLYPH = re.compile(r'Image\(systemName:\s*"(chevron\.left|xmark)"\)')
BUTTON = re.compile(r"(?<![A-Za-z0-9_])Button\s*[({]")
ROLE = re.compile(r'accessibility(?:Label|Identifier)\([^\n]*(?i:back|close)')
LOOKBACK = 4
LOOKAHEAD = 12


def violations(path: Path, source: str) -> list[str]:
    lines = source.splitlines()
    found = []
    for i, line in enumerate(lines):
        glyph = GLYPH.search(line)
        if not glyph:
            continue
        button = next((j for j in range(i, max(-1, i - LOOKBACK - 1), -1) if BUTTON.search(lines[j])), None)
        if button is None:
            continue
        if OPT_OUT in line or OPT_OUT in lines[button]:
            continue
        if not any(ROLE.search(lines[k]) for k in range(i, min(len(lines), i + LOOKAHEAD + 1))):
            continue
        found.append(f"{path}:{i + 1}: custom {glyph.group(1)} back/close button")
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
        print(f"\n{len(found)} custom back/close button(s). Use the system control: the NavigationStack back, "
              "a ToolbarItem(placement: .cancellationAction), or Button(role: .close); one way out per screen. "
              f'For a justified exception add "// {OPT_OUT}" on the Button line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
