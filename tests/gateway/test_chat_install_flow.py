"""Chat install end to end: RPC handlers and the redirect route against a real store, with the two
contract fakes standing in for a provider and a recording stand-in for the adapter env writer.
"""

from __future__ import annotations

import logging
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from gateway import chat_install_runtime
from gateway.chat_install_store import ChatInstallStore
from hermes_cli.web_routers import chat_install as route
from tests.gateway.chat_install_harness import HTTPS, RecordingControl, db_bytes, forbidden_in, nonce_of, register_fakes, walk_json
from tests.tui_gateway.contracts.chat_provider_fakes import FAKE_TOKEN, AuthorizeOnlyFake, CredentialAppFake
from tui_gateway import chat_install as ci
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.contracts import chat_provider as wire
from tui_gateway.ws_legacy_fallback import _connection_profile_home

BOT = "default"
CODE = "code-from-slack"


@pytest.fixture
def env(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    control = RecordingControl()
    monkeypatch.setattr(chat_install_runtime, "MessagingAdapterControl", lambda: control)
    monkeypatch.setattr(chat_install_runtime, "public_url_for", lambda _home: HTTPS)
    credential, authorize = CredentialAppFake(), AuthorizeOnlyFake()
    register_fakes(monkeypatch, credential, authorize)
    app = FastAPI()
    app.include_router(route.router)
    return type("Env", (), {"home": home, "control": control, "client": TestClient(app), "providers": {
        credential.provider_id: credential, authorize.provider_id: authorize}})()


def call(method: str, **params) -> dict:
    scoped = {} if method == "chat.provider.list" else {"workspace": "w1"}
    response = server.handle_request({"id": "1", "method": method, "params": {**scoped, **params}})
    if "result" in response:
        METHODS[method].result.model_validate(response["result"])
    return response


def state_of(response: dict) -> wire.SetupState:
    assert "error" not in response, response["error"]
    return wire.SetupState.model_validate(response["result"]["state"])


def drive_to_allow(provider_id: str) -> wire.SetupState:
    state = state_of(call("chat.install.begin", provider_id=provider_id))
    if state.step is wire.SetupStep.needs_credential:
        state = state_of(call("chat.install.advance", provider_id=provider_id, event="credential_saved",
                              expected_revision=state.revision, vault_item_id="vault-config"))
    if state.step is wire.SetupStep.needs_manual_step:
        state = state_of(call("chat.install.advance", provider_id=provider_id, event="manual_step_done",
                              expected_revision=state.revision))
    assert state.step is wire.SetupStep.needs_allow
    return state


def allow(env, state: wire.SetupState, **query):
    return env.client.get("/webapp/chat-install/callback", params={"code": CODE, "state": nonce_of(state.next_action.link), **query})


def own_log(caplog) -> str:
    return "\n".join(r.getMessage() for r in caplog.records if not r.name.startswith("httpx"))


@pytest.fixture(params=["fake-credential", "fake-authorize"])
def provider_id(request):
    return request.param


def test_full_flow_reaches_ready_and_restricts_the_bot_to_the_owner(env, provider_id, caplog):
    caplog.set_level(logging.DEBUG)
    state = drive_to_allow(provider_id)
    assert state.next_action.kind is wire.NextActionKind.open_link and "state=" in state.next_action.link
    assert state.fallback_action.action_id == "bot_token"
    page = allow(env, state)
    assert page.status_code == 200 and "Go back to Pal" in page.text
    assert page.headers["cache-control"] == "no-store" and page.headers["referrer-policy"] == "no-referrer"
    assert CODE not in page.text and nonce_of(state.next_action.link) not in page.text
    final = call("chat.install.status", provider_id=provider_id)
    assert state_of(final).step is wire.SetupStep.ready and state_of(final).fallback_action is None
    installation = wire.Installation.model_validate(final["result"]["installation"])
    assert "U_OWNER" not in walk_json(final) and ChatInstallStore(env.home).owner_id(installation.id) == "U_OWNER"
    assert env.control.applied == [(BOT, provider_id, {"FAKE_BOT_TOKEN": FAKE_TOKEN, "FAKE_ALLOWED_USERS": "U_OWNER"}, [])]
    assert env.control.reloads == [BOT]
    nonce = nonce_of(state.next_action.link)
    assert forbidden_in(own_log(caplog), [nonce]) == []
    wire_text = repr(final) + repr(call("chat.binding.list", provider_id=provider_id))
    assert FAKE_TOKEN not in wire_text and CODE not in wire_text


def test_second_client_resumes_from_persisted_state(env):
    first = state_of(call("chat.install.begin", provider_id="fake-credential"))
    assert first.step is wire.SetupStep.needs_credential
    ChatInstallStore(env.home)
    resumed = state_of(call("chat.install.status", provider_id="fake-credential"))
    assert resumed == first
    moved = state_of(call("chat.install.advance", provider_id="fake-credential", event="credential_saved",
                          expected_revision=resumed.revision, vault_item_id="vault-config"))
    assert moved.revision > first.revision


def test_replayed_forged_and_unknown_state_are_rejected_and_consumed_once(env):
    state = drive_to_allow("fake-authorize")
    forged = env.client.get("/webapp/chat-install/callback", params={"code": CODE, "state": "forged" * 8})
    assert forged.status_code == 400 and "expired or was already used" in forged.text
    assert env.client.get("/webapp/chat-install/callback", params={"code": CODE}).status_code == 400
    assert allow(env, state).status_code == 200
    replay = allow(env, state)
    assert replay.status_code == 400 and CODE not in replay.text
    assert len(env.control.applied) == 1


def test_expired_state_is_rejected(env, monkeypatch):
    state = drive_to_allow("fake-authorize")
    store = ChatInstallStore(env.home)
    key = (BOT, "fake-authorize", "w1")
    assert store.consume_nonce(nonce_of(state.next_action.link), now=10**12) is None
    assert store.consume_nonce(nonce_of(state.next_action.link)) is None
    assert store.load(key).step is wire.SetupStep.needs_allow


def test_second_redirect_never_creates_a_second_installation(env):
    state = drive_to_allow("fake-authorize")
    assert allow(env, state).status_code == 200
    again = state_of(call("chat.install.begin", provider_id="fake-authorize"))
    assert again.step is wire.SetupStep.ready
    store = ChatInstallStore(env.home)
    service = chat_install_runtime.build_service(env.home)
    fresh = store.issue_nonce((BOT, "fake-authorize", "w1"))
    assert service.complete_redirect(fresh, CODE, None).value == "completed"
    assert len(env.providers["fake-authorize"].installs) == 1
    assert len(env.control.applied) == 1
    assert store.installation(again.installation_id).id == again.installation_id


def test_denied_allow_lands_in_a_retryable_error(env):
    state = drive_to_allow("fake-authorize")
    page = env.client.get("/webapp/chat-install/callback", params={"state": nonce_of(state.next_action.link), "error": "access_denied"})
    assert page.status_code == 200 and "access_denied" not in page.text
    failed = state_of(call("chat.install.status", provider_id="fake-authorize"))
    assert failed.error.code is wire.SetupErrorCode.allow_denied and failed.error.fix is wire.FixAction.restart_allow
    assert env.control.applied == []
    retried = state_of(call("chat.install.advance", provider_id="fake-authorize", event="retry", expected_revision=failed.revision))
    assert retried.step is wire.SetupStep.needs_allow and retried.next_action.link
    assert nonce_of(retried.next_action.link) != nonce_of(state.next_action.link)
    assert allow(env, retried).status_code == 200
    assert state_of(call("chat.install.status", provider_id="fake-authorize")).step is wire.SetupStep.ready


def test_provider_failure_becomes_install_failed_with_no_provider_text(env, caplog):
    caplog.set_level(logging.DEBUG)
    provider = env.providers["fake-authorize"]

    def boom(state, code):
        raise RuntimeError(f"slack said invalid_auth for {FAKE_TOKEN}")

    provider.complete_install = boom
    state = drive_to_allow("fake-authorize")
    assert allow(env, state).status_code == 200
    failed = state_of(call("chat.install.status", provider_id="fake-authorize"))
    assert failed.error.code is wire.SetupErrorCode.install_failed
    assert forbidden_in(own_log(caplog) + failed.model_dump_json()) == [] and "invalid_auth" not in caplog.text
    assert env.control.applied == []


def test_installation_without_owner_never_reaches_ready(env):
    provider = env.providers["fake-authorize"]
    provider.authorizing_identity = lambda installation: None
    state = drive_to_allow("fake-authorize")
    allow(env, state)
    failed = state_of(call("chat.install.status", provider_id="fake-authorize"))
    assert failed.step is wire.SetupStep.error and failed.error.code is wire.SetupErrorCode.install_failed
    assert env.control.applied == []


def test_adapter_failure_is_install_failed_and_retry_finishes_without_a_second_install(env, caplog):
    caplog.set_level(logging.DEBUG)
    env.control.fail_apply = True
    state = drive_to_allow("fake-authorize")
    allow(env, state)
    failed = state_of(call("chat.install.status", provider_id="fake-authorize"))
    assert failed.error.code is wire.SetupErrorCode.install_failed and "provider secret text" not in caplog.text
    env.control.fail_apply = False
    done = state_of(call("chat.install.advance", provider_id="fake-authorize", event="retry", expected_revision=failed.revision))
    assert done.step is wire.SetupStep.ready
    assert len(env.providers["fake-authorize"].installs) == 1 and len(env.control.applied) == 1


def test_paste_fallback_adopts_a_token_when_the_redirect_never_arrives(env):
    state = drive_to_allow("fake-credential")
    adopted = state_of(call("chat.install.advance", provider_id="fake-credential", event="allow_granted",
                            expected_revision=state.revision, vault_item_id="vault-bot-token"))
    assert adopted.step is wire.SetupStep.ready
    assert env.control.applied[0][2]["FAKE_ALLOWED_USERS"] == "U_OWNER"


def test_stale_revision_is_a_typed_conflict_and_unmoved(env):
    state = drive_to_allow("fake-authorize")
    response = call("chat.install.advance", provider_id="fake-authorize", event="retry", expected_revision=state.revision - 1)
    assert response["error"]["code"] == 4409 and response["error"]["data"]["reason"] == "stale_revision"
    assert state_of(call("chat.install.status", provider_id="fake-authorize")) == state


def test_events_that_do_not_apply_are_typed_invalid(env):
    state = drive_to_allow("fake-authorize")
    for event in ("installed", "failed", "app_created", "credential_saved", "retry"):
        response = call("chat.install.advance", provider_id="fake-authorize", event=event, expected_revision=state.revision)
        assert response["error"]["data"]["reason"] == "invalid_event", event
    no_item = call("chat.install.advance", provider_id="fake-authorize", event="allow_granted", expected_revision=state.revision)
    assert no_item["error"]["data"]["reason"] == "invalid_event"


def test_begin_without_an_https_public_url_is_a_guided_step(env, monkeypatch):
    for url in (None, "http://pal.example.test"):
        monkeypatch.setattr(chat_install_runtime, "public_url_for", lambda _home, url=url: url)
        response = call("chat.install.begin", provider_id="fake-authorize")
        assert response["error"]["data"]["reason"] == "needs_public_url"
        assert response["error"]["data"]["next_action"] == {"kind": "button", "action_id": "set_public_url", "link": None, "copy_text": None}
        assert response["error"]["data"]["state"]["step"] == "not_started"
    assert ChatInstallStore(env.home).load((BOT, "fake-authorize", "w1")) is None


def test_unknown_provider_and_bot_ticket_are_refused(env):
    assert call("chat.install.status", provider_id="nope")["error"]["data"]["reason"] == "provider_unknown"
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        for method, extra in (("chat.provider.list", {}), ("chat.install.status", {"provider_id": "fake-authorize"}),
                              ("chat.install.begin", {"provider_id": "fake-authorize"}),
                              ("chat.install.revoke", {"provider_id": "fake-authorize"}),
                              ("chat.space.join", {"provider_id": "fake-authorize", "space_id": "s-public"})):
            response = call(method, **extra)
            assert response["error"]["code"] == 4403 and response["error"]["data"]["reason"] == "owner_only", method
    finally:
        _connection_profile_home.reset(token)
    assert ChatInstallStore(env.home).load((BOT, "fake-authorize", "w1")) is None


def test_provider_list_spaces_join_and_bindings(env):
    listed = call("chat.provider.list")
    assert {p["provider_id"] for p in listed["result"]["providers"]} == {"fake-credential", "fake-authorize"}
    assert call("chat.spaces.list", provider_id="fake-authorize")["error"]["data"]["reason"] == "no_installation"
    allow(env, drive_to_allow("fake-authorize"))
    spaces = call("chat.spaces.list", provider_id="fake-authorize")["result"]["spaces"]
    assert {s["id"] for s in spaces} == {"s-public", "s-private"}
    public = call("chat.space.join", provider_id="fake-authorize", space_id="s-public", hello=True)
    assert public["result"]["outcome"] == "joined"
    private = call("chat.space.join", provider_id="fake-authorize", space_id="s-private")
    assert private["result"]["outcome"] == "needs_invite" and private["result"]["next_action"]["copy_text"] == "/invite @pal"
    bindings = {b["space_id"]: b["live"] for b in call("chat.binding.list", provider_id="fake-authorize")["result"]["bindings"]}
    assert bindings == {"s-public": True, "s-private": False}
    row = ChatInstallStore(env.home).binding("fake-authorize-install-default-w1", "s-public")
    assert row.hello_requested is True and row.hello_sent_at is None


def test_revoke_clears_env_bindings_and_keeps_the_app_for_reinstall(env):
    state = drive_to_allow("fake-credential")
    allow(env, state)
    call("chat.space.join", provider_id="fake-credential", space_id="s-public")
    revoked = call("chat.install.revoke", provider_id="fake-credential")
    assert state_of(revoked).step is wire.SetupStep.revoked and revoked["result"]["installation"] is None
    assert env.control.applied[-1] == (BOT, "fake-credential", {}, ["FAKE_ALLOWED_USERS", "FAKE_BOT_TOKEN"])
    assert env.control.reloads == [BOT, BOT]
    assert call("chat.binding.list", provider_id="fake-credential")["result"]["bindings"] == []
    again = state_of(call("chat.install.begin", provider_id="fake-credential"))
    assert again.step is wire.SetupStep.needs_credential and again.app_id == state_of(revoked).app_id
    assert env.providers["fake-credential"].apps_created == [again.app_id]
    reinstall = state_of(call("chat.install.advance", provider_id="fake-credential", event="credential_saved",
                              expected_revision=again.revision, vault_item_id="vault-config"))
    assert reinstall.app_id == again.app_id and env.providers["fake-credential"].apps_created == [again.app_id]


def test_store_state_survives_a_restart_and_events_are_one_per_revision(env):
    state = drive_to_allow("fake-credential")
    allow(env, state)
    reopened = ChatInstallStore(env.home)
    final = reopened.load((BOT, "fake-credential", "w1"))
    assert final.step is wire.SetupStep.ready
    events = reopened.events_after(0)
    assert [s.revision for _, s in events] == list(range(1, final.revision + 1))
    assert [seq for seq, _ in events] == sorted({seq for seq, _ in events})


def test_watcher_emits_each_revision_exactly_once(env, monkeypatch):
    emitted: list[tuple[str, dict]] = []
    monkeypatch.setattr(server, "_broadcast_global_event", lambda event, payload=None, **_: emitted.append((event, payload)))
    monkeypatch.setattr(server, "_chat_install_seq", None)
    server._broadcast_chat_install_changes()
    assert emitted == []
    state = drive_to_allow("fake-authorize")
    allow(env, state)
    server._broadcast_chat_install_changes()
    server._broadcast_chat_install_changes()
    final = ChatInstallStore(env.home).load((BOT, "fake-authorize", "w1"))
    assert [e for e, _ in emitted] == ["chat.install.changed"] * final.revision
    assert [p["state"]["revision"] for _, p in emitted] == list(range(1, final.revision + 1))
    for _, payload in emitted:
        wire.ChatInstallChangedPayload.model_validate(payload)


def test_secrets_stay_out_of_the_database_and_nonces_are_stored_hashed(env):
    state = drive_to_allow("fake-authorize")
    allow(env, state)
    raw = db_bytes(env.home.parent)
    assert FAKE_TOKEN.encode() not in raw and CODE.encode() not in raw
    import sqlite3
    conn = sqlite3.connect(next(env.home.parent.rglob("chat_install.db")))
    assert conn.execute("SELECT COUNT(*) FROM nonces").fetchone()[0] == 0
    store = ChatInstallStore(env.home)
    raw_nonce = store.issue_nonce((BOT, "p", "w"))
    assert raw_nonce.encode() not in db_bytes(env.home.parent)
    assert oct(next(env.home.parent.rglob("chat_install.db")).stat().st_mode & 0o777) == "0o600"


def test_authorize_link_keeps_provider_query_and_replaces_a_state_param(env):
    service = chat_install_runtime.build_service(env.home)
    key = (BOT, "fake-authorize", "w1")
    plain = service._with_nonce("https://x.invalid/allow?scope=a,b&state=provider", key)
    assert plain.startswith("https://x.invalid/allow?scope=a%2Cb&state=") and "provider" not in plain
    assert service._with_nonce("https://x.invalid/allow", key).count("?") == 1
    assert ci.REDIRECT_PATH == "/webapp/chat-install/callback"


def test_callback_is_public_at_the_sign_in_gate():
    from hermes_cli.dashboard_auth.middleware import _path_is_public
    assert _path_is_public(ci.REDIRECT_PATH)
