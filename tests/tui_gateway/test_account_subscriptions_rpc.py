from __future__ import annotations

import base64
import json
import logging
import os
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

CODEX_TOKEN_SECRET = "codex-refresh-secret-value"
COPILOT_TOKEN = "gho_launchcopilottoken0123456789abcdef"
OPENAI_KEY = "sk-launch-openai-key-0123456789abcdef"
SECONDARY_COPILOT_TOKEN = "gho_secondarycopilottoken0123456789ab"
RESET_EPOCH = int((datetime.now(UTC) + timedelta(hours=3)).timestamp())
WEEK_RESET_EPOCH = int((datetime.now(UTC) + timedelta(days=5)).timestamp())


def _jwt(account_id: str, subject: str, email: str) -> str:
    def part(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    claims = {"sub": subject, "email": email, "https://api.openai.com/auth": {"chatgpt_account_id": account_id}}
    return ".".join((part({"alg": "none"}), part(claims), "signature"))


def _entry(entry_id: str, label: str, token: str, *, auth_type: str = "api_key", **extra) -> dict:
    return {"id": entry_id, "label": label, "auth_type": auth_type, "priority": 0, "source": "manual",
            "access_token": token, **extra}


def _write_home(home: Path, pool: dict, *, provider: str) -> None:
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.yaml").write_text(f"model:\n  provider: {provider}\n  default: fixture-model\n")
    (home / "auth.json").write_text(json.dumps({"version": 1, "credential_pool": pool}))


def _record_spend(home: Path, provider: str, *, usd: float, input_tokens: int, output_tokens: int) -> None:
    from hermes_state import SessionDB

    db = SessionDB(db_path=home / "state.db")
    try:
        db.create_session(f"session-{provider}", "cli", model="fixture-model")
        db.update_token_counts(
            f"session-{provider}", input_tokens=input_tokens, output_tokens=output_tokens, model="fixture-model",
            estimated_cost_usd=usd, cost_status="estimated", cost_source="fixture", billing_provider=provider,
            api_call_count=1)
    finally:
        db.close()


def _codex_usage_body() -> dict:
    return {"plan_type": "plus", "rate_limit": {
        "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_at": RESET_EPOCH},
        "secondary_window": {"used_percent": 10, "limit_window_seconds": 604800, "reset_at": WEEK_RESET_EPOCH}}}


def _copilot_usage_body() -> dict:
    return {"copilot_plan": "individual", "quota_reset_date": "2099-01-01", "quota_snapshots": {
        "premium_interactions": {"entitlement": 300, "remaining": 240, "percent_remaining": 80.0, "unlimited": False},
        "chat": {"entitlement": 50, "remaining": 25, "percent_remaining": 50.0, "unlimited": False},
        "completions": {"unlimited": True}}}


class Wire:
    def __init__(self):
        self.event = threading.Event()
        self.response = None

    def write(self, response):
        self.response = response
        self.event.set()
        return True


@pytest.fixture
def runtime(tmp_path, monkeypatch):
    launch = tmp_path / "launch-home"
    secondary = launch / "profiles" / "secondary"
    codex_token = _jwt("acct-launch", "sub-launch", "launch@example.test")
    _write_home(launch, {
        "openai-codex": [_entry("codex1", "launch@example.test", codex_token, auth_type="oauth",
                                refresh_token=CODEX_TOKEN_SECRET, base_url="https://chatgpt.com/backend-api/codex")],
        "copilot": [_entry("copilot1", "octocat", COPILOT_TOKEN)],
        "openai-api": [_entry("openai1", "work key", OPENAI_KEY, base_url="https://api.openai.com/v1")],
    }, provider="openai-codex")
    _write_home(secondary, {
        "copilot": [_entry("copilot2", "secondary-octocat", SECONDARY_COPILOT_TOKEN)],
    }, provider="copilot")
    monkeypatch.setenv("HERMES_HOME", str(launch))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_SHARED_AUTH_DIR", str(tmp_path / "shared-auth"))

    from agent import account_usage_cache, secret_scope
    from tui_gateway import launch_profile_policy, server

    monkeypatch.setattr(launch_profile_policy, "_snapshot", None)
    monkeypatch.setattr(server, "_hermes_home", str(launch))
    monkeypatch.setattr(server, "_served_profile_homes", set())
    for table in ("_snapshots", "_started", "_last_try"):
        monkeypatch.setattr(account_usage_cache, table, {})
    monkeypatch.setattr(account_usage_cache, "_inflight", set())
    previous_multiplex = secret_scope.is_multiplex_active()
    launch_profile_policy.activate_multi_profile_hosting()

    state = SimpleNamespace(
        server=server, homes={"launch": launch, "secondary": secondary}, calls=[], gate=None,
        codex_token=codex_token, copilot_status=200)

    def http_edge(request: httpx.Request) -> httpx.Response:
        state.calls.append((request.method, str(request.url), request.headers.get("authorization")))
        if state.gate is not None:
            state.gate(request)
        if request.url.host == "chatgpt.com" and request.url.path.endswith("/wham/usage"):
            return httpx.Response(200, json=_codex_usage_body())
        if request.url.host == "api.github.com" and request.url.path == "/copilot_internal/user":
            if state.copilot_status != 200:
                return httpx.Response(state.copilot_status, json={"message": "boom"})
            return httpx.Response(200, json=_copilot_usage_body())
        return httpx.Response(404, json={})

    real_client = httpx.Client

    def client(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(http_edge)
        return real_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "Client", client)
    try:
        yield state
    finally:
        secret_scope.set_multiplex_active(previous_multiplex)


def _dispatch(server, params: dict | None = None) -> dict:
    wire = Wire()
    response = server.dispatch(
        {"jsonrpc": "2.0", "id": "probe", "method": "account.subscriptions", "params": params or {}}, wire)
    if response is None:
        assert wire.event.wait(30), "account.subscriptions did not answer"
        response = wire.response
    return response


def _subscriptions(runtime, **params) -> dict[str, dict]:
    response = _dispatch(runtime.server, params)
    assert "result" in response, response
    return {row["id"]: row for row in response["result"]["subscriptions"]}


def _ordered_ids(runtime, **params) -> list[str]:
    response = _dispatch(runtime.server, params)
    return [row["id"] for row in response["result"]["subscriptions"]]


def _window(row: dict, label: str) -> dict:
    return next(w for w in row["windows"] if w["label"] == label)


def test_lists_every_credential_with_windows_plan_and_spend(runtime):
    _record_spend(runtime.homes["launch"], "openai-api", usd=1.25, input_tokens=1000, output_tokens=200)

    rows = _subscriptions(runtime, refresh=True)

    assert set(rows) == {"codex1", "copilot1", "openai1"}
    codex, copilot, openai = rows["codex1"], rows["copilot1"], rows["openai1"]
    assert (codex["provider"], codex["provider_label"], codex["kind"], codex["plan"]) == (
        "openai-codex", "ChatGPT", "subscription", "Plus")
    assert codex["account_label"] == "launch@example.test"
    assert _window(codex, "Session")["used_percent"] == 42
    assert _window(codex, "Weekly")["used_percent"] == 10
    assert _window(codex, "Session")["resets_at"] == datetime.fromtimestamp(RESET_EPOCH, UTC).isoformat()
    assert codex["state"] == "ready" and codex["unavailable_reason"] is None and codex["fetched_at"]
    assert (copilot["provider_label"], copilot["kind"], copilot["plan"], copilot["account_label"]) == (
        "GitHub Copilot", "subscription", "Individual", "octocat")
    assert _window(copilot, "Premium requests")["used_percent"] == pytest.approx(20.0)
    assert _window(copilot, "Chat")["used_percent"] == pytest.approx(50.0)
    assert not any(w["label"] == "Completions" for w in copilot["windows"])
    assert _window(copilot, "Chat")["resets_at"].startswith("2099-01-01")
    assert (openai["provider_label"], openai["kind"], openai["plan"], openai["windows"]) == (
        "OpenAI API", "api_key", None, [])
    assert openai["spend"] == {"period_days": 7, "usd": 1.25, "input_tokens": 1000, "output_tokens": 200}
    assert openai["state"] == "unknown" and openai["unavailable_reason"]


def test_orders_active_first_then_subscriptions_then_api_keys(runtime):
    assert _ordered_ids(runtime) == ["codex1", "copilot1", "openai1"]

    (runtime.homes["launch"] / "config.yaml").write_text("model:\n  provider: openai-api\n  default: fixture-model\n")

    ordered = _ordered_ids(runtime)
    assert ordered[0] == "openai1"
    assert set(ordered[1:]) == {"codex1", "copilot1"}
    assert _subscriptions(runtime)["openai1"]["active"] is True


def test_cache_read_makes_no_network_call_and_serves_what_a_refresh_stored(runtime):
    cold = _subscriptions(runtime)

    assert runtime.calls == []
    assert cold["codex1"]["state"] == "unknown" and cold["codex1"]["windows"] == []
    assert cold["codex1"]["unavailable_reason"]

    _subscriptions(runtime, refresh=True)
    fetched = len(runtime.calls)
    assert fetched == 2

    warm = _subscriptions(runtime)

    assert len(runtime.calls) == fetched
    assert _window(warm["codex1"], "Session")["used_percent"] == 42
    assert _window(warm["copilot1"], "Premium requests")["used_percent"] == pytest.approx(20.0)


def test_refresh_fetches_accounts_concurrently(runtime):
    barrier = threading.Barrier(2, timeout=10)
    runtime.gate = lambda request: barrier.wait()

    rows = _subscriptions(runtime, refresh=True)

    assert rows["codex1"]["state"] == "ready" and rows["copilot1"]["state"] == "ready"


def test_dead_credential_is_unavailable_and_never_fetched(runtime):
    auth = runtime.homes["launch"] / "auth.json"
    store = json.loads(auth.read_text())
    store["credential_pool"]["copilot"][0].update(last_status="dead", last_error_code=401)
    auth.write_text(json.dumps(store))

    rows = _subscriptions(runtime, refresh=True)

    assert rows["copilot1"]["state"] == "unavailable" and rows["copilot1"]["windows"] == []
    assert rows["copilot1"]["unavailable_reason"]
    assert not any("api.github.com" in url for _, url, _ in runtime.calls)
    assert rows["codex1"]["state"] == "ready"


def test_failed_fetch_is_unknown_with_a_generic_reason_and_spares_siblings(runtime):
    runtime.copilot_status = 500

    rows = _subscriptions(runtime, refresh=True)

    assert rows["copilot1"]["state"] == "unknown" and rows["copilot1"]["windows"] == []
    assert rows["copilot1"]["unavailable_reason"] == "Usage could not be fetched."
    assert rows["codex1"]["state"] == "ready"


def test_fetch_past_the_deadline_is_unknown_and_timed_out(runtime, monkeypatch):
    from hermes_cli import account_subscriptions

    release = threading.Event()
    runtime.gate = lambda request: release.wait(10) if request.url.host == "api.github.com" else None
    monkeypatch.setattr(account_subscriptions, "FETCH_DEADLINE_S", 0.3)
    try:
        rows = _subscriptions(runtime, refresh=True)
    finally:
        release.set()

    assert rows["copilot1"]["state"] == "unknown"
    assert rows["copilot1"]["unavailable_reason"] == "Usage lookup timed out."
    assert rows["codex1"]["state"] == "ready"


def test_no_credential_or_token_preview_reaches_the_response_or_logs(runtime, caplog):
    store_path = runtime.homes["launch"] / "auth.json"
    store = json.loads(store_path.read_text())
    store["credential_pool"]["openai-api"][0]["label"] = OPENAI_KEY[:12] + "..."
    store_path.write_text(json.dumps(store))
    runtime.copilot_status = 401

    with caplog.at_level(logging.DEBUG):
        response = _dispatch(runtime.server, {"refresh": True})

    serialized = json.dumps(response) + "\n".join(record.getMessage() for record in caplog.records)
    secrets = (runtime.codex_token, CODEX_TOKEN_SECRET, COPILOT_TOKEN, OPENAI_KEY, OPENAI_KEY[:12],
               COPILOT_TOKEN[:10], runtime.codex_token.split(".")[1])
    assert not [secret for secret in secrets if secret in serialized]
    openai = next(row for row in response["result"]["subscriptions"] if row["id"] == "openai1")
    assert openai["account_label"] is None


def test_secondary_profile_shadows_the_launch_credential_it_replaces_and_inherits_the_rest(runtime):
    ambient = dict(os.environ)

    rows = _subscriptions(runtime, refresh=True, profile="secondary")

    assert set(rows) == {"copilot2", "codex1", "openai1"}
    assert rows["copilot2"]["active"] is True and rows["copilot2"]["account_label"] == "secondary-octocat"
    assert [bearer for _, url, bearer in runtime.calls if "api.github.com" in url] == [
        f"token {SECONDARY_COPILOT_TOKEN}"]
    assert dict(os.environ) == ambient
    assert set(_subscriptions(runtime)) == {"codex1", "copilot1", "openai1"}


def test_a_provider_with_several_credentials_lists_each_and_withholds_shared_spend(runtime):
    auth = runtime.homes["launch"] / "auth.json"
    store = json.loads(auth.read_text())
    store["credential_pool"]["openai-api"].append(_entry("openai2", "second key", "sk-second-key-0123456789abcdef"))
    auth.write_text(json.dumps(store))
    _record_spend(runtime.homes["launch"], "openai-api", usd=3.0, input_tokens=10, output_tokens=5)

    rows = _subscriptions(runtime)

    assert {"openai1", "openai2"} <= set(rows)
    assert rows["openai1"]["spend"] is None and rows["openai2"]["spend"] is None
    assert rows["codex1"]["spend"] == {"period_days": 7, "usd": 0.0, "input_tokens": 0, "output_tokens": 0}


def test_unknown_params_are_refused_by_the_wire_contract(runtime):
    response = _dispatch(runtime.server, {"refresh": True, "bogus": 1})

    assert "result" not in response
    assert response["error"]["code"] == 4000


def test_copilot_signed_in_outside_the_pool_is_listed_with_its_quota(runtime, monkeypatch):
    launch = runtime.homes["launch"]
    store = json.loads((launch / "auth.json").read_text())
    store["credential_pool"]["copilot"] = []
    (launch / "auth.json").write_text(json.dumps(store))
    for name in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr("hermes_cli.git_credentials._gh_cli_token", lambda: COPILOT_TOKEN)

    rows = _subscriptions(runtime, refresh=True)

    copilot = rows["copilot"]
    assert (copilot["provider_label"], copilot["kind"], copilot["state"]) == ("GitHub Copilot", "subscription", "ready")
    assert _window(copilot, "Chat")["used_percent"] == pytest.approx(50.0)
    assert COPILOT_TOKEN not in json.dumps(rows)
