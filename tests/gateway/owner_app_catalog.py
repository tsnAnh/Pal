import shutil
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]


@pytest.fixture
def owner_app_upwork(tmp_path, monkeypatch):
    root = tmp_path / 'optional-mcps'
    shutil.copytree(REPO / 'optional-mcps', root)
    manifest = root / 'upwork' / 'manifest.yaml'
    manifest.write_text(manifest.read_text().replace('  type: oauth\n', '  type: oauth\n  signin_on: owner_app\n', 1))
    monkeypatch.setenv('HERMES_OPTIONAL_MCPS', str(root))
