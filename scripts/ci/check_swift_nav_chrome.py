#!/usr/bin/env python3
"""Fail when Pal Swift code draws its own back or close button.

The Pal apps use the system back and close controls, one way out per screen: the
NavigationStack back, a ``ToolbarItem(placement: .cancellationAction)`` or a
``Button(role: .close)``. A custom one is a ``Button`` whose label is
``Image(systemName: "chevron.left")`` or ``Image(systemName: "xmark")`` and whose
accessibility label or identifier names it a back or close. An in-content dismiss,
a clear-search glyph (``xmark.circle.fill``) or any other glyph does not match. A
justified exception carries ``nav-chrome: ok`` on the Button or Image line.

The Mac window hides its title bar and draws the traffic lights over the top of
the content, so two more shapes put controls under them: a window toolbar item or
navigation title in macOS code (``ToolbarItem(`` or ``.navigationTitle(``), and a
full-window overlay in a view that ignores the top safe area
(``.frame(maxWidth: .infinity, maxHeight: .infinity)`` then ``.background(``)
without the shell's ``MacMetrics.topBarHeight`` inset. Text matching sees these
shapes only; it cannot see where a control is drawn at run time.

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
MAC_TOOLBAR = re.compile(r"(?<![A-Za-z0-9_])ToolbarItem(?:Group)?\(|\.navigationTitle\(")
IF_OS = re.compile(r"#if\s+os\((macOS|iOS)\)\s*$")
TOP_UNSAFE = ".ignoresSafeArea(.container, edges: .top)"
FULL_FRAME = ".frame(maxWidth: .infinity, maxHeight: .infinity)"
OVERLAY_CHAIN = 4


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


def mac_lines(path: Path, lines: list[str]) -> list[bool]:
    stack: list[bool | None] = []
    in_mac_dir = "Mac" in path.parts
    flags = []
    for line in lines:
        text = line.strip()
        if text.startswith("#if"):
            match = IF_OS.match(text)
            stack.append(None if match is None else match.group(1) == "macOS")
        elif text.startswith("#else") and stack and stack[-1] is not None:
            stack[-1] = not stack[-1]
        elif text.startswith("#endif") and stack:
            stack.pop()
        known = [flag for flag in stack if flag is not None]
        flags.append(known[-1] if known else in_mac_dir)
    return flags


def mac_chrome_violations(path: Path, source: str) -> list[str]:
    lines = source.splitlines()
    found = []
    for i, (line, is_mac) in enumerate(zip(lines, mac_lines(path, lines))):
        if is_mac and OPT_OUT not in line and MAC_TOOLBAR.search(line):
            found.append(f"{path}:{i + 1}: macOS window toolbar item under the hidden title bar")
    if TOP_UNSAFE not in source:
        return found
    for i, line in enumerate(lines):
        if FULL_FRAME not in line or OPT_OUT in line:
            continue
        chain = [line]
        for follow in lines[i + 1:i + 1 + OVERLAY_CHAIN]:
            if not follow.strip().startswith("."):
                break
            chain.append(follow)
        if any(".background(" in c for c in chain) and not any("topBarHeight" in c for c in chain):
            found.append(f"{path}:{i + 1}: full-window overlay without the MacMetrics.topBarHeight inset")
    return found


def scan(root: Path) -> list[str]:
    found = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        source = path.read_text(encoding="utf-8-sig")
        found += violations(rel, source) + mac_chrome_violations(rel, source)
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} nav chrome finding(s). Use the system control: the NavigationStack back, "
              "a ToolbarItem(placement: .cancellationAction), or Button(role: .close); one way out per screen. "
              "On macOS draw the header in content (SheetChrome) below MacMetrics.topBarHeight, never in the window toolbar. "
              f'For a justified exception add "// {OPT_OUT}" on the Button line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
