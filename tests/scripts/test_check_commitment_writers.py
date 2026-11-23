"""The ledger guard: only gateway/commitments.py may name the commitment tables in SQL."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ci" / "check_commitment_writers.py"


def _run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), "--root", str(root)], capture_output=True, text=True,
                          check=False, timeout=120)


def _write(root: Path, files: dict[str, str]) -> None:
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def test_the_checkout_passes():
    result = _run(ROOT)
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_owner_module_tests_and_prose_pass(tmp_path):
    _write(tmp_path, {
        "gateway/commitments.py": 'SQL = "INSERT INTO commitments (id) VALUES (?)"\n',
        "tests/gateway/test_x.py": 'conn.execute("DELETE FROM commitment_events")\n',
        "agent/prompt.py": 'RULE = "Record your commitments and update commitments when blocked."\n',
        "tools/commitment_tool.py": "from gateway import commitments\ncommitments.list_active(home)\n",
    })
    result = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("source", [
    'conn.execute("INSERT INTO commitments (id) VALUES (?)")\n',
    'conn.execute("insert or ignore into commitment_events (event_key) values (?)")\n',
    'conn.execute("UPDATE commitments SET state = ?")\n',
    'conn.execute("REPLACE INTO commitments VALUES (?)")\n',
    'conn.execute("DELETE FROM commitment_events")\n',
    'conn.execute("SELECT * FROM commitments WHERE id = ?")\n',
    'conn.execute(f"UPDATE commitments SET rev = {rev}")\n',
    'conn.execute("""\n    UPDATE\n        "commitments"\n    SET state = ?\n""")\n',
    'conn.execute("DROP TABLE IF EXISTS commitment_events")\n',
    'rows = conn.execute("SELECT c.id FROM sessions s JOIN commitments c ON c.id = s.id")\n',
])
def test_sql_on_the_ledger_tables_elsewhere_fails(tmp_path, source):
    _write(tmp_path, {"gateway/elsewhere.py": "x = 1\n" + source})
    result = _run(tmp_path)
    assert result.returncode == 1
    assert "gateway/elsewhere.py:2" in result.stdout
