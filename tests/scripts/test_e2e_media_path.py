import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "e2e_media_path.py"


def test_media_and_preview_paths_come_back_byte_identical_through_the_gateway(tmp_path):
    run = subprocess.run(
        [sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, timeout=240, cwd=tmp_path, check=False)
    output = run.stdout + run.stderr
    cases = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    assert run.returncode == 0, output
    assert len(cases) == 7 and all(case["ok"] for case in cases), cases
    served = [case for case in cases if "read_sha256" in case]
    assert len(served) == 4 and all(case["read_sha256"] == case["sent_sha256"] for case in served)
