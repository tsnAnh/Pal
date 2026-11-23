#!/usr/bin/env python3
"""Fail when the Pal chat image viewer breaks its structure rules.

Text matching only (no Swift toolchain); reuses the comment- and string-blanking ``Source`` scanner
of ``check_swift_glass.py``. There is no baseline: every rule has zero findings on main. A justified
exception carries ``viewer-lint: ok`` on the flagged line.

Rules: viewer-sheet-on-mac, viewer-clear-glass, viewer-own-composer, viewer-decode-main.

Run: python scripts/ci/check_swift_image_viewer.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import SKIP_DIRS, Finding, Source

OPT_OUT = "viewer-lint: ok"
VIEWER_DIR = ("App", "Chat", "ImageViewer")
COMPOSER = re.compile(r"(?<![A-Za-z0-9_])ChatComposer\(")
SHEET_USE = re.compile(r"(?<![A-Za-z0-9_])ChatImageViewer\(")
CONDITIONAL = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
IOS_TERM = re.compile(r"\(*os\(iOS\)\)*")

SHEET_MESSAGE = ("ChatImageViewer used outside #if os(iOS). The Mac viewer lives in the chat pane "
                 "(MacImageViewer), never a sheet")
COMPOSER_MISSING = ("the image viewer has no ChatComposer. The message box is the shared ChatComposer(...), "
                    "so the viewer must host it")


@dataclass(frozen=True)
class ViewerRule:
    rule: str
    pattern: re.Pattern[str]
    message: str


VIEWER_RULES = (
    ViewerRule(
        "viewer-clear-glass",
        re.compile(r"\.palGlass\(|\.glassEffect(?:ID|Union|Transition)?\(|\.buttonStyle\(\s*\.glass|\.glassProminent\b"
                   r"|\.glassButtonStyle\(\s*(?:prominent:\s*false\s*)?\)|\.interactiveGlassButtonStyle\("),
        "regular glass in the image viewer. The viewer floats over the image, so use .palClearGlass(...)",
    ),
    ViewerRule(
        "viewer-own-composer",
        re.compile(r"(?<![A-Za-z0-9_])(?:TextField|TextEditor|SecureField)\("),
        "own text input in the image viewer. The message box is the shared ChatComposer(...)",
    ),
    ViewerRule(
        "viewer-decode-main",
        re.compile(r"CGImageSourceCreate|(?<![A-Za-z0-9_])(?:NSImage|PlatformImage|UIImage)\(\s*data\s*:"
                   r"|(?<![A-Za-z0-9_])ChatImageDecoder\.downsample\("),
        "image decode in the image viewer. Decode through ChatImageSource / the detached decoder in ChatImages.swift, "
        "never on the main actor in a view",
    ),
)
RULES = ("viewer-sheet-on-mac", *(r.rule for r in VIEWER_RULES))


def is_ios_only(condition: str) -> bool:
    return all(
        any(IOS_TERM.fullmatch(term) for term in disjunct.split("&&"))
        for disjunct in condition.replace(" ", "").split("||")
    )


def ios_only_lines(plain: list[str]) -> set[int]:
    """Zero-based indexes of the lines that sit inside an iOS-only ``#if`` branch."""
    inside: set[int] = set()
    branches: list[bool] = []
    for i, line in enumerate(plain):
        m = CONDITIONAL.match(line)
        if not m:
            if any(branches):
                inside.add(i)
            continue
        keyword, condition = m.groups()
        if keyword == "if":
            branches.append(is_ios_only(condition))
        elif keyword == "elseif" and branches:
            branches[-1] = is_ios_only(condition)
        elif keyword == "else" and branches:
            branches[-1] = False
        elif keyword == "endif" and branches:
            branches.pop()
    return inside


def has_composer(source: str) -> bool:
    return any(COMPOSER.search(line) for line in Source(source).plain)


def violations(rel: Path, source: str) -> list[Finding]:
    src = Source(source)
    found: list[Finding] = []

    def add(rule: str, line: int, message: str) -> None:
        text = src.original[line - 1]
        if OPT_OUT not in text:
            found.append(Finding(rule, rel.as_posix(), line, text.strip(), message))

    if rel.parts[:1] == VIEWER_DIR[:1]:
        ios_only = ios_only_lines(src.plain)
        for i, code in enumerate(src.plain):
            if i not in ios_only and SHEET_USE.search(code):
                add("viewer-sheet-on-mac", i + 1, SHEET_MESSAGE)
    if rel.parts[:3] == VIEWER_DIR:
        for rule in VIEWER_RULES:
            for i, code in enumerate(src.plain):
                if rule.pattern.search(code):
                    add(rule.rule, i + 1, rule.message)
    return found


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    composer = False
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        source = path.read_text(encoding="utf-8-sig")
        found += violations(rel, source)
        composer = composer or (rel.parts[:3] == VIEWER_DIR and has_composer(source))
    if (root.joinpath(*VIEWER_DIR)).is_dir() and not composer:
        found.append(Finding("viewer-own-composer", "/".join(VIEWER_DIR), 1, "", COMPOSER_MISSING))
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} image viewer finding(s). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
