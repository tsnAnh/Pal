"""The desk service: owner decisions, one-shot execution, reply claims and crash recovery."""

import asyncio
import threading

import pytest

from gateway.config import Platform
from gateway.desk import (
    AskPayload,
    DeskItem,
    ItemKind,
    ItemState,
    Origin,
    Recipient,
    SendPayload,
    send_digest,
)
from gateway.desk import delivery
from gateway.desk.service import DecideStatus, Desk, Reply
from gateway.platforms.owner_desk import DeskSendError

OWNER = "U0OWNER"
ORIGIN = Origin("agent:default:slack:dm:T0:D0OWNER:1.1", "default")


class StubAdapter:
    def __init__(self):
        self.sent = []
        self.closed = []
        self.fail_with = None

    async def desk_send(self, to, text):
        await asyncio.sleep(0)
        if self.fail_with is not None:
            raise self.fail_with
        self.sent.append((to.user_id, text))
        return {"ts": f"9.{len(self.sent)}", "channel": "D0CAROL"}

    async def close_owner_card(self, ref, text):
        self.closed.append(text)

    async def send_owner_card(self, contact, card):
        return {"ts": "5.5", "channel": "D0OWNER"}


class StubRunner:
    def __init__(self, adapter):
        self._adapter = adapter

    def _adapters_for_profile(self, _profile):
        return {Platform.SLACK: self._adapter}


@pytest.fixture
def adapter():
    return StubAdapter()


@pytest.fixture
def woken(monkeypatch):
    calls = []

    async def record(_runner, item, wake):
        calls.append((item.id, wake.text))

    monkeypatch.setattr(delivery, "wake_origin", record)
    return calls


@pytest.fixture
def desk(tmp_path, adapter, woken):
    return Desk(tmp_path, runner=StubRunner(adapter))


def send_item(item_id="dk_s", *, wait=False, state=ItemState.OPEN) -> DeskItem:
    to = Recipient("slack", "T0", "U0CAROL", "D0CAROL", None, True)
    return DeskItem(id=item_id, kind=ItemKind.SEND, state=state, revision=0, origin=ORIGIN, owner_id=OWNER,
                    platform="slack", scope_id="T0", payload=SendPayload(to, "Lunch at noon?", send_digest(to, "Lunch at noon?"),
                                                                        wait, 30 if wait else None, "Carol"),
                    outcome=None, created_at=1_000.0, expires_at=9_999_999_999.0, settled_at=None, delivered_at=None)


def ask_item(item_id="dk_a") -> DeskItem:
    target = Recipient("slack", "T0", "U0ALICE", "D0ALICE", None, True)
    return DeskItem(id=item_id, kind=ItemKind.ASK, state=ItemState.OPEN, revision=0, origin=ORIGIN, owner_id=OWNER,
                    platform="slack", scope_id="T0", payload=AskPayload("when?", target, "7.7"), outcome=None,
                    created_at=1_000.0, expires_at=9_999_999_999.0, settled_at=None, delivered_at=None)


def decide(desk, item_id, *, actor=OWNER, choice="approve"):
    return asyncio.run(desk.decide(item_id, actor_id=actor, choice=choice))


def test_two_simultaneous_approvals_apply_once_and_send_once(desk, adapter):
    desk.store.reserve(send_item())
    results = []
    gate = threading.Barrier(2)

    def tap():
        gate.wait()
        results.append(decide(desk, "dk_s").status)

    threads = [threading.Thread(target=tap) for _ in range(2)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert sorted(r.value for r in results) == ["applied", "stale"]
    assert adapter.sent == [("U0CAROL", "Lunch at noon?")]
    assert desk.store.get("dk_s").state is ItemState.DONE


def test_a_decision_after_the_other_decision_is_stale_and_changes_nothing(desk, adapter):
    desk.store.reserve(send_item("dk_one"))
    desk.store.reserve(send_item("dk_two"))
    assert decide(desk, "dk_one", choice="decline").status is DecideStatus.APPLIED
    assert decide(desk, "dk_one", choice="approve").status is DecideStatus.STALE
    assert decide(desk, "dk_two").status is DecideStatus.APPLIED
    assert decide(desk, "dk_two", choice="decline").status is DecideStatus.STALE
    assert adapter.sent == [("U0CAROL", "Lunch at noon?")]
    assert desk.store.get("dk_one").state is ItemState.DECLINED
    assert desk.store.get("dk_two").state is ItemState.DONE


def test_only_the_owner_can_decide_and_an_ask_is_not_a_decision(desk, adapter):
    desk.store.reserve(send_item())
    desk.store.reserve(ask_item())
    assert decide(desk, "dk_s", actor="U0ALICE").status is DecideStatus.FORBIDDEN
    assert decide(desk, "dk_s", actor="").status is DecideStatus.FORBIDDEN
    assert decide(desk, "dk_a").status is DecideStatus.NOT_FOUND
    assert decide(desk, "dk_missing").status is DecideStatus.NOT_FOUND
    assert decide(desk, "dk_s", choice="maybe").status is DecideStatus.NOT_FOUND
    assert desk.store.get("dk_s").state is ItemState.OPEN and adapter.sent == []


def test_a_send_the_platform_refuses_fails_without_retry_and_wakes_the_origin(desk, adapter, woken):
    adapter.fail_with = DeskSendError("channel_not_found")
    desk.store.reserve(send_item())
    assert decide(desk, "dk_s").status is DecideStatus.APPLIED
    assert desk.store.get("dk_s").state is ItemState.FAILED
    asyncio.run(desk.tick())
    assert adapter.sent == [] and len(woken) == 1 and "[Not sent]" in woken[0][1]


def test_a_send_that_ends_without_an_answer_is_unknown_and_never_sent_again(desk, adapter, woken):
    adapter.fail_with = RuntimeError("connection reset")
    desk.store.reserve(send_item())
    decide(desk, "dk_s")
    adapter.fail_with = None
    asyncio.run(desk.tick())
    asyncio.run(desk.recover_stranded())
    assert desk.store.get("dk_s").state is ItemState.UNKNOWN
    assert adapter.sent == []
    assert len(woken) == 1 and "[Unconfirmed]" in woken[0][1]


def test_an_approved_send_that_waits_opens_exactly_one_follow_up_ask_anchored_on_the_posted_message(desk, adapter):
    desk.store.reserve(send_item(wait=True))
    decide(desk, "dk_s")
    asks = [i for i in desk.store.listing(frozenset({ItemState.OPEN}), frozenset({ItemKind.ASK}))]
    assert len(asks) == 1
    assert asks[0].payload.anchor_ts == "9.1" and asks[0].payload.target.user_id == "U0CAROL"
    assert asks[0].origin == ORIGIN
    asyncio.run(desk.tick())
    assert len(desk.store.listing(frozenset({ItemState.OPEN}), frozenset({ItemKind.ASK}))) == 1


def test_a_reply_is_claimed_by_exactly_one_message_and_wakes_the_origin_once(desk, woken):
    desk.store.reserve(ask_item())
    first = asyncio.run(desk.claim_reply("dk_a", Reply("U0ALICE", "Alice", "Friday", "8.1")))
    second = asyncio.run(desk.claim_reply("dk_a", Reply("U0ALICE", "Alice", "Thursday", "8.2")))
    assert (first, second) == (True, False)
    assert len(woken) == 1 and "Friday" in woken[0][1] and "Thursday" not in woken[0][1]
    assert desk.store.get("dk_a").delivered_at is not None


def test_a_crash_between_lease_and_answer_becomes_unknown_on_boot_and_a_stale_posting_on_the_tick(desk, adapter):
    desk.store.reserve(send_item("dk_exec"))
    desk.store.transition("dk_exec", ItemState.OPEN, ItemState.APPROVED, revision=0)
    desk.store.transition("dk_exec", ItemState.APPROVED, ItemState.EXECUTING, revision=1)
    stale = ask_item("dk_post")
    desk.store.reserve(DeskItem(**{**stale.__dict__, "state": ItemState.POSTING, "created_at": 1.0}))
    asyncio.run(desk.recover_stranded())
    asyncio.run(desk.tick())
    assert desk.store.get("dk_exec").state is ItemState.UNKNOWN
    assert desk.store.get("dk_post").state is ItemState.UNKNOWN
    assert adapter.sent == []
