#!/usr/bin/env python3
"""Fail when SQL naming the commitment ledger tables appears outside gateway/commitments.py.

``gateway/commitments.py`` is the only module that reads or writes ``commitments`` and ``commitment_events``;
every other caller goes through its functions, so the state machine cannot be bypassed.

Flags, in every Python file outside that module and any ``tests`` directory, a string constant (pieces of an
f-string included) in which a SQL keyword (INSERT INTO, REPLACE INTO, UPDATE ... SET, DELETE FROM, FROM, JOIN,
DROP TABLE, ALTER TABLE, CREATE TABLE, CREATE TRIGGER ... ON) is followed by one of the table names, matched
case-insensitively across whitespace. Prose that merely says "commitments" does not match.

Run: python scripts/ci/check_commitment_writers.py [--root DIR]
Exit 1 on any violation, 0 when clean.
"""

from __future__ import annotations

import argparse
import ast
import os
import re
from pathlib import Path

_OWNER = "gateway/commitments.py"
_SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "__pycache__", "tests"}
_TABLE = r"""["`\[]?\b(?:commitments|commitment_events)\b["`\]]?"""
_KEYWORDS = (
    r"""\binsert\s+(?:or\s+\w+\s+)?into|\breplace\s+into|\bdelete\s+from|\bfrom|\bjoin"""
    r"""|\bdrop\s+table(?:\s+if\s+exists)?|\balter\s+table|\bcreate\s+table(?:\s+if\s+not\s+exists)?"""
    r"""|\bcreate\s+(?:temp\s+|temporary\s+)?trigger\b[^;]*?\bon"""
)
_SQL = re.compile(rf"(?:{_KEYWORDS})\s+{_TABLE}|\bupdate(?:\s+or\s+\w+)?\s+{_TABLE}\s+set\b", re.IGNORECASE)


def names_ledger_table(text: str) -> bool:
    return _SQL.search(text) is not None


def ledger_sql_lines(source: str) -> list[int]:
    """Line numbers of the string constants in ``source`` that run SQL on a ledger table."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []
    return sorted({node.lineno for node in ast.walk(tree)
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)
                   and names_ledger_table(node.value)})


def find_ledger_sql(root: Path) -> list[tuple[str, int]]:
    """``(path, line)`` of every ledger SQL string outside the owning module."""
    root = root.resolve()
    if not root.is_dir():
        raise ValueError(f"repository root is not a directory: {root}")
    offenders = []
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(name for name in dirnames if name not in _SKIP_DIRS)
        for name in sorted(filenames):
            if not name.endswith(".py"):
                continue
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            if rel == _OWNER:
                continue
            try:
                source = path.read_text(encoding="utf-8-sig")
            except (OSError, UnicodeDecodeError):
                continue
            if "commitment" not in source.lower():
                continue
            offenders.extend((rel, line) for line in ledger_sql_lines(source))
    return offenders


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Reject SQL on the commitment ledger tables outside its module.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="repository root to inspect (default: this checkout)")
    args = parser.parse_args(argv)
    try:
        offenders = find_ledger_sql(args.root)
    except ValueError as exc:
        parser.error(str(exc))
    if not offenders:
        print(f"No SQL on the commitment tables outside {_OWNER}.")
        return 0
    print("::error::the commitment ledger tables are used outside their owner")
    for rel, line in offenders:
        print(f"  {rel}:{line}")
    print(f"Go through the functions of {_OWNER}; it is the only module that touches these tables.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
