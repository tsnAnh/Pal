#!/usr/bin/env python3
"""Vendor one brand logo per model provider from LobeHub Lobe Icons (MIT) into the asset catalogue.

PROVIDER_SLUGS maps a provider id to a Lobe Icons base slug, or None when the set has no logo (the apps
then draw initials on the white tile). Per provider the tool prefers ``<slug>-color`` when its darkest
fill keeps MIN_CONTRAST on white (scripts/ci/check_provider_logos.py defines how that is measured) and
otherwise falls back to the mono ``<slug>`` file with currentColor set to #111111.

Writes App/Assets.xcassets/ProviderLogos/<id>.imageset/{logo.svg,Contents.json} and
Design/ProviderLogos/manifest.json, and removes imagesets of ids no longer in the table.
scripts/ci/check_provider_logos.py fails CI when a catalogue provider is missing from the manifest.

Run: python apps/ios/Tools/provider-logos/vendor_provider_logos.py
"""

from __future__ import annotations

import json
import re
import shutil
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO / "scripts" / "ci"))

from check_provider_logos import IMAGESET_DIR, MANIFEST, MIN_CONTRAST, dominant_contrast

PACKAGE = "@lobehub/icons-static-svg"
VERSION = "1.106.0"
LICENSE = "MIT"
SOURCE = f"https://unpkg.com/{PACKAGE}@{VERSION}/icons/{{slug}}.svg"
NO_LOGO_FLAG = "no-logo-found: monogram fallback"
LOCAL_SYMBOL = ("local", "desktopcomputer")

PROVIDER_SLUGS: dict[str, str | None] = {
    "actual": None,
    "ai-gateway": "vercel",
    "alibaba": "alibaba",
    "alibaba-cn": "alibaba",
    "alibaba-coding-plan": "alibaba",
    "alibaba-coding-plan-cn": "alibaba",
    "alibaba-token-plan": "alibaba",
    "alibaba-token-plan-cn": "alibaba",
    "anthropic": "anthropic",
    "arcee": "arcee",
    "azure-foundry": "azure",
    "bedrock": "bedrock",
    "claude-subscription-directsdk-experimental": "claude",
    "commandcode": "commandcode",
    "commandcode-anthropic": "commandcode",
    "custom": None,
    "deepinfra": "deepinfra",
    "deepseek": "deepseek",
    "fireworks": "fireworks",
    "gemini": "gemini",
    "gmi": "gmicloud",
    "huggingface": "huggingface",
    "kilocode": "kilocode",
    "kimi-coding": "kimi",
    "kimi-coding-cn": "kimi",
    "lmstudio": "lmstudio",
    "meta-ai": "meta",
    "minimax": "minimax",
    "minimax-cn": "minimax",
    "minimax-oauth": "minimax",
    "nebius-token-factory": "nebius",
    "nous": "nousresearch",
    "novita": "novita",
    "nvidia": "nvidia",
    "ollama-cloud": "ollama",
    "openai-api": "openai",
    "openai-codex": "openai",
    "opencode-go": "opencode",
    "opencode-zen": "opencode",
    "openrouter": "openrouter",
    "qwen-oauth": "qwen",
    "router": None,
    "solstice": None,
    "stepfun": "stepfun",
    "tencent-tokenhub": "tencent",
    "tencent-tokenplan": "tencent",
    "upstage": "upstage",
    "vertex": "vertexai",
    "xai": "xai",
    "xai-oauth": "xai",
    "xiaomi": "xiaomimimo",
    "zai": "zai",
}


def fetch(slug: str) -> str | None:
    try:
        with urllib.request.urlopen(SOURCE.format(slug=slug), timeout=30) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def normalised(svg: str) -> str:
    svg = re.sub(r"<title>.*?</title>", "", svg, flags=re.DOTALL)
    svg = re.sub(r'\sstyle="[^"]*"', "", svg)
    svg = svg.replace('width="1em"', 'width="24"').replace('height="1em"', 'height="24"')
    svg = svg.replace("currentColor", "#111111")
    for required in ('width="24"', 'height="24"', "viewBox="):
        if required not in svg:
            raise ValueError(f"normalised svg lacks {required}")
    return svg


def choose(slug: str) -> tuple[str, str, str]:
    colour = fetch(f"{slug}-color")
    if colour is not None:
        ratio = dominant_contrast(normalised(colour))
        if ratio is not None and ratio >= MIN_CONTRAST:
            return f"{slug}-color", "color", normalised(colour)
    mono = fetch(slug)
    if mono is None:
        raise SystemExit(f"{slug}: not in {PACKAGE}@{VERSION}")
    return slug, "mono-dark", normalised(mono)


def write_imageset(provider: str, svg: str) -> None:
    folder = IMAGESET_DIR / f"{provider}.imageset"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    (folder / "logo.svg").write_text(svg, encoding="utf-8")
    contents = {
        "images": [{"filename": "logo.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")


def entry(slug: str | None, variant: str, flag: str | None) -> dict[str, object]:
    return {
        "slug": slug,
        "variant": variant,
        "source": SOURCE.format(slug=slug) if variant in ("color", "mono-dark") else None,
        "license": LICENSE,
        "version": VERSION,
        "flag": flag,
    }


def main() -> int:
    providers: dict[str, dict[str, object]] = {}
    for provider, base in PROVIDER_SLUGS.items():
        if base is None:
            providers[provider] = entry(None, "monogram", NO_LOGO_FLAG)
            continue
        slug, variant, svg = choose(base)
        write_imageset(provider, svg)
        providers[provider] = entry(slug, variant, None)
    local_id, symbol = LOCAL_SYMBOL
    providers[local_id] = {**entry(symbol, "symbol", None), "source": None, "license": None, "version": None}
    drawn = {provider for provider, base in PROVIDER_SLUGS.items() if base}
    for stale in IMAGESET_DIR.glob("*.imageset"):
        if stale.name.removesuffix(".imageset") not in drawn:
            shutil.rmtree(stale)
    manifest = {"package": PACKAGE, "version": VERSION, "license": LICENSE, "providers": dict(sorted(providers.items()))}
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"{len(providers)} providers; monogram: {' '.join(p for p, e in providers.items() if e['variant'] == 'monogram')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
