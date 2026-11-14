from __future__ import annotations

import json
import uuid

import pytest

from hermes_cli import model_provider_control as control
from hermes_cli.profiles import create_profile
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home


@pytest.fixture
def home(monkeypatch, tmp_path):
    root = tmp_path / "hermes-home"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    for var in ("DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DASHSCOPE_API_KEY", "ALIBABA_CODING_PLAN_API_KEY",
                "GOOGLE_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"):
        monkeypatch.delenv(var, raising=False)
    monkeypatch.setattr(server, "_hermes_home", root)
    create_profile("scout", no_alias=True, no_skills=True)
    return root


@pytest.fixture
def canary():
    return f"CANARY-{uuid.uuid4()}"


def _rpc(method, params=None):
    return server.handle_request({"id": "1", "method": method, "params": params or {}})


def _ok(method, params=None):
    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params or {})
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


def _row(provider_id, profile=None):
    listing = _ok("model.providers.list", {"profile": profile} if profile else {})
    return next(p for p in listing["providers"] if p["id"] == provider_id)


def _env(home):
    path = home / ".env"
    return path.read_text() if path.exists() else ""


def test_list_covers_every_registry_provider_with_a_kind_and_state(home):
    listing = _ok("model.providers.list")
    assert listing["profile"] == "default"
    ids = {p["id"] for p in listing["providers"]}
    assert {"nous", "openai-codex", "deepseek", "anthropic", "openrouter", "bedrock", "vertex", "qwen-oauth", "custom"} <= ids
    kinds = {p["id"]: p["kind"] for p in listing["providers"]}
    assert kinds["deepseek"] == "api_key" and kinds["nous"] == "device_code"
    assert kinds["bedrock"] == "unsupported" and kinds["qwen-oauth"] == "unsupported"
    assert all(p["reason"] for p in listing["providers"] if p["kind"] == "unsupported")
    assert all(p["state"] == "unsupported" for p in listing["providers"] if p["kind"] == "unsupported")
    assert all(p["scope"] == "account" for p in listing["providers"] if p["id"] in {"nous", "xai-oauth"})


def test_status_per_credential_kind_is_set_not_set_or_expired(home, monkeypatch, canary):
    assert _row("deepseek")["state"] == "not_set"
    control.store_pasted_credential("deepseek", canary)
    assert _row("deepseek")["state"] == "set"
    monkeypatch.setattr("hermes_cli.auth.get_auth_status", lambda pid=None: {"logged_in": False, "relogin_required": True})
    assert _row("nous")["state"] == "expired"
    monkeypatch.setattr("hermes_cli.auth.get_auth_status", lambda pid=None: {"logged_in": True})
    assert _row("openai-codex")["state"] == "set"
    monkeypatch.setattr("hermes_cli.auth.get_auth_status", lambda pid=None: {"logged_in": False})
    monkeypatch.setattr("hermes_cli.auth.get_provider_auth_state", lambda pid: None)
    assert _row("openai-codex")["state"] == "not_set"


def test_responses_never_carry_the_stored_value(home, canary):
    control.store_pasted_credential("deepseek", canary)
    text = json.dumps([_ok("model.providers.list"), _ok("model.providers.remove", {"provider": "deepseek"})])
    assert canary not in text


def test_set_replace_then_remove_an_api_key(home, canary):
    control.store_pasted_credential("deepseek", canary)
    assert f"DEEPSEEK_API_KEY={canary}" in _env(home)
    fresh = f"CANARY-{uuid.uuid4()}"
    control.store_pasted_credential("deepseek", fresh)
    assert canary not in _env(home) and fresh in _env(home)
    result = _ok("model.providers.remove", {"provider": "deepseek"})
    assert result["outcome"] == "removed" and result["provider"]["state"] == "not_set"
    assert "DEEPSEEK_API_KEY" not in _env(home)
    assert _ok("model.providers.remove", {"provider": "deepseek"})["outcome"] == "nothing_to_remove"


def test_removing_a_shared_key_keeps_it_for_the_other_provider(home, canary):
    control.store_pasted_credential("alibaba", canary)
    result = _ok("model.providers.remove", {"provider": "alibaba-coding-plan"})
    assert result["outcome"] in {"nothing_to_remove", "still_set"}
    assert canary in _env(home)


def test_a_key_supplied_by_the_host_environment_reports_still_set(home, monkeypatch, canary):
    monkeypatch.setenv("DEEPSEEK_API_KEY", canary)
    monkeypatch.setattr("hermes_cli.config.remove_env_value", lambda key: False)
    monkeypatch.setattr("hermes_cli.credential_lifecycle.remove_provider_env_credential", lambda key: {})
    result = _ok("model.providers.remove", {"provider": "deepseek"})
    assert result["outcome"] == "still_set" and result["reason"] and canary not in json.dumps(result)


def test_a_failed_remove_keeps_the_stored_value_and_hides_the_error(home, monkeypatch, canary):
    control.store_pasted_credential("deepseek", canary)

    def boom(provider_id):
        raise OSError(f"cannot write {canary}")
    monkeypatch.setattr(control, "remove_credential", boom)
    result = _ok("model.providers.remove", {"provider": "deepseek"})
    assert result["outcome"] == "failed" and canary not in json.dumps(result)
    assert f"DEEPSEEK_API_KEY={canary}" in _env(home)


def test_unsupported_and_unknown_providers_cannot_be_removed(home):
    assert _ok("model.providers.remove", {"provider": "bedrock"})["outcome"] == "unsupported"
    assert _ok("model.providers.remove", {"provider": "nope"})["outcome"] == "unsupported"


def test_account_wide_logins_are_refused_for_a_secondary_profile(home):
    token = _connection_profile_home.set(str(server._profile_home("scout")))
    try:
        refused = _ok("model.providers.remove", {"provider": "nous"})
        listing = _ok("model.providers.list")
    finally:
        _connection_profile_home.reset(token)
    assert refused["outcome"] == "refused" and "main profile" in refused["reason"]
    assert listing["profile"] == "scout"


def test_a_secondary_profile_never_touches_the_main_profiles_key(home, canary):
    control.store_pasted_credential("deepseek", canary)
    token = _connection_profile_home.set(str(server._profile_home("scout")))
    try:
        assert _row("deepseek")["state"] == "not_set"
        assert _ok("model.providers.remove", {"provider": "deepseek"})["outcome"] == "nothing_to_remove"
    finally:
        _connection_profile_home.reset(token)
    assert f"DEEPSEEK_API_KEY={canary}" in _env(home)


def test_an_unknown_profile_is_refused(home):
    assert _rpc("model.providers.list", {"profile": "ghost"})["error"]["code"] == 4064
    for name in ("remove", "set_base_url"):
        assert _rpc(f"model.providers.{name}", {"profile": "ghost", "provider": "deepseek"})["error"]["code"] == 4064


def test_base_url_set_reset_and_validation(home):
    row = _row("deepseek")
    assert row["base_url_editable"] and row["base_url"] is None and row["default_base_url"]
    saved = _ok("model.providers.set_base_url", {"provider": "deepseek", "base_url": "https://llm.example.test/v1/"})
    assert saved["outcome"] == "saved" and saved["provider"]["base_url"] == "https://llm.example.test/v1"
    for bad in ("ftp://x.test", "not a url", "https://user:pw@x.test/", "https://" + "a" * 3000, ""):
        result = _ok("model.providers.set_base_url", {"provider": "deepseek", "base_url": bad})
        assert result["outcome"] == "invalid", bad
    assert _row("deepseek")["base_url"] == "https://llm.example.test/v1"
    assert _ok("model.providers.set_base_url", {"provider": "deepseek"})["outcome"] == "reset"
    assert _row("deepseek")["base_url"] is None


def test_base_url_is_unsupported_for_providers_without_one(home):
    assert _ok("model.providers.set_base_url", {"provider": "nous", "base_url": "https://x.test"})["outcome"] == "unsupported"
    assert _ok("model.providers.set_base_url", {"provider": "ghost", "base_url": "https://x.test"})["outcome"] == "unsupported"


def test_removing_anthropic_after_a_setup_token_leaves_both_slots_empty(home, canary):
    token = f"sk-ant-oat01-{canary}"
    assert control.store_pasted_credential("anthropic", token)
    assert _row("anthropic")["state"] == "set"
    assert f"ANTHROPIC_TOKEN={token}" in _env(home)
    result = _ok("model.providers.remove", {"provider": "anthropic"})
    assert result["outcome"] == "removed" and result["provider"]["state"] == "not_set"
    assert "ANTHROPIC_TOKEN" not in _env(home) and "ANTHROPIC_API_KEY" not in _env(home)
    assert _row("anthropic")["state"] == "not_set"
    assert canary not in json.dumps(result)


def test_only_api_key_providers_accept_a_pasted_credential(home):
    with pytest.raises(ValueError):
        control.store_pasted_credential("nous", "anything")
    assert control.store_pasted_credential("deepseek", "") is False


def _pool_sources(home):
    path = home / "auth.json"
    pool = json.loads(path.read_text()).get("credential_pool", {}).get("anthropic", []) if path.exists() else []
    return {entry.get("source") for entry in pool}


def test_pasting_an_api_key_over_a_setup_token_clears_the_token_from_env_and_pool(home, canary):
    token = f"sk-ant-oat01-{canary}"
    key = f"sk-ant-api03-{canary}"
    assert control.store_pasted_credential("anthropic", token)
    assert "env:ANTHROPIC_TOKEN" in _pool_sources(home)
    assert control.store_pasted_credential("anthropic", key)
    assert f"ANTHROPIC_API_KEY={key}" in _env(home) and "ANTHROPIC_TOKEN" not in _env(home)
    assert "env:ANTHROPIC_TOKEN" not in _pool_sources(home)
    assert _row("anthropic")["state"] == "set"
