from __future__ import annotations

import httpx
import pytest

from agent import account_usage

TOKEN = "gho_copilotusagetoken0123456789abcdef"


@pytest.fixture
def github(monkeypatch):
    seen = []
    responses = {"status": 200, "body": {}}

    def edge(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(responses["status"], json=responses["body"])

    real_client = httpx.Client
    monkeypatch.setattr(httpx, "Client", lambda *a, **k: real_client(*a, **{**k, "transport": httpx.MockTransport(edge)}))
    return type("Github", (), {"seen": seen, "responses": responses})


def _quota(entitlement=None, remaining=None, percent_remaining=None, unlimited=False):
    return {"entitlement": entitlement, "remaining": remaining, "percent_remaining": percent_remaining,
            "unlimited": unlimited}


def test_quota_snapshots_become_windows_and_unlimited_quotas_become_details(github):
    github.responses["body"] = {
        "copilot_plan": "business", "quota_reset_date_utc": "2099-02-01T00:00:00.000Z",
        "quota_snapshots": {
            "premium_interactions": _quota(300, 30, 10.0),
            "chat": _quota(unlimited=True),
            "completions": _quota(2000, 1500),
        }}

    snapshot = account_usage.fetch_account_usage("copilot", api_key=TOKEN, identity_id="fp:test", read_only=True)

    windows = {w.label: w for w in snapshot.windows}
    assert set(windows) == {"Premium requests", "Completions"}
    assert windows["Premium requests"].used_percent == pytest.approx(90.0)
    assert windows["Premium requests"].scope == "model"
    assert windows["Completions"].used_percent == pytest.approx(25.0)
    assert windows["Completions"].scope == "account"
    assert windows["Completions"].reset_at.isoformat() == "2099-02-01T00:00:00+00:00"
    assert snapshot.plan == "Business"
    assert snapshot.details == ("Chat: unlimited",)
    request = github.seen[0]
    assert str(request.url) == "https://api.github.com/copilot_internal/user"
    assert request.headers["authorization"] == f"token {TOKEN}"


def test_a_reply_without_quota_snapshots_is_unavailable_and_names_no_secret(github):
    github.responses["body"] = {"copilot_plan": "free"}

    snapshot = account_usage.fetch_account_usage("copilot", api_key=TOKEN, read_only=True)

    assert snapshot.windows == () and snapshot.unavailable_reason
    assert TOKEN not in snapshot.unavailable_reason


def test_a_rejected_token_fails_open_without_leaking_it(github, caplog):
    github.responses["status"] = 401

    with caplog.at_level("DEBUG"):
        snapshot = account_usage.fetch_account_usage("copilot", api_key=TOKEN, read_only=True)

    assert snapshot is None
    assert TOKEN not in caplog.text


@pytest.fixture
def no_github_login(monkeypatch):
    for name in ("COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr("hermes_cli.git_credentials._gh_cli_token", lambda: None)


def test_no_token_means_no_request(github, no_github_login):
    assert account_usage.fetch_account_usage("copilot") is None
    assert github.seen == []


def test_a_free_plan_omits_quotas_it_has_no_entitlement_for(github):
    github.responses["body"] = {
        "copilot_plan": "individual", "access_type_sku": "free_limited_copilot",
        "quota_reset_date_utc": "2099-12-01T00:00:00.000Z",
        "quota_snapshots": {
            "premium_interactions": _quota(0, 0, 0.0),
            "chat": _quota(200, 150, 75.0),
            "completions": _quota(2000, 2000, 100.0),
        }}

    snapshot = account_usage.fetch_account_usage("copilot", api_key=TOKEN, read_only=True)

    assert snapshot.plan == "Free"
    assert {w.label: w.used_percent for w in snapshot.windows} == {"Chat": 25.0, "Completions": 0.0}


def test_an_empty_pool_reads_the_github_cli_login(github, no_github_login, monkeypatch):
    monkeypatch.setattr("hermes_cli.git_credentials._gh_cli_token", lambda: TOKEN)
    github.responses["body"] = {"copilot_plan": "pro", "quota_snapshots": {"chat": _quota(100, 50)}}

    snapshot = account_usage.fetch_account_usage("copilot")

    assert [w.label for w in snapshot.windows] == ["Chat"]
    assert github.seen[0].headers["authorization"] == f"token {TOKEN}"
