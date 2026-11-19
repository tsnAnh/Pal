#!/usr/bin/env python3
"""Fail when a Pal icon is drawn without the shared PalDesign icon component.

Every icon is the primary ink (white in dark mode, black in light mode) from the palette, never
the system accent (blue) and never the unstyled default. SwiftUI cannot hide
``Image(systemName:)``, so this check is what enforces the shared component:
``PalIcon("name", ink:)``, ``Label("Title", palIcon: "name")`` and ``.palIcon(_:)``
(``Packages/PalDesign/Sources/PalDesign/Components/PalIcon.swift``).

Rules: icon-raw-image (``Image(systemName:``), icon-raw-label (``systemImage:``), icon-blue
(``.foregroundColor(.blue)``, ``.tint(.blue)``, ``.accentColor``, ``Color.accentColor``,
``Color.blue``, ``.foregroundStyle(.tint)``), icon-symbol-mode (``.symbolRenderingMode(.multicolor)``
or ``.palette``), icon-custom-ink (``ink: .custom(`` hides a colour from the palette).

An exception is one line in ``scripts/ci/swift_icon_tint_allowlist.txt``:
``<path relative to apps/ios>:<rule>: <reason>``. It covers that rule in that file, and the reason
is required. An ``Image(systemName:)`` inside a ``Text`` (interpolation or initialiser) inherits the text's ink and is
not a finding.

Run: python scripts/ci/check_swift_icon_tint.py [apps_ios_root] [allowlist]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
COMPONENT = Path("Packages/PalDesign/Sources/PalDesign/Components/PalIcon.swift")
ALLOWLIST = Path(__file__).with_name("swift_icon_tint_allowlist.txt")
FIX = 'draw it with PalIcon("name", ink:), Label("Title", palIcon: "name") or .palIcon(_:) from PalDesign (PalIcon.swift)'
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
TEXT_INTERPOLATION = re.compile(r'(?:\\\(|\bText\()\s*Image\(systemName:')
RULES: tuple[tuple[str, re.Pattern[str], str], ...] = (
    ("icon-raw-image", re.compile(r"\bImage\(systemName:"), f"raw Image(systemName:) takes the system tint; {FIX}"),
    ("icon-raw-label", re.compile(r"\bsystemImage:"), f"systemImage: takes the system tint; {FIX}"),
    (
        "icon-blue",
        re.compile(
            r"\.foregroundColor\(\s*\.blue\b|\.tint\(\s*\.blue\b|\.accentColor\b|\bColor\.blue\b"
            r"|\.foregroundStyle\(\s*\.(?:tint|blue)\b"
        ),
        f"blue or system-accent icon ink; {FIX}",
    ),
    (
        "icon-symbol-mode",
        re.compile(r"\.symbolRenderingMode\(\s*\.(?:multicolor|palette)\b"),
        f"multicolour or palette symbol rendering recolours an icon; {FIX}",
    ),
    ("icon-custom-ink", re.compile(r"\bink:.*\.custom\("), "a custom icon ink bypasses the palette; use a PalIconInk case"),
)


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    text: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


def load_allowlist(path: Path) -> tuple[dict[tuple[str, str], str], list[str]]:
    allowed: dict[tuple[str, str], str] = {}
    problems: list[str] = []
    if not path.is_file():
        return allowed, problems
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        parts = [part.strip() for part in entry.split(":", 2)]
        known = {rule for rule, _, _ in RULES}
        if len(parts) != 3 or parts[1] not in known or not parts[2]:
            problems.append(f"{path.name}:{number}: expected '<path>:<rule>: <reason>' with a known rule and a reason")
            continue
        allowed[(parts[0], parts[1])] = parts[2]
    return allowed, problems


def code_of(line: str) -> str:
    return STRING.sub('""', line.split("//", 1)[0]) if not TEXT_INTERPOLATION.search(line) else ""


def violations(rel: Path, source: str) -> list[Finding]:
    if rel == COMPONENT:
        return []
    found = []
    for number, line in enumerate(source.splitlines(), 1):
        code = code_of(line)
        for rule, pattern, message in RULES:
            if pattern.search(code):
                found.append(Finding(rule, rel.as_posix(), number, line.strip(), message))
    return found


def scan(root: Path, allowlist: Path = ALLOWLIST) -> list[Finding]:
    allowed, problems = load_allowlist(allowlist)
    found = [Finding("icon-allowlist", allowlist.name, 0, p, p) for p in problems]
    used: set[tuple[str, str]] = set()
    for base in (root / "App", root / "Packages"):
        for path in sorted(base.rglob("*.swift")):
            rel = path.relative_to(root)
            if SKIP_DIRS.intersection(rel.parts):
                continue
            for finding in violations(rel, path.read_text(encoding="utf-8-sig")):
                key = (finding.path, finding.rule)
                if key in allowed:
                    used.add(key)
                else:
                    found.append(finding)
    for path, rule in sorted(set(allowed) - used):
        found.append(Finding("icon-allowlist", allowlist.name, 0, f"{path}:{rule}", f"stale allowlist entry {path}:{rule}; delete it"))
    return found


def main(argv: list[str]) -> int:
    args = argv[1:]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    allowlist = Path(args[1]) if len(args) > 1 else ALLOWLIST
    found = scan(root, allowlist)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} icon tint finding(s). Every icon is the primary ink (white in dark, black in light): {FIX}. "
              "A justified exception is a line in scripts/ci/swift_icon_tint_allowlist.txt.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
