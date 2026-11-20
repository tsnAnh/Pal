#!/usr/bin/env python3
"""Fail when a Mac-visible icon-only Button has no hover tooltip.

An icon-only control on the Mac is a ``Button`` whose label draws a ``PalIcon``,
``Image`` or ``MacConnectAppsGlyph`` and no ``Text`` or ``Label``. Pointer users read
its name from ``.help(...)`` the way VoiceOver users read ``.accessibilityLabel``, so
every such Button carries both in its modifier chain. Code inside ``#if os(iOS)`` is
exempt. A justified exception carries ``mac-controls: ok`` on the Button line.

Run: python scripts/ci/check_swift_mac_controls.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "mac-controls: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
BUTTON = re.compile(r"(?<![A-Za-z0-9_])Button\s*(?:\(action:[^)]*\)|\{[^}\n]*\})\s*(?:label:\s*)?\{")
BUTTON_LABEL = re.compile(r"(?<![A-Za-z0-9_])Button\s*(?:\([^)\n]*\)|\{[^\n]*\})\s*(?:label:\s*)?\{\s*$|(?<![A-Za-z0-9_])Button\s*\(action:[^\n]*\)\s*\{\s*(?://.*)?$")
ICON = re.compile(r"PalIcon\(|Image\(systemName:|MacConnectAppsGlyph\(")
TEXTUAL = re.compile(r"(?<![A-Za-z0-9_.])(?:Text|Label)\(")
IF_OS = re.compile(r"#if\s+os\((macOS|iOS)\)\s*$")
CHAIN_LIMIT = 14


def mac_visible(lines: list[str]) -> list[bool]:
    stack: list[bool | None] = []
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
        flags.append(all(flag is not False for flag in stack))
    return flags


def label_block(lines: list[str], start: int) -> tuple[list[str], int] | None:
    opening = lines[start]
    depth = opening.count("{") - opening.count("}")
    if "label:" not in opening and not re.search(r"\)\s*\{\s*(?://.*)?$|\}\s*label:\s*\{\s*$", opening):
        return None
    if re.search(r"\{[^{}]*\}\s*label:\s*\{\s*$", opening):
        depth = 1
    body: list[str] = []
    for index in range(start + 1, min(len(lines), start + 40)):
        body.append(lines[index])
        depth += lines[index].count("{") - lines[index].count("}")
        if depth <= 0:
            return body, index
    return None


def violations(path: Path, source: str) -> list[str]:
    lines = source.splitlines()
    visible = mac_visible(lines)
    found = []
    for i, line in enumerate(lines):
        if not visible[i] or OPT_OUT in line or "Button" not in line:
            continue
        if not re.search(r"(?<![A-Za-z0-9_])Button\s*[({]", line) or re.search(r'Button\s*\(\s*"|Button\s*\(\s*(?:String|role)', line):
            continue
        block = label_block(lines, i)
        if block is None:
            continue
        body, end = block
        text = "\n".join(body[:-1] if body else body)
        if not ICON.search(text) or TEXTUAL.search(text):
            continue
        chain = []
        for follow in lines[end:end + CHAIN_LIMIT]:
            stripped = follow.strip()
            if follow is not lines[end] and stripped and not stripped.startswith("."):
                break
            chain.append(stripped)
        if not any(".help(" in c for c in chain):
            found.append(f"{path}:{i + 1}: icon-only Button without .help(...) tooltip")
    return found


def scan(root: Path) -> list[str]:
    found = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts) or rel.parts[0] != "App":
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} Mac control finding(s). Add .help(<same text as the accessibility label>) after the "
              f'Button, or put "// {OPT_OUT}" on the Button line for a justified exception.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
