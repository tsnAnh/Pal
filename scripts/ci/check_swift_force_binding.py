#!/usr/bin/env python3
"""Fail on a force-unwrapped SwiftUI Binding or restored viewer state; opt out with ``binding-lint: ok``."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_swift_glass import SKIP_DIRS, Finding, Source

OPT_OUT = "binding-lint: ok"
VIEWER_DIRS = (("App", "Chat", "ImageViewer"), ("App", "Chat", "Media"), ("App", "Chat", "HTMLViewer"))


@dataclass(frozen=True)
class BindingRule:
    rule: str
    pattern: re.Pattern[str]
    message: str
    viewers_only: bool = False


BINDING_RULES = (
    BindingRule(
        "binding-force-unwrap",
        re.compile(
            r"(?<![A-Za-z0-9_])Binding(?:<[^>]*>)?\(\s*\$"
            r"|(?<![A-Za-z0-9_])Binding(?:<[^>]*>)?\(\s*unwrapping\s*:"
            r"|\$[A-Za-z_][A-Za-z0-9_]*(?:\??\.[A-Za-z_][A-Za-z0-9_]*)*!(?!=)"
        ),
        "Binding that force-unwraps an optional (Binding($x), Binding(unwrapping:), $x!). It traps when a dismissal sets "
        "the source to nil while the child view still updates. Pass the value, or use Binding(_:retaining:)",
    ),
    BindingRule(
        "viewer-no-restore",
        re.compile(r"@(?:SceneStorage|AppStorage)\b|(?<![A-Za-z0-9_])NSUserActivity\b|restorableState"),
        "restored or persisted state in a viewer. A viewer never reopens on launch: its item lives in @State only",
        viewers_only=True,
    ),
)
RULES = tuple(r.rule for r in BINDING_RULES)


def violations(rel: Path, source: str) -> list[Finding]:
    src = Source(source)
    in_viewer = rel.parts[:3] in VIEWER_DIRS
    found: list[Finding] = []
    for rule in BINDING_RULES:
        if rule.viewers_only and not in_viewer:
            continue
        for i, code in enumerate(src.plain):
            if rule.pattern.search(code) and OPT_OUT not in src.original[i]:
                found.append(Finding(rule.rule, rel.as_posix(), i + 1, src.original[i].strip(), rule.message))
    return found


def scan(root: Path) -> list[Finding]:
    found: list[Finding] = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if SKIP_DIRS.intersection(rel.parts):
            continue
        found += violations(rel, path.read_text(encoding="utf-8-sig"))
    return found


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for finding in found:
        print(finding.render())
    if found:
        print(f"\n{len(found)} force-unwrapped binding finding(s). Fix the code; "
              f'for a justified exception add "// {OPT_OUT}" on the line.')
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
