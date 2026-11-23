#!/usr/bin/env python3
"""Vendor one brand logo per Connect Apps catalog icon into the asset catalogue, and write its manifest.

LOGOS maps a logo id (the ``icon:`` of ``hermes_cli/data/pal_connectors.yaml``) to where its mark comes from.
Every logo is one universal ``logo.svg`` that reads on the white tile the apps draw it on, so there is no
dark variant. Sources, in the order to try them: ``simple`` (a Simple Icons file already vendored in the
imageset, CC0-1.0), ``iconify`` (the Iconify ``logos`` collection of gilbarbara/logos, CC0-1.0), ``recolour`` (a
Simple Icons path in one flat ink for a brand colour too pale on white), ``brand`` (the brand's own file from its
site or press kit, with the terms recorded), then ``monogram`` (initials on the white tile, always flagged).
Never hand-draw a path. Trademarks stay with their owners.

Writes App/Assets.xcassets/ConnectorLogos/<id>.imageset/{logo.svg,Contents.json} and
Design/ConnectorLogos/manifest.json, and removes imagesets of ids no longer in the table.
scripts/ci/check_connector_logos.py fails CI when a catalog icon has no entry or imageset, a logo is too pale
on white, or a dark variant comes back.

Run: python apps/ios/Tools/connector-logos/vendor_connector_logos.py
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import urllib.request
from pathlib import Path
from typing import NamedTuple

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts" / "ci"))

from check_connector_logos import IMAGESET_DIR, MANIFEST, MIN_CONTRAST
from check_provider_logos import dominant_contrast

ICONIFY = "https://api.iconify.design/{prefix}/{name}.svg"
ICONIFY_LOGOS_SOURCE = "https://github.com/gilbarbara/logos/blob/master/logos/{name}.svg"
SIMPLE_SOURCE = "https://github.com/simple-icons/simple-icons/blob/develop/icons/{slug}.svg"
CC0 = "CC0-1.0"
FETCHED = "2026-11-23"
REPO_VERSION = "vendored in 8020ca77"
INK = "#1A1A1A"
NEUTRAL_SPREAD = 24

IMAGESETS = REPO / IMAGESET_DIR
MANIFEST_PATH = REPO / MANIFEST


class Spec(NamedTuple):
    kind: str
    ref: str
    flag: str | None = None
    license: str | None = None


def simple(slug: str, flag: str | None = None) -> Spec:
    return Spec("simple", slug, flag, CC0)


def iconify(name: str, flag: str | None = None) -> Spec:
    return Spec("iconify", name, flag, CC0)


def brand(url: str, license: str, flag: str | None = None) -> Spec:
    return Spec("brand", url, flag, license)


def monogram(reason: str) -> Spec:
    return Spec("monogram", "", f"no-logo-found: monogram fallback ({reason})")


CONTRAST_FLAG = "replaced: the repo mark was too pale on white"

LOGOS: dict[str, Spec] = {
    "airtable": simple("airtable"),
    "atlassian": simple("atlassian"),
    "aws-knowledge": iconify("aws", "AWS mark for AWS Knowledge: owner review of AWS trademark terms"),
    "buildkite": simple("buildkite"),
    "calendly": simple("calendly"),
    "canva": simple("canva"),
    "circleci": simple("circleci"),
    "clickhouse": Spec("recolour", "clickhouse", "recolour: brand yellow is 1.5:1 on white, near-black used; owner review", CC0),
    "clickup": simple("clickup"),
    "cloudflare": simple("cloudflare"),
    "cloudinary": simple("cloudinary"),
    "comfy-cloud": simple("comfy-cloud"),
    "context7": brand("https://raw.githubusercontent.com/upstash/context7/master/public/context7-icon.svg", "MIT (Upstash repo)",
                      "official repo icon: the repo licence does not address the trademark, owner review"),
    "craft": monogram("Craft brand terms: assets unaltered, never combined with other graphics, written consent needed"),
    "datadog": simple("datadog"),
    "deepwiki": monogram("deepwiki.com blocks automated fetches and cognition.ai/brand has no DeepWiki mark"),
    "discord": iconify("discord-icon"),
    "dropbox": simple("dropbox"),
    "figma": simple("figma"),
    "gamma": brand("https://cdn.gamma.app/gdwwhyewwldwc8z/e8a5cedfa4b74512af84b7b5f00770ca/optimized/Gamma_Social_Avatar_Dark-2.svg",
                  "none stated (brand.gamma.app brand page)", "licence not stated on the brand page: owner review"),
    "github": simple("github"),
    "gitlab": simple("gitlab"),
    "google-ads": iconify("google-ads"),
    "google-workspace": iconify("google-icon", "generic Google G mark, not the Workspace logo (the set has only a wordmark): owner review"),
    "grafana": simple("grafana"),
    "higgsfield": iconify("higgsfield-icon"),
    "hugging_face": iconify("hugging-face-icon", CONTRAST_FLAG),
    "intercom": iconify("intercom-icon", CONTRAST_FLAG),
    "linear": simple("linear"),
    "microsoft-learn": iconify("microsoft-icon"),
    "mintlify": simple("mintlify"),
    "miro": simple("miro"),
    "monday": iconify("monday-icon"),
    "motherduck": monogram("the site has no standalone icon file, only the nav logo"),
    "neon": simple("neon"),
    "netlify": simple("netlify"),
    "notion": simple("notion"),
    "paypal": iconify("paypal"),
    "posthog": iconify("posthog-icon"),
    "postman": simple("postman"),
    "prisma-postgres": simple("prisma"),
    "railway": simple("railway"),
    "resend": iconify("resend-icon"),
    "semgrep": brand("https://semgrep.dev/build/assets/favicon-CIx-xpG_.svg", "none stated (the site's own favicon)",
                     "licence not stated: owner review"),
    "sentry": simple("sentry"),
    "shopify": iconify("shopify"),
    "slack": iconify("slack-icon"),
    "stripe": simple("stripe"),
    "supabase": simple("supabase"),
    "t3code": brand("https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/prod/logo.svg", "MIT (T3 Code repo)",
                    "T3 Code's own repo mark, not the T3 Stack mark; the repo licence does not address the trademark: owner review"),
    "todoist": simple("todoist"),
    "trello": simple("trello"),
    "twilio-docs": iconify("twilio-icon"),
    "unreal-engine": simple("unrealengine"),
    "upwork": simple("upwork"),
    "vercel": simple("vercel"),
    "webflow": simple("webflow"),
    "wolfram": simple("wolframmathematica"),
    "wordpress-com": simple("wordpress"),
}


def fetch(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def em_to_pixels(svg: str) -> str:
    def pixels(match: re.Match[str]) -> str:
        return f'{match[1]}="{round(float(match[2]) * 24, 2):g}"'

    return re.sub(r'\b(width|height)="([\d.]+)em"', pixels, svg)


def recoloured(svg: str, ink: str) -> str:
    return re.sub(r"<svg\b", f'<svg fill="{ink}"', svg.replace("currentColor", ink), count=1)


def fill_spread(svg: str) -> int:
    colors = re.findall(r'fill="#([0-9a-fA-F]{6})"', svg)
    channels = [int(colors[0][i : i + 2], 16) for i in (0, 2, 4)] if colors else [0, 0, 0]
    return max(channels) - min(channels)


def variant_of(svg: str) -> str:
    return "mono-dark" if fill_spread(svg) <= NEUTRAL_SPREAD else "color"


def existing_logo(logo_id: str) -> str:
    folder = IMAGESETS / f"{logo_id}.imageset"
    for name in ("logo.svg", "light.svg"):
        if (folder / name).is_file():
            return (folder / name).read_text(encoding="utf-8")
    raise SystemExit(f"{logo_id}: no vendored Simple Icons file in {folder}; fetch it first")


def render(logo_id: str, spec: Spec) -> tuple[str, str, str]:
    if spec.kind == "simple":
        svg = existing_logo(logo_id)
        return svg, SIMPLE_SOURCE.format(slug=spec.ref), REPO_VERSION
    if spec.kind == "iconify":
        svg = em_to_pixels(fetch(ICONIFY.format(prefix="logos", name=spec.ref)))
        return svg, ICONIFY_LOGOS_SOURCE.format(name=spec.ref), FETCHED
    if spec.kind == "recolour":
        svg = recoloured(em_to_pixels(fetch(ICONIFY.format(prefix="simple-icons", name=spec.ref))), INK)
        return svg, SIMPLE_SOURCE.format(slug=spec.ref), FETCHED
    if spec.kind == "brand":
        return fetch(spec.ref), spec.ref, FETCHED
    raise SystemExit(f"{logo_id}: unknown kind {spec.kind}")


def write_imageset(logo_id: str, svg: str) -> None:
    folder = IMAGESETS / f"{logo_id}.imageset"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    (folder / "logo.svg").write_text(svg, encoding="utf-8")
    contents = {
        "images": [{"filename": "logo.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    logos: dict[str, dict[str, object]] = {}
    for logo_id, spec in LOGOS.items():
        if spec.kind == "monogram":
            logos[logo_id] = {"variant": "monogram", "source": None, "license": None, "version": None, "flag": spec.flag}
            continue
        svg, source, version = render(logo_id, spec)
        ratio = dominant_contrast(svg)
        if ratio is None or ratio < MIN_CONTRAST:
            raise SystemExit(f"{logo_id}: contrast on white is {ratio}, below {MIN_CONTRAST}:1; pick another variant")
        write_imageset(logo_id, svg)
        logos[logo_id] = {"variant": variant_of(svg), "source": source, "license": spec.license, "version": version, "flag": spec.flag}
    for stale in IMAGESETS.glob("*.imageset"):
        name = stale.name.removesuffix(".imageset")
        if name not in LOGOS or LOGOS[name].kind == "monogram":
            shutil.rmtree(stale)
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST_PATH.write_text(json.dumps({"logos": dict(sorted(logos.items()))}, indent=2) + "\n", encoding="utf-8")
    print(f"{len(logos)} logos; monogram: {' '.join(i for i, e in logos.items() if e['variant'] == 'monogram')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
