import threading
from dataclasses import replace
from types import SimpleNamespace

import pytest

from gateway.audience import (
    Admission,
    AdmissionKind,
    Audience,
    AudiencePolicy,
    AudiencePolicyKind,
    MemberRate,
    RateVerdict,
    SenderFacts,
    audience_of_key,
    decide_admission,
    posture_for_key,
)
from gateway.config import GatewayConfig, Platform
from gateway.session import SessionSource, build_session_key


def facts(user="U1", *, same_scope=True, restricted=False, bot=False) -> SenderFacts:
    return SenderFacts(user_id=user, scope_id="T1", same_scope=same_scope, is_bot=bot,
                       is_restricted=restricted, display_name="Alice")


def policy(kind="workspace", members=(), include_restricted=False, per_hour=30) -> AudiencePolicy:
    return AudiencePolicy(AudiencePolicyKind(kind), frozenset(members), include_restricted, per_hour)


@pytest.mark.parametrize("raw", [
    None, "workspace", [], 7, {}, {"policy": "everyone"}, {"policy": "listed", "members": "U1"},
    {"policy": "listed", "members": [1]}, {"policy": "workspace", "member_turns_per_hour": 0},
    {"policy": "workspace", "member_turns_per_hour": True}, {"policy": "workspace", "include_restricted": "yes"},
])
def test_absent_or_malformed_policy_is_owner_only(raw):
    parsed = AudiencePolicy.from_config(raw)
    assert parsed.kind is AudiencePolicyKind.OWNER_ONLY
    assert not parsed.admits(facts())


def test_policy_block_parses_every_field():
    parsed = AudiencePolicy.from_config({"policy": "listed", "members": ["U1", "U2"], "include_restricted": True,
                                         "member_turns_per_hour": 5})
    assert parsed == policy("listed", {"U1", "U2"}, True, 5)
    assert AudiencePolicy.from_config({"policy": "workspace"}).member_turns_per_hour == 30


@pytest.mark.parametrize("pol, fact, admitted", [
    (policy("owner_only"), facts(), False),
    (policy("workspace"), None, False),
    (policy("workspace"), facts(), True),
    (policy("workspace"), facts(same_scope=False), False),
    (policy("workspace"), facts(bot=True), False),
    (policy("workspace"), facts(restricted=True), False),
    (policy("workspace", include_restricted=True), facts(restricted=True), True),
    (policy("listed", {"U2"}), facts("U1"), False),
    (policy("listed", {"U1"}), facts("U1"), True),
    (policy("listed", {"U1"}), facts("U1", same_scope=False), False),
    (policy("listed", {"U1"}), facts("U1", restricted=True), False),
])
def test_policy_admits_only_on_positive_proof(pol, fact, admitted):
    assert pol.admits(fact) is admitted


def test_admission_precedence_owner_then_open_ask_then_policy_then_refused():
    pol, fact = policy("workspace"), facts()
    assert decide_admission(True, "ask-1", pol, fact).kind is AdmissionKind.OWNER
    reply = decide_admission(False, "ask-1", pol, fact)
    assert reply.kind is AdmissionKind.REPLY and reply.ask_id == "ask-1"
    member = decide_admission(False, None, pol, fact)
    assert member == Admission(AdmissionKind.MEMBER, fact) and member.audience is Audience.MEMBER
    for refused in (decide_admission(False, None, policy("owner_only"), fact),
                    decide_admission(False, None, pol, None)):
        assert refused.kind is AdmissionKind.REFUSED and refused.audience is Audience.OWNER


def test_member_rate_window_notices_once_then_goes_silent_until_it_rolls():
    now = [0.0]
    rate = MemberRate(clock=lambda: now[0])
    verdicts = [rate.check(2) for _ in range(5)]
    assert verdicts == [RateVerdict.ALLOWED, RateVerdict.ALLOWED, RateVerdict.NOTICE,
                        RateVerdict.SILENT, RateVerdict.SILENT]
    now[0] = 3601.0
    assert rate.check(2) is RateVerdict.ALLOWED
    assert rate.check(2) is RateVerdict.ALLOWED
    assert rate.check(2) is RateVerdict.NOTICE


def test_member_rate_is_safe_under_concurrent_callers():
    rate = MemberRate(clock=lambda: 0.0)
    out, lock = [], threading.Lock()

    def worker():
        verdict = rate.check(10)
        with lock:
            out.append(verdict)

    threads = [threading.Thread(target=worker) for _ in range(40)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert out.count(RateVerdict.ALLOWED) == 10 and out.count(RateVerdict.NOTICE) == 1


def slack_source(audience=Audience.OWNER, **kw) -> SessionSource:
    base = dict(platform=Platform.SLACK, chat_id="C1", chat_type="group", user_id="U1", thread_id="1.2",
                scope_id="T1", audience=audience)
    return SessionSource(**{**base, **kw})


@pytest.mark.parametrize("kw", [{}, {"chat_type": "dm", "chat_id": "D1", "thread_id": None}, {"thread_id": None}])
def test_member_key_extends_the_owner_key_and_never_equals_it(kw):
    owner_key = build_session_key(slack_source(**kw))
    member_key = build_session_key(slack_source(Audience.MEMBER, **kw))
    assert member_key != owner_key and member_key.startswith(owner_key)
    assert audience_of_key(member_key) is Audience.MEMBER and audience_of_key(owner_key) is Audience.OWNER


def test_audience_is_serialized_only_for_members_and_survives_a_round_trip():
    owner, member = slack_source(), slack_source(Audience.MEMBER)
    assert "audience" not in owner.to_dict()
    assert member.to_dict()["audience"] == "member"
    assert SessionSource.from_dict(member.to_dict()).audience is Audience.MEMBER
    assert SessionSource.from_dict(owner.to_dict()).audience is Audience.OWNER


def test_posture_is_the_one_member_posture_per_key_and_none_for_owners():
    owner_key = build_session_key(slack_source())
    member_key = build_session_key(slack_source(Audience.MEMBER))
    assert posture_for_key(owner_key) is None
    posture = posture_for_key(member_key)
    assert posture.toolsets == ("member",)
    assert posture.skip_memory and posture.skip_context_files and posture.skip_background_review
    assert posture_for_key(member_key) == posture
    other = build_session_key(slack_source(Audience.MEMBER, chat_id="C2", user_id="U9"))
    assert posture_for_key(other).ephemeral_prompt == posture.ephemeral_prompt


def runner():
    from gateway.run import GatewayRunner
    instance = object.__new__(GatewayRunner)
    instance.config = GatewayConfig()
    return instance


def entry(source, key):
    return SimpleNamespace(origin=source, session_key=key, transport_profile=None)


def test_restored_source_keeps_a_member_row_whose_origin_matches_its_key():
    source = slack_source(Audience.MEMBER)
    restored = runner()._restored_source(entry(source, build_session_key(source)))
    assert restored is not None and restored.audience is Audience.MEMBER


@pytest.mark.parametrize("origin_audience, key_audience", [
    (Audience.OWNER, Audience.MEMBER), (Audience.MEMBER, Audience.OWNER)])
def test_restored_source_refuses_an_origin_that_disagrees_with_its_key(origin_audience, key_audience, caplog):
    origin = slack_source(origin_audience)
    key = build_session_key(replace(origin, audience=key_audience))
    with caplog.at_level("WARNING"):
        assert runner()._restored_source(entry(origin, key)) is None
    assert any("audience" in r.getMessage() for r in caplog.records)
