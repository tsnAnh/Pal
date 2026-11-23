from __future__ import annotations

import json
import logging
import os
import socket
import time
from types import SimpleNamespace

import pytest

from tests.tui_gateway.model_providers_support import (
    canary, completion, credential_files, failure, files_mentioning, home, llm, ok, rpc,
)
from tui_gateway import server
from tui_gateway.ws_legacy_fallback import _connection_profile_home

__all__ = ["canary", "home", "llm"]


def _test(llm, canary, **overrides):
    params = {"provider": "deepseek", "model": "probe-model", "base_url": llm.base_url, "api_key": canary}
    params.update(overrides)
    return ok("model.providers.test", params)


class _FakeClient:
    def __init__(self, reply="OK"):
        self.calls: list[dict] = []
        self.base_url = "https://fake.test/v1"
        self._reply = reply
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._create))

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content=self._reply))])


@pytest.fixture
def fake_client(monkeypatch):
    client = _FakeClient()
    resolved: list[dict] = []

    def resolve(provider, model=None, **kwargs):
        resolved.append({"provider": provider, "model": model, **kwargs})
        return client, model

    monkeypatch.setattr("agent.auxiliary_client.resolve_provider_client", resolve)
    client.resolved = resolved
    return client


def test_a_working_key_reports_latency_and_a_capped_preview_and_changes_nothing(home, llm, canary):
    llm.body = completion("0123456789" * 10)
    before = credential_files(home)
    result = _test(llm, canary)
    assert result["ok"] is True and result["provider"] == "deepseek" and result["model"] == "probe-model"
    assert isinstance(result["latency_ms"], int) and result["latency_ms"] >= 0
    assert result["reply_preview"] == ("0123456789" * 10)[:40]
    assert result.get("error") is None
    sent = llm.requests[0]
    assert sent["authorization"] == f"Bearer {canary}" and sent["body"]["model"] == "probe-model"
    assert credential_files(home) == before
    assert files_mentioning(home, canary) == []


@pytest.mark.parametrize("status, body, kind, retryable", [
    (401, failure("Incorrect API key provided", code="invalid_api_key"), "auth", False),
    (404, failure("The model `probe-model` does not exist", code="model_not_found"), "model", False),
    (429, failure("Rate limit reached for requests", type="rate_limit_error"), "quota", True),
    (402, failure("Insufficient balance. Please add credits to your account."), "quota", False),
])
def test_provider_failures_become_a_kind_and_a_retry_hint(home, llm, canary, status, body, kind, retryable):
    llm.status, llm.body = status, body
    before = credential_files(home)
    result = _test(llm, canary)
    assert result["ok"] is False and result["error"]["kind"] == kind and result["error"]["retryable"] is retryable
    assert result["error"]["code"] and 0 < len(result["error"]["reason"]) <= 300
    assert credential_files(home) == before


def test_an_unreachable_endpoint_is_a_network_failure(home, canary):
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    result = ok("model.providers.test", {"provider": "deepseek", "model": "m", "api_key": canary,
                                         "base_url": f"http://127.0.0.1:{port}/v1", "timeout_s": 5})
    assert result["ok"] is False and result["error"]["kind"] == "network" and result["error"]["retryable"] is True


def test_a_silent_endpoint_times_out_in_about_the_requested_time(home, llm, canary):
    llm.hang = True
    started = time.monotonic()
    result = _test(llm, canary, timeout_s=1)
    elapsed = time.monotonic() - started
    assert result["ok"] is False and result["error"]["kind"] == "timeout" and result["error"]["retryable"] is True
    assert elapsed < 15
    llm.release.set()


def test_the_timeout_defaults_to_30_and_is_clamped_to_60(home, fake_client, canary):
    ok("model.providers.test", {"provider": "deepseek", "model": "m", "api_key": canary})
    ok("model.providers.test", {"provider": "deepseek", "model": "m", "api_key": canary, "timeout_s": 900})
    ok("model.providers.test", {"provider": "deepseek", "model": "m", "api_key": canary, "timeout_s": 2.5})
    assert [c["timeout"] for c in fake_client.calls] == [30, 60, 2.5]


@pytest.mark.parametrize("overrides", [
    {"model": ""}, {"model": "x" * 300}, {"model": "bad\nname"}, {"provider": ""},
    {"timeout_s": 0}, {"timeout_s": -3}, {"timeout_s": True},
    {"base_url": "ftp://x.test"}, {"base_url": "https://user:pw@x.test/"}, {"api_key": "nön-ascii"},
])
def test_malformed_params_are_rejected_without_a_call(home, llm, canary, overrides):
    params = {"provider": "deepseek", "model": "m", "base_url": llm.base_url, "api_key": canary, **overrides}
    response = rpc("model.providers.test", params)
    assert response["error"]["code"] in {4000, 4001}
    assert llm.requests == []
    assert canary not in json.dumps(response)


def test_an_address_is_refused_for_a_provider_without_an_editable_address(home, llm, canary):
    response = rpc("model.providers.test", {"provider": "nous", "model": "m", "base_url": llm.base_url})
    assert response["error"]["code"] == 4001 and llm.requests == []


def test_missing_required_params_are_rejected(home):
    assert rpc("model.providers.test", {"provider": "deepseek"})["error"]["code"] in {4000, 4001}
    assert rpc("model.providers.test", {"model": "m"})["error"]["code"] in {4000, 4001}


@pytest.mark.parametrize("provider", ["nous", "xai-oauth"])
def test_account_wide_logins_are_not_tested_from_a_secondary_profile(home, fake_client, provider):
    token = _connection_profile_home.set(str(server._profile_home("scout")))
    try:
        response = rpc("model.providers.test", {"provider": provider, "model": "m"})
    finally:
        _connection_profile_home.reset(token)
    assert response["error"]["code"] == 4095 and "main profile" in response["error"]["message"]
    assert fake_client.calls == []


def test_unsupported_and_unknown_providers_answer_ok_false(home, fake_client):
    for provider in ("bedrock", "nope"):
        result = ok("model.providers.test", {"provider": provider, "model": "m"})
        assert result["ok"] is False and result["error"]["kind"] == "unsupported"
        assert result["error"]["code"] == "unsupported_provider" and result["error"]["reason"]
        assert result["error"]["retryable"] is False
    assert fake_client.calls == []


def test_a_sign_in_provider_is_tested_with_its_stored_login_and_never_the_staged_key(home, fake_client, canary):
    before = credential_files(home)
    result = ok("model.providers.test", {"provider": "openai-codex", "model": "m", "api_key": canary})
    assert result["ok"] is True
    assert fake_client.resolved[0]["provider"] == "openai-codex"
    assert fake_client.resolved[0].get("explicit_api_key") is None
    assert credential_files(home) == before


def test_a_provider_with_nothing_set_answers_auth_without_a_request(home, canary, monkeypatch):
    monkeypatch.setattr("agent.auxiliary_client.resolve_provider_client", lambda *a, **k: (None, None))
    result = ok("model.providers.test", {"provider": "deepseek", "model": "m"})
    assert result["ok"] is False and result["error"]["kind"] == "auth" and result["error"]["retryable"] is False


def test_the_staged_key_is_the_one_sent_and_the_stored_one_is_left_alone(home, llm, canary):
    from hermes_cli import model_provider_control as control
    stored = f"STORED-{canary}"
    control.store_pasted_credential("deepseek", stored)
    before = credential_files(home)
    result = _test(llm, canary)
    assert result["ok"] is True and llm.requests[0]["authorization"] == f"Bearer {canary}"
    assert credential_files(home) == before


def test_a_failing_staged_key_never_falls_back_to_another_credential(home, llm, canary):
    from hermes_cli import model_provider_control as control
    control.store_pasted_credential("deepseek", f"STORED-{canary}")
    llm.status, llm.body = 401, failure("bad key")
    before = credential_files(home)
    result = _test(llm, canary)
    assert result["error"]["kind"] == "auth"
    assert {r["authorization"] for r in llm.requests} == {f"Bearer {canary}"}
    assert credential_files(home) == before


def test_a_secondary_profile_is_tested_with_its_own_environment(home, llm, canary, monkeypatch):
    monkeypatch.setenv("DEEPSEEK_API_KEY", "launch-profile-key")
    scout = server._profile_home("scout")
    (scout / ".env").write_text(f"DEEPSEEK_API_KEY=scout-{canary}\n")
    environ_before = dict(os.environ)
    result = ok("model.providers.test", {"profile": "scout", "provider": "deepseek", "model": "m",
                                         "base_url": llm.base_url})
    assert result["ok"] is True and llm.requests[0]["authorization"] == f"Bearer scout-{canary}"
    assert dict(os.environ) == environ_before


def test_the_staged_key_appears_in_no_response_log_or_file(home, llm, canary, caplog):
    llm.status = 401
    llm.body = failure(f"Incorrect API key provided: {canary}. You can find your key at https://example.test/keys.")
    caplog.set_level(logging.DEBUG)
    response = server.handle_request({"id": "1", "method": "model.providers.test", "params": {
        "provider": "deepseek", "model": "m", "base_url": llm.base_url, "api_key": canary}})
    assert response["result"]["ok"] is False
    assert canary not in json.dumps(response)
    formatter = logging.Formatter()
    for record in caplog.records:
        text = formatter.format(record) + str(record.args) + str(record.__dict__.get("extra", ""))
        assert canary not in text, record.name
    assert files_mentioning(home, canary) == []


def test_an_unexpected_failure_inside_the_call_is_contained_and_scrubbed(home, canary, monkeypatch, caplog):
    def explode(*args, **kwargs):
        raise RuntimeError(f"boom {canary}")

    monkeypatch.setattr("agent.auxiliary_client.resolve_provider_client", explode)
    caplog.set_level(logging.DEBUG)
    response = server.handle_request({"id": "1", "method": "model.providers.test", "params": {
        "provider": "deepseek", "model": "m", "api_key": canary}})
    assert response["result"]["ok"] is False
    assert canary not in json.dumps(response)
    formatter = logging.Formatter()
    assert all(canary not in formatter.format(r) + str(r.args) for r in caplog.records)
