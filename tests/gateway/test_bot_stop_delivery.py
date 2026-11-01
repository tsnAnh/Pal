"""An explicit Stop reaches the Bot Chat turn one delivery started, running or still queued."""
import os
from pathlib import Path
import subprocess
import sys


def test_stop_delivery_cancels_queued_and_interrupts_running_turns(tmp_path):
    root = Path(__file__).resolve().parents[2]
    env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TZ', 'TIRITH_ENABLED') if k in os.environ}
    env['PYTHONPATH'] = str(root)
    proc = subprocess.run([sys.executable, str(root / 'tests/gateway/fixtures/bot_stop_peer.py'),
                           str(tmp_path)], cwd=root, env=env, stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=150, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    print(proc.stdout)
