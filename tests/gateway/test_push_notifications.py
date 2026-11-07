"""Push alerts for a bot that finished or is waiting: sent through the real dispatcher and turn runner, observed at
the APNs HTTP boundary (``httpx.MockTransport``). Failure cases this file pins: attentive client, toggle off,
APNs unconfigured, duplicate event, dead token, transient and persistent APNs errors, cron and interrupted turns,
and one bot's toggle never deciding another bot's alert."""
import asyncio
import logging
import os
import time
from types import SimpleNamespace

import jwt
import pytest

from agent import secret_scope
from gateway import device_registry, push_apns, push_notify
from gateway.session_controls import AuthorityConnection
from hermes_state_keys import CRON_PRINCIPAL_ID
from tests.gateway.devices_harness import (
    APNS_TOKEN, IPHONE, KEY_ID, MAC, TEAM_ID, TOPIC, call, configure_apns, drain_push, install_apns_stub,
    make_authority, new_apns_stub, transport, write_profile_config,
)

REPLY = "Three files changed.\nSecond line stays on the phone's side of the screen."
BUNDLE = "dev.example.hermes"
ENABLED = "bot_mode:\n  notifications: true\n"


@pytest.fixture
def stub(monkeypatch):
    stub = new_apns_stub()
    install_apns_stub(monkeypatch, stub)
    yield stub
    drain_push()


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    title: Atlas\n", encoding="utf-8")
    return tmp_path


async def answer(event):
    return REPLY


def connect(authority, identity=None, **attrs):
    peer = transport()
    for name, value in attrs.items():
        setattr(peer, name, value)
    return AuthorityConnection(authority, peer, {"user_id": "owner"} if identity is None else identity)


async def phone_with_push(authority, *, environment="sandbox", device=IPHONE):
    phone = connect(authority)
    await call(phone, "client.hello", device)
    registered = await call(phone, "push.register", {
        "device_id": device["device_id"], "apns_token": APNS_TOKEN, "environment": environment, "bundle_id": BUNDLE}, rid=2)
    assert registered["result"]["registered"] is True, registered
    await call(phone, "session.resume", {"session_id": "s"}, rid=3)
    return phone


async def finish_turn(authority, connection, submission_id="turn-1"):
    reply = await call(connection, "prompt.submit", {"session_id": "s", "submission_id": submission_id, "text": "go"}, rid=9)
    assert reply["result"]["status"] == "queued", reply
    await authority.sessions["s"].task
    await asyncio.to_thread(drain_push)


@pytest.mark.asyncio
async def test_a_finished_turn_with_nobody_attentive_sends_exactly_one_alert(root, stub, caplog):
    write_profile_config(root)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    toggled = await call(phone, "config.set", {"key": "bot_mode.notifications", "value": True}, rid=4)
    assert toggled["result"]["value"] is True
    await call(phone, "client.attention", {"state": "background"}, rid=5)

    with caplog.at_level(logging.DEBUG):
        await finish_turn(authority, phone)

    assert len(stub.requests) == 1
    request = stub.requests[0]
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{APNS_TOKEN}"
    assert request.method == "POST"
    assert request.headers["apns-topic"] == TOPIC
    assert request.headers["apns-push-type"] == "alert"
    assert request.headers["apns-priority"] == "10"
    assert int(request.headers["apns-expiration"]) > time.time()
    scheme, bearer = request.headers["authorization"].split(" ", 1)
    assert scheme == "bearer"
    assert jwt.get_unverified_header(bearer) == {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    claims = jwt.decode(bearer, stub.public_pem, algorithms=["ES256"])
    assert claims["iss"] == TEAM_ID and abs(claims["iat"] - time.time()) < 60
    assert stub.payloads() == [{
        "aps": {"alert": {"title": "Atlas", "body": "Three files changed."}, "sound": "default",
                "thread-id": "default"},
        "profile": "default", "session_id": "s"}]
    assert APNS_TOKEN not in caplog.text and "Three files changed" not in caplog.text
    await phone.close()


@pytest.mark.asyncio
async def test_production_tokens_go_to_the_production_host_and_the_key_may_be_inline(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub, inline=True)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority, environment="production")
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone)
    assert [str(request.url.host) for request in stub.requests] == ["api.push.apple.com"]
    await phone.close()


@pytest.mark.asyncio
async def test_a_foreground_client_anywhere_suppresses_the_alert_until_it_looks_away(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    desktop = connect(authority)
    await call(desktop, "client.hello", MAC, rid=2)
    await call(phone, "client.attention", {"state": "background"}, rid=5)

    await finish_turn(authority, phone, "turn-1")
    assert stub.requests == []

    await call(desktop, "client.attention", {"state": "background"}, rid=3)
    await finish_turn(authority, phone, "turn-2")
    assert len(stub.requests) == 1
    await phone.close()
    await desktop.close()


@pytest.mark.asyncio
async def test_the_phone_in_the_foreground_does_not_alert_itself(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "foreground"}, rid=5)
    await finish_turn(authority, phone)
    assert stub.requests == []
    await phone.close()


@pytest.mark.asyncio
async def test_a_bot_with_notifications_off_never_alerts(root, stub):
    write_profile_config(root)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone, "turn-1")
    assert stub.requests == []

    await call(phone, "config.set", {"key": "bot_mode.notifications", "value": "on"}, rid=6)
    await finish_turn(authority, phone, "turn-2")
    assert len(stub.requests) == 1
    await call(phone, "config.set", {"key": "bot_mode.notifications", "value": "off"}, rid=7)
    await finish_turn(authority, phone, "turn-3")
    assert len(stub.requests) == 1
    await phone.close()


@pytest.mark.asyncio
async def test_without_apns_credentials_nothing_is_sent_and_the_reason_is_logged_once(root, stub, caplog, monkeypatch):
    write_profile_config(root, ENABLED)
    monkeypatch.setattr(push_notify, "_noted_unconfigured", False)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    with caplog.at_level(logging.INFO, logger="gateway.push_notify"):
        await finish_turn(authority, phone, "turn-1")
        await finish_turn(authority, phone, "turn-2")
    assert stub.requests == []
    notes = [record.getMessage() for record in caplog.records if record.name == "gateway.push_notify"]
    assert len(notes) == 1 and "not sent" in notes[0]
    assert device_registry.push_targets(root)[0].token == APNS_TOKEN
    await phone.close()


@pytest.mark.asyncio
async def test_a_gone_token_is_forgotten_after_apns_answers_410(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    stub.responses = [(410, {"reason": "Unregistered"})]
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone)
    assert len(stub.requests) == 1
    assert device_registry.push_targets(root) == []
    row = (await call(phone, "devices.list", {}, rid=6))["result"]["devices"][0]
    assert row["push_enabled"] is False
    await phone.close()


@pytest.mark.asyncio
async def test_transient_apns_errors_are_retried_with_backoff_and_the_token_survives(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    stub.responses = [(503, {"reason": "ServiceUnavailable"}), (429, {"reason": "TooManyRequests"}), (200, {})]
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone)
    assert len(stub.requests) == 3 and len(stub.sleeps) == 2
    assert all(0 < pause <= 3.0 for pause in stub.sleeps)
    assert device_registry.push_targets(root)[0].token == APNS_TOKEN
    await phone.close()


@pytest.mark.asyncio
async def test_a_persistent_apns_outage_gives_up_without_leaking_the_token_or_reply(root, stub, caplog):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    stub.responses = [(500, {"reason": "InternalServerError"})]
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    with caplog.at_level(logging.DEBUG):
        await finish_turn(authority, phone)
    assert len(stub.requests) == push_apns.MAX_ATTEMPTS
    assert device_registry.push_targets(root)[0].token == APNS_TOKEN
    assert APNS_TOKEN not in caplog.text and "Three files changed" not in caplog.text
    await phone.close()


@pytest.mark.asyncio
async def test_an_expired_provider_token_is_renewed_once(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    stub.responses = [(403, {"reason": "ExpiredProviderToken"}), (200, {})]
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    await finish_turn(authority, phone)
    assert len(stub.requests) == 2 and stub.sleeps == []
    await phone.close()


@pytest.mark.asyncio
async def test_a_client_that_cannot_be_built_pauses_push_without_spending_the_turns_alert(root, stub, monkeypatch):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    working = push_apns.build_client
    attempts = []

    def failing(config):
        attempts.append(config)
        raise RuntimeError("h2 is not installed")
    monkeypatch.setattr(push_apns, "build_client", failing)
    complete = {"status": "complete", "text": "ok"}
    push_notify.turn_finished(authority, "s", row_for("a-1"), complete)
    push_notify.turn_finished(authority, "s", row_for("a-2"), complete)
    await asyncio.to_thread(drain_push)
    assert len(attempts) == 1 and stub.requests == []

    monkeypatch.setattr(push_apns, "build_client", working)
    monkeypatch.setattr(push_apns, "_retry_after", 0.0)
    push_notify.turn_finished(authority, "s", row_for("a-1"), complete)
    await asyncio.to_thread(drain_push)
    assert len(stub.requests) == 1
    await phone.close()


def row_for(admission_id="a-1", principal="owner"):
    return {"admission_id": admission_id, "principal_id": principal}


async def attached_phone(authority):
    phone = await phone_with_push(authority)
    await call(phone, "client.attention", {"state": "background"}, rid=5)
    return phone


@pytest.mark.asyncio
async def test_one_turn_alerts_once_however_often_its_completion_is_published(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await attached_phone(authority)
    complete = {"status": "complete", "text": REPLY}
    for _ in range(3):
        push_notify.turn_finished(authority, "s", row_for(), complete)
    push_notify.turn_finished(authority, "s", row_for("a-2"), complete)
    await asyncio.to_thread(drain_push)
    assert len(stub.requests) == 2
    await phone.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("row,complete,expected", [
    (row_for(principal=CRON_PRINCIPAL_ID), {"status": "complete", "text": "x"}, None),
    (row_for(), {"status": "interrupted", "text": "x"}, None),
    (row_for(), {"status": "complete", "text": ""}, "Finished"),
    (row_for(), {"status": "complete", "text": "\n\n  **Done**   with   it \n more"}, "**Done** with it"),
    (row_for(), {"status": "complete", "text": "w" * 400}, "w" * (push_notify.BODY_LIMIT - 1) + "…"),
    (row_for(), {"status": "error", "text": "traceback"}, "Stopped with a problem"),
])
async def test_what_a_finished_turn_says(root, stub, row, complete, expected):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await attached_phone(authority)
    push_notify.turn_finished(authority, "s", row, complete)
    await asyncio.to_thread(drain_push)
    bodies = [payload["aps"]["alert"]["body"] for payload in stub.payloads()]
    assert bodies == ([] if expected is None else [expected])
    await phone.close()


@pytest.mark.asyncio
async def test_a_bot_waiting_on_approval_or_a_question_alerts_without_leaking_the_command(root, stub, monkeypatch):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    phone = await attached_phone(authority)
    monkeypatch.setattr(authority, "check_approval_generation", lambda *args: None)
    authority.register_approval("s", 1, SimpleNamespace(), {"request_id": "ask-1", "command": "rm -rf /secret",
                                                              "description": "delete it"})
    authority.register_approval("s", 1, SimpleNamespace(), {"request_id": "ask-1", "command": "rm -rf /secret",
                                                              "description": "delete it"})
    authority.register_clarify("s", 1, SimpleNamespace(clarify_id="q-1", question="Which branch?", choices=["a", "b"],
                                                       multi_select=False))
    await asyncio.to_thread(drain_push)
    assert [payload["aps"]["alert"] for payload in stub.payloads()] == [
        {"title": "Atlas", "body": "is waiting for you"}, {"title": "Atlas", "body": "is waiting for you"}]
    assert b"secret" not in b"".join(request.content for request in stub.requests)
    assert {payload["session_id"] for payload in stub.payloads()} == {"s"}
    await phone.close()


@pytest.mark.asyncio
async def test_every_registered_phone_is_alerted_on_its_own_environment(root, stub):
    write_profile_config(root, ENABLED)
    configure_apns(root, stub)
    authority = await make_authority(root, answer=answer)
    first = await attached_phone(authority)
    second = connect(authority)
    other = {**IPHONE, "device_id": "ipad-0002", "label": "iPad"}
    await call(second, "client.hello", other)
    await call(second, "push.register", {"device_id": "ipad-0002", "apns_token": "cd" * 32, "environment": "production",
                                         "bundle_id": BUNDLE})
    await call(second, "client.attention", {"state": "background"}, rid=3)
    push_notify.turn_finished(authority, "s", row_for(), {"status": "complete", "text": "ok"})
    await asyncio.to_thread(drain_push)
    assert sorted((request.url.host, request.url.path.rsplit("/", 1)[1]) for request in stub.requests) == [
        ("api.push.apple.com", "cd" * 32), ("api.sandbox.push.apple.com", APNS_TOKEN)]
    await first.close()
    await second.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("multiplexed", [False, True])
async def test_one_bots_toggle_never_decides_another_bots_alert(tmp_path, monkeypatch, stub, multiplexed):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.setattr(secret_scope, "_MULTIPLEX_ACTIVE", multiplexed)
    write_profile_config(tmp_path)
    configure_apns(tmp_path, stub)
    alpha_home, beta_home = tmp_path / "profiles" / "alpha", tmp_path / "profiles" / "beta"
    write_profile_config(alpha_home, ENABLED)
    write_profile_config(beta_home, "bot_mode:\n  notifications: false\n")
    (alpha_home / "profile.yaml").write_text("ui_meta:\n  hermes-bots:\n    title: Alpha Bot\n", encoding="utf-8")
    (beta_home / ".env").write_text("OPENAI_API_KEY=beta-only\n", encoding="utf-8")
    runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=multiplexed), session_authorities=[])
    alpha = await make_authority(alpha_home, runner, register=False)
    beta = await make_authority(beta_home, runner, register=False)
    runner.session_authorities.extend([alpha, beta])
    phone = connect(alpha)
    await call(phone, "client.hello", IPHONE)
    await call(phone, "push.register", {"device_id": IPHONE["device_id"], "apns_token": APNS_TOKEN,
                                        "environment": "sandbox", "bundle_id": BUNDLE}, rid=2)
    await call(phone, "client.attention", {"state": "background"}, rid=3)
    environment_before = dict(os.environ)

    push_notify.turn_finished(beta, "s", row_for("beta-1"), {"status": "complete", "text": "beta done"})
    push_notify.turn_finished(alpha, "s", row_for("alpha-1"), {"status": "complete", "text": "alpha done"})
    push_notify.waiting_on_user(beta, "s", "beta-ask", push_notify.Kind.APPROVAL)
    await asyncio.to_thread(drain_push)

    assert [(payload["aps"]["alert"]["title"], payload["profile"]) for payload in stub.payloads()] == [
        ("Alpha Bot", "alpha")]
    assert dict(os.environ) == environment_before
    await phone.close()


@pytest.mark.asyncio
async def test_each_bot_keeps_its_own_notification_toggle(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    write_profile_config(tmp_path)
    alpha_home, beta_home = tmp_path / "profiles" / "alpha", tmp_path / "profiles" / "beta"
    write_profile_config(alpha_home)
    write_profile_config(beta_home, "bot_mode:\n  notifications: true\n")
    runner = SimpleNamespace(config=SimpleNamespace(multiplex_profiles=False), session_authorities=[])
    alpha = await make_authority(alpha_home, runner, register=False)
    beta = await make_authority(beta_home, runner, register=False)
    runner.session_authorities.extend([alpha, beta])
    on_alpha = connect(alpha)
    on_beta = connect(beta)

    async def toggle(connection, rid):
        return (await call(connection, "config.get", {"key": "bot_mode.notifications"}, rid=rid))["result"]["value"]

    assert (await toggle(on_alpha, 1), await toggle(on_beta, 2)) == ("off", "on")
    set_alpha = await call(on_alpha, "config.set", {"key": "bot_mode.notifications", "value": True}, rid=3)
    assert set_alpha["result"] == {"key": "bot_mode.notifications", "value": True}
    assert (await toggle(on_alpha, 4), await toggle(on_beta, 5)) == ("on", "on")
    await call(on_beta, "config.set", {"key": "bot_mode.notifications", "value": "off"}, rid=6)
    assert (await toggle(on_alpha, 7), await toggle(on_beta, 8)) == ("on", "off")
    assert "notifications: true" in (alpha_home / "config.yaml").read_text(encoding="utf-8")
    assert "notifications: false" in (beta_home / "config.yaml").read_text(encoding="utf-8")

    invalid = await call(on_alpha, "config.set", {"key": "bot_mode.notifications", "value": "maybe"}, rid=9)
    assert invalid["error"]["message"] == "invalid_params"
    assert await toggle(on_alpha, 10) == "on"
    await on_alpha.close()
    await on_beta.close()
