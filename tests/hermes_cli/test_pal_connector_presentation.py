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
    "aws-knowledge": "not in Simple Icons",
    "canva": "not in Simple Icons",
    "comfy-cloud": "not in Simple Icons",
    "context7": "not in Simple Icons",
    "craft": "not in Simple Icons",
    "deepwiki": "not in Simple Icons",
    "gamma": "not in Simple Icons",
    "google-workspace": "not in Simple Icons",
    "microsoft-learn": "not in Simple Icons",
    "monday": "not in Simple Icons",
    "motherduck": "not in Simple Icons",
    "semgrep": "not in Simple Icons",
    "slack": "not in Simple Icons",
    "twilio-docs": "not in Simple Icons",
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
