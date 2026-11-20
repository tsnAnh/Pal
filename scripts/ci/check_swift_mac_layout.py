#!/usr/bin/env python3
"""Fail when the Mac shell can be wider than its window or a sidebar row can be wider than its column.

Mac window fit has one owner, ``MacLayoutMetrics`` (Packages/PalDesign/.../Theme/MacLayoutMetrics.swift), and one
layout, ``MacShellLayout`` (App/Mac/MacShellLayout.swift), which allocates the sidebar, the chat column and the
inspector from the window width and ignores how wide a child says it wants to be. Sidebar rows go through
``.boundedToColumn()`` (PalDesign ``LeadingBoundedLayout``), so a row, or any sibling in the same stack, can never
centre-overflow and crop its own leading edge.

Rules (each finding names the file, line and the fix):

* mac-metric-literal: a window, sidebar, rail, inspector or chat-column width declared as a literal outside MacLayoutMetrics.
* mac-window-literal: ``defaultSize(width:)`` or a ``minWidth``/``idealWidth``/``frame(width:)`` literal of 100 or more in the shell files.
* mac-window-min: ``MacLayoutMetrics.windowMin`` is not derived from the widest sidebar plus the minimum chat column.
* mac-shell-stack: ``MacShellView`` lays the shell out with a stack instead of ``MacShellLayout``.
* mac-row-unbounded: a ``LazyVStack`` of sidebar rows or a ``Mac*Row`` view that is not bounded with ``.boundedToColumn()``.
* mac-row-fixed-size: ``fixedSize()`` or ``fixedSize(horizontal: true)`` inside a ``Mac*Row`` view.

A justified exception carries ``mac-layout: ok <reason>`` on the line.

Run: python scripts/ci/check_swift_mac_layout.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "mac-layout: ok"
METRICS = "Packages/PalDesign/Sources/PalDesign/Theme/MacLayoutMetrics.swift"
SHELL_FILES = (
    "App/PalApp.swift",
    "App/Mac/MacShell.swift",
    "App/Mac/MacSidebar.swift",
    "App/Mac/MacSidebarRail.swift",
    "App/Mac/MacSidebarHero.swift",
    "App/Mac/MacInspector.swift",
    "App/Platform/ChatPlatform.swift",
)
ROW_FILES = ("App/Mac/MacSidebar.swift", "App/Mac/MacSidebarRail.swift", "App/Rooms/RoomListRows.swift")
METRIC_LITERAL = re.compile(
    r"\b(?:let|var)\s+(sidebarWidth\w*|railWidth|inspectorWidth|chatColumn\w*|windowMin\w*|defaultWindow\w*)\b[^=\n]*=\s*\d"
)
WINDOW_LITERAL = re.compile(r"\.defaultSize\(\s*width:\s*\d|(?:minWidth|idealWidth|\.frame\(width):\s*\d{3,}")
ROW_STRUCT = re.compile(r"^(?:private |fileprivate )?struct (Mac\w*Row)\b")
FIXED_SIZE = re.compile(r"\.fixedSize\(\s*(?:horizontal:\s*true[^)]*)?\)")
BOUND = ".boundedToColumn()"
FIX_METRIC = "declare it in MacLayoutMetrics (PalDesign) and read it from there"
FIX_ROW = "add .boundedToColumn() (PalDesign LeadingBoundedLayout) so the row cannot exceed its column"


def _read(root: Path, rel: str) -> list[str] | None:
    path = root / rel
    return path.read_text(encoding="utf-8-sig").splitlines() if path.is_file() else None


def _block_end(lines: list[str], start: int) -> int:
    depth = 0
    seen = False
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        seen = seen or "{" in lines[index]
        if seen and depth <= 0:
            return index
    return len(lines) - 1


def _literal_findings(root: Path) -> list[str]:
    found = []
    for rel in SHELL_FILES:
        for i, line in enumerate(_read(root, rel) or []):
            if OPT_OUT in line:
                continue
            if METRIC_LITERAL.search(line):
                found.append(f"{rel}:{i + 1}: mac-metric-literal: width literal outside MacLayoutMetrics; {FIX_METRIC}")
            elif WINDOW_LITERAL.search(line):
                found.append(f"{rel}:{i + 1}: mac-window-literal: hard width literal in the Mac shell; {FIX_METRIC}")
    return found


def _window_min_findings(root: Path) -> list[str]:
    lines = _read(root, METRICS)
    if lines is None:
        return [f"{METRICS}:1: mac-window-min: MacLayoutMetrics is missing; the Mac window fit has no owner"]
    for i, line in enumerate(lines):
        if re.search(r"\bwindowMin\b[^=\n]*=", line):
            if "sidebarWidthRange.upperBound" in line and "chatColumnMin" in line:
                return []
            return [
                f"{METRICS}:{i + 1}: mac-window-min: windowMin must be sidebarWidthRange.upperBound + chatColumnMin "
                "so the window always holds the widest sidebar and a usable column"
            ]
    return [f"{METRICS}:1: mac-window-min: windowMin is not declared in MacLayoutMetrics"]


def _shell_stack_findings(root: Path) -> list[str]:
    lines = _read(root, "App/Mac/MacShell.swift")
    start = next((i for i, line in enumerate(lines or []) if "struct MacShellView" in line), None)
    if lines is None or start is None:
        return []
    body = range(start, _block_end(lines, start) + 1)
    found = []
    for i in body:
        if OPT_OUT not in lines[i] and re.search(r"\b(?:HStack|ZStack)\(spacing: 0\)\s*\{", lines[i]):
            found.append(
                f"App/Mac/MacShell.swift:{i + 1}: mac-shell-stack: the shell is laid out by a stack, so a wide child "
                "widens the window and crops the sidebar; use MacShellLayout"
            )
    if not any("MacShellLayout" in lines[i] for i in body):
        found.append("App/Mac/MacShell.swift:1: mac-shell-stack: MacShellView does not use MacShellLayout")
    return found


def _row_findings(root: Path) -> list[str]:
    found = []
    for rel in ROW_FILES:
        lines = _read(root, rel)
        if lines is None:
            continue
        for i, line in enumerate(lines):
            if "LazyVStack(" in line and OPT_OUT not in line and not rel.startswith("App/Rooms/"):
                end = _block_end(lines, i)
                follow = next((lines[j].strip() for j in range(end + 1, min(end + 4, len(lines))) if lines[j].strip()), "")
                if not follow.startswith(BOUND):
                    found.append(f"{rel}:{i + 1}: mac-row-unbounded: this LazyVStack of rows is not bounded to the column; {FIX_ROW}")
            match = ROW_STRUCT.match(line)
            if not match:
                continue
            span = range(i, _block_end(lines, i) + 1)
            if not any(BOUND in lines[j] or OPT_OUT in lines[j] for j in span):
                found.append(f"{rel}:{i + 1}: mac-row-unbounded: {match.group(1)} is not bounded to the column; {FIX_ROW}")
            for j in span:
                if FIXED_SIZE.search(lines[j]) and OPT_OUT not in lines[j]:
                    found.append(
                        f"{rel}:{j + 1}: mac-row-fixed-size: fixedSize in {match.group(1)} lets text exceed the column; "
                        "drop it and use lineLimit(1)"
                    )
    return found


def scan(root: Path) -> list[str]:
    if not (root / "App" / "Mac").is_dir():
        return []
    return _literal_findings(root) + _window_min_findings(root) + _shell_stack_findings(root) + _row_findings(root)


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} Mac layout finding(s). The window fit lives in MacLayoutMetrics and MacShellLayout; rows use .boundedToColumn().")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
