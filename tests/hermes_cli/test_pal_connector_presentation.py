import json
from pathlib import Path

from hermes_cli.pal_connectors import load_pal_connectors

LOGOS = Path(__file__).resolve().parents[2] / "apps" / "ios" / "App" / "Assets.xcassets" / "ConnectorLogos"
MANIFEST = Path(__file__).resolve().parents[2] / "apps" / "ios" / "Design" / "ConnectorLogos" / "manifest.json"
CATEGORIES = (
    "Developer tools", "Hosting and infrastructure", "Monitoring and analytics", "Work management", "Docs and files",
    "Design and web", "Sales and support", "Finance", "Communication", "Other",
)
OTHER_ALLOWED = {
    "upwork": "freelance marketplace; no category in the list fits",
    "wolfram": "computation engine; no category in the list fits",
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


def test_every_entry_names_a_logo_and_never_the_puzzle_placeholder():
    logos = _logo_ids()
    monograms = {
        logo_id for logo_id, entry in json.loads(MANIFEST.read_text(encoding="utf-8"))["logos"].items()
        if entry["variant"] == "monogram"
    }
    for entry in load_pal_connectors():
        assert entry.icon != "plugin_glyph", f"{entry.id}: catalogued connectors show a brand logo, never the puzzle"
        assert entry.icon in logos | monograms, f"{entry.id}: icon {entry.icon!r} has no logo imageset or flagged monogram"


def test_no_logo_asset_set_is_orphaned_and_each_set_ships_its_images():
    icons = {e.icon for e in load_pal_connectors()}
    for name in sorted(_logo_ids()):
        assert name in icons, f"{name}: asset set matches no catalog icon"
        contents = json.loads((LOGOS / f"{name}.imageset" / "Contents.json").read_text(encoding="utf-8"))
        files = [image["filename"] for image in contents["images"]]
        assert files and all((LOGOS / f"{name}.imageset" / f).is_file() for f in files), f"{name}: image file missing"
