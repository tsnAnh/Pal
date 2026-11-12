from __future__ import annotations

import importlib.util
import json
import logging
import stat
import sys
import types
from base64 import urlsafe_b64encode
from datetime import UTC, datetime, timedelta
from hashlib import sha256
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from tui_gateway import google_workspace as gw
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

CLIENT_ID = "test-client-id.apps.googleusercontent.com"
CLIENT_SECRET = "canary-client-secret-0123456789"
ACCESS = "ya29.CANARYACCESS0123456789"
REFRESH = "1//CANARYREFRESH0123456789"
CODE = "4/0CANARYCODE0123456789"
CLIENT_JSON = json.dumps({"installed": {"client_id": CLIENT_ID, "project_id": "pal-test", "client_secret": CLIENT_SECRET,
                                        "auth_uri": "https://evil.example/auth", "token_uri": "https://evil.example/token"}})
NAMES = {"google_workspace.status", "google_workspace.verify", "google_workspace.client.set",
         "google_workspace.signout", "google_workspace.signin.start", "google_workspace.signin.finish",
         "google_workspace.signin.cancel"}
SKILL = Path(__file__).resolve().parents[2] / "skills" / "productivity" / "google-workspace" / "scripts"


class Google:
    def __init__(self):
        self.posts: list[tuple[str, dict]] = []
        self.gets: list[str] = []
        self.token_reply = {"access_token": ACCESS, "refresh_token": REFRESH, "expires_in": 3599, "token_type": "Bearer",
                            "scope": "openid https://www.googleapis.com/auth/userinfo.email "
                                     "https://www.googleapis.com/auth/gmail.readonly "
                                     "https://www.googleapis.com/auth/calendar.readonly"}
        self.token_status = 200
        self.userinfo_status = 200
        self.down = False

    def post(self, url, data=None, timeout=None, follow_redirects=None, headers=None):
        assert follow_redirects is False and timeout
        self.posts.append((url, dict(data or {})))
        if self.down:
            raise httpx.ConnectError("offline")
        if url == gw.REVOKE_URI:
            return httpx.Response(200, json={}, request=httpx.Request("POST", url))
        return httpx.Response(self.token_status, json=self.token_reply, request=httpx.Request("POST", url))

    def get(self, url, headers=None, timeout=None, follow_redirects=None):
        assert follow_redirects is False and timeout
        self.gets.append(url)
        if self.down:
            raise httpx.ConnectError("offline")
        return httpx.Response(self.userinfo_status, json={"email": "owner@example.com"}, request=httpx.Request("GET", url))

    def exchanges(self):
        return [d for u, d in self.posts if u == gw.TOKEN_URI]


@pytest.fixture
def google(monkeypatch):
    fake = Google()
    monkeypatch.setattr(httpx, "post", fake.post)
    monkeypatch.setattr(httpx, "get", fake.get)
    yield fake
    gw.cancel_all()


@pytest.fixture
def home():
    return gw._home()


def _call(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


def _ok(method, params=None):
    response = _call(method, params)
    assert "error" not in response, response
    return response["result"]


def _setup():
    return _ok("google_workspace.client.set", {"client_json": CLIENT_JSON})


def _start(services=("gmail", "calendar"), write=()):
    result = _ok("google_workspace.signin.start", {"services": list(services), "write_services": list(write)})
    query = parse_qs(urlsplit(result["auth_url"]).query)
    return result["flow_id"], {k: v[0] for k, v in query.items()}


def _redirect(query, **override):
    values = {"code": CODE, "state": query["state"], **override}
    base = query["redirect_uri"]
    return base + "?" + "&".join(f"{k}={v}" for k, v in values.items() if v is not None)


def _signed_in(google, services=("gmail", "calendar"), write=()):
    _setup()
    flow_id, query = _start(services, write)
    done = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})
    assert done["state"] == "signed_in", done
    return done


def test_client_json_is_stored_for_the_skill_and_never_returned(home, caplog):
    caplog.set_level(logging.DEBUG)
    result = _setup()
    assert result["state"] == "needs_sign_in"
    stored = json.loads((home / "google_client_secret.json").read_text())["installed"]
    assert stored["client_id"] == CLIENT_ID and stored["client_secret"] == CLIENT_SECRET
    assert stored["token_uri"] == gw.TOKEN_URI and "evil" not in json.dumps(stored)
    assert stat.S_IMODE((home / "google_client_secret.json").stat().st_mode) == 0o600
    assert CLIENT_SECRET not in json.dumps(result) and CLIENT_SECRET not in caplog.text


def test_client_from_two_fields_and_bad_input(home):
    ok = _ok("google_workspace.client.set", {"client_id": CLIENT_ID, "client_secret": CLIENT_SECRET})
    assert ok["state"] == "needs_sign_in"
    for params in ({"client_json": "{not json"}, {"client_json": json.dumps({"web": {"client_id": CLIENT_ID, "client_secret": "x"}})},
                   {"client_id": "plain", "client_secret": "x"}, {}):
        assert _call("google_workspace.client.set", params)["error"]["code"] == 4101


def test_status_before_setup(google):
    assert _ok("google_workspace.status") == {"state": "not_configured", "email": None, "services": [],
                                              "write_services": [], "reauth_reason": None}
    assert google.posts == [] and google.gets == []


def test_scopes_default_read_only_and_write_is_opt_in():
    read_only = gw.scopes_for(["gmail", "calendar", "drive", "contacts", "sheets", "docs"], [])
    assert all(s.endswith(("readonly", "openid", "email")) or s == "openid" for s in read_only)
    assert not any(s.endswith(("gmail.send", "gmail.modify", "/calendar", "/drive", "/spreadsheets", "/documents")) for s in read_only)
    both = gw.scopes_for(["gmail", "calendar"], ["gmail"])
    assert "https://www.googleapis.com/auth/gmail.send" in both and "https://www.googleapis.com/auth/gmail.readonly" in both
    assert "https://www.googleapis.com/auth/calendar" not in both
    for services, write in (([], []), (["gmail"], ["calendar"]), (["contacts"], ["contacts"])):
        with pytest.raises(gw.WorkspaceError):
            gw.scopes_for(services, write)


def test_auth_url_uses_pkce_loopback_and_incremental_consent(home):
    _setup()
    _, query = _start()
    assert query["code_challenge_method"] == "S256" and query["include_granted_scopes"] == "true"
    assert query["access_type"] == "offline" and query["client_id"] == CLIENT_ID
    redirect = urlsplit(query["redirect_uri"])
    assert redirect.scheme == "http" and redirect.hostname == "127.0.0.1" and 49152 <= redirect.port < 65536
    assert "gmail.send" not in query["scope"] and "gmail.readonly" in query["scope"]
    assert CLIENT_SECRET not in query.get("client_secret", "") and "client_secret" not in query


def test_exchange_sends_the_verifier_and_the_same_redirect(google, home):
    _setup()
    flow_id, query = _start()
    flow = gw._flows[flow_id]
    done = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})
    sent = google.exchanges()[0]
    assert sent["redirect_uri"] == query["redirect_uri"] and sent["code"] == CODE and sent["grant_type"] == "authorization_code"
    assert urlsafe_b64encode(sha256(sent["code_verifier"].encode()).digest()).rstrip(b"=").decode() == query["code_challenge"]
    assert done["state"] == "signed_in" and done["status"]["email"] == "owner@example.com"
    assert done["status"]["services"] == ["gmail", "calendar"] and done["status"]["write_services"] == []
    assert flow_id not in gw._flows and flow.verifier not in json.dumps(done)


def test_written_token_loads_in_the_skills_own_code(google, home, monkeypatch):
    _signed_in(google)
    sys.path.insert(0, str(SKILL))
    try:
        spec = importlib.util.spec_from_file_location("gws_setup_under_test", SKILL / "setup.py")
        setup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(setup)
        bridge = importlib.util.spec_from_file_location("gws_bridge_under_test", SKILL / "gws_bridge.py")
        bridge_mod = importlib.util.module_from_spec(bridge)
        bridge.loader.exec_module(bridge_mod)
    finally:
        sys.path.remove(str(SKILL))
    token_path = home / "google_token.json"
    monkeypatch.setattr(setup, "TOKEN_PATH", token_path)
    monkeypatch.setattr(setup, "_ensure_deps", lambda: None)
    payload = setup._load_token_payload(token_path)
    assert payload["type"] == "authorized_user" and payload["refresh_token"] == REFRESH
    assert "https://www.googleapis.com/auth/gmail.readonly" in payload["scopes"]
    assert "https://www.googleapis.com/auth/gmail.send" in setup._missing_scopes_from_payload(payload)
    assert setup.check_auth(quiet=True) is True
    from google.oauth2.credentials import Credentials
    creds = Credentials.from_authorized_user_file(str(token_path))
    assert creds.valid and creds.refresh_token == REFRESH and set(creds.scopes) == set(payload["scopes"])
    monkeypatch.setattr(bridge_mod, "get_token_path", lambda: token_path)
    assert bridge_mod.get_valid_token() == ACCESS
    from google_auth_oauthlib.flow import Flow
    Flow.from_client_secrets_file(str(home / "google_client_secret.json"), scopes=payload["scopes"], redirect_uri="http://localhost:1")


def test_incremental_sign_in_keeps_granted_scopes_and_shows_write(google, home):
    _signed_in(google)
    google.token_reply = {**google.token_reply, "refresh_token": None,
                          "scope": "openid https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify "
                                   "https://www.googleapis.com/auth/gmail.readonly"}
    flow_id, query = _start(("gmail",), ("gmail",))
    done = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})
    assert done["status"]["write_services"] == ["gmail"] and done["status"]["services"] == ["gmail", "calendar"]
    assert json.loads((home / "google_token.json").read_text())["refresh_token"] == REFRESH


@pytest.mark.parametrize("shape", ["full", "query", "query_qmark"])
def test_paste_shapes_that_complete_the_sign_in(google, shape):
    _setup()
    flow_id, query = _start()
    full = _redirect(query)
    pasted = {"full": full, "query": full.split("?", 1)[1], "query_qmark": "?" + full.split("?", 1)[1]}[shape]
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": pasted})["state"] == "signed_in"


@pytest.mark.parametrize("make,code,state", [
    (lambda q: CODE, "unrecognized", "retry"),
    (lambda q: _redirect(q, state=None), "missing_state", "retry"),
    (lambda q: _redirect(q, state="other"), "state_mismatch", "retry"),
    (lambda q: _redirect(q) + "&code=second", "duplicate_param", "retry"),
    (lambda q: _redirect(q).replace("127.0.0.1", "evil.example"), "wrong_address", "retry"),
    (lambda q: _redirect(q, code=None), "missing_code", "retry"),
])
def test_bad_pastes_are_refused_without_calling_google(google, make, code, state):
    _setup()
    flow_id, query = _start()
    done = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": make(query)})
    assert (done["state"], done["code"]) == (state, code) and google.posts == []
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["state"] == "signed_in"


def test_access_denied_ends_the_flow(google):
    _setup()
    flow_id, query = _start()
    done = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query, code=None, error="access_denied")})
    assert done["state"] == "denied" and google.posts == []
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["code"] == "no_flow"


def test_paste_is_single_use_even_when_google_refuses(google, home):
    _setup()
    flow_id, query = _start()
    google.token_status, google.token_reply = 400, {"error": "invalid_grant"}
    first = _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})
    assert first["state"] == "failed" and first["code"] == "rejected"
    google.token_status, google.token_reply = 200, Google().token_reply
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["code"] == "no_flow"
    assert len(google.exchanges()) == 1 and not (home / "google_token.json").exists()


def test_flow_expires(google, monkeypatch):
    _setup()
    now = [1000.0]
    monkeypatch.setattr(gw, "_clock", lambda: now[0])
    flow_id, query = _start()
    now[0] += 301
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["code"] == "expired"
    assert google.posts == []


def test_too_many_bad_pastes_end_the_flow(google):
    _setup()
    flow_id, _ = _start()
    states = [_ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": "nonsense"})["state"] for _ in range(5)]
    assert states == ["retry"] * 4 + ["failed"]


def test_unreachable_google_fails_without_a_token(google, home):
    _setup()
    flow_id, query = _start()
    google.down = True
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["code"] == "unreachable"
    assert not (home / "google_token.json").exists()


def test_second_owner_session_finishes_but_another_profile_cannot(google):
    _setup()
    flow_id, query = _start()
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        assert _call("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert google.posts == []
    assert _ok("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": _redirect(query)})["state"] == "signed_in"


def test_status_does_no_network_and_reads_granted_services(google, home):
    _signed_in(google, write=("gmail",))
    google.posts.clear()
    google.gets.clear()
    for _ in range(3):
        status = _ok("google_workspace.status")
    assert status["state"] == "signed_in" and status["email"] == "owner@example.com"
    assert google.posts == [] and google.gets == []
    assert set(status) == {"state", "email", "services", "write_services", "reauth_reason"}


def test_missing_or_unreadable_token_is_reauth_needed_after_sign_in(google, home):
    _signed_in(google)
    token = home / "google_token.json"
    token.write_text("{broken")
    assert _ok("google_workspace.status")["reauth_reason"] == "token_unreadable"
    token.unlink()
    status = _ok("google_workspace.status")
    assert status["state"] == "reauth_needed" and status["reauth_reason"] == "token_missing"


def test_verify_revoked_grant_becomes_reauth_for_every_reader_and_does_not_loop(google, home):
    _signed_in(google)
    stored = json.loads((home / "google_token.json").read_text())
    stored["expiry"] = (datetime.now(UTC) - timedelta(hours=1)).strftime(gw.EXPIRY_FORMAT)
    (home / "google_token.json").write_text(json.dumps(stored))
    google.posts.clear()
    google.token_status, google.token_reply = 400, {"error": "invalid_grant", "error_description": "Token has been revoked"}
    status = _ok("google_workspace.verify")
    assert status["state"] == "reauth_needed" and status["reauth_reason"] == "revoked"
    assert len(google.exchanges()) == 1
    google.posts.clear()
    assert _ok("google_workspace.status")["state"] == "reauth_needed" and google.posts == []


def test_verify_ok_refreshes_once_and_clears_reauth(google, home):
    _signed_in(google)
    gw._set_marker(reauth="revoked")
    assert _ok("google_workspace.status")["state"] == "reauth_needed"
    google.token_reply = {"access_token": "ya29.NEW", "expires_in": 3600}
    stored = json.loads((home / "google_token.json").read_text())
    stored["expiry"] = "2001-01-01T00:00:00Z"
    (home / "google_token.json").write_text(json.dumps(stored))
    assert _ok("google_workspace.verify")["state"] == "signed_in"
    again = json.loads((home / "google_token.json").read_text())
    assert again["token"] == "ya29.NEW" and again["refresh_token"] == REFRESH and again["scopes"] == stored["scopes"]


def test_verify_offline_changes_nothing(google):
    _signed_in(google)
    google.down = True
    assert _call("google_workspace.verify")["error"]["data"]["code"] == "unreachable"
    google.down = False
    assert _ok("google_workspace.status")["state"] == "signed_in"


def test_signout_removes_only_the_token_and_revokes_best_effort(google, home):
    _signed_in(google)
    google.down = True
    status = _ok("google_workspace.signout")
    assert status["state"] == "needs_sign_in" and not (home / "google_token.json").exists()
    assert (home / "google_client_secret.json").exists()


def test_remove_setup_removes_the_client_too_and_revokes(google, home):
    _signed_in(google)
    status = _ok("google_workspace.signout", {"remove_setup": True})
    assert status["state"] == "not_configured" and not (home / "google_client_secret.json").exists()
    assert any(u == gw.REVOKE_URI and d["token"] == REFRESH for u, d in google.posts)


def test_new_client_id_signs_the_old_account_out(google, home):
    _signed_in(google)
    other = CLIENT_ID.replace("test-client-id", "other-client-id")
    assert _ok("google_workspace.client.set", {"client_id": other, "client_secret": CLIENT_SECRET})["state"] == "needs_sign_in"
    assert not (home / "google_token.json").exists()


def test_secrets_never_reach_logs_or_responses(google, home, caplog):
    caplog.set_level(logging.DEBUG)
    responses = [_call("google_workspace.client.set", {"client_json": CLIENT_JSON})]
    flow_id, query = _start()
    pasted = _redirect(query)
    responses.append(_call("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": pasted}))
    responses.append(_call("google_workspace.signin.finish", {"flow_id": flow_id, "pasted": pasted}))
    responses.append(_call("google_workspace.status"))
    google.down = True
    responses.append(_call("google_workspace.verify"))
    blob = json.dumps(responses) + caplog.text
    for canary in (CLIENT_SECRET, ACCESS, REFRESH, CODE, query["state"]):
        assert canary not in blob
    files = [p.name for p in home.iterdir()]
    assert "config.yaml" not in files or CLIENT_SECRET not in (home / "config.yaml").read_text()


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_worker_and_capability_less_connections_cannot_reach_the_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_secondary_profile_ticket_is_refused(google):
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        extra = {"google_workspace.client.set": {"client_json": CLIENT_JSON},
                 "google_workspace.signin.start": {"services": ["gmail"]},
                 "google_workspace.signin.finish": {"flow_id": "x", "pasted": "y"},
                 "google_workspace.signin.cancel": {"flow_id": "x"}}
        for name in NAMES:
            assert _call(name, extra.get(name))["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
    assert google.posts == [] and google.gets == []
