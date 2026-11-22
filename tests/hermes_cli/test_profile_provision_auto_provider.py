from __future__ import annotations

import json
from pathlib import Path

import hermes_yaml as yaml
import pytest

from hermes_cli import auth, profiles
from hermes_cli.profile_provision import ProfileCreateRequest, provision_profile

AUTO_MODEL = (
    "model:\n"
    "  default: gpt-6.1-sol\n"
    "  provider: auto\n"
    "  base_url: https://openrouter.ai/api/v1\n"
    "  api_mode: codex_responses\n"
)


@pytest.fixture()
def launch(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(auth, "_auth_file_path", lambda: auth.get_hermes_home() / "auth.json")
    for key in ("OPENROUTER_API_KEY", "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    (home / "config.yaml").write_text(AUTO_MODEL)
    (home / ".env").write_text("")
    monkeypatch.setattr(profiles, "seed_profile_skills", lambda path, quiet=True, problems=None: {"copied": []})
    return home


def _bot_page_create(name: str):
    return provision_profile(ProfileCreateRequest(
        name=name, clone_from="default", clone_config=True, share_auth=True, alias=False))


def _model(profile: Path) -> dict:
    return yaml.safe_load((profile / "config.yaml").read_text(encoding="utf-8"))["model"]


def test_bot_cloned_from_an_auto_launch_runs_on_the_login_the_launch_uses(launch, monkeypatch):
    (launch / "auth.json").write_text(json.dumps(
        {"version": 1, "providers": {"openai-codex": {}}, "credential_pool": {}, "active_provider": "openai-codex"}))
    monkeypatch.setattr(auth, "get_codex_auth_status", lambda: {"logged_in": True})

    result = _bot_page_create("upwork-pal")

    assert not (result.path / "auth.json").exists()
    model = _model(result.path)
    assert (model["provider"], model["default"]) == ("openai-codex", "gpt-6.1-sol")
    assert "base_url" not in model
    assert "api_mode" not in model
    assert result.mirrored["model_inherited"] is True


def test_bot_cloned_from_an_auto_launch_with_no_login_keeps_auto(launch):
    (launch / "auth.json").write_text(json.dumps({"version": 1, "providers": {}, "credential_pool": {}}))

    result = _bot_page_create("scout")

    assert _model(result.path)["provider"] == "auto"
    assert result.mirrored["model_inherited"] is False
    assert result.warnings == []
