from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest
from pydantic import BaseModel

from tests.tui_gateway.contracts.chat_provider_fakes import (
    FAKE_TOKEN,
    FIXED_NOW,
    AuthorizeOnlyFake,
    CredentialAppFake,
    MemorySetupStore,
)
from tui_gateway import chat_install as ci
from tui_gateway.contracts import chat_provider as wire

REPO = Path(__file__).resolve().parents[3]
FIXTURE = REPO / "apps/ios/Fixtures/chat-provider/wire.json"
SWIFT = REPO / "apps/ios/Packages/PalKit/Sources/PalProtocol/ChatProviderWire.swift"
SCRIPT = (
    wire.SetupEventKind.begin, wire.SetupEventKind.credential_saved, wire.SetupEventKind.app_created,
    wire.SetupEventKind.manual_step_done, wire.SetupEventKind.allow_granted, wire.SetupEventKind.installed,
)
log = logging.getLogger("chat_install_test")


class Gateway:
    def __init__(self, provider: ci.ChatProvider, store: MemorySetupStore):
        self.provider, self.store = provider, store
        self.vault = {"vault-config": FAKE_TOKEN}
        self.config_item = "vault-config"
        self.caps = provider.capabilities()

    def state(self, bot: str, workspace: str) -> wire.SetupState:
        return self.store.load((bot, self.provider.provider_id, workspace)) or ci.initial_state(
            bot, self.provider.provider_id, workspace, FIXED_NOW)

    def send(self, bot: str, workspace: str, kind: wire.SetupEventKind, **extra) -> wire.SetupState:
        state = self.state(bot, workspace)
        if kind is wire.SetupEventKind.app_created and ci.needs_app_creation(state):
            created = self.provider.begin_install(state, self.config_item)
            extra |= {"app_id": created.app_id, "authorize_link": created.authorize_link}
        if kind is wire.SetupEventKind.manual_step_done and state.step is wire.SetupStep.needs_manual_step:
            extra.setdefault("manual_step", wire.ProviderCapability(state.next_action.action_id))
        if kind is wire.SetupEventKind.allow_granted and state.step is wire.SetupStep.needs_allow:
            extra["installation_id"] = self.provider.complete_install(state, "code-from-redirect").id
        new = ci.advance(state, ci.SetupEvent(kind=kind, **extra), self.caps, FIXED_NOW)
        if new is not state:
            self.store.save(new, state.revision)
        log.info("setup %s", new.model_dump_json())
        return new

    def run(self, bot: str = "pal", workspace: str = "w1") -> wire.SetupState:
        for kind in SCRIPT:
            self.send(bot, workspace, kind)
        return self.state(bot, workspace)


@pytest.fixture(params=[CredentialAppFake, AuthorizeOnlyFake], ids=["credential", "authorize"])
def gateway(request):
    return Gateway(request.param(), MemorySetupStore())


def test_same_script_reaches_ready_for_both_providers():
    seen = {}
    for fake in (CredentialAppFake(), AuthorizeOnlyFake()):
        gw = Gateway(fake, MemorySetupStore())
        steps = []
        for kind in SCRIPT:
            steps.append(gw.send("pal", "w1", kind).step)
        assert steps[-1] is wire.SetupStep.ready
        seen[fake.provider_id] = steps
    assert wire.SetupStep.needs_credential in seen["fake-credential"]
    assert wire.SetupStep.needs_manual_step in seen["fake-credential"]
    assert wire.SetupStep.needs_credential not in seen["fake-authorize"]
    assert wire.SetupStep.creating_app not in seen["fake-authorize"]


def test_replay_restart_and_second_client_never_duplicate(gateway):
    gateway.send("pal", "w1", wire.SetupEventKind.begin)
    gateway.send("pal", "w1", wire.SetupEventKind.credential_saved)
    gateway.send("pal", "w1", wire.SetupEventKind.app_created)
    gateway.send("pal", "w1", wire.SetupEventKind.app_created)
    restarted = Gateway(gateway.provider, gateway.store)
    restarted.send("pal", "w1", wire.SetupEventKind.begin)
    restarted.send("pal", "w1", wire.SetupEventKind.app_created)
    phone = Gateway(restarted.provider, gateway.store)
    final = phone.run()
    final_again = phone.run()
    assert final.step is wire.SetupStep.ready and final_again == final
    assert len(gateway.provider.apps_created) <= 1
    assert len(restarted.provider.installs) == 1
    assert final.installation_id in restarted.provider.installs


def test_revoke_forgets_the_app_so_reinstall_creates_a_fresh_one():
    gw = Gateway(CredentialAppFake(), MemorySetupStore())
    first = gw.run()
    revoked = gw.send("pal", "w1", wire.SetupEventKind.revoked)
    assert revoked.step is wire.SetupStep.revoked
    assert revoked.app_id is None and revoked.installation_id is None and revoked.manual_steps_done == []
    second = gw.run()
    assert second.step is wire.SetupStep.ready and second.app_id != first.app_id
    assert gw.provider.apps_created == [first.app_id, second.app_id]


def test_paste_fallback_offered_only_while_waiting_for_allow(gateway):
    for kind in SCRIPT:
        state = gateway.send("pal", "w1", kind)
        if state.step is wire.SetupStep.needs_allow:
            assert state.fallback_action == wire.NextAction(kind=wire.NextActionKind.paste_credential, action_id="bot_token")
        else:
            assert state.fallback_action is None


def test_stale_writer_is_rejected():
    gw = Gateway(AuthorizeOnlyFake(), MemorySetupStore())
    old = gw.state("pal", "w1")
    gw.send("pal", "w1", wire.SetupEventKind.begin)
    with pytest.raises(ci.StaleRevision):
        gw.store.save(ci.advance(old, ci.SetupEvent(kind=wire.SetupEventKind.begin), gw.caps, FIXED_NOW), old.revision)


def test_every_error_has_a_fix_and_retry_recovers(gateway):
    assert set(ci.FIX_FOR_ERROR) == set(wire.SetupErrorCode)
    gateway.send("pal", "w1", wire.SetupEventKind.begin)
    for code in wire.SetupErrorCode:
        failed = gateway.send("pal", "w1", wire.SetupEventKind.failed, error=code)
        assert failed.error.fix is ci.FIX_FOR_ERROR[code]
        assert failed.next_action.action_id == failed.error.fix.value
        assert "invalid_auth" not in failed.model_dump_json()
        gateway.send("pal", "w1", wire.SetupEventKind.retry)
    assert gateway.run().step is wire.SetupStep.ready


_SECRET_WORDS = ("token", "secret", "password", "credential_value", "api_key")


def _walk(model: type[BaseModel], seen: set) -> list[str]:
    if model in seen:
        return []
    seen.add(model)
    names = []
    for name, field in model.model_fields.items():
        names.append(f"{model.__name__}.{name}")
        for arg in _types(field.annotation):
            if isinstance(arg, type) and issubclass(arg, BaseModel):
                names += _walk(arg, seen)
    return names


def _types(annotation):
    args = getattr(annotation, "__args__", None)
    if not args:
        return [annotation]
    return [t for a in args for t in _types(a)]


def test_no_wire_field_can_carry_a_secret():
    fields = [f for m in wire.WIRE_MODELS for f in _walk(m, set())]
    assert fields
    bad = [f for f in fields if any(w in f.split(".")[1] for w in _SECRET_WORDS)]
    assert not bad, bad


def test_fake_token_never_reaches_payloads_or_logs(gateway, caplog):
    caplog.set_level(logging.INFO, logger="chat_install_test")
    gateway.run()
    payloads = [m.model_dump_json() for m in _fixture_models(gateway)]
    assert all(FAKE_TOKEN not in p for p in payloads)
    assert caplog.records and all(FAKE_TOKEN not in r.getMessage() for r in caplog.records)


def test_abstract_provider_raises_typed_not_implemented():
    class Bare(ci.ChatProvider):
        provider_id = "bare"

    bare, state = Bare(), ci.initial_state("pal", "bare", "w1", FIXED_NOW)
    install = CredentialAppFake().complete_install(state, "x")
    calls = {
        "capabilities": lambda: bare.capabilities(),
        "begin_install": lambda: bare.begin_install(state, None),
        "complete_install": lambda: bare.complete_install(state, "x"),
        "identity_projection": lambda: bare.identity_projection(ci.BotIdentitySource("pal", "Pal", None)),
        "list_spaces": lambda: bare.list_spaces(install),
        "join_space": lambda: bare.join_space(install, "s"),
        "revoke": lambda: bare.revoke(install),
        "adapter_env": lambda: bare.adapter_env(install),
        "adopt_token": lambda: bare.adopt_token(state, "vault-item"),
        "update_identity": lambda: bare.update_identity(install),
        "accept_app_level_credential": lambda: bare.accept_app_level_credential(state, "vault-item"),
        "store_icon": lambda: bare.store_icon("pal", b""),
        "open_owner_dm": lambda: bare.open_owner_dm(install, "U1"),
        "list_people": lambda: bare.list_people(install, "", ""),
        "people_names": lambda: bare.people_names(install, []),
        "leave_space": lambda: bare.leave_space(install, "s"),
        "reconnect_adapter": lambda: bare.reconnect_adapter(install),
    }
    assert set(calls) == {n for n in vars(ci.ChatProvider) if not n.startswith("_")} - {"provider_id", "allowed_users_env", "authorizing_identity",
                                                                                  "accept_config_credential", "has_config_credential", "parse_owner_identity",
                                                                                  "new_install_config", "is_direct_space", "manual_step_action",
                                                                                  "satisfied_manual_steps", "per_bot_adapter", "needs_public_url", "install_in_place", "apply_owner", "adapter_status"}
    for operation, call in calls.items():
        with pytest.raises(ci.ProviderNotImplemented) as info:
            call()
        assert (info.value.provider_id, info.value.operation) == ("bare", operation)
    assert bare.authorizing_identity(install) is None
    assert bare.adapter_status(install) is None


def test_slack_policy_records_known_limits_and_unverified_defaults():
    policy = ci.SLACK_CAPABILITIES.identity_policy
    assert (policy.app_name_max, policy.display_name_max, policy.username_max) == (35, 80, 21)
    modes = {e.capability: e.mode for e in ci.SLACK_CAPABILITIES.capabilities}
    for cap in (wire.ProviderCapability.set_icon, wire.ProviderCapability.app_level_credential,
                wire.ProviderCapability.gateway_redirect, wire.ProviderCapability.unattended_refresh):
        assert modes[cap] is wire.CapabilityMode.guided


def _fixture_models(gw: Gateway) -> list[BaseModel]:
    state = gw.state("pal", "w1")
    install = gw.provider.installs[state.installation_id]
    join = gw.provider.join_space(install, "s-private")
    return [
        wire.ChatProviderListResult(providers=[gw.caps]),
        wire.ChatInstallStatusResult(state=state, installation=install),
        wire.ChatSpacesListResult(spaces=gw.provider.list_spaces(install)),
        wire.ChatSpaceJoinResult(outcome=join.outcome, next_action=join.next_action),
        wire.ChatBindingListResult(bindings=[wire.Binding(bot="pal", space_id="s-public", installation_id=install.id, live=True)]),
        wire.ChatInstallChangedPayload(state=state),
        wire.ChatIdentityUpdateResult(outcome=wire.IdentityUpdateOutcome.needs_manual_avatar,
                                      identity=gw.provider.identity_projection(ci.BotIdentitySource("pal", "Pal", None)),
                                      next_action=wire.NextAction(kind=wire.NextActionKind.button, action_id="set_icon")),
        gw.provider.identity_projection(ci.BotIdentitySource("pal", "Pal the Very Helpful Assistant Bot!", "avatars/pal.png")),
    ]


def render_fixture() -> str:
    out = {}
    for fake in (CredentialAppFake(), AuthorizeOnlyFake()):
        gw = Gateway(fake, MemorySetupStore())
        gw.run()
        out[fake.provider_id] = {type(m).__name__: m.model_dump(mode="json") for m in _fixture_models(gw)}
    return json.dumps(out, indent=2, sort_keys=True) + "\n"


def test_wire_round_trips_and_fixture_is_current():
    text = render_fixture()
    data = json.loads(text)
    for provider in data.values():
        for name, payload in provider.items():
            model = getattr(wire, name)
            assert model.model_validate(payload).model_dump(mode="json") == payload
    assert FIXTURE.read_text(encoding="utf-8") == text, "regenerate: python -m tests.tui_gateway.contracts.test_chat_provider_contract"


def test_swift_mirror_names_every_enum_value():
    swift = SWIFT.read_text(encoding="utf-8")
    enums = [v for v in vars(wire).values() if isinstance(v, type) and issubclass(v, wire.WireEnum) and v is not wire.WireEnum]
    missing = {f"{e.__name__}.{item.value}" for e in enums for item in e if f'"{item.value}"' not in swift}
    assert not missing, missing


if __name__ == "__main__":
    FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    FIXTURE.write_text(render_fixture(), encoding="utf-8")
