#!/usr/bin/env python3
"""Fail when a catalogued connector would show the puzzle placeholder instead of its brand logo.

The Connect Apps list draws every catalogued connector on the shared white ``BrandLogoTile`` with the imageset its
``icon`` names in ``hermes_cli/data/pal_connectors.yaml``. Only custom and non-catalogued rows keep the puzzle. This
check reads the catalog line by line (no YAML library on the bare CI interpreter) and the manifest
``apps/ios/Design/ConnectorLogos/manifest.json`` written by ``apps/ios/Tools/connector-logos/vendor_connector_logos.py``.

Rules: missing-icon, missing-entry, bad-entry, missing-imageset, low-contrast, unflagged-monogram, dark-variant,
orphan-imageset, puzzle-misuse. Contrast is measured exactly as ``check_provider_logos.py`` does (darkest paint
against the white tile, at least ``MIN_CONTRAST``). ``puzzle-misuse`` is a grep over ``App/ConnectApps``: the
``PluginGlyphTile`` puzzle may appear only in the files listed in ``PUZZLE_ALLOWLIST``, each with a reason; an entry
that matches nothing is itself a finding.

Run: python scripts/ci/check_connector_logos.py
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_provider_logos import MIN_CONTRAST, Finding, dominant_contrast

REPO = Path(__file__).resolve().parents[2]
CATALOG = Path("hermes_cli") / "data" / "pal_connectors.yaml"
IOS = Path("apps") / "ios"
MANIFEST = IOS / "Design" / "ConnectorLogos" / "manifest.json"
IMAGESET_DIR = IOS / "App" / "Assets.xcassets" / "ConnectorLogos"
CONNECT_APPS = IOS / "App" / "ConnectApps"
VENDOR_TOOL = "apps/ios/Tools/connector-logos/vendor_connector_logos.py"

PLACEHOLDER_ICON = "plugin_glyph"
IMAGE_VARIANTS = ("color", "mono-dark")
VARIANTS = (*IMAGE_VARIANTS, "monogram")
PUZZLE = re.compile(r"\bPluginGlyphTile\b")
PUZZLE_ALLOWLIST: dict[str, str] = {
    "ConnectorLogo.swift": "draws the puzzle for custom and non-catalogued rows, chosen by ConnectApp.tileMark",
    "ConnectAppsList.swift": "Skills rows are not connectors and have no brand logo",
    "ConnectAppsMacInstalled.swift": "Private skills rows are not connectors and have no brand logo",
    "ConnectAppsPhoneInstalled.swift": "Private skills rows are not connectors and have no brand logo",
    "SkillsCatalogSheet.swift": "Skills rows are not connectors and have no brand logo",
}


def catalog_icons(catalog: Path) -> dict[str, str]:
    icons: dict[str, str] = {}
    current = None
    for line in catalog.read_text(encoding="utf-8-sig").splitlines():
        if match := re.match(r"- id: (\S+)\s*$", line):
            current = match[1].strip("\"'")
            icons[current] = ""
        elif current and (match := re.match(r"  icon: (.*?)\s*$", line)):
            icons[current] = match[1].strip("\"'")
    return icons


def _manifest_findings(icon: str, entry: object) -> list[Finding]:
    if not isinstance(entry, dict):
        return [Finding("bad-entry", icon, f"{icon}: manifest entry is not an object. Run {VENDOR_TOOL}")]
    problems = []
    variant = entry.get("variant")
    if variant not in VARIANTS:
        problems.append(f"variant {variant!r} is not one of {', '.join(VARIANTS)}")
    if variant in IMAGE_VARIANTS and not str(entry.get("source") or "").startswith("https://"):
        problems.append("no source URL")
    if variant in IMAGE_VARIANTS and not entry.get("license"):
        problems.append("no licence")
    return [Finding("bad-entry", icon, f"{icon}: {problem}. Fix its row in {VENDOR_TOOL} and run it") for problem in problems]


def _imageset_findings(icon: str, imageset_dir: Path) -> list[Finding]:
    folder = imageset_dir / f"{icon}.imageset"
    logo, contents = folder / "logo.svg", folder / "Contents.json"
    how = f"run {VENDOR_TOOL} to regenerate it"
    for needed in (logo, contents):
        if not needed.is_file():
            return [Finding("missing-imageset", icon, f"{icon}: {needed.name} is missing in {folder}. {how}")]
    try:
        json.loads(contents.read_text(encoding="utf-8-sig"))
        ratio = dominant_contrast(logo.read_text(encoding="utf-8-sig"))
    except (ValueError, ET.ParseError) as error:
        return [Finding("missing-imageset", icon, f"{icon}: unreadable logo files ({error}). {how}")]
    if ratio is None or ratio < MIN_CONTRAST:
        shown = "no visible fill" if ratio is None else f"{ratio:.2f}:1"
        return [Finding("low-contrast", icon,
                        f"{icon}: logo contrast on white is {shown}, below {MIN_CONTRAST}:1. "
                        f"Pick a darker variant of the brand mark in {VENDOR_TOOL} and run it")]
    return []


def _dark_variant_findings(imageset_dir: Path) -> list[Finding]:
    found = []
    for folder in sorted(imageset_dir.glob("*.imageset")):
        icon = folder.name.removesuffix(".imageset")
        stale = [path.name for path in folder.glob("dark*.svg")]
        contents = folder / "Contents.json"
        appearances = contents.is_file() and '"appearances"' in contents.read_text(encoding="utf-8-sig")
        if stale or appearances:
            found.append(Finding("dark-variant", icon,
                                 f"{icon}: the tile is white in dark mode too, so a dark variant ({', '.join(stale) or 'appearances'}) "
                                 f"is never drawn. Keep one universal logo.svg: {VENDOR_TOOL}"))
    return found


def _puzzle_findings(root: Path) -> list[Finding]:
    found = []
    used: set[str] = set()
    for source in sorted((root / CONNECT_APPS).glob("*.swift")):
        if PUZZLE.search(source.read_text(encoding="utf-8-sig")):
            used.add(source.name)
            if source.name not in PUZZLE_ALLOWLIST:
                found.append(Finding("puzzle-misuse", source.name,
                                     f"{source.name}: PluginGlyphTile is the custom/non-catalogued puzzle only. Draw a connector "
                                     "with ConnectorLogoTile(app:) so a catalogued one gets its brand logo"))
    for name in sorted(set(PUZZLE_ALLOWLIST) - used):
        found.append(Finding("puzzle-misuse", name, f"{name}: no longer uses PluginGlyphTile. Remove it from PUZZLE_ALLOWLIST"))
    return found


def check(root: Path) -> list[Finding]:
    try:
        manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8-sig"))["logos"]
    except (OSError, ValueError, KeyError) as error:
        return [Finding("bad-entry", str(MANIFEST), f"manifest unreadable ({error}). Run {VENDOR_TOOL}")]
    found: list[Finding] = []
    icons = catalog_icons(root / CATALOG)
    wanted: set[str] = set()
    for connector, icon in icons.items():
        if not icon or icon == PLACEHOLDER_ICON:
            found.append(Finding("missing-icon", connector,
                                 f"{connector}: icon is {icon or 'empty'!r}, the puzzle placeholder. Set `icon:` in {CATALOG.name} "
                                 f"to a logo id from {VENDOR_TOOL} (add the brand there first)"))
        else:
            wanted.add(icon)
    for icon in sorted(wanted):
        entry = manifest.get(icon)
        if entry is None:
            found.append(Finding("missing-entry", icon,
                                 f"{icon}: no logo entry. Add '{icon}' to LOGOS in {VENDOR_TOOL} (an Iconify or Simple Icons "
                                 "slug, a brand file, or a flagged monogram) and run it"))
            continue
        if problems := _manifest_findings(icon, entry):
            found += problems
        elif entry["variant"] in IMAGE_VARIANTS:
            found += _imageset_findings(icon, root / IMAGESET_DIR)
        elif not entry.get("flag"):
            found.append(Finding("unflagged-monogram", icon,
                                 f"{icon}: monogram without a flag. Set it through {VENDOR_TOOL} so the missing logo is recorded"))
    for folder in sorted((root / IMAGESET_DIR).glob("*.imageset")):
        icon = folder.name.removesuffix(".imageset")
        if icon not in wanted:
            found.append(Finding("orphan-imageset", icon,
                                 f"{icon}: no catalog entry uses this imageset. Delete {folder.name} or set an `icon:` to it"))
    return [*found, *_dark_variant_findings(root / IMAGESET_DIR), *_puzzle_findings(root)]


def main() -> int:
    if not (REPO / IOS).is_dir():
        return 0
    found = check(REPO)
    for finding in found:
        print(f"connector-logos [{finding.rule}] {finding.message}")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
