from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from gateway.chat_discord.shared_adapter import BOT_TOKEN_ENV, CONNECT_WAIT_S, Reading
from gateway.chat_install_service import ChatServiceError
from tests.gateway.chat_discord.discord_kit import BOT, Kit
from tests.gateway.chat_discord.fake_discord import GUILD_ID, OWNER_ID
from tui_gateway.contracts import chat_provider as wire

STEP, STATE, REASON = wire.SetupStep, wire.AdapterState, wire.AdapterFailure


def begin(kit: Kit):
    kit.allow_owner(OWNER_ID)
    service = kit.service()
    return service, service.begin(BOT, "discord", GUILD_ID)[0]


def outcome(state) -> tuple[wire.SetupStep, str | None]:
    return state.step, state.error.reason if state.error else None


def adapter_of(service) -> wire.AdapterStatus | None:
    return service.live_adapter(service.status(BOT, "discord", GUILD_ID)[1])


def test_done_gives_the_shared_adapter_the_pasted_app_token(kit):
    _, state = begin(kit)
    assert state.step is STEP.ready
    assert f"{BOT_TOKEN_ENV}={kit.token}" in (kit.home / ".env").read_text(encoding="utf-8")
    assert kit.config()["platforms"]["discord"]["enabled"] is True


def test_no_gateway_to_reload_asks_for_a_restart(kit):
    kit.runtime.answers = False
    _, state = begin(kit)
    assert outcome(state) == (STEP.error, REASON.restart_needed.value)


def test_an_adapter_that_never_gets_ready_ends_the_wait(kit):
    kit.runtime.after_reload = ("retrying", "discord_connect_timeout")
    _, state = begin(kit)
    assert outcome(state) == (STEP.error, REASON.adapter_offline.value)
    assert CONNECT_WAIT_S <= kit.runtime.seconds < CONNECT_WAIT_S + 1


def test_a_connected_status_older_than_the_reload_does_not_count(kit):
    kit.runtime.stamp = (datetime.now(UTC) - timedelta(minutes=5)).isoformat()
    _, state = begin(kit)
    assert outcome(state) == (STEP.error, REASON.adapter_offline.value)


@pytest.mark.parametrize(("code", "reason"), [
    ("discord_auth_error", REASON.invalid_token),
    ("discord_intents_required", REASON.missing_intent),
    ("adapter_unavailable", REASON.restart_needed),
    ("something the app has no sentence for", REASON.adapter_offline),
])
def test_a_fatal_adapter_ends_in_one_fixed_reason(kit, code, reason):
    kit.runtime.after_reload = ("fatal", code)
    _, state = begin(kit)
    assert outcome(state) == (STEP.error, reason.value)
    assert code not in state.model_dump_json()


def test_retry_finishes_once_the_adapter_comes_online(kit):
    kit.runtime.after_reload = ("fatal", "discord_intents_required")
    service, state = begin(kit)
    kit.runtime.after_reload = ("connected", None)
    state, installation = service.advance(BOT, "discord", GUILD_ID, wire.SetupEventKind.retry, state.revision)
    assert state.step is STEP.ready and installation is not None


@pytest.mark.parametrize(("reading", "expected"), [
    (Reading("not_configured", False, None, None), (STATE.not_started, None)),
    (Reading("connecting", True, None, None), (STATE.connecting, None)),
    (Reading("fatal", True, "discord_auth_error", None), (STATE.failed, REASON.invalid_token)),
    (Reading("gateway_stopped", True, None, None), (STATE.failed, REASON.restart_needed)),
])
def test_a_ready_record_never_reads_as_online_without_a_live_adapter(kit, reading, expected):
    service, _ = begin(kit)
    kit.runtime.reading = reading
    live = adapter_of(service)
    assert service.status(BOT, "discord", GUILD_ID)[0].step is STEP.ready
    assert (live.state, live.reason) == expected


def test_reconnect_rebuilds_the_adapter_and_answers_live_state(kit):
    service, _ = begin(kit)
    kit.runtime.reading = Reading("disabled", False, None, None)
    reloads = kit.runtime.reloads
    _, _, live = service.reconnect(BOT, "discord", GUILD_ID)
    assert (live.state, kit.runtime.reloads) == (STATE.online, reloads + 1)
    assert kit.restarts == []


def test_reconnect_without_a_saved_token_names_the_token(kit):
    service, _ = begin(kit)
    kit.token = None
    assert service.reconnect(BOT, "discord", GUILD_ID)[2].reason is REASON.invalid_token


def test_reconnect_needs_a_ready_install(kit):
    with pytest.raises(ChatServiceError) as refused:
        kit.service().reconnect(BOT, "discord", GUILD_ID)
    assert refused.value.reason is wire.ChatRpcErrorReason.no_installation
