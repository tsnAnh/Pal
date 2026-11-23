"""scripts/ci/check_provider_logos.py: every provider the apps can list has a brand logo on record."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_provider_logos.py"
sys.path.insert(0, str(SCRIPT.parent))

import check_provider_logos as lint

MANIFEST = Path("manifest.json")
IMAGESETS = Path("sets")
BLUE = '<svg width="24" height="24" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#0052D9"/></svg>'
LIME = '<svg width="24" height="24" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#C8FF00"/></svg>'
LIME_ON_WHITE = (
    '<svg width="24" height="24" viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#FFFFFF"/>'
    '<path d="M2 2h20v20H2z" fill="url(#g)"/>'
    '<defs><linearGradient id="g"><stop stop-color="#C8FF00"/><stop offset="1" stop-color="#FFFF00"/></linearGradient></defs></svg>'
)
GRADIENT_WITH_DARK_STOP = LIME_ON_WHITE.replace('stop-color="#FFFF00"', 'stop-color="#114A8B"')
FAINT_SHADOW = BLUE.replace("</svg>", '<path d="M0 0h1v1H0z" fill="#000" fill-opacity=".2"/></svg>')


def _write_logo(root: Path, provider: str, svg: str) -> None:
    folder = root / IMAGESETS / f"{provider}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "logo.svg").write_text(svg, encoding="utf-8")
    (folder / "Contents.json").write_text('{"images": [{"filename": "logo.svg", "idiom": "universal"}]}', encoding="utf-8")


def _tree(root: Path, entries: dict[str, dict], logos: dict[str, str]) -> Path:
    (root / MANIFEST).write_text(json.dumps({"providers": entries}), encoding="utf-8")
    for provider, svg in logos.items():
        _write_logo(root, provider, svg)
    return root


def _good(root: Path) -> Path:
    return _tree(
        root,
        {
            "alpha": {"slug": "alpha-color", "variant": "color", "flag": None},
            "beta": {"slug": "beta", "variant": "mono-dark", "flag": None},
            "gamma": {"slug": None, "variant": "monogram", "flag": "no-logo-found: monogram fallback"},
            "local": {"slug": "desktopcomputer", "variant": "symbol", "flag": None},
        },
        {"alpha": BLUE, "beta": BLUE.replace("#0052D9", "#111111")},
    )


def _run(root: Path, ids: list[str]) -> list[lint.Finding]:
    return lint.check(root, ids, MANIFEST, IMAGESETS)


def test_a_complete_tree_is_clean(tmp_path: Path) -> None:
    assert _run(_good(tmp_path), ["alpha", "beta", "gamma"]) == []


def test_a_provider_without_a_manifest_entry_fails_and_says_how_to_add_it(tmp_path: Path) -> None:
    found = _run(_good(tmp_path), ["alpha", "newcomer"])
    assert [f.rule for f in found] == ["missing-entry"]
    assert "newcomer" in found[0].message
    assert "PROVIDER_SLUGS" in found[0].message and "vendor_provider_logos.py" in found[0].message


def test_an_entry_whose_imageset_is_missing_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / IMAGESETS / "alpha.imageset" / "logo.svg").unlink()
    assert [f.rule for f in _run(root, ["alpha"])] == ["missing-imageset"]


def test_an_imageset_without_contents_json_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    (root / IMAGESETS / "beta.imageset" / "Contents.json").unlink()
    assert [f.rule for f in _run(root, ["beta"])] == ["missing-imageset"]


def test_a_logo_too_pale_for_the_white_tile_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "alpha", LIME)
    found = _run(root, ["alpha"])
    assert [f.rule for f in found] == ["low-contrast"]
    assert "alpha" in found[0].message


def test_a_pale_gradient_over_white_cutouts_still_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "alpha", LIME_ON_WHITE)
    assert [f.rule for f in _run(root, ["alpha"])] == ["low-contrast"]


def test_a_dark_gradient_stop_keeps_a_logo_visible(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "alpha", GRADIENT_WITH_DARK_STOP)
    assert _run(root, ["alpha"]) == []


def test_a_faint_shadow_does_not_count_as_a_dark_fill(tmp_path: Path) -> None:
    root = _good(tmp_path)
    _write_logo(root, "alpha", FAINT_SHADOW.replace("#0052D9", "#C8FF00"))
    assert [f.rule for f in _run(root, ["alpha"])] == ["low-contrast"]


def test_a_monogram_without_a_flag_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    manifest["providers"]["gamma"]["flag"] = None
    (root / MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")
    assert [f.rule for f in _run(root, ["gamma"])] == ["unflagged-monogram"]


def test_an_unknown_variant_fails(tmp_path: Path) -> None:
    root = _good(tmp_path)
    manifest = json.loads((root / MANIFEST).read_text(encoding="utf-8"))
    manifest["providers"]["alpha"]["variant"] = "sparkly"
    (root / MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")
    assert [f.rule for f in _run(root, ["alpha"])] == ["bad-entry"]


def test_a_missing_manifest_fails(tmp_path: Path) -> None:
    assert [f.rule for f in _run(tmp_path, ["alpha"])] == ["bad-entry"]


def test_contrast_follows_the_wcag_ratio_against_white() -> None:
    assert round(lint.contrast_on_white("#000000"), 2) == 21.0
    assert lint.contrast_on_white("#ffffff") == 1.0
    assert lint.contrast_on_white("#c8ff00") < lint.MIN_CONTRAST < lint.contrast_on_white("#23d57c")


def test_the_real_tree_has_a_logo_for_every_listed_provider() -> None:
    proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_the_ids_read_from_source_equal_the_live_catalogue() -> None:
    from hermes_cli.provider_catalog import provider_catalog_by_slug
    from providers import unlisted_provider_names

    live = {slug for slug, d in provider_catalog_by_slug().items() if d.auth_type != "virtual"}
    live |= unlisted_provider_names() | set(lint.EXTRA_IDS)
    assert set(lint.catalogue_ids()) == live


def test_the_check_runs_without_the_yaml_library() -> None:
    blocker = "import sys; sys.modules['ruamel'] = None; sys.modules['ruamel.yaml'] = None; import runpy; runpy.run_path(sys.argv[1], run_name='__main__')"
    proc = subprocess.run([sys.executable, "-I", "-c", blocker, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
