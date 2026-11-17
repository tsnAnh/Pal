from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from datetime import datetime

FIELDS = ("ts", "trace", "method", "code", "reason", "device_kind", "device_name", "app_build",
          "gateway_version", "params_shape", "scope", "source")
_TABLE = (("time", 19), ("method", 28), ("code", 6), ("reason", 22), ("device", 24), ("build", 10),
          ("gateway", 10), ("trace", 16))


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def read_recent(*, minutes: int, limit: int, method: str | None, root=None,
                now: float | None = None) -> list[dict] | None:
    from gateway.diag_ledger import _db_path
    path = _db_path(root)
    if not path.is_file():
        return None
    since = (time.time() if now is None else now) - minutes * 60
    query = f"SELECT {', '.join(FIELDS)} FROM faults WHERE ts >= ?"
    args: list = [since]
    if method:
        query += " AND method = ?"
        args.append(method)
    query += " ORDER BY ts DESC, id DESC LIMIT ?"
    args.append(limit)
    conn = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    try:
        conn.row_factory = sqlite3.Row
        return [dict(row) for row in conn.execute(query, args)]
    finally:
        conn.close()


def _row_cells(row: dict) -> tuple[str, ...]:
    device = " ".join(part for part in (row["device_kind"], row["device_name"]) if part)
    return (datetime.fromtimestamp(row["ts"]).strftime("%Y-%m-%d %H:%M:%S"), row["method"],
            "" if row["code"] is None else str(row["code"]), row["reason"], device, row["app_build"],
            row["gateway_version"], row["trace"])


def _print_table(rows: list[dict]) -> None:
    print("  ".join(name.ljust(width) for name, width in _TABLE).rstrip())
    for row in rows:
        print("  ".join(cell.ljust(width) for cell, (_, width) in zip(_row_cells(row), _TABLE)).rstrip())


def cmd_diag(args: argparse.Namespace) -> int:
    minutes = _clamp(args.minutes, 1, 10080)
    limit = _clamp(args.limit, 1, 200)
    try:
        rows = read_recent(minutes=minutes, limit=limit, method=args.method)
    except sqlite3.Error as exc:
        print(f"could not read the fault ledger ({type(exc).__name__}: {exc})", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(rows or [], indent=2))
    elif rows is None:
        print("No fault ledger on this host yet: the gateway has recorded no faults.")
    elif not rows:
        print(f"No faults recorded in the last {minutes} minute(s).")
    else:
        _print_table(rows)
    return 0


def build_diag_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "diag", help="Read the gateway's local fault ledger (read-only).",
        description="Read faults the gateway recorded on this host. Local file only; no network, no token.")
    sub = parser.add_subparsers(dest="diag_action", required=True)
    recent = sub.add_parser(
        "recent", help="List recent gateway faults, newest first.",
        description="List recent gateway faults, newest first. Fields: " + ", ".join(FIELDS)
        + ". device_kind is mac or iphone; the ledger holds no parameter values.")
    recent.add_argument("--minutes", type=int, default=10, help="Look back N minutes (1..10080, default 10).")
    recent.add_argument("--limit", type=int, default=50, help="At most N rows (1..200, default 50).")
    recent.add_argument("--method", help="Only faults for this RPC method.")
    recent.add_argument("--json", action="store_true", help="Print the rows as a JSON array.")
    recent.set_defaults(func=cmd_diag)
