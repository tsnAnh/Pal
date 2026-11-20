#!/usr/bin/env python3
"""Fail when the Connect Apps sheet leaves the one palette: Liquid Glass clear controls, ink only.

Scans ``App/ConnectApps/*.swift`` and ``App/Setup/SetupButtons.swift``. The sheet draws with
``PalTokens`` / ``theme.palette`` ink and the clear glass components (``.palClearGlass``,
``.buttonStyle(.palClearCapsule)``, ``ClearGlassSearchField`` in ``PalDesign/Components/ClearGlass.swift``);
a raw blue, accent, hex, tint, bordered text field or regular glass there is a regression.

Rules: connect-blue, connect-accent, connect-red, connect-hex, connect-tint, connect-bordered-field,
connect-glass-regular. An exception is one entry of ALLOWLIST, keyed by (file relative to apps/ios,
rule) with a reason; an entry that matches nothing is itself a finding.

Run: python scripts/ci/check_swift_connect_palette.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

SETUP_BUTTONS = Path("App/Setup/SetupButtons.swift")
CONNECT_DIR = Path("App/ConnectApps")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
RULES: tuple[tuple[str, re.Pattern[str], str], ...] = (
    (
        "connect-blue",
        re.compile(r"\bColor\.blue\b|\bColor\(\s*\.blue\b|(?<![\w.])\.blue\b"),
        "raw blue; use PalTokens.textPrimary or the theme.palette ink through the shared components",
    ),
    (
        "connect-accent",
        re.compile(r"\.accentColor\b"),
        "system accent (blue); use PalTokens.textPrimary or the theme.palette ink through the shared components",
    ),
    ("connect-red", re.compile(r"\bColor\.red\b"), "raw red; use Color(theme.palette.destructive)"),
    (
        "connect-hex",
        re.compile(r"\bRGB\(\s*hex:|\bColor\(\s*hex|\b0x[0-9A-Fa-f]{6,8}\b"),
        "hex literal; use a PalTokens or theme.palette token",
    ),
    ("connect-tint", re.compile(r"\.tint\("), "remove .tint(; clear glass is untinted"),
    (
        "connect-bordered-field",
        re.compile(r"\.textFieldStyle\(\s*\.roundedBorder"),
        "bordered text field; use ClearGlassSearchField (PalDesign/Components/ClearGlass.swift)",
    ),
    (
        "connect-glass-regular",
        re.compile(r"\bGlass\.regular\b"),
        "regular glass; use .palClearGlass, .buttonStyle(.palClearCapsule) or Glass.clear",
    ),
)
ALLOWLIST: dict[tuple[str, str], str] = {
    ("App/ConnectApps/DeviceTile.swift", "connect-hex"): "brand device tile fill colours",
    ("App/ConnectApps/CustomConnectorForm.swift", "connect-hex"): "teal avatar accent fallback, the catalog's own colour",
    ("App/ConnectApps/McpSignInSheet.swift", "connect-red"): "valid/invalid status mark, green and red state colours",
    ("App/ConnectApps/ConnectAppsMacList.swift", "connect-red"): "Mac row problem state mark",
    ("App/ConnectApps/SkillsCatalogSheet.swift", "connect-tint"): "DelayedProgressView spinner coloured with a palette colour",
}


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    text: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.line}: [{self.rule}] {self.message}"


def code_of(line: str) -> str:
    return STRING.sub('""', line.split("//", 1)[0])


def violations(rel: Path, source: str) -> list[Finding]:
    found = []
    for number, line in enumerate(source.splitlines(), 1):
        code = code_of(line)
        for rule, pattern, message in RULES:
            if pattern.search(code):
                found.append(Finding(rule, rel.as_posix(), number, line.strip(), message))
    return found


def scoped_files(root: Path) -> list[Path]:
    files = sorted((root / CONNECT_DIR).glob("*.swift"))
    if (root / SETUP_BUTTONS).is_file():
        files.append(root / SETUP_BUTTONS)
    return files


def scan(root: Path, allowlist: dict[tuple[str, str], str] | None = None) -> list[Finding]:
    allowed = ALLOWLIST if allowlist is None else allowlist
    found: list[Finding] = []
    used: set[tuple[str, str]] = set()
    for path in scoped_files(root):
        rel = path.relative_to(root)
        for finding in violations(rel, path.read_text(encoding="utf-8-sig")):
            key = (finding.path, finding.rule)
            if key in allowed:
                used.add(key)
            else:
                found.append(finding)
    for path, rule in sorted(set(allowed) - used):
        if not (root / path).is_file():
            continue
        found.append(Finding("connect-allowlist", path, 0, rule, f"stale allowlist entry {rule}; delete it"))
    return found


def main(argv: list[str]) -> int:
    args = argv[1:]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} Connect Apps palette finding(s). The sheet is clear glass and ink only: "
              "PalTokens / theme.palette, .palClearGlass, .palClearCapsule, ClearGlassSearchField. "
              "A justified exception is an entry of ALLOWLIST in scripts/ci/check_swift_connect_palette.py.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
