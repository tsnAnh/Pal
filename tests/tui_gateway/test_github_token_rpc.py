from __future__ import annotations

import builtins
import json
import logging
import subprocess
import types
import httpx

import pytest

from tui_gateway import github_oauth, github_token, server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

CANARY = "ghp_CANARYTOKEN0123456789abcdefghijklmnop"
FUTURE = "2099-01-01 00:00:00 UTC"
PAST = "2020-01-01 00:00:00 UTC"
BOT_XDG = "/run/hermes/bot-desktop/config"


def api_output(status=200, scopes="repo, workflow, read:org, gist", expiry=None, login="octocat"):
    reason = {200: "OK", 401: "Unauthorized"}.get(status, "Other")
    lines = [f"HTTP/2.0 {status} {reason}", "Content-Type: application/json"]
    if scopes is not None:
        lines.append(f"X-Oauth-Scopes: {scopes}")
    if expiry:
        lines.append(f"Github-Authentication-Token-Expiration: {expiry}")
    body = json.dumps({"login": login} if status == 200 else {"message": "Bad credentials"})
    return "\n".join(lines) + "\n\n" + body + "\n"


class Gh:
    def __init__(self, stored=None, protocol="https", login_code=0, fail=None):
        self.stored = stored if stored is not None else api_output()
        self.protocol, self.login_code, self.fail = protocol, login_code, fail
        self.calls: list[dict] = []

    def run(self, argv, **kwargs):
        self.calls.append({"argv": list(argv), "input": kwargs.get("input"), "env": kwargs.get("env")})
        if self.fail == argv[:3]:
            return subprocess.CompletedProcess(argv, 1, "", "boom")
        if argv[:3] == ["gh", "api", "user"]:
            code = 0 if self.stored.startswith("HTTP/2.0 200") else 1
            if self.stored == "NOT_LOGGED_IN":
                return subprocess.CompletedProcess(argv, 4, "", "To get started with GitHub CLI, please run:  gh auth login")
            return subprocess.CompletedProcess(argv, code, self.stored, "")
        if argv[:3] == ["gh", "config", "get"]:
            return subprocess.CompletedProcess(argv, 0, self.protocol + "\n", "")
        if argv[:3] == ["gh", "auth", "login"]:
            return subprocess.CompletedProcess(argv, self.login_code, "", f"echo {kwargs.get('input')}" if self.login_code else "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    def argvs(self):
        return [c["argv"] for c in self.calls]


@pytest.fixture
def gh(monkeypatch):
    fake = Gh()
    monkeypatch.setattr(github_token.subprocess, "run", fake.run)
    return fake




CLIENT_ID = "Ov23liFAKECLIENTID00"
ACCESS = "gho_CANARYACCESS0123456789abcdefghijklmn"
DEVICE = "DEVICE-CODE-CANARY-0123456789"


class Clock:
    now = 1000.0

    def __call__(self):
        return self.now


class GitHub:
    def __init__(self):
        self.posts: list[tuple[str, dict]] = []
        self.token_replies: list[dict] = []
        self.code_reply = {"device_code": DEVICE, "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device",
                           "expires_in": 900, "interval": 5}
        self.user = (200, {"X-OAuth-Scopes": "repo, workflow, read:org, gist"}, {"login": "octocat"})
        self.down = False
        self.gets: list[dict] = []

    def post(self, url, data=None, headers=None, timeout=None, follow_redirects=None):
        self.posts.append((url, dict(data or {})))
        assert follow_redirects is False and timeout
        if self.down:
            raise httpx.ConnectError("offline")
        body = self.code_reply if url == github_oauth.DEVICE_CODE_URL else self.token_replies.pop(0)
        return httpx.Response(200, json=body, request=httpx.Request("POST", url))

    def get(self, url, headers=None, timeout=None, follow_redirects=None):
        self.gets.append({"url": url, "headers": headers})
        assert follow_redirects is False and timeout
        if self.down:
            raise httpx.ConnectError("offline")
        status, hdrs, body = self.user
        return httpx.Response(status, headers=hdrs, json=body, request=httpx.Request("GET", url))


@pytest.fixture
def clock(monkeypatch):
    fake = Clock()
    monkeypatch.setattr(github_oauth, "_clock", fake)
    yield fake
    github_oauth.cancel_all()


@pytest.fixture
def hub(monkeypatch, clock):
    fake = GitHub()
    monkeypatch.setattr(httpx, "post", fake.post)
    monkeypatch.setattr(httpx, "get", fake.get)
    return fake


@pytest.fixture
def configured():
    assert "result" in _call("github.oauth.config.set", {"client_id": CLIENT_ID})


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def _start():
    response = _call("github.oauth.start")
    assert "error" not in response, response
    METHODS["github.oauth.start"].result.model_validate(response["result"])
    return response["result"]


def _poll(session_id):
    response = _call("github.oauth.poll", {"session_id": session_id})
    METHODS["github.oauth.poll"].result.model_validate(response["result"])
    return response["result"]


def _next(clock, seconds=5):
    clock.now += seconds


@pytest.mark.parametrize("stored,state,extra", [
    (api_output(), "set", {"login": "octocat", "token_kind": "classic", "scopes": ["repo", "workflow", "read:org", "gist"]}),
    (api_output(scopes="repo"), "missing_scopes", {"missing_scopes": ["workflow", "read:org", "gist"], "token_kind": "classic"}),
    (api_output(status=401), "invalid", {}),
    (api_output(status=401, expiry=PAST), "expired", {"expires_at": "2020-01-01T00:00:00Z"}),
    (api_output(scopes=None, expiry=FUTURE), "set", {"token_kind": "fine_grained", "scopes": [], "expires_at": "2099-01-01T00:00:00Z"}),
    (api_output(), "set", {"expires_at": None}),
    ("NOT_LOGGED_IN", "missing", {"login": None, "token_kind": "unknown"}),
    ("garbage with no status line", "unknown", {}),
])
def test_status_for_each_state(monkeypatch, configured, stored, state, extra):
    fake = Gh(stored=stored, protocol="ssh")
    monkeypatch.setattr(github_token.subprocess, "run", fake.run)
    result = _call("github.token.status")["result"]
    METHODS["github.token.status"].result.model_validate(result)
    assert result["state"] == state and result["git_protocol"] == "ssh"
    assert {k: result[k] for k in extra} == extra


def test_status_says_the_oauth_app_is_not_configured_until_a_client_id_is_set(monkeypatch):
    fake = Gh(stored="NOT_LOGGED_IN")
    monkeypatch.setattr(github_token.subprocess, "run", fake.run)
    assert _call("github.token.status")["result"]["state"] == "oauth_app_not_configured"
    _call("github.oauth.config.set", {"client_id": CLIENT_ID})
    assert _call("github.token.status")["result"]["state"] == "missing"


def test_status_degrades_when_gh_is_missing(monkeypatch, configured):
    def boom(*args, **kwargs):
        raise FileNotFoundError("gh")
    monkeypatch.setattr(github_token.subprocess, "run", boom)
    assert _call("github.token.status")["result"] == {
        "state": "unknown", "login": None, "scopes": [], "missing_scopes": [], "expires_at": None,
        "token_kind": "unknown", "git_protocol": "unset"}


def test_client_id_is_saved_read_cleared_and_validated(monkeypatch):
    assert _call("github.oauth.config.get")["result"] == {"client_id": None}
    assert _call("github.oauth.config.set", {"client_id": f"  {CLIENT_ID} "})["result"] == {"client_id": CLIENT_ID}
    assert _call("github.oauth.config.get")["result"] == {"client_id": CLIENT_ID}
    assert _call("github.oauth.config.set", {"client_id": "bad id!"})["error"]["code"] == 4101
    assert _call("github.oauth.config.get")["result"] == {"client_id": CLIENT_ID}
    assert _call("github.oauth.config.set", {"client_id": None})["result"] == {"client_id": None}
    assert _call("github.oauth.config.get")["result"] == {"client_id": None}


def test_start_without_a_client_id_is_typed(hub):
    error = _call("github.oauth.start")["error"]
    assert error["code"] == 5311 and error["data"]["code"] == "oauth_app_not_configured"
    assert hub.posts == []


def test_start_returns_the_code_and_asks_github_for_the_bot_scopes(hub, configured):
    started = _start()
    assert started["user_code"] == "ABCD-1234" and started["verification_uri"] == "https://github.com/login/device"
    assert started["interval"] == 5 and 0 < started["expires_in"] <= 900
    assert hub.posts == [(github_oauth.DEVICE_CODE_URL, {"client_id": CLIENT_ID, "scope": "repo workflow read:org gist"})]
    assert DEVICE not in json.dumps(started)


def test_a_second_start_returns_the_pending_flow(hub, configured):
    first = _start()
    assert _start()["session_id"] == first["session_id"]
    assert len(hub.posts) == 1


def test_start_after_the_flow_ended_begins_a_new_one(hub, configured, gh):
    first = _start()
    _call("github.oauth.cancel", {"session_id": first["session_id"]})
    assert _start()["session_id"] != first["session_id"]


@pytest.mark.parametrize("reply,code", [
    ({"error": "device_flow_disabled"}, "oauth_app_rejected"),
    ({"error": "incorrect_client_credentials"}, "oauth_app_rejected"),
    ({"unexpected": True}, "unreachable"),
])
def test_start_errors_are_typed(hub, configured, reply, code):
    hub.code_reply = reply
    error = _call("github.oauth.start")["error"]
    assert error["code"] == 5311 and error["data"]["code"] == code


def test_start_when_github_is_unreachable(hub, configured):
    hub.down = True
    assert _call("github.oauth.start")["error"]["data"]["code"] == "unreachable"


def test_pending_then_signed_in_applies_the_token_once_through_stdin(hub, configured, clock, gh):
    gh.stored = api_output()
    session = _start()["session_id"]
    hub.token_replies = [{"error": "authorization_pending"}, {"access_token": ACCESS, "token_type": "bearer", "scope": "repo,workflow"}]
    assert _poll(session)["state"] == "pending"
    _next(clock)
    assert _poll(session)["state"] == "pending"
    _next(clock)
    result = _poll(session)
    assert result["state"] == "signed_in" and result["login"] == "octocat"
    assert hub.posts[-1] == (github_oauth.ACCESS_TOKEN_URL, {"client_id": CLIENT_ID, "device_code": DEVICE,
                                                              "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
    argvs = gh.argvs()
    login = ["gh", "auth", "login", "--hostname", "github.com", "--with-token"]
    assert argvs.count(login) == 1
    assert ["gh", "config", "set", "git_protocol", "https"] in argvs
    assert ["gh", "config", "set", "git_protocol", "https", "-h", "github.com"] in argvs
    assert all(i < argvs.index(login) for i, a in enumerate(argvs) if a[:3] == ["gh", "config", "set"])
    for call in gh.calls:
        assert ACCESS not in " ".join(call["argv"]) and ACCESS not in json.dumps(call["env"])
        assert (call["input"] == f"{ACCESS}\n") == (call["argv"] == login)
    assert hub.gets[0]["headers"]["Authorization"] == f"Bearer {ACCESS}"
    assert _poll(session) == result


def test_polls_faster_than_the_interval_do_not_call_github(hub, configured, clock):
    session = _start()["session_id"]
    for _ in range(3):
        assert _poll(session)["state"] == "pending"
    assert len(hub.posts) == 1


def test_slow_down_raises_the_interval(hub, configured, clock):
    session = _start()["session_id"]
    hub.token_replies = [{"error": "slow_down", "interval": 10}, {"error": "authorization_pending"}]
    _next(clock)
    assert _poll(session)["state"] == "pending"
    _next(clock, 5)
    assert _poll(session)["state"] == "pending" and len(hub.posts) == 2
    _next(clock, 10)
    assert _poll(session)["state"] == "pending" and len(hub.posts) == 3


def test_slow_down_without_an_interval_adds_five_seconds(hub, configured, clock):
    session = _start()["session_id"]
    hub.token_replies = [{"error": "slow_down"}]
    _next(clock)
    _poll(session)
    assert github_oauth._current.interval == 10


@pytest.mark.parametrize("reply,state", [
    ({"error": "expired_token"}, "expired"),
    ({"error": "access_denied"}, "denied"),
    ({"error": "access_denied", "error_description": "The organization has OAuth App access restrictions."}, "org_approval_needed"),
    ({"error": "incorrect_device_code"}, "failed"),
])
def test_terminal_answers_from_github(hub, configured, clock, reply, state):
    session = _start()["session_id"]
    hub.token_replies = [reply]
    _next(clock)
    result = _poll(session)
    assert result["state"] == state
    assert _poll(session) == result


def test_org_restriction_text_from_the_user_call_is_org_approval_needed(hub, configured, clock, gh):
    hub.user = (403, {}, {"message": "Although you appear to have the correct authorization credentials, the `Acme` organization has enabled OAuth App access restrictions, meaning that data access to third-parties is limited."})
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    result = _poll(session)
    assert result["state"] == "org_approval_needed" and "organization owner" in result["message"]
    assert gh.calls == []


def test_the_code_expiring_ends_the_flow(hub, configured, clock):
    session = _start()["session_id"]
    clock.now += 901
    assert _poll(session)["state"] == "expired"
    assert github_oauth._current.device_code == ""
    assert len(hub.posts) == 1


def test_missing_scopes_are_reported_and_not_applied(hub, configured, clock, gh):
    hub.user = (200, {"X-OAuth-Scopes": "repo"}, {"login": "octocat"})
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    result = _poll(session)
    assert result["state"] == "failed" and result["code"] == "missing_scopes" and result["missing_scopes"] == ["workflow", "read:org", "gist"]
    assert gh.calls == []


def test_a_rejected_token_is_failed_and_not_applied(hub, configured, clock, gh):
    hub.user = (401, {}, {"message": "Bad credentials"})
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    result = _poll(session)
    assert result["state"] == "failed" and result["code"] == "invalid" and gh.calls == []


def test_a_failed_gh_login_is_apply_failed(hub, configured, clock, monkeypatch):
    fake = Gh(login_code=1)
    monkeypatch.setattr(github_token.subprocess, "run", fake.run)
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    result = _poll(session)
    assert result["state"] == "failed" and result["code"] == "apply_failed"
    assert ACCESS not in json.dumps(result)


def test_a_failed_setup_step_never_reaches_the_login(hub, configured, clock, monkeypatch):
    fake = Gh(fail=["gh", "config", "set"])
    monkeypatch.setattr(github_token.subprocess, "run", fake.run)
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    assert _poll(session)["code"] == "apply_failed"
    assert not any(a[:3] == ["gh", "auth", "login"] for a in fake.argvs())


def test_github_going_offline_while_polling_stays_pending(hub, configured, clock):
    session = _start()["session_id"]
    hub.down = True
    _next(clock)
    assert _poll(session)["state"] == "pending"


def test_cancel_drops_the_flow_and_its_device_code(hub, configured, clock):
    session = _start()["session_id"]
    assert _call("github.oauth.cancel", {"session_id": session})["result"] == {"ok": True}
    assert github_oauth._current is None
    assert _poll(session)["state"] == "failed"
    assert _call("github.oauth.cancel", {"session_id": "other"})["result"] == {"ok": True}


def test_gateway_stop_and_a_new_client_id_drop_the_flow(hub, configured):
    _start()
    github_oauth.cancel_all()
    assert github_oauth._current is None
    _start()
    _call("github.oauth.config.set", {"client_id": CLIENT_ID})
    assert github_oauth._current is None


def test_validation_without_a_scope_header_is_a_fine_grained_token(hub):
    hub.user = (200, {}, {"login": "octocat"})
    assert github_token.validate_token("github_pat_FAKE")["token_kind"] == "fine_grained"


def test_http_calls_follow_no_redirects_and_unreachable_carries_no_token(monkeypatch, caplog):
    def refuse(url, headers=None, timeout=None, follow_redirects=None):
        assert follow_redirects is False
        raise httpx.ConnectError(f"cannot reach {headers['Authorization']}")
    monkeypatch.setattr(httpx, "get", refuse)
    with caplog.at_level(logging.DEBUG):
        with pytest.raises(github_token.TokenError) as raised:
            github_token.validate_token(ACCESS)
    assert raised.value.code == "unreachable"
    assert ACCESS not in str(raised.value) + repr(raised.value) + caplog.text
    assert raised.value.__cause__ is None and raised.value.__suppress_context__


def test_canary_access_token_is_absent_from_responses_logs_and_reprs(hub, configured, clock, gh, caplog):
    seen = []
    with caplog.at_level(logging.DEBUG):
        started = _start()
        hub.token_replies = [{"access_token": ACCESS, "token_type": "bearer", "scope": "repo,workflow"}]
        _next(clock)
        seen += [started, _poll(started["session_id"]), _call("github.token.status"), _call("github.oauth.config.get")]
        hub.user = (401, {}, {"message": "Bad credentials"})
        again = _start()
        hub.token_replies = [{"access_token": ACCESS}]
        _next(clock)
        seen.append(_poll(again["session_id"]))
        hub.token_replies = [{"access_token": ACCESS, "boom": 1}]
    blob = json.dumps(seen) + caplog.text + repr(github_oauth._current)
    assert ACCESS not in blob and DEVICE not in blob and "hosts.yml" not in blob


def test_an_unexpected_failure_is_logged_without_the_token(hub, configured, clock, monkeypatch, caplog):
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    monkeypatch.setattr(github_token, "validate_token", lambda token: (_ for _ in ()).throw(RuntimeError("boom")))
    _next(clock)
    with caplog.at_level(logging.DEBUG):
        error = _call("github.oauth.poll", {"session_id": session})["error"]
    assert error["code"] == 5311 and ACCESS not in json.dumps(error) + caplog.text


def test_the_token_is_never_read_back(hub, configured, clock, gh, monkeypatch):
    opened = []
    real_open = builtins.open
    monkeypatch.setattr(builtins, "open", lambda f, *a, **k: (opened.append(str(f)), real_open(f, *a, **k))[1])
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    _poll(session)
    _call("github.token.status")
    argvs = gh.argvs()
    assert "--show-token" not in [part for argv in argvs for part in argv]
    assert ["gh", "auth", "token"] not in [a[:3] for a in argvs]
    assert not [p for p in opened if "hosts.yml" in p or "/gh/" in p or ".config/gh" in p]


def test_subprocess_env_keeps_host_xdg_and_drops_tokens(monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", "/home/host/.config")
    monkeypatch.setenv("GH_TOKEN", ACCESS)
    monkeypatch.setenv("GITHUB_TOKEN", ACCESS)
    monkeypatch.setattr("tools.bot_desktop.runtime.published_env",
                        lambda: {"DISPLAY": ":20", "XDG_CONFIG_HOME": BOT_XDG})
    env = github_token.host_env()
    assert env["XDG_CONFIG_HOME"] == "/home/host/.config"
    assert not {"GH_TOKEN", "GITHUB_TOKEN"} & set(env)
    assert ACCESS not in json.dumps(env)


def test_gh_runs_with_the_host_env_not_the_bot_desktop_one(hub, configured, clock, gh, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", "/home/host/.config")
    monkeypatch.setattr("tools.bot_desktop.runtime.published_env", lambda: {"XDG_CONFIG_HOME": BOT_XDG})
    session = _start()["session_id"]
    hub.token_replies = [{"access_token": ACCESS}]
    _next(clock)
    _poll(session)
    assert gh.calls and all(c["env"]["XDG_CONFIG_HOME"] == "/home/host/.config" for c in gh.calls)


NAMES = {"github.token.status", "github.oauth.start", "github.oauth.poll", "github.oauth.cancel",
         "github.oauth.config.get", "github.oauth.config.set"}


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_the_paste_token_method_does_not_exist():
    assert "github.token.set" not in METHODS and "github.token.set" not in server._methods
    assert not hasattr(github_token, "set_token")


def test_worker_and_capability_less_connections_cannot_reach_the_github_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_secondary_profile_ticket_is_refused(hub, configured, gh):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        extra = {"github.oauth.poll": {"session_id": "x"}, "github.oauth.cancel": {"session_id": "x"},
                 "github.oauth.config.set": {"client_id": CLIENT_ID}}
        for name in NAMES:
            assert _call(name, extra.get(name))["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert gh.calls == [] and hub.posts == []
