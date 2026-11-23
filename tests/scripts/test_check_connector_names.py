"""scripts/ci/check_connector_names.py: a catalog connector's name is explicit, distinct, and not its id title-cased."""

import importlib.util
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci" / "check_connector_names.py"
_SPEC = importlib.util.spec_from_file_location("_check_connector_names", SCRIPT)
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)


def _run(tmp_path, entries, allowlist=""):
    catalog = tmp_path / "pal_connectors.yaml"
    body = "".join(
        f"- id: {i}\n" + (f"  name: {n}\n" if n is not None else "") for i, n in entries)
    catalog.write_text(f"version: 1\nconnectors:\n{body}")
    allowed = tmp_path / "allowlist.txt"
    allowed.write_text(allowlist)
    return _MODULE.check(catalog, allowed)


def test_an_id_title_cased_is_rejected_with_the_fix(tmp_path):
    problems = _run(tmp_path, [("circleci", "Circleci"), ("wordpress-com", "Wordpress Com")])
    assert len(problems) == 2
    assert "circleci: name 'Circleci' is just the id title-cased" in problems[0]
    assert "pal_connectors.yaml" in problems[0] and "allowlist.txt" in problems[0]


def test_an_allowlisted_title_cased_name_passes_and_a_brand_spelling_needs_no_line(tmp_path):
    entries = [("airtable", "Airtable"), ("github", "GitHub")]
    assert _run(tmp_path, entries, "airtable  brand spelling is a single capitalised word\n") == []


def test_a_missing_or_blank_name_is_rejected(tmp_path):
    problems = _run(tmp_path, [("alpha", None), ("beta", "' '")])
    assert [p.split(":")[0] for p in problems] == ["alpha", "beta"]
    assert all("no explicit name" in p for p in problems)


def test_duplicate_names_are_rejected_ignoring_case(tmp_path):
    problems = _run(tmp_path, [("slack", "Slack (workspace)"), ("slack_mcp", "slack (workspace)")])
    assert len(problems) == 1 and "slack_mcp: name 'slack (workspace)' duplicates slack" in problems[0]


def test_a_stale_or_reasonless_allowlist_line_is_rejected(tmp_path):
    problems = _run(
        tmp_path, [("github", "GitHub"), ("canva", "Canva")], "github  was title-cased once\ncanva\n")
    assert any("github no longer needs its line" in p for p in problems)
    assert any("allowlist.txt:2:" in p for p in problems)


def test_the_real_catalog_passes():
    result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stdout
