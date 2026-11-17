#!/usr/bin/env python3
"""Fail when a PalKit error enum that classifies gateway errors cannot hand its GatewayFault to a screen.

A screen shows a failure through the shared status layout, whose Details button needs the
``GatewayFault`` (method, code, reason, trace). An ``enum ...Error`` or ``enum ...Failure`` under
``apps/ios/Packages/PalKit/Sources`` whose body reads ``GatewayTransportError`` or ``RPCError`` wraps
gateway calls, so it must declare ``var fault: GatewayFault?`` or conform to ``FaultCarrying``. An
enum that legitimately cannot is listed with its reason in ``swift_fault_details_allowlist.txt``.

Run: python scripts/ci/check_swift_fault_details.py [apps_ios_root]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCES = Path("Packages/PalKit/Sources")
ALLOWLIST = HERE / "swift_fault_details_allowlist.txt"
ENUM = re.compile(r"^[ \t]*(?:public\s+|internal\s+|package\s+)?enum\s+(\w+(?:Error|Failure))\b([^{\n]*)\{", re.MULTILINE)
GATEWAY = re.compile(r"\b(?:GatewayTransportError|RPCError)\b")
FAULT = re.compile(r"\bvar\s+fault\s*:\s*GatewayFault\?")


def _body(source: str, open_brace: int) -> str:
    depth = 0
    for i in range(open_brace, len(source)):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        if depth == 0:
            return source[open_brace:i + 1]
    return source[open_brace:]


def load_allowlist(path: Path = ALLOWLIST) -> dict[str, str]:
    entries = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name, _, reason = line.partition(":")
        if not reason.strip():
            raise SystemExit(f"{path.name}: {name.strip()} needs a reason after ':'")
        entries[name.strip()] = reason.strip()
    return entries


def violations(path: Path, source: str, allowed: dict[str, str]) -> list[str]:
    found = []
    for match in ENUM.finditer(source):
        name, conformances = match.group(1), match.group(2)
        body = _body(source, match.end() - 1)
        if not GATEWAY.search(body) or name in allowed:
            continue
        if "FaultCarrying" in conformances or FAULT.search(body):
            continue
        line = source.count("\n", 0, match.start()) + 1
        found.append(f"{path}:{line}: {name} wraps gateway errors but exposes no `var fault: GatewayFault?`")
    return found


def scan(ios_root: Path, allowed: dict[str, str]) -> list[str]:
    root = ios_root / SOURCES
    found = []
    for path in sorted(root.rglob("*.swift")):
        found += violations(path.relative_to(root), path.read_text(encoding="utf-8-sig"), allowed)
    return found


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else HERE.parents[1] / "apps" / "ios"
    found = scan(root, load_allowlist())
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} fault-details finding(s). Keep the GatewayFault (a `faulted(..., GatewayFault)` case and "
              "`public var fault: GatewayFault?`) so the status layout can show Details, or add the enum to "
              f"scripts/ci/{ALLOWLIST.name} with the reason it cannot carry one.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
