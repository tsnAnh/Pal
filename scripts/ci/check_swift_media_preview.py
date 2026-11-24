#!/usr/bin/env python3
"""Fail when Pal chat media previews grow a stroke or a bubble.

Text matching only (no Swift toolchain); reuses the comment- and string-blanking ``Source`` scanner
of ``check_swift_glass.py``. There is no baseline: every rule has zero findings on main. A justified
exception carries ``media-preview-lint: ok`` on the flagged line.

Scope: every .swift file under App/Chat/Media/ and App/Chat/HTMLViewer/ plus App/Chat/ImageViewer/MacMediaViewer.swift
and MacHTMLViewer.swift.
Rules: media-no-stroke, media-no-bubble.

Run: python scripts/ci/check_swift_media_preview.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import SKIP_DIRS, Finding, Source

OPT_OUT = "media-preview-lint: ok"
MEDIA_DIRS = (("App", "Chat", "Media"), ("App", "Chat", "HTMLViewer"))
MEDIA_FILES = (
    ("App", "Chat", "ImageViewer", "MacMediaViewer.swift"),
    ("App", "Chat", "ImageViewer", "MacHTMLViewer.swift"),
)


@dataclass(frozen=True)
class MediaRule:
    rule: str
    pattern: re.Pattern[str]
    message: str


MEDIA_RULES = (
    MediaRule(
        "media-no-stroke",
        re.compile(r"\.(?:stroke|strokeBorder|border)\s*\(|(?<![A-Za-z0-9_])cardStroke(?![A-Za-z0-9_])"),
        "stroke or border on a media preview. The preview is one stroke-free surface; separation comes from "
        "fill, a soft shadow and spacing, never an outline",
    ),
    MediaRule(
        "media-no-bubble",
        re.compile(r"(?<![A-Za-z0-9_])ChatBubble(?![A-Za-z0-9_])"),
        "ChatBubble around a media preview. Media is a sibling of the text bubble in AssistantBubble/UserBubble, "
        "never wrapped; draw the one rounded full-bleed surface itself",
    ),
)
RULES = tuple(r.rule for r in MEDIA_RULES)


def in_scope(rel: Path) -> bool:
    return rel.parts[:3] in MEDIA_DIRS or rel.parts in MEDIA_FILES


def violations(rel: Path, source: str) -> list[Finding]:
    if not in_scope(rel):
        return []
    src = Source(source)
    found: list[Finding] = []
    for rule in MEDIA_RULES:
        for i, code in enumerate(src.plain):
            if rule.pattern.search(code) and OPT_OUT not in src.original[i]:
                found.append(Finding(rule.rule, rel.as_posix(), i + 1, src.original[i].strip(), rule.message))
    return sorted(found, key=lambda f: (f.path, f.line, f.rule))


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        if in_scope(rel):
            found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} media preview finding(s). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
