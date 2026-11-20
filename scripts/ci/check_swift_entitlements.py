#!/usr/bin/env python3
"""Fail when the default Pal project asks for a capability a plain developer account cannot sign.

A plain ``xcodegen`` then ``xcodebuild`` (Debug or Release, macOS or iOS, automatic signing) must build on a
developer account that has only the default capabilities. CI never signs, so it cannot see an entitlement, an
extension App ID or an App Group that the account lacks. Anything beyond ``ALLOWED_KEYS`` lives behind the
``PAL_COMM_NOTIFICATIONS`` switch: ``project.yml`` includes ``Variants/CommNotifications/comm-notifications.yml``
only when ``PAL_COMM_NOTIFICATIONS=1``, and that tree holds the extension target, the entitlements that need
the capability and the App Group.

Rules (each finding names the file, line and the fix):

* entitlement-key: an ``*.entitlements`` file outside ``Variants/CommNotifications`` (or a ``properties:`` block
  in project.yml) requests a key that is not in ``ALLOWED_KEYS``.
* switched-key: such a file requests a key that needs the capability (``SWITCHED_KEYS``).
* extension-target: project.yml declares an extension target; extensions need their own App ID.
* switch-wiring: the variant tree exists but project.yml does not include it with
  ``enable: ${PAL_COMM_NOTIFICATIONS}``, or includes it unconditionally.
* variant-parity: a variant entitlements file lacks a key (or value) of the default file it replaces, so
  building with the switch ON would drop it.
* entitlements-missing: a ``CODE_SIGN_ENTITLEMENTS`` path points at no file.

Run: python scripts/ci/check_swift_entitlements.py [apps_ios_root]
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

SWITCH = "PAL_COMM_NOTIFICATIONS"
VARIANT_DIR = "Variants/CommNotifications"
SPEC = "project.yml"
SKIP_DIRS = {".build", "build", "DerivedData", "Pods", "node_modules"}
ALLOWED_KEYS = {
    "aps-environment",
    "com.apple.developer.aps-environment",
    "com.apple.developer.homekit",
    "com.apple.security.automation.apple-events",
    "com.apple.security.device.audio-input",
    "com.apple.security.device.camera",
    "com.apple.security.personal-information.addressbook",
    "com.apple.security.personal-information.calendars",
    "com.apple.security.personal-information.location",
}
SWITCHED_KEYS = {
    "com.apple.developer.usernotifications.communication",
    "com.apple.security.application-groups",
}
EXTENSION_TYPES = ("app-extension", "extensionkit-extension", "xpc-service", "watchkit2-extension")
FIX_SWITCH = (
    f"put it behind {SWITCH}: the entitlement goes in {VARIANT_DIR}/<Target>[-macOS].entitlements and an extension "
    f"target in {VARIANT_DIR}/comm-notifications.yml, which project.yml includes only when {SWITCH}=1; "
    "a plain xcodegen build must sign on an account without the capability"
)
FIX_KEY = (
    f"{FIX_SWITCH}; add the key to ALLOWED_KEYS in scripts/ci/check_swift_entitlements.py only if every "
    "developer account can sign it"
)
KEY_LINE = re.compile(r"^(\s*)(\S[^:]*):\s*(.*?)\s*$")


def _read(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8-sig").splitlines()


def _entitlement_files(root: Path) -> list[Path]:
    return sorted(
        path for path in root.rglob("*.entitlements") if not SKIP_DIRS.intersection(path.relative_to(root).parts)
    )


def _plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def _key_line(path: Path, key: str) -> int:
    for index, line in enumerate(_read(path), start=1):
        if f"<key>{key}</key>" in line:
            return index
    return 1


def _in_variant(rel: str) -> bool:
    return rel.startswith(VARIANT_DIR + "/")


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


def _includes(lines: list[str]) -> list[dict]:
    found: list[dict] = []
    for index, line in _top_block(lines, "include"):
        stripped = line.strip()
        if stripped.startswith("- "):
            body = stripped[2:].strip()
            entry = {"line": index, "path": "", "enable": None}
            if body.startswith("path:"):
                entry["path"] = body.split(":", 1)[1].strip().strip("\"'")
            else:
                entry["path"] = body.strip("\"'")
            found.append(entry)
        elif found and stripped.startswith("enable:"):
            found[-1]["enable"] = stripped.split(":", 1)[1].strip().strip("\"'")
        elif found and stripped.startswith("path:"):
            found[-1]["path"] = stripped.split(":", 1)[1].strip().strip("\"'")
    return found


def _entitlement_findings(root: Path) -> list[str]:
    found = []
    for path in _entitlement_files(root):
        rel = path.relative_to(root).as_posix()
        if _in_variant(rel):
            continue
        for key in _plist(path):
            line = _key_line(path, key)
            if key in SWITCHED_KEYS:
                found.append(f"{rel}:{line}: switched-key: {key} needs a capability a plain developer account lacks; {FIX_SWITCH}")
            elif key not in ALLOWED_KEYS:
                found.append(f"{rel}:{line}: entitlement-key: {key} is not an entitlement every developer account can sign; {FIX_KEY}")
    return found


def _spec_findings(root: Path) -> list[str]:
    spec = root / SPEC
    lines = _read(spec)
    found = []
    for name, target in _targets(lines).items():
        if target["type"].startswith(EXTENSION_TYPES):
            found.append(
                f"{SPEC}:{target['line']}: extension-target: target {name} is of type {target['type']} and needs its own App ID; {FIX_SWITCH}"
            )
        for line, key in target["properties"]:
            if key in SWITCHED_KEYS:
                found.append(f"{SPEC}:{line}: switched-key: {key} needs a capability a plain developer account lacks; {FIX_SWITCH}")
            elif key not in ALLOWED_KEYS:
                found.append(f"{SPEC}:{line}: entitlement-key: {key} is not an entitlement every developer account can sign; {FIX_KEY}")
    variant_spec = root / VARIANT_DIR / "comm-notifications.yml"
    included = [item for item in _includes(lines) if item["path"].startswith(VARIANT_DIR)]
    for item in included:
        if item["enable"] != "${" + SWITCH + "}":
            found.append(
                f"{SPEC}:{item['line']}: switch-wiring: {item['path']} must be included with `enable: ${{{SWITCH}}}` "
                f"so a plain xcodegen leaves it out"
            )
    if variant_spec.is_file() and not included:
        found.append(f"{SPEC}:1: switch-wiring: {VARIANT_DIR}/comm-notifications.yml is never included; add it under `include:` with `enable: ${{{SWITCH}}}`")
    return found


def _missing_findings(root: Path) -> list[str]:
    found = []
    specs = [root / SPEC]
    variant_spec = root / VARIANT_DIR / "comm-notifications.yml"
    if variant_spec.is_file():
        specs.append(variant_spec)
    for spec in specs:
        rel_spec = spec.relative_to(root).as_posix()
        for target in _targets(_read(spec)).values():
            for line, rel in target["entitlement_paths"]:
                if not (root / rel).is_file():
                    found.append(f"{rel_spec}:{line}: entitlements-missing: CODE_SIGN_ENTITLEMENTS points at {rel}, which does not exist")
    return found


def _parity_findings(root: Path) -> list[str]:
    found = []
    variants = root / VARIANT_DIR
    if not variants.is_dir():
        return found
    for variant in sorted(variants.glob("*.entitlements")):
        default = root / "App" / variant.name
        if not default.is_file():
            continue
        on, off = _plist(variant), _plist(default)
        for key, value in off.items():
            if on.get(key) != value:
                found.append(
                    f"{variant.relative_to(root).as_posix()}:1: variant-parity: lacks {key} that "
                    f"{default.relative_to(root).as_posix()} sets; the {SWITCH}=1 build must request everything the default does"
                )
    return found


def scan(root: Path) -> list[str]:
    if not (root / SPEC).is_file():
        return []
    return _spec_findings(root) + _entitlement_findings(root) + _missing_findings(root) + _parity_findings(root)


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[2] / "apps" / "ios"
    found = scan(root)
    for entry in found:
        print(entry)
    if found:
        print(
            f"\n{len(found)} entitlement finding(s). The default build must sign without the Communication "
            f"Notifications capability, an extension App ID or an App Group; {SWITCH}=1 turns them on."
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
