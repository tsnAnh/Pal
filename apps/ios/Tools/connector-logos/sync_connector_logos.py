#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))

from hermes_cli.pal_connectors import load_pal_connectors

LOGO_DIR = REPO / "apps" / "ios" / "App" / "Assets.xcassets" / "ConnectorLogos"
SLUG_OVERRIDES = {
    "hugging_face": "huggingface",
    "prisma-postgres": "prisma",
    "unreal-engine": "unrealengine",
    "wordpress-com": "wordpress",
}
FLIP_BELOW = 0.18
FLIP_ABOVE = 0.85
LIGHT_ON_DARK = "FFFFFF"
DARK_ON_LIGHT = "1D1D1F"


def luminance(hex_color: str) -> float:
    def channel(value: int) -> float:
        c = value / 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (int(hex_color[i : i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)


def tinted(svg: str, color: str) -> str:
    return re.sub(r"<svg\b", f'<svg fill="#{color}"', svg, count=1)


def renderings(brand: str) -> tuple[str, str]:
    lum = luminance(brand)
    light = DARK_ON_LIGHT if lum > FLIP_ABOVE else brand
    dark = LIGHT_ON_DARK if lum < FLIP_BELOW else brand
    return light, dark


def write_imageset(entry_id: str, svg: str, brand: str) -> None:
    light, dark = renderings(brand)
    folder = LOGO_DIR / f"{entry_id}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    for stale in folder.glob("*.svg"):
        stale.unlink()
    images = [{"filename": "light.svg", "idiom": "universal"}]
    (folder / "light.svg").write_text(tinted(svg, light), encoding="utf-8")
    if dark != light:
        (folder / "dark.svg").write_text(tinted(svg, dark), encoding="utf-8")
        images.append({"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "dark.svg", "idiom": "universal"})
    contents = {"images": images, "info": {"author": "xcode", "version": 1}, "properties": {"preserves-vector-representation": True}}
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Write one asset set per catalog entry from an unpacked simple-icons npm package.")
    parser.add_argument("package", type=Path, help="directory holding icons/ and data/simple-icons.json")
    package = parser.parse_args().package
    brands = {item.get("slug") or re.sub(r"[^a-z0-9]", "", item["title"].lower()): item["hex"] for item in json.loads((package / "data" / "simple-icons.json").read_text(encoding="utf-8"))}
    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    (LOGO_DIR / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, indent=2) + "\n", encoding="utf-8")
    missing = []
    for entry in load_pal_connectors():
        slug = SLUG_OVERRIDES.get(entry.id, entry.id)
        source = package / "icons" / f"{slug}.svg"
        if not source.is_file() or slug not in brands:
            missing.append(entry.id)
            continue
        write_imageset(entry.id, source.read_text(encoding="utf-8"), brands[slug])
    print("no simple-icons mark:", " ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
