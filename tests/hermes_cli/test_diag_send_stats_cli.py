import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from gateway import send_stats

REPO = Path(__file__).resolve().parents[2]


def hermes(home: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "HERMES_HOME": str(home)}
    return subprocess.run([sys.executable, "-m", "hermes_cli.main", "diag", "send-stats", *args], cwd=REPO, env=env,
                          capture_output=True, text=True, timeout=120, check=False)


@pytest.fixture
def home(tmp_path: Path) -> Path:
    path = tmp_path / "hermes"
    path.mkdir()
    for status, why, ms in (("steered", "absorbed", 10), ("steered", "absorbed", 30), ("queued", "not_steerable", 5)):
        send_stats.record("admitted", "adm", status, why, ms, root=path)
    send_stats.record("drained", "adm", "", "", 2000, root=path)
    return path


def test_json_reports_counts_and_spreads(home):
    result = hermes(home, "--json")
    assert result.returncode == 0, result.stderr
    stats = json.loads(result.stdout)
    assert stats["by_status"] == {"steered": 2, "queued": 1, "turn": 0, "untouched": 0}
    assert stats["by_why"] == {"absorbed": 2, "not_steerable": 1}
    assert stats["absorb_ms"] == {"min": 5, "median": 10, "max": 30}
    assert (stats["steer_drained"], stats["wait_ms"]) == (1, {"min": 2000, "median": 2000, "max": 2000})


def test_text_output_and_read_only(home):
    before = (home / send_stats.DB_NAME).stat().st_mtime_ns
    result = hermes(home)
    assert result.returncode == 0, result.stderr
    assert "admitted 3, steer_drained 1" in result.stdout
    assert "status: steered 2, queued 1, turn 0, untouched 0" in result.stdout
    assert "absorb_ms: min 5  median 10  max 30" in result.stdout
    assert (home / send_stats.DB_NAME).stat().st_mtime_ns == before


def test_a_host_with_no_ledger_says_so_and_creates_nothing(tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    result = hermes(empty)
    assert result.returncode == 0 and "No send_trace ledger" in result.stdout
    assert not (empty / send_stats.DB_NAME).exists()
