#!/usr/bin/env python3
"""Fail when a user-visible string in the Pal Swift apps says "Hermes".

The apps/ios product is branded Pal. Code names (modules, types, bundle ids, Keychain
services, RPC methods) keep "Hermes"; anything a person reads must not. A Swift string
literal outside the test targets that contains the whole word ``Hermes`` fails this
check, unless its line carries ``brand: ok`` or the literal is on the allowlist below
(URLs, reverse-DNS identifiers, import lines).

Run: python scripts/ci/check_swift_brand.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OPT_OUT = "brand: ok"
SKIP_DIRS = {"Tests", "UITests", "Fixtures", ".build"}
WORD = re.compile(r"(?<![A-Za-z0-9_])Hermes(?![A-Za-z0-9_])")
ALLOW = (
    re.compile(r"https?://\S*Hermes", re.IGNORECASE),
    re.compile(r"[a-z]+(?:\.[A-Za-z0-9_-]+)+Hermes"),
)


def _literal(source: str, i: int, out: list[tuple[int, str]]) -> int:
    """Parse the string literal opening at ``i``; append it and any nested ones to ``out``."""
    hashes = 0
    while source[i + hashes] == "#":
        hashes += 1
    j = i + hashes
    multi = source.startswith('"""', j)
    close = ('"""' if multi else '"') + "#" * hashes
    opener = "\\" + "#" * hashes + "("
    start = k = j + (3 if multi else 1)
    slot = len(out)
    out.append((0, ""))
    while k < len(source) and not source.startswith(close, k):
        if source.startswith(opener, k):
            k = _skip_interpolation(source, k + len(opener), out)
        elif source[k] == "\\" and not hashes:
            k += 2
        else:
            k += 1
    out[slot] = (source.count("\n", 0, i) + 1, source[start:k])
    return k + len(close)


def _skip_interpolation(source: str, k: int, out: list[tuple[int, str]]) -> int:
    depth = 1
    while k < len(source) and depth:
        ch = source[k]
        if ch == '"':
            k = _literal(source, k, out)
            continue
        depth += (ch == "(") - (ch == ")")
        k += 1
    return k


def swift_literals(source: str) -> list[tuple[int, str]]:
    """Every string literal as (line number, text); comments are skipped."""
    out: list[tuple[int, str]] = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            i = source.find("\n", i)
            i = n if i < 0 else i
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif source[i] == '"' or (source[i] == "#" and re.match(r"#+\"", source[i:i + 8])):
            i = _literal(source, i, out)
        else:
            i += 1
    return out


def violations(path: Path, source: str) -> list[str]:
    lines = source.splitlines()
    found = []
    for lineno, text in swift_literals(source):
        if not WORD.search(text) or any(p.search(text) for p in ALLOW):
            continue
        if OPT_OUT in lines[lineno - 1]:
            continue
        found.append(f"{path}:{lineno}: user-visible string says Hermes: {text.strip()[:100]!r}")
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
        print(f'\n{len(found)} string(s) say "Hermes". The product is Pal: reword them, or add "// {OPT_OUT}" '
              "on the line when the text is an identifier, not something a person reads.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
