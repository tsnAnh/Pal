"""Outbound and reply-matching rules of the owner desk, as behaviour tables."""

import itertools

import pytest

from gateway.audience import Audience
from gateway.desk import (
    AMBIGUOUS_REPLY,
    AskPayload,
    DeskItem,
    ItemKind,
    ItemState,
    Origin,
    Outbound,
    Recipient,
    TurnFacts,
    match_reply,
    outbound_decision,
)

OWNER, ALICE, BOB = "U0OWNER", "U0ALICE", "U0BOB"
REPORT = "C0REPORT"


def turn(**changes) -> TurnFacts:
    base = dict(audience=Audience.OWNER, internal=False, actor_is_owner=True, carries_member_content=False,
                named_user_ids=frozenset({ALICE}), named_conversation_ids=frozenset(), owner_id=OWNER,
                report_conversation_id=REPORT)
    return TurnFacts(**{**base, **changes})


def person(user_id: str) -> Recipient:
    return Recipient("slack", "T0", user_id, "D0" + user_id[1:], None, True)


def channel(conversation_id: str) -> Recipient:
    return Recipient("slack", "T0", None, conversation_id, None, False)


def test_a_named_person_in_a_clean_owner_message_is_sent_now():
    assert outbound_decision(turn(), person(ALICE)) is Outbound.SEND_NOW


@pytest.mark.parametrize("changes", [
    {"internal": True},
    {"actor_is_owner": False},
    {"carries_member_content": True},
    {"named_user_ids": frozenset()},
    {"named_user_ids": frozenset({BOB})},
    {"audience": Audience.MEMBER},
])
def test_every_broken_condition_of_a_named_send_asks_the_owner(changes):
    assert outbound_decision(turn(**changes), person(ALICE)) is Outbound.ASK_OWNER


@pytest.mark.parametrize("changes", [
    {}, {"internal": True}, {"actor_is_owner": False}, {"carries_member_content": True},
    {"named_user_ids": frozenset()},
])
def test_the_owner_and_the_report_channel_are_always_sent_now_for_the_owner_lane(changes):
    assert outbound_decision(turn(**changes), person(OWNER)) is Outbound.SEND_NOW
    assert outbound_decision(turn(**changes), channel(REPORT)) is Outbound.SEND_NOW


def test_the_member_lane_never_sends_even_to_the_owner():
    assert outbound_decision(turn(audience=Audience.MEMBER), person(OWNER)) is Outbound.ASK_OWNER
    assert outbound_decision(turn(audience=Audience.MEMBER), channel(REPORT)) is Outbound.ASK_OWNER


def test_a_channel_the_owner_named_is_sent_now_and_an_unnamed_one_asks():
    named = turn(named_conversation_ids=frozenset({"C0OPS"}))
    assert outbound_decision(named, channel("C0OPS")) is Outbound.SEND_NOW
    assert outbound_decision(named, channel("C0OTHER")) is Outbound.ASK_OWNER


def ask(ask_id: str, user: str, conversation: str, anchor: str, *, direct=True, state=ItemState.OPEN) -> DeskItem:
    target = Recipient("slack", "T0", user, conversation, None, direct)
    return DeskItem(id=ask_id, kind=ItemKind.ASK, state=state, revision=0, origin=Origin("agent:default:k", "default"),
                    owner_id=OWNER, platform="slack", scope_id="T0", payload=AskPayload("q?", target, anchor),
                    outcome=None, created_at=0.0, expires_at=1e12, settled_at=None, delivered_at=None)


def test_a_threaded_reply_under_the_anchor_wins_over_other_open_asks():
    asks = [ask("a", ALICE, "D1", "100.1"), ask("b", ALICE, "D1", "200.1")]
    assert match_reply(asks, user_id=ALICE, conversation_id="D1", thread_ts="200.1") is asks[1]


def test_a_threaded_reply_under_no_anchor_claims_nothing():
    asks = [ask("a", ALICE, "D1", "100.1")]
    assert match_reply(asks, user_id=ALICE, conversation_id="D1", thread_ts="999.9") is None


def test_a_top_level_dm_reply_matches_the_single_open_ask():
    asks = [ask("a", ALICE, "D1", "100.1")]
    assert match_reply(asks, user_id=ALICE, conversation_id="D1", thread_ts=None) is asks[0]


def test_a_top_level_dm_reply_with_two_open_asks_is_ambiguous():
    asks = [ask("a", ALICE, "D1", "100.1"), ask("b", ALICE, "D1", "200.1")]
    assert match_reply(asks, user_id=ALICE, conversation_id="D1", thread_ts=None) is AMBIGUOUS_REPLY


@pytest.mark.parametrize("who, where", [(BOB, "D1"), (ALICE, "D2")])
def test_a_reply_from_someone_else_or_elsewhere_claims_nothing(who, where):
    asks = [ask("a", ALICE, "D1", "100.1")]
    assert match_reply(asks, user_id=who, conversation_id=where, thread_ts=None) is None
    assert match_reply(asks, user_id=who, conversation_id=where, thread_ts="100.1") is None


def test_a_channel_ask_is_only_answered_in_its_thread():
    asks = [ask("a", ALICE, "C1", "100.1", direct=False)]
    assert match_reply(asks, user_id=ALICE, conversation_id="C1", thread_ts=None) is None
    assert match_reply(asks, user_id=ALICE, conversation_id="C1", thread_ts="100.1") is asks[0]


def test_only_open_asks_can_be_matched():
    asks = [ask("a", ALICE, "D1", "100.1", state=ItemState.DONE)]
    assert match_reply(asks, user_id=ALICE, conversation_id="D1", thread_ts="100.1") is None


@pytest.mark.parametrize("audience, internal, actor, content",
                         list(itertools.product(Audience, (False, True), (False, True), (False, True))))
def test_a_third_person_is_sent_now_only_for_a_clean_owner_instruction(audience, internal, actor, content):
    facts = turn(audience=audience, internal=internal, actor_is_owner=actor, carries_member_content=content)
    expected = audience is Audience.OWNER and not internal and actor and not content
    assert (outbound_decision(facts, person(ALICE)) is Outbound.SEND_NOW) is expected
