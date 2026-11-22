"""Each served profile has its own desk: a reply is routed by the asking profile's open questions only.

Two real profiles under a temp ``HERMES_HOME``, each with its own desk database. The admission callback fires on
the adapter's event loop outside any turn, so the open questions it consults must come from the owning
profile's home, never from the launch profile's.
"""

import os
from pathlib import Path

import pytest

from gateway.audience import AdmissionKind, SenderFacts
from gateway.config import Platform
from gateway.desk import AskPayload, DeskItem, DeskStore, ItemKind, ItemState, Origin, Recipient

_AUTH_ENV = ("SLACK_ALLOWED_USERS", "SLACK_ALLOW_ALL_USERS", "SLACK_ALLOW_BOTS", "GATEWAY_ALLOWED_USERS",
             "GATEWAY_ALLOW_ALL_USERS")
PERSON = "U0PERSON"


def _facts() -> SenderFacts:
    return SenderFacts(user_id=PERSON, scope_id="T0STANDIN", same_scope=True, is_bot=False, is_restricted=False,
                       display_name=PERSON)


def _ask(profile: str, conversation: str, anchor: str) -> DeskItem:
    target = Recipient("slack", "T0STANDIN", PERSON, conversation, None, True)
    return DeskItem(id=f"dk_{profile}", kind=ItemKind.ASK, state=ItemState.OPEN, revision=0,
                    origin=Origin(f"agent:{profile}:slack:dm:T0STANDIN:D0OWNER", profile), owner_id="U0OWNER",
                    platform="slack", scope_id="T0STANDIN", payload=AskPayload("when?", target, anchor), outcome=None,
                    created_at=1_000.0, expires_at=9_999_999_999.0, settled_at=None, delivered_at=None)


@pytest.fixture
def two_profiles(monkeypatch):
    home = Path(os.environ["HERMES_HOME"])
    secondary = home / "profiles" / "bot2"
    secondary.mkdir(parents=True)
    (home / "config.yaml").write_text("gateway:\n  multiplex_profiles: true\n", encoding="utf-8")
    (secondary / "config.yaml").write_text("", encoding="utf-8")
    for key in _AUTH_ENV:
        monkeypatch.setenv(key, "")
        monkeypatch.delenv(key)
    from agent import secret_scope
    previous = secret_scope.is_multiplex_active()
    secret_scope.set_multiplex_active(True)
    yield home, secondary
    secret_scope.set_multiplex_active(previous)


def _check(profile):
    from gateway.config import GatewayConfig, load_gateway_config
    from gateway.pairing import PairingStore
    from gateway.run import GatewayRunner

    runner = object.__new__(GatewayRunner)
    runner.pairing_store = PairingStore(profile="default")
    runner.pairing_stores = {"default": runner.pairing_store, "bot2": PairingStore(profile="bot2")}
    runner._primary_profile_name = "default"
    runner.adapters, runner._profile_adapters = {}, {}
    runner.config = load_gateway_config() if profile == "default" else GatewayConfig(multiplex_profiles=True)
    return runner._make_adapter_admission_check(Platform.SLACK, profile_name=None if profile == "default" else profile)


def _verdict(check, conversation: str):
    return check(PERSON, "dm", conversation, is_bot=False, thread_id=None, facts=_facts(), message_id="9.9")


def test_a_reply_is_admitted_by_the_profile_that_asked_and_refused_by_its_neighbour(two_profiles):
    home, _secondary = two_profiles
    DeskStore(home).reserve(_ask("default", "D0PERSON", "7.1"))
    primary, other = _check("default"), _check("bot2")
    assert _verdict(primary, "D0PERSON").kind is AdmissionKind.REPLY
    assert _verdict(other, "D0PERSON").kind is AdmissionKind.REFUSED
    assert _verdict(primary, "D0PERSON").kind is AdmissionKind.REPLY


def test_the_secondary_profiles_questions_are_invisible_to_the_primary(two_profiles):
    home, secondary = two_profiles
    DeskStore(secondary).reserve(_ask("bot2", "D0PERSON", "7.2"))
    primary, other = _check("default"), _check("bot2")
    assert _verdict(other, "D0PERSON").kind is AdmissionKind.REPLY
    assert _verdict(primary, "D0PERSON").kind is AdmissionKind.REFUSED
    assert not (home / "desk.db").exists(), "asking the primary must not create its desk"


def test_each_profile_keeps_its_own_desk_file(two_profiles):
    home, secondary = two_profiles
    DeskStore(home).reserve(_ask("default", "D0PERSON", "7.1"))
    DeskStore(secondary).reserve(_ask("bot2", "D0PERSON", "7.2"))
    assert [i.id for i in DeskStore(home).open_asks("slack", 10)] == ["dk_default"]
    assert [i.id for i in DeskStore(secondary).open_asks("slack", 10)] == ["dk_bot2"]
