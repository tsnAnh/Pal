#!/usr/bin/env python3
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
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return []
    return sorted({node.lineno for node in ast.walk(tree)
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)
                   and names_ledger_table(node.value)})


def find_ledger_sql(root: Path) -> list[tuple[str, int]]:
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
