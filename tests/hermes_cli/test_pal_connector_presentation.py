import json
from pathlib import Path

from hermes_cli.pal_connectors import load_pal_connectors

LOGOS = Path(__file__).resolve().parents[2] / "apps" / "ios" / "App" / "Assets.xcassets" / "ConnectorLogos"
FALLBACK_ICON = "plugin_glyph"
CATEGORIES = (
    "Developer tools", "Hosting and infrastructure", "Monitoring and analytics", "Work management", "Docs and files",
    "Design and web", "Sales and support", "Finance", "Communication", "Other",
)
OTHER_ALLOWED = {
    "upwork": "freelance marketplace; no category in the list fits",
    "wolfram": "computation engine; no category in the list fits",
}
LOGO_FALLBACK = {
    "aws-knowledge": "AWS marks need AWS written permission or a partner licence",
    "context7": "Upstash kit states no logo terms",
    "craft": "Craft kit forbids implying a relationship and grants no integration-listing right",
    "deepwiki": "no DeepWiki kit or terms",
    "discord": "brand terms not reviewed",
    "discord_mcp": "brand terms not reviewed",
    "gamma": "kit and terms return 403",
    "higgsfield": "no brand kit or terms",
    "google-ads": "Google requires an approved permission request",
    "google-workspace": "Google requires an approved permission request",
    "microsoft-learn": "Microsoft logos require a licence",
    "monday": "press kit has PNG only and no integration terms",
    "motherduck": "no brand kit or terms",
    "paypal": "brand terms not reviewed",
    "posthog": "brand terms not reviewed",
    "resend": "brand terms not reviewed",
    "semgrep": "no brand kit or terms",
    "shopify": "brand terms not reviewed",
    "slack": "Slack terms require a written licence for the logo",
    "slack_mcp": "Slack terms require a written licence for the logo",
    "t3code": "no T3 Code brand kit or terms",
    "twilio-docs": "Twilio logos need express written permission",
}


def _logo_ids() -> set[str]:
    return {p.name.removesuffix(".imageset") for p in LOGOS.glob("*.imageset")}


def test_every_entry_has_a_listed_category_and_other_is_justified():
    for entry in load_pal_connectors():
        assert entry.category in CATEGORIES, f"{entry.id}: unknown category {entry.category!r}"
        if entry.category == "Other":
            assert entry.id in OTHER_ALLOWED, f"{entry.id}: needs a real category or an OTHER_ALLOWED reason"
        else:
            assert entry.id not in OTHER_ALLOWED, f"{entry.id}: drop it from OTHER_ALLOWED"


def test_every_entry_has_a_logo_asset_or_a_listed_fallback():
    logos = _logo_ids()
    for entry in load_pal_connectors():
        if entry.id in LOGO_FALLBACK:
            assert entry.icon == FALLBACK_ICON, f"{entry.id}: fallback entries use {FALLBACK_ICON}"
            assert entry.id not in logos, f"{entry.id}: has a logo, drop it from LOGO_FALLBACK"
        else:
            assert entry.icon == entry.id, f"{entry.id}: icon must be the entry id"
            assert entry.id in logos, f"{entry.id}: no logo asset set in ConnectorLogos and no LOGO_FALLBACK entry"


def test_no_logo_asset_set_is_orphaned_and_each_set_ships_its_images():
    ids = {e.id for e in load_pal_connectors()}
    for name in sorted(_logo_ids()):
        assert name in ids, f"{name}: asset set matches no catalog entry"
        contents = json.loads((LOGOS / f"{name}.imageset" / "Contents.json").read_text(encoding="utf-8"))
        files = [image["filename"] for image in contents["images"]]
        assert files and all((LOGOS / f"{name}.imageset" / f).is_file() for f in files), f"{name}: image file missing"
