"""speech_memory.settings.get/set plus capabilities.set_key for the TTS and memory keys: set, replace and remove
per bot, status as set / not set only, provider choices that refuse a missing key, and no value outside the
bot's own .env."""

from __future__ import annotations

import json
import logging
import uuid
from pathlib import Path

import pytest

import hermes_yaml as yaml
from hermes_cli.profiles import create_profile, get_profile_dir
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.speech_memory_settings import MEMORY_KEYS, TTS_KEYS, _tts_key_table

NEW_KEYS = [*TTS_KEYS, *MEMORY_KEYS]
OTHER_KEYS = ["OPENAI_API_KEY", "GOOGLE_API_KEY", *NEW_KEYS]


@pytest.fixture
def bots(tmp_path, monkeypatch) -> Path:
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    for key in OTHER_KEYS:
        monkeypatch.delenv(key, raising=False)
    create_profile("scout", no_alias=True, no_skills=True)
    create_profile("pilot", no_alias=True, no_skills=True)
    return home


def _canary() -> str:
    return f"CANARY-{uuid.uuid4().hex}"


def _call(method: str, params: dict) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params})


def _ok(method: str, params: dict) -> dict:
    response = _call(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params)
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _set_key(profile: str, key: str, value: str | None) -> dict:
    return _ok("capabilities.set_key", {"profile": profile, "key_name": key, "value": value})


def _settings(profile: str = "scout") -> dict:
    return _ok("speech_memory.settings.get", {"profile": profile})


def _provider(area: str, provider_id: str, profile: str = "scout") -> dict:
    return next(p for p in _settings(profile)[area]["providers"] if p["id"] == provider_id)


def _choose(profile: str, area: str, provider: str, voice: str | None = None) -> dict:
    params = {"profile": profile, "area": area, "provider": provider, **({} if voice is None else {"voice": voice})}
    return _ok("speech_memory.settings.set", params)


def _env(profile: str) -> dict[str, str]:
    path = get_profile_dir(profile) / ".env"
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line) if path.exists() else {}


def _config(profile: str) -> dict:
    path = get_profile_dir(profile) / "config.yaml"
    return yaml.safe_load(path.read_text()) or {} if path.exists() else {}


def _key_provider(key: str) -> tuple[str, str]:
    for provider_id, (_env_vars, save_var) in _tts_key_table().items():
        if save_var == key:
            return "tts", provider_id
    return "memory", {"RETAINDB_API_KEY": "retaindb", "BRV_API_KEY": "byterover"}[key]


def test_the_key_table_and_the_allowlist_agree():
    assert {save_var for _env_vars, save_var in _tts_key_table().values()} == set(TTS_KEYS)


def test_lists_providers_with_status_only(bots):
    settings = _settings()
    assert settings["profile"] == "scout"
    tts = {p["id"]: p for p in settings["tts"]["providers"]}
    assert {"edge", "elevenlabs", "openai", "xai", "minimax", "mistral", "gemini"} <= set(tts)
    assert tts["edge"].get("key_name") is None and tts["edge"]["ready"] is True
    assert tts["elevenlabs"]["key_name"] == "ELEVENLABS_API_KEY" and tts["elevenlabs"]["key_set"] is False
    assert settings["tts"]["selected"] == "edge" and settings["tts"]["voice"]["options"]
    memory = {p["id"]: p for p in settings["memory"]["providers"]}
    assert memory["retaindb"]["key_name"] == "RETAINDB_API_KEY" and memory["retaindb"]["key_required"] is True
    assert memory["byterover"]["key_name"] == "BRV_API_KEY" and memory["byterover"]["key_required"] is False
    assert settings["memory"]["selected"] == ""


@pytest.mark.parametrize("key", NEW_KEYS)
def test_set_replace_and_remove(bots, key):
    area, provider_id = _key_provider(key)
    first, second = _canary(), _canary()
    assert _provider(area, provider_id)["key_set"] is False
    assert _set_key("scout", key, first)["is_set"] is True
    assert _env("scout")[key] == first
    row = _provider(area, provider_id)
    assert row["key_set"] is True and row["can_remove"] is True
    _set_key("scout", key, second)
    assert _env("scout")[key] == second
    assert _set_key("scout", key, None)["is_set"] is False
    assert key not in _env("scout")
    row = _provider(area, provider_id)
    assert row["key_set"] is False and row["can_remove"] is False


@pytest.mark.parametrize("key", NEW_KEYS)
def test_a_key_for_one_bot_never_reaches_another(bots, key):
    area, provider_id = _key_provider(key)
    _set_key("scout", key, _canary())
    assert _provider(area, provider_id, "pilot")["key_set"] is False
    assert key not in _env("pilot")


@pytest.mark.parametrize("value", ["", "   ", "two\nlines", "naïve", "x" * 4097])
def test_a_value_that_cannot_be_a_key_is_refused_and_nothing_is_written(bots, value):
    response = _call("capabilities.set_key", {"profile": "scout", "key_name": "ELEVENLABS_API_KEY", "value": value})
    assert "error" in response
    assert value.strip() == "" or value not in json.dumps(response)
    assert _env("scout") == {}


@pytest.mark.parametrize("key", ["OPENAI_API_KEY", "GOOGLE_API_KEY", "ELEVENLABS_API_KEY_2", "LD_PRELOAD", "retaindb_api_key"])
def test_a_key_outside_the_allowlist_is_refused_and_nothing_is_written(bots, key):
    response = _call("capabilities.set_key", {"profile": "scout", "key_name": key, "value": _canary()})
    assert "error" in response
    assert _env("scout") == {}


def test_an_unknown_bot_is_refused_and_nothing_is_stored(bots):
    response = _call("capabilities.set_key", {"profile": "ghost", "key_name": "RETAINDB_API_KEY", "value": _canary()})
    assert "error" in response
    assert not (get_profile_dir("ghost") / ".env").exists()
    assert _env("scout") == {} and _env("pilot") == {}
    assert "error" in _call("speech_memory.settings.get", {"profile": "ghost"})
    assert "error" in _call("speech_memory.settings.set", {"profile": "ghost", "area": "tts", "provider": "edge"})


@pytest.mark.parametrize("key", ["ELEVENLABS_API_KEY", "RETAINDB_API_KEY"])
def test_a_failed_write_keeps_the_old_value(bots, monkeypatch, caplog, key):
    old, new = _canary(), _canary()
    _set_key("scout", key, old)

    def refuse(*args, **kwargs):
        raise OSError(f"disk refused {new}")

    caplog.set_level(logging.DEBUG)
    with monkeypatch.context() as patch:
        patch.setattr("hermes_cli.config.atomic_replace", refuse)
        response = _call("capabilities.set_key", {"profile": "scout", "key_name": key, "value": new})
    assert response["error"]["code"] == 5103
    assert new not in json.dumps(response) + caplog.text
    assert _env("scout")[key] == old


def test_a_failed_removal_keeps_the_value(bots, monkeypatch):
    value = _canary()
    _set_key("scout", "MISTRAL_API_KEY", value)

    def refuse(*args, **kwargs):
        raise OSError("disk refused")

    with monkeypatch.context() as patch:
        patch.setattr("hermes_cli.config.atomic_replace", refuse)
        response = _call("capabilities.set_key", {"profile": "scout", "key_name": "MISTRAL_API_KEY", "value": None})
    assert response["error"]["code"] == 5103
    assert _env("scout")["MISTRAL_API_KEY"] == value
    assert _provider("tts", "mistral")["key_set"] is True


def test_a_shared_model_key_shows_as_set_but_has_nothing_to_remove_here(bots):
    (get_profile_dir("scout") / ".env").write_text(f"OPENAI_API_KEY={_canary()}\n")
    row = _provider("tts", "openai")
    assert row["key_set"] is True and row["can_remove"] is False and row["key_name"] == "VOICE_TOOLS_OPENAI_KEY"
    assert row["note"]


def test_a_provider_that_needs_a_key_cannot_be_chosen_until_it_has_one(bots):
    refused = _choose("scout", "tts", "elevenlabs")
    assert refused["outcome"] == "needs_key" and refused["reason"]
    assert _config("scout") == {}
    _set_key("scout", "ELEVENLABS_API_KEY", _canary())
    saved = _choose("scout", "tts", "elevenlabs")
    assert saved["outcome"] == "saved" and saved["settings"]["tts"]["selected"] == "elevenlabs"
    assert _config("scout")["tts"]["provider"] == "elevenlabs"
    assert _config("pilot") == {}


def test_the_edge_voice_is_chosen_from_the_listed_voices(bots):
    voices = [o["id"] for o in _settings()["tts"]["voice"]["options"]]
    assert "zh-CN-XiaoxiaoNeural" in voices
    assert _choose("scout", "tts", "edge", "zh-CN-XiaoxiaoNeural")["outcome"] == "saved"
    assert _settings()["tts"]["voice"]["current"] == "zh-CN-XiaoxiaoNeural"
    assert _choose("scout", "tts", "edge", "not-a-voice")["outcome"] == "invalid"
    assert _settings()["tts"]["voice"]["current"] == "zh-CN-XiaoxiaoNeural"


def test_a_voice_with_another_provider_is_invalid(bots):
    _set_key("scout", "ELEVENLABS_API_KEY", _canary())
    assert _choose("scout", "tts", "elevenlabs", "en-US-AriaNeural")["outcome"] == "invalid"
    assert _config("scout") == {}


@pytest.mark.parametrize("area,provider", [("tts", "no-such-engine"), ("tts", ""), ("memory", "no-such-memory"),
                                           ("tts", "neutts")])
def test_an_unavailable_provider_is_refused_and_nothing_is_written(bots, area, provider):
    result = _choose("scout", area, provider)
    assert result["outcome"] == "unsupported"
    assert _config("scout") == {}


def test_the_memory_provider_is_chosen_and_cleared(bots):
    assert _choose("scout", "memory", "retaindb")["outcome"] == "needs_key"
    _set_key("scout", "RETAINDB_API_KEY", _canary())
    assert _choose("scout", "memory", "retaindb")["settings"]["memory"]["selected"] == "retaindb"
    assert _config("scout")["memory"]["provider"] == "retaindb"
    assert _choose("scout", "memory", "byterover")["outcome"] == "saved"
    cleared = _choose("scout", "memory", "")
    assert cleared["outcome"] == "saved" and cleared["settings"]["memory"]["selected"] == ""
    assert _config("pilot") == {}


def test_a_failed_save_keeps_the_previous_choice(bots, monkeypatch):
    _choose("scout", "memory", "byterover")
    monkeypatch.setattr("hermes_cli.config.save_config", lambda *a, **k: (_ for _ in ()).throw(OSError("disk refused")))
    result = _choose("scout", "memory", "")
    assert result["outcome"] == "failed" and "settings" not in result or result["settings"] is None
    assert _config("scout")["memory"]["provider"] == "byterover"


def test_the_value_appears_nowhere_but_the_bots_env_file(bots, caplog, capsys):
    caplog.set_level(logging.DEBUG)
    values = [_canary() for _ in NEW_KEYS]
    answers = []
    for key, value in zip(NEW_KEYS, values):
        answers += [_set_key("scout", key, value), _settings(), _call("capabilities.status", {"profile": "scout"})]
    answers += [_choose("scout", "tts", "elevenlabs"), _settings()]
    for key in NEW_KEYS:
        answers.append(_set_key("scout", key, None))
    out = capsys.readouterr()
    outside = json.dumps(answers) + caplog.text + out.out + out.err
    assert not any(value in outside for value in values)
