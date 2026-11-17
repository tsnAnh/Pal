import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from gateway import diag_ledger

REPO = Path(__file__).resolve().parents[2]


def hermes(home: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "HERMES_HOME": str(home)}
    return subprocess.run([sys.executable, "-m", "hermes_cli.main", "diag", "recent", *args], cwd=REPO, env=env,
                          capture_output=True, text=True, timeout=120, check=False)


def fault(age_seconds: float, method: str, trace: str, **extra) -> diag_ledger.Fault:
    return diag_ledger.Fault(ts=time.time() - age_seconds, trace=trace, method=method, code=-32001,
                             reason="permission_denied", device_kind="iphone", device_name="Test Phone",
                             app_build="412", gateway_version="0.0.0", **extra)


@pytest.fixture
def root(tmp_path: Path) -> Path:
    home = tmp_path / "hermes"
    home.mkdir()
    for age, method, trace in ((30, "kanban.boards.list", "t-new"), (300, "settings.get", "t-mid"),
                               (3600, "kanban.boards.list", "t-old")):
        diag_ledger.record(fault(age, method, trace), root=home)
    return home


def test_json_lists_only_the_last_ten_minutes_newest_first_with_every_field(root):
    result = hermes(root, "--json")
    assert result.returncode == 0, result.stderr
    rows = json.loads(result.stdout)
    assert [row["trace"] for row in rows] == ["t-new", "t-mid"]
    assert set(rows[0]) == {"ts", "trace", "method", "code", "reason", "device_kind", "device_name", "app_build",
                            "gateway_version", "params_shape", "scope", "source"}
    assert rows[0]["device_kind"] == "iphone" and rows[0]["code"] == -32001


def test_method_filter_and_window(root):
    rows = json.loads(hermes(root, "--json", "--minutes", "120", "--method", "kanban.boards.list").stdout)
    assert [row["trace"] for row in rows] == ["t-new", "t-old"]


def test_minutes_and_limit_are_clamped(root):
    assert [r["trace"] for r in json.loads(hermes(root, "--json", "--minutes", "0").stdout)] == ["t-new"]
    assert len(json.loads(hermes(root, "--json", "--minutes", "999999", "--limit", "0").stdout)) == 1
    assert len(json.loads(hermes(root, "--json", "--minutes", "120", "--limit", "999").stdout)) == 3


def test_a_bot_profile_reads_the_install_root_ledger(root):
    profile = root / "profiles" / "pal"
    profile.mkdir(parents=True)
    rows = json.loads(hermes(profile, "--json").stdout)
    assert [row["trace"] for row in rows] == ["t-new", "t-mid"]


def test_human_table_names_device_build_and_trace(root):
    out = hermes(root).stdout
    assert "kanban.boards.list" in out and "iphone Test Phone" in out and "t-new" in out and "t-old" not in out


def test_reading_never_changes_the_ledger_file(root):
    db = root / diag_ledger.DB_NAME
    before = (db.stat().st_mtime_ns, db.stat().st_size)
    assert hermes(root, "--json").returncode == 0
    assert hermes(root).returncode == 0
    assert (db.stat().st_mtime_ns, db.stat().st_size) == before


def test_missing_ledger_says_so_and_is_not_created(tmp_path):
    result = hermes(tmp_path)
    assert result.returncode == 0
    assert result.stdout.strip().count("\n") == 0 and "no fault" in result.stdout.lower()
    assert json.loads(hermes(tmp_path, "--json").stdout) == []
    assert not (tmp_path / diag_ledger.DB_NAME).exists()


def test_empty_window_says_so(root):
    result = hermes(root, "--minutes", "1", "--method", "nothing.here")
    assert result.returncode == 0 and result.stdout.strip() == "No faults recorded in the last 1 minute(s)."
