#!/usr/bin/env python3
"""Fail when a model provider the Pal apps can list has no usable brand logo.

The ids are the non-virtual providers of ``hermes_cli.provider_catalog`` (what
``hermes_cli/model_provider_control.py`` serves to the apps), the pre-release ones the catalogue hides
until a user opts in, and ``EXTRA_IDS``. They are read from source (the ``CANONICAL_PROVIDERS`` table and the
provider profiles declared under ``plugins/model-providers``) so the check runs on the bare CI interpreter, without the YAML library. Each needs an entry in ``apps/ios/Design/ProviderLogos/manifest.json``
(written by ``apps/ios/Tools/provider-logos/vendor_provider_logos.py``) and, unless its variant is
``monogram`` or ``symbol``, a vendored imageset under ``App/Assets.xcassets/ProviderLogos``.

Rules: missing-entry, bad-entry, missing-imageset, low-contrast, unflagged-monogram.

Dominant fill: the app draws every logo on a white tile, so the fill that must stay visible is the darkest
paint in the file. Shapes resolve ``fill`` through their ancestors (default black); ``url(#...)`` paints are
skipped and every gradient ``stop-color`` is pooled instead; white fills (cut-outs), ``none`` and paints under half opaque (shadow gradients) are ignored;
clip paths, masks and defs paint nothing. Contrast is the WCAG ratio of white to that fill,
(1.05) / (L + 0.05), and must be at least ``MIN_CONTRAST``.

Run: python scripts/ci/check_provider_logos.py
"""

from __future__ import annotations

import ast
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import NamedTuple

REPO = Path(__file__).resolve().parents[2]
IOS = REPO / "apps" / "ios"
MANIFEST = IOS / "Design" / "ProviderLogos" / "manifest.json"
IMAGESET_DIR = IOS / "App" / "Assets.xcassets" / "ProviderLogos"
VENDOR_TOOL = "apps/ios/Tools/provider-logos/vendor_provider_logos.py"

MIN_CONTRAST = 1.6
FAINT = 0.5
IMAGE_VARIANTS = ("color", "mono-dark")
VARIANTS = (*IMAGE_VARIANTS, "monogram", "symbol")
EXTRA_IDS = ("claude-subscription-directsdk-experimental",)
VIRTUAL_IDS = frozenset({"moa"})
CANONICAL_TABLE = Path("hermes_cli") / "models_catalog_static.py"

SVG = "{http://www.w3.org/2000/svg}"
SHAPES = {"path", "circle", "ellipse", "rect", "polygon", "polyline", "line", "text"}
PAINTLESS = {"defs", "clipPath", "mask", "symbol", "pattern", "marker"}
NAMED = {"white": "#ffffff", "black": "#000000"}
RGB = re.compile(r"rgb\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)")


class Finding(NamedTuple):
    rule: str
    subject: str
    message: str


def _hex(paint: str) -> str | None:
    paint = paint.strip().lower()
    paint = NAMED.get(paint, paint)
    if match := RGB.fullmatch(paint):
        return "#" + "".join(f"{int(part):02x}" for part in match.groups())
    if re.fullmatch(r"#[0-9a-f]{3}", paint):
        return "#" + "".join(c * 2 for c in paint[1:])
    if re.fullmatch(r"#[0-9a-f]{6}([0-9a-f]{2})?", paint):
        return paint[:7]
    if paint in ("none", "transparent") or paint.startswith("url("):
        return None
    raise ValueError(f"unsupported paint {paint!r}")


def luminance(color: str) -> float:
    def channel(value: int) -> float:
        c = value / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (int(color[i : i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def contrast_on_white(color: str) -> float:
    return 1.05 / (luminance(color) + 0.05)


def painted_colors(svg: str) -> set[str]:
    found: set[str] = set()

    def walk(element: ET.Element, inherited: str, paints: bool) -> None:
        tag = element.tag.removeprefix(SVG)
        fill = element.get("fill", inherited)
        faint = float(element.get("stop-opacity" if tag == "stop" else "fill-opacity", "1")) < FAINT
        if tag == "stop" and not faint:
            found.add(_hex(element.get("stop-color", "#000000")) or "#000000")
        if paints and tag in SHAPES and not faint and (color := _hex(fill)) is not None:
            found.add(color)
        for child in element:
            walk(child, fill, paints and tag not in PAINTLESS)

    walk(ET.fromstring(svg), "#000000", True)
    found.discard("#ffffff")
    return found


def dominant_contrast(svg: str) -> float | None:
    colors = painted_colors(svg)
    return max(contrast_on_white(c) for c in colors) if colors else None


def _entry_problems(provider: str, entry: object) -> list[str]:
    if not isinstance(entry, dict):
        return ["entry is not an object"]
    problems = []
    variant = entry.get("variant")
    if variant not in VARIANTS:
        problems.append(f"variant {variant!r} is not one of {', '.join(VARIANTS)}")
    if variant == "symbol" and not entry.get("slug"):
        problems.append("a symbol entry needs the SF Symbol name in slug")
    return problems


def _imageset_problems(provider: str, imageset_dir: Path) -> list[Finding]:
    folder = imageset_dir / f"{provider}.imageset"
    logo, contents = folder / "logo.svg", folder / "Contents.json"
    how = f"run {VENDOR_TOOL} to regenerate it"
    if not logo.is_file():
        return [Finding("missing-imageset", provider, f"{provider}: {logo} is missing. {how}")]
    if not contents.is_file():
        return [Finding("missing-imageset", provider, f"{provider}: {contents} is missing. {how}")]
    try:
        json.loads(contents.read_text(encoding="utf-8-sig"))
        ratio = dominant_contrast(logo.read_text(encoding="utf-8-sig"))
    except (ValueError, ET.ParseError) as error:
        return [Finding("missing-imageset", provider, f"{provider}: unreadable logo files ({error}). {how}")]
    if ratio is None or ratio < MIN_CONTRAST:
        shown = "no visible fill" if ratio is None else f"{ratio:.2f}:1"
        return [Finding("low-contrast", provider,
                        f"{provider}: logo contrast on white is {shown}, below {MIN_CONTRAST}:1. "
                        f"Use a darker variant of the brand file in {VENDOR_TOOL} and run it")]
    return []


def check(root: Path, ids: Iterable[str], manifest_path: Path, imageset_dir: Path) -> list[Finding]:
    try:
        providers = json.loads((root / manifest_path).read_text(encoding="utf-8-sig"))["providers"]
    except (OSError, ValueError, KeyError) as error:
        return [Finding("bad-entry", str(manifest_path), f"manifest unreadable ({error}). Run {VENDOR_TOOL}")]
    found: list[Finding] = []
    for provider in sorted(set(ids)):
        entry = providers.get(provider)
        if entry is None:
            found.append(Finding("missing-entry", provider,
                                 f"{provider}: no logo entry. Add '{provider}' to PROVIDER_SLUGS in {VENDOR_TOOL} "
                                 "(a brand slug from @lobehub/icons-static-svg, or None for a monogram) and run it"))
            continue
        if problems := _entry_problems(provider, entry):
            found += [Finding("bad-entry", provider, f"{provider}: {problem}") for problem in problems]
            continue
        if entry["variant"] in IMAGE_VARIANTS:
            found += _imageset_problems(provider, root / imageset_dir)
        elif entry["variant"] == "monogram" and not entry.get("flag"):
            found.append(Finding("unflagged-monogram", provider,
                                 f"{provider}: monogram without a flag. Set it through {VENDOR_TOOL} so the "
                                 "missing logo is recorded"))
    return found


def _canonical_slugs(table: Path) -> set[str]:
    for node in ast.parse(table.read_text(encoding="utf-8-sig")).body:
        if isinstance(node, ast.AnnAssign) and getattr(node.target, "id", "") == "CANONICAL_PROVIDERS":
            rows = next(g.iter for g in node.value.generators)
            return {row.elts[0].value for row in rows.elts}
    raise SystemExit(f"provider-logos: CANONICAL_PROVIDERS not found in {table}")


def _plugin_profile_names(plugins: Path) -> set[str]:
    names: set[str] = set()
    for source in plugins.glob("*/__init__.py"):
        for node in ast.walk(ast.parse(source.read_text(encoding="utf-8-sig"))):
            if isinstance(node, ast.Call) and "Profile" in ast.unparse(node.func):
                names |= {
                    kw.value.value for kw in node.keywords
                    if kw.arg == "name" and isinstance(kw.value, ast.Constant) and isinstance(kw.value.value, str)
                }
    return names


def catalogue_ids(repo: Path = REPO) -> list[str]:
    slugs = _canonical_slugs(repo / CANONICAL_TABLE) | _plugin_profile_names(repo / "plugins" / "model-providers")
    return sorted({*slugs, *EXTRA_IDS} - VIRTUAL_IDS)


def main(load_ids: Callable[[], list[str]] = catalogue_ids) -> int:
    if not IOS.is_dir():
        return 0
    found = check(REPO, load_ids(), MANIFEST, IMAGESET_DIR)
    for finding in found:
        print(f"provider-logos [{finding.rule}] {finding.message}")
    return 1 if found else 0


if __name__ == "__main__":
    raise SystemExit(main())
