#!/usr/bin/env python3
"""Fail when the Pal project's entitlements wiring cannot sign.

The app requests Communication Notifications and the App Group; the notification extension rides the
same App Group but Apple grants the Communication Notifications entitlement only to the app. CI never
signs, so it cannot see either mistake; this reads ``project.yml`` and the entitlements files it names.

Rules (each finding names the file, line and the fix):

* entitlements-missing: a ``CODE_SIGN_ENTITLEMENTS`` path points at no file.
* extension-communication: an extension target's entitlements request the Communication Notifications
  entitlement; signing fails, so remove it from the extension.

Run: python scripts/ci/check_swift_entitlements.py [apps_ios_root]
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

SPEC = "project.yml"
COMMUNICATION_KEY = "com.apple.developer.usernotifications.communication"
EXTENSION_TYPES = ("app-extension", "extensionkit-extension", "xpc-service", "watchkit2-extension")
KEY_LINE = re.compile(r"^(\s*)(\S[^:]*):\s*(.*?)\s*$")


def _read(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8-sig").splitlines()


def _plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def _key_line(path: Path, key: str) -> int:
    for index, line in enumerate(_read(path), start=1):
        if f"<key>{key}</key>" in line:
            return index
    return 1


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _top_block(lines: list[str], name: str) -> list[tuple[int, str]]:
    found, inside = [], False
    for index, line in enumerate(lines, start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if _indent(line) == 0:
            inside = line.rstrip() == f"{name}:"
            continue
        if inside:
            found.append((index, line))
    return found


def _targets(lines: list[str]) -> dict[str, dict]:
    found: dict[str, dict] = {}
    current: dict | None = None
    properties_indent: int | None = None
    entitlements_indent: int | None = None
    for index, line in _top_block(lines, "targets"):
        indent = _indent(line)
        match = KEY_LINE.match(line)
        if not match:
            continue
        key, value = match.group(2), match.group(3)
        if indent == 2 and not value:
            current = {"line": index, "type": "", "entitlement_paths": [], "properties": []}
            found[key] = current
            properties_indent = entitlements_indent = None
            continue
        if current is None:
            continue
        if entitlements_indent is not None and indent <= entitlements_indent:
            entitlements_indent = properties_indent = None
        if key == "entitlements" and not value:
            entitlements_indent = indent
            continue
        if indent == 4 and key == "type":
            current["type"] = value.strip("\"'")
        if key.startswith("CODE_SIGN_ENTITLEMENTS") and value:
            current["entitlement_paths"].append((index, value.strip("\"'")))
        if key == "properties" and not value and entitlements_indent is not None:
            properties_indent = indent
            continue
        if properties_indent is not None:
            if indent > properties_indent:
                current["properties"].append((index, key))
            else:
                properties_indent = None
    return found


def _missing_findings(root: Path) -> list[str]:
    return [
        f"{SPEC}:{line}: entitlements-missing: CODE_SIGN_ENTITLEMENTS points at {rel}, which does not exist"
        for target in _targets(_read(root / SPEC)).values()
        for line, rel in target["entitlement_paths"]
        if not (root / rel).is_file()
    ]


def _extension_findings(root: Path) -> list[str]:
    found = []
    for name, target in _targets(_read(root / SPEC)).items():
        if not target["type"].startswith(EXTENSION_TYPES):
            continue
        for line, key in target["properties"]:
            if key == COMMUNICATION_KEY:
                found.append(_communication_finding(SPEC, line, name))
        for _, rel in target["entitlement_paths"]:
            path = root / rel
            if path.is_file() and COMMUNICATION_KEY in _plist(path):
                found.append(_communication_finding(rel, _key_line(path, COMMUNICATION_KEY), name))
    return found


def _communication_finding(rel: str, line: int, name: str) -> str:
    return (
        f"{rel}:{line}: extension-communication: extension {name} requests {COMMUNICATION_KEY}; "
        "Apple grants it only to the app, so remove it from the extension"
    )


def scan(root: Path) -> list[str]:
    if not (root / SPEC).is_file():
        return []
    return _missing_findings(root) + _extension_findings(root)


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(f"\n{len(found)} entitlement finding(s). Fix the entitlements wiring in {SPEC}.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
