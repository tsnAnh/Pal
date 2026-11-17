"""Migration 53→54: clarify questions never time out by default.

Contract: step 53 wrote ``agent.clarify_timeout: 90`` into user configs, so exactly 90 reads as the old
default and becomes 0 (unlimited); every other explicit value survives; an absent key stays absent and
inherits the unlimited default. Driven through ``run_migrations`` against a temp home.
"""

import os
from unittest.mock import patch

import pytest

import hermes_yaml as yaml


def _run(tmp_path, agent, version=53):
    from hermes_cli.config_migrations import run_migrations

    tmp_path.mkdir()
    (tmp_path / "config.yaml").write_text(
        yaml.safe_dump({"_config_version": version, "agent": agent}), encoding="utf-8")
    with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}, clear=False):
        run_migrations(version, {"env_added": [], "config_added": [], "warnings": []}, quiet=True)
    return yaml.safe_load((tmp_path / "config.yaml").read_text(encoding="utf-8"))


@pytest.mark.parametrize("before,after", [(90, 0), (30, 30), (600, 600), (0, 0), (3600, 3600)])
def test_only_the_old_default_becomes_unlimited(tmp_path, before, after):
    config = _run(tmp_path / f"v{before}", {"clarify_timeout": before})
    assert config["agent"]["clarify_timeout"] == after


def test_absent_key_stays_absent_and_inherits_unlimited(tmp_path):
    from hermes_cli.config import load_config

    config = _run(tmp_path / "absent", {"max_turns": 10})
    assert "clarify_timeout" not in config["agent"]
    with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path / "absent")}):
        assert load_config()["agent"]["clarify_timeout"] == 0


def test_migration_is_idempotent_and_never_rewrites_a_later_choice(tmp_path):
    first = _run(tmp_path / "once", {"clarify_timeout": 90})
    assert first["agent"]["clarify_timeout"] == 0
    second = _run(tmp_path / "twice", first["agent"], version=54)
    assert second["agent"]["clarify_timeout"] == 0
    chosen = _run(tmp_path / "chosen", {"clarify_timeout": 90}, version=54)
    assert chosen["agent"]["clarify_timeout"] == 90, "already-migrated configs are not touched again"


def test_fresh_config_defaults_to_unlimited(tmp_path):
    from hermes_cli.config import load_config

    with patch.dict(os.environ, {"HERMES_HOME": str(tmp_path)}):
        assert load_config()["agent"]["clarify_timeout"] == 0
