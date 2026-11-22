"""Each served profile admits members by its own ``platforms.slack.audience``, never by a neighbour's.

Two real profiles under a temp ``HERMES_HOME``: the primary lists one person, the secondary bot lists
another. The runner's admission callback is the one the Slack adapter is wired with; it fires on the
adapter's event loop, outside any turn, so the policy it reads must come from the owning profile's
scope, not from the launch profile's ``os.environ`` or module globals.
"""

import os
from pathlib import Path

import pytest

from gateway.audience import Admission, AdmissionKind, SenderFacts
from gateway.config import Platform

_AUTH_ENV = ("SLACK_ALLOWED_USERS", "SLACK_ALLOW_ALL_USERS", "SLACK_ALLOW_BOTS", "GATEWAY_ALLOWED_USERS",
             "GATEWAY_ALLOW_ALL_USERS")
PRIMARY_PERSON, SECONDARY_PERSON = "U0PRIMARY", "U0SECOND"


def _facts(user_id: str) -> SenderFacts:
    return SenderFacts(user_id=user_id, scope_id="T0STANDIN", same_scope=True, is_bot=False,
                       is_restricted=False, display_name=user_id)


def _config(person: str) -> str:
    return f"platforms:\n  slack:\n    audience:\n      policy: listed\n      members: ['{person}']\n"


@pytest.fixture
def two_profiles(monkeypatch):
    home = Path(os.environ["HERMES_HOME"])
    secondary = home / "profiles" / "bot2"
    secondary.mkdir(parents=True)
    (home / "config.yaml").write_text(
        "gateway:\n  multiplex_profiles: true\n" + _config(PRIMARY_PERSON), encoding="utf-8")
    (secondary / "config.yaml").write_text(_config(SECONDARY_PERSON), encoding="utf-8")
    for key in _AUTH_ENV:
        monkeypatch.setenv(key, "")
        monkeypatch.delenv(key)
    from agent import secret_scope
    previous = secret_scope.is_multiplex_active()
    secret_scope.set_multiplex_active(True)
    yield home, secondary
    secret_scope.set_multiplex_active(previous)


def _admission_check(profile):
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


def _verdict(check, user_id: str) -> Admission:
    return check(user_id, "group", "C0000CHN", is_bot=False, thread_id=None, facts=_facts(user_id))


@pytest.mark.parametrize("profile, person, other", [
    ("default", PRIMARY_PERSON, SECONDARY_PERSON),
    ("bot2", SECONDARY_PERSON, PRIMARY_PERSON),
])
def test_a_profile_admits_its_own_listed_member_and_refuses_the_neighbours(two_profiles, profile, person, other):
    check = _admission_check(profile)
    assert _verdict(check, person).kind is AdmissionKind.MEMBER
    assert _verdict(check, other).kind is AdmissionKind.REFUSED


def test_the_same_person_is_a_member_of_one_bot_and_a_stranger_to_the_other(two_profiles):
    primary, secondary = _admission_check("default"), _admission_check("bot2")
    assert _verdict(primary, PRIMARY_PERSON).kind is AdmissionKind.MEMBER
    assert _verdict(secondary, PRIMARY_PERSON).kind is AdmissionKind.REFUSED
    assert _verdict(primary, PRIMARY_PERSON).kind is AdmissionKind.MEMBER
