#!/usr/bin/env python3
"""Fail when a Pal text input draws a second surface inside or around Liquid Glass.

Every text input is ``PalTextField``, ``PalTextEditor`` or ``PalGlassTextField``
(``Packages/PalDesign/Sources/PalDesign/Components/PalTextInput.swift``): plain style, no bezel, no
border, no ring and no background of its own, so the glass (or the bare container) is the only surface.
The default text-field style draws a bezel on macOS, which shows as a grey field inside the glass capsule.

Rules: glass-input-bordered-style (``.textFieldStyle(.roundedBorder|.squareBorder|.bordered)``),
glass-input-bare (a bare ``TextField(``, ``SecureField(`` or ``TextEditor(``), glass-input-appkit
(``NSTextField(``, ``NSSearchField(``, ``NSSecureTextField(``, ``UITextField(`` or a subclass of one; label
initialisers such as ``NSTextField(labelWithString:)`` are not inputs), glass-input-chrome (a rounded
``.background(`` or ``.overlay(`` applied directly on an input call).

An exception is one line of ``scripts/ci/glass_input_allowlist.txt``: ``<path relative to apps/ios>:<pattern>``,
two spaces, then the reason. The pattern is a plain substring of the flagged source line (stripped). An
entry that waives nothing is itself a finding.

Run: python scripts/ci/check_swift_glass_input.py [apps_ios_root] [allowlist]
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from check_swift_glass import SKIP_DIRS, Finding, Source, blank_comments

COMPONENT = Path("Packages/PalDesign/Sources/PalDesign/Components/PalTextInput.swift")
ALLOWLIST = Path(__file__).with_name("glass_input_allowlist.txt")
ALLOWLIST_RULE = "glass-input-allowlist"
SEPARATOR = "  "
FIX = (
    "use PalTextField / PalTextEditor / PalGlassTextField "
    "(apps/ios/Packages/PalDesign/Sources/PalDesign/Components/PalTextInput.swift): plain style, no bezel, "
    "no second surface; replace TextField(...) with PalTextField(label, text:, prompt: Text(...))"
)
BORDERED = re.compile(r"\.textFieldStyle\(\s*\.(?:roundedBorder|squareBorder|bordered)\b")
BARE = re.compile(r"(?<![A-Za-z0-9_])(?:TextField|SecureField|TextEditor)\(")
APPKIT_TYPES = r"(?:NSTextField|NSSearchField|NSSecureTextField|UITextField)"
APPKIT_CREATE = re.compile(
    rf"(?<![A-Za-z0-9_]){APPKIT_TYPES}\((?!\s*(?:wrappingLabelWithString|labelWithString)\b)"
)
APPKIT_SUBCLASS = re.compile(rf"\bclass\s+\w+\s*(?:<[^>{{]*>)?\s*:\s*(?:[\w.]+\s*,\s*)*{APPKIT_TYPES}\b")
INPUT_CALLS = ("PalTextField", "PalTextEditor", "SecretField", "TextField", "SecureField", "TextEditor")
CHROME_MODIFIERS = frozenset({"background", "overlay"})
ROUNDED_SHAPE = re.compile(
    r"\b(?:RoundedRectangle|UnevenRoundedRectangle|ConcentricRectangle|Capsule|Circle)\b"
    r"|\.(?:rect\(\s*cornerRadius|capsule\b|circle\b|strokeBorder\b|stroke\()"
)
MODIFIER = re.compile(r"\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)")


def _line_rule(pattern: re.Pattern[str], rule: str, message: str):
    def scan(src: Source, plain: str):
        for m in pattern.finditer(plain):
            yield rule, src.line_of(m.start()), message

    return scan


def _chain(src: Source, plain: str, end: int):
    """(modifier name, text of its arguments and trailing closure) for each modifier that follows ``end``."""
    index = end + 1
    while True:
        m = MODIFIER.match(plain, index)
        if not m:
            return
        name, cursor = m.group(1), m.end()
        stop = cursor
        if cursor < len(plain) and plain[cursor] == "(" and cursor in src.close:
            stop = src.end_of_call(cursor) + 1
        else:
            trailing = re.compile(r"\s*\{").match(plain, cursor)
            if trailing and (trailing.end() - 1) in src.close:
                stop = src.close[trailing.end() - 1] + 1
        yield name, plain[cursor:stop]
        index = stop


def _chrome(src: Source, plain: str):
    for name in INPUT_CALLS:
        for start, open_index, end in src.calls(name):
            if plain[start:start + len(name)] != name:
                continue
            surfaces = [n for n, body in _chain(src, plain, end) if n in CHROME_MODIFIERS and ROUNDED_SHAPE.search(body)]
            if surfaces:
                yield "glass-input-chrome", src.line_of(start), (
                    f"{name} draws its own rounded surface with .{'/.'.join(dict.fromkeys(surfaces))}; "
                    f"the input carries no background, border or ring (the glass or its container is the surface). {FIX}"
                )


SCANNERS = (
    _line_rule(BORDERED, "glass-input-bordered-style",
               f"bordered text-field style draws a bezel inside the glass; {FIX}"),
    _line_rule(BARE, "glass-input-bare",
               f"bare TextField, SecureField or TextEditor takes the platform bezel (a second grey field on macOS); {FIX}"),
    _line_rule(APPKIT_CREATE, "glass-input-appkit",
               f"native text field created outside the shared component; {FIX}"),
    _line_rule(APPKIT_SUBCLASS, "glass-input-appkit",
               f"native text field subclass outside the shared component; {FIX}"),
    _chrome,
)


@dataclass(frozen=True)
class Waiver:
    path: str
    pattern: str
    reason: str
    line: int


def violations(rel: Path, source: str) -> list[Finding]:
    src = Source(source)
    plain = blank_comments(source)[1]
    found = []
    for scanner in SCANNERS:
        for rule, line, message in scanner(src, plain):
            found.append(Finding(rule, rel.as_posix(), line, src.original[line - 1].strip(), message))
    return found


def load_allowlist(path: Path) -> tuple[list[Waiver], list[Finding]]:
    waivers: list[Waiver] = []
    problems: list[Finding] = []
    if not path.is_file():
        return waivers, problems
    shown = f"scripts/ci/{path.name}"
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        entry = raw.strip()
        if not entry or entry.startswith("#"):
            continue
        target, _, rest = entry.partition(":")
        pattern, _, reason = rest.partition(SEPARATOR)
        if not target.strip() or not pattern.strip() or not reason.strip():
            problems.append(Finding(ALLOWLIST_RULE, shown, number, entry,
                                    "expected '<path>:<line pattern>  <reason>' (two spaces before the reason)"))
            continue
        waivers.append(Waiver(target.strip(), pattern.strip(), reason.strip(), number))
    return waivers, problems


def scoped_files(root: Path) -> list[Path]:
    files = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(root)
        if rel != COMPONENT and not SKIP_DIRS.intersection(rel.parts):
            files.append(path)
    return files


def scan(root: Path, allowlist: Path = ALLOWLIST) -> list[Finding]:
    waivers, found = load_allowlist(allowlist)
    used: Counter[int] = Counter()
    for path in scoped_files(root):
        rel = path.relative_to(root)
        for finding in violations(rel, path.read_text(encoding="utf-8-sig")):
            hit = next((w for w in waivers if w.path == finding.path and w.pattern in finding.text), None)
            if hit:
                used[hit.line] += 1
            else:
                found.append(finding)
    shown = f"scripts/ci/{allowlist.name}"
    for waiver in waivers:
        if not used[waiver.line] and (root / waiver.path).is_file():
            found.append(Finding(ALLOWLIST_RULE, shown, waiver.line, waiver.pattern,
                                 f"stale allowlist entry for {waiver.path} ({waiver.pattern!r}); delete it"))
    return sorted(found, key=lambda f: (f.path, f.line, f.rule))


def main(argv: list[str]) -> int:
    args = argv[1:]
    root = Path(args[0]) if args else Path(__file__).resolve().parents[2] / "apps" / "ios"
    allowlist = Path(args[1]) if len(args) > 1 else ALLOWLIST
    found = scan(root, allowlist)
    for finding in found:
        print(finding.render())
    if found:
        counts = Counter(f.rule for f in found)
        print("\n" + ", ".join(f"{rule}: {n}" for rule, n in sorted(counts.items())))
        print(f"{len(found)} text input finding(s). Every input is one Liquid Glass surface: PalTextField, PalTextEditor "
              "or PalGlassTextField (PalDesign/Components/PalTextInput.swift). "
              "A justified exception is a line of scripts/ci/glass_input_allowlist.txt.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
