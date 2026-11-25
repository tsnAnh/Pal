import os
import time
from types import SimpleNamespace

import pytest

from gateway.run_bootstrap import _purge_retired_held_drafts


@pytest.fixture
def home_with_old_drafts(tmp_path, monkeypatch):
    home = tmp_path / "hermes"
    pending = home / "bot_mode" / "drafts" / "pending"
    pending.mkdir(parents=True)
    old, fresh = pending / ("a" * 32 + ".json"), pending / ("b" * 32 + ".json")
    for path in (old, fresh):
        path.write_text('{"state": "pending"}', encoding="utf-8")
    two_days_ago = time.time() - 2 * 24 * 3600
    os.utime(old, (two_days_ago, two_days_ago))
    monkeypatch.setenv("HERMES_HOME", str(home))
    return home


def test_gateway_start_deletes_the_retired_hold_store_old_and_fresh_files_alike(home_with_old_drafts):
    _purge_retired_held_drafts(SimpleNamespace(multiplex_profiles=False))
    assert not (home_with_old_drafts / "bot_mode" / "drafts").exists()


def test_the_purge_is_idempotent(home_with_old_drafts):
    config = SimpleNamespace(multiplex_profiles=False)
    _purge_retired_held_drafts(config)
    _purge_retired_held_drafts(config)
    assert not (home_with_old_drafts / "bot_mode" / "drafts").exists()


def test_other_files_of_the_profile_are_left_alone(home_with_old_drafts):
    keep = home_with_old_drafts / "bot_mode" / "settings.json"
    keep.write_text("{}", encoding="utf-8")
    _purge_retired_held_drafts(SimpleNamespace(multiplex_profiles=False))
    assert keep.exists()


def test_the_deleted_modules_no_longer_exist():
    import importlib.util
    assert importlib.util.find_spec("tools.bot_mode_draft_store") is None
    assert importlib.util.find_spec("gateway.session_held_drafts") is None
