"""scripts/ci/check_connector_logos.py: a catalogued connector never ships without a brand logo on the white tile."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_connector_logos.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_connector_logos as lint

BLUE = '<svg width="24" height="24" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#0052D9"/></svg>'
LIME = BLUE.replace("#0052D9", "#C8FF00")
LOGO_SOURCE = "https://api.iconify.design/logos/alpha.svg"


def _tree(root: Path, icons: dict[str, str], manifest: dict[str, dict], logos: dict[str, str]) -> Path:
    catalog = root / lint.CATALOG
    catalog.parent.mkdir(parents=True)
    catalog.write_text("version: 1\nconnectors:\n" + "".join(f"- id: {c}\n  icon: {i}\n" for c, i in icons.items()))
    (root / lint.MANIFEST).parent.mkdir(parents=True)
    (root / lint.MANIFEST).write_text(json.dumps({"logos": manifest}), encoding="utf-8")
    (root / lint.CONNECT_APPS).mkdir(parents=True)
    for name in lint.PUZZLE_ALLOWLIST:
        (root / lint.CONNECT_APPS / name).write_text("PluginGlyphTile()\n", encoding="utf-8")
    for icon, svg in logos.items():
        _write_logo(root, icon, svg)
    return root


def _write_logo(root: Path, icon: str, svg: str) -> None:
    folder = root / lint.IMAGESET_DIR / f"{icon}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "logo.svg").write_text(svg, encoding="utf-8")
    (folder / "Contents.json").write_text('{"images": [{"filename": "logo.svg", "idiom": "universal"}]}', encoding="utf-8")


def _good(root: Path) -> Path:
    return _tree(
        root,
        {"alpha": "alpha", "alpha_mcp": "alpha", "gamma": "gamma"},
        {
            "alpha": {"variant": "color", "source": LOGO_SOURCE, "license": "CC0-1.0", "flag": None},
            "gamma": {"variant": "monogram", "source": None, "license": None, "flag": "no-logo-found: monogram fallback"},
        },
        {"alpha": BLUE},
    )


def _rules(root: Path) -> list[str]:
    return [finding.rule for finding in lint.check(root)]


def _edit_manifest(root: Path, icon: str, **changes: object) -> None:
    manifest = json.loads((root / lint.MANIFEST).read_text(encoding="utf-8"))
    manifest["logos"][icon].update(changes)
    (root / lint.MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")


def test_a_complete_tree_is_clean_and_two_connectors_may_share_one_logo(tmp_path: Path) -> None:
    assert lint.check(_good(tmp_path)) == []


def test_a_catalog_entry_still_on_the_puzzle_placeholder_fails_and_names_the_connector(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / lint.CATALOG).write_text("version: 1\nconnectors:\n- id: alpha\n  icon: alpha\n- id: slack\n  icon: plugin_glyph\n")
    found = lint.check(root)
    assert [f.rule for f in found] == ["missing-icon"]
    assert found[0].subject == "slack" and "pal_connectors.yaml" in found[0].message


def test_an_icon_without_a_manifest_entry_fails_and_says_how_to_add_it(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / lint.CATALOG).write_text("version: 1\nconnectors:\n- id: newcomer\n  icon: newcomer\n")
    found = lint.check(root)
    assert "missing-entry" in [f.rule for f in found]
    assert "newcomer" in found[0].message and "LOGOS" in found[0].message


def test_an_imageset_that_is_missing_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / lint.IMAGESET_DIR / "alpha.imageset" / "logo.svg").unlink()
    assert _rules(root) == ["missing-imageset"]


def test_an_entry_without_a_source_url_or_licence_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _edit_manifest(root, "alpha", source=None, license="")
    found = lint.check(root)
    assert [f.rule for f in found] == ["bad-entry", "bad-entry"]
    assert {"no source URL", "no licence"} == {f.message.split(": ")[1].split(".")[0] for f in found}


def test_an_unknown_variant_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _edit_manifest(root, "alpha", variant="sparkly")
    assert _rules(root) == ["bad-entry"]


def test_a_logo_too_pale_for_the_white_tile_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "alpha", LIME)
    found = lint.check(root)
    assert [f.rule for f in found] == ["low-contrast"] and "alpha" in found[0].message


def test_a_monogram_without_a_flag_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _edit_manifest(root, "gamma", flag=None)
    assert _rules(root) == ["unflagged-monogram"]


def test_a_dark_variant_file_or_appearance_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / lint.IMAGESET_DIR / "alpha.imageset" / "dark.svg").write_text(BLUE, encoding="utf-8")
    assert _rules(root) == ["dark-variant"]
    (root / lint.IMAGESET_DIR / "alpha.imageset" / "dark.svg").unlink()
    contents = root / lint.IMAGESET_DIR / "alpha.imageset" / "Contents.json"
    contents.write_text('{"images": [{"appearances": [], "filename": "logo.svg"}]}', encoding="utf-8")
    assert _rules(root) == ["dark-variant"]


def test_an_imageset_no_catalog_entry_uses_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "stale", BLUE)
    assert _rules(root) == ["orphan-imageset"]


def test_the_puzzle_outside_its_allowed_files_fails_and_a_stale_allowance_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / lint.CONNECT_APPS / "ConnectFlatRow.swift").write_text("icon: { PluginGlyphTile() }\n", encoding="utf-8")
    (root / lint.CONNECT_APPS / "SkillsCatalogSheet.swift").write_text("nothing\n", encoding="utf-8")
    found = lint.check(root)
    assert [f.rule for f in found] == ["puzzle-misuse", "puzzle-misuse"]
    assert {f.subject for f in found} == {"ConnectFlatRow.swift", "SkillsCatalogSheet.swift"}


def test_a_missing_manifest_fails(tmp_path: Path) -> None:
    assert [f.rule for f in lint.check(tmp_path)] == ["bad-entry"]


def test_the_real_tree_gives_every_catalogued_connector_a_logo() -> None:
    proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
