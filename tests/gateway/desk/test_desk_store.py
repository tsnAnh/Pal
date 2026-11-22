"""The desk store: reservations, compare-and-set transitions and the ticker's queries."""

import threading

import pytest

from gateway.desk import (
    AskPayload,
    DeskItem,
    DeskStore,
    HandoffPayload,
    ItemKind,
    ItemState,
    Origin,
    Recipient,
    SendPayload,
    item_id_for_call,
)

OWNER = "U0OWNER"


class Clock:
    def __init__(self):
        self.now = 1_000.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def store(tmp_path, clock):
    return DeskStore(tmp_path, clock)


def ask_item(item_id="dk_a", *, user="U0ALICE", conversation="D0ALICE", state=ItemState.POSTING, expires=2_000.0,
             session="agent:default:slack:dm:D0OWNER") -> DeskItem:
    target = Recipient("slack", "T0", user, conversation, None, True)
    return DeskItem(id=item_id, kind=ItemKind.ASK, state=state, revision=0, origin=Origin(session, "default"),
                    owner_id=OWNER, platform="slack", scope_id="T0", payload=AskPayload("when?", target, None),
                    outcome=None, created_at=1_000.0, expires_at=expires, settled_at=None, delivered_at=None)


def handoff_item(item_id="dk_h") -> DeskItem:
    payload = HandoffPayload("restart staging", "stuck", "U0ALICE", "Alice", "C0OPS", "1.1")
    return DeskItem(id=item_id, kind=ItemKind.HANDOFF, state=ItemState.OPEN, revision=0,
                    origin=Origin("agent:default:slack:group:C0OPS:1.1:~member", "default"), owner_id=OWNER,
                    platform="slack", scope_id="T0", payload=payload, outcome=None, created_at=1_000.0,
                    expires_at=5_000.0, settled_at=None, delivered_at=None)


def test_a_reservation_is_idempotent_and_the_first_writer_wins(store):
    assert store.reserve(ask_item()) is True
    assert store.reserve(ask_item(user="U0BOB")) is False
    assert store.get("dk_a").payload.target.user_id == "U0ALICE"


def test_the_call_identity_gives_the_same_id_for_a_retried_call_and_another_for_a_new_one():
    first = item_id_for_call("sess", "turn", "call-1")
    assert first == item_id_for_call("sess", "turn", "call-1")
    assert first != item_id_for_call("sess", "turn", "call-2")
    assert first.startswith("dk_") and len(first) == len("dk_") + 16


def test_the_payload_round_trips_for_every_kind(store):
    send = SendPayload(Recipient("slack", "T0", "U0BOB", "D0BOB", None, True), "hello", "abc", True, 30, "Bob")
    item = DeskItem(id="dk_s", kind=ItemKind.SEND, state=ItemState.OPEN, revision=0, origin=Origin("", "default"),
                    owner_id=OWNER, platform="slack", scope_id="T0", payload=send, outcome=None, created_at=1.0,
                    expires_at=9.0, settled_at=None, delivered_at=None)
    for entry in (ask_item(), handoff_item(), item):
        store.reserve(entry)
        assert store.get(entry.id) == entry


def test_a_transition_needs_the_state_and_revision_it_expects(store):
    store.reserve(ask_item())
    opened = store.transition("dk_a", ItemState.POSTING, ItemState.OPEN, revision=0)
    assert opened.state is ItemState.OPEN and opened.revision == 1
    assert store.transition("dk_a", ItemState.POSTING, ItemState.OPEN, revision=0) is None
    assert store.transition("dk_a", ItemState.OPEN, ItemState.DONE, revision=0) is None
    assert store.get("dk_a").state is ItemState.OPEN


def test_two_threads_racing_the_same_transition_have_exactly_one_winner(store):
    store.reserve(handoff_item())
    results = []
    barrier = threading.Barrier(8)

    def decide():
        barrier.wait()
        results.append(store.transition("dk_h", ItemState.OPEN, ItemState.APPROVED, revision=0))

    threads = [threading.Thread(target=decide) for _ in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert sum(r is not None for r in results) == 1
    assert store.get("dk_h").state is ItemState.APPROVED and store.get("dk_h").revision == 1


def test_a_terminal_transition_stamps_the_settle_time_and_keeps_the_outcome(store, clock):
    store.reserve(ask_item(state=ItemState.OPEN))
    clock.now = 1_500.0
    done = store.transition("dk_a", ItemState.OPEN, ItemState.DONE, revision=0, outcome={"text": "Friday"})
    assert done.settled_at == 1_500.0 and done.outcome == {"text": "Friday"} and done.delivered_at is None


def test_a_settle_that_needs_no_wake_is_born_delivered(store, clock):
    store.reserve(ask_item(state=ItemState.OPEN))
    done = store.transition("dk_a", ItemState.OPEN, ItemState.CANCELLED, revision=0, wake_origin=False)
    assert done.delivered_at == clock.now
    assert store.undelivered() == []


def test_open_asks_are_found_by_workspace_conversation_and_person_only_while_open(store):
    store.reserve(ask_item("dk_1", state=ItemState.OPEN))
    store.reserve(ask_item("dk_2", state=ItemState.OPEN, conversation="D0OTHER"))
    store.reserve(ask_item("dk_3", state=ItemState.POSTING))
    store.reserve(ask_item("dk_4", state=ItemState.OPEN, user="U0BOB"))
    assert [i.id for i in store.open_asks_for("slack", "T0", "D0ALICE", "U0ALICE")] == ["dk_1"]
    assert store.open_asks_for("slack", "T9", "D0ALICE", "U0ALICE") == []


def test_due_stale_stranded_approved_and_card_queries(store, clock):
    store.reserve(ask_item("dk_open", state=ItemState.OPEN, expires=1_100.0))
    store.reserve(ask_item("dk_posting", state=ItemState.POSTING, expires=9_000.0))
    store.reserve(handoff_item("dk_wait"))
    clock.now = 1_400.0
    assert [i.id for i in store.due(clock.now)] == ["dk_open"]
    assert [i.id for i in store.stale_posting(before=clock.now - 300.0)] == ["dk_posting"]
    assert store.stale_posting(before=clock.now - 600.0) == []
    assert [i.id for i in store.awaiting_card()] == ["dk_wait"]
    store.set_card_ref("dk_wait", {"channel": "D0OWNER", "ts": "1.1"})
    assert store.awaiting_card() == []
    approved = store.transition("dk_wait", ItemState.OPEN, ItemState.APPROVED, revision=0)
    assert [i.id for i in store.approved()] == ["dk_wait"]
    store.transition("dk_wait", ItemState.APPROVED, ItemState.EXECUTING, revision=approved.revision)
    assert [i.id for i in store.stranded()] == ["dk_wait"]


def test_undelivered_lists_settled_items_until_they_are_marked(store):
    store.reserve(ask_item(state=ItemState.OPEN))
    done = store.transition("dk_a", ItemState.OPEN, ItemState.DONE, revision=0, outcome={"text": "x"})
    assert [i.id for i in store.undelivered()] == ["dk_a"]
    assert store.mark_delivered("dk_a", done.revision) is True
    assert store.mark_delivered("dk_a", done.revision) is False
    assert store.undelivered() == []


def test_cancelling_a_session_closes_only_its_open_asks(store):
    store.reserve(ask_item("dk_mine", state=ItemState.OPEN, session="agent:default:k1"))
    store.reserve(ask_item("dk_other", state=ItemState.OPEN, session="agent:default:k2"))
    store.reserve(handoff_item())
    assert [i.id for i in store.cancel_open_asks("agent:default:k1")] == ["dk_mine"]
    assert store.get("dk_mine").state is ItemState.CANCELLED
    assert store.get("dk_other").state is ItemState.OPEN and store.get("dk_h").state is ItemState.OPEN


def test_the_database_is_private_to_the_profile_home(store, tmp_path):
    store.reserve(ask_item())
    assert (tmp_path / "desk.db").exists()
    assert (tmp_path / "desk.db").stat().st_mode & 0o077 == 0


def test_pruning_removes_only_old_settled_items_that_were_delivered_and_whose_card_is_closed(store, clock):
    for item_id in ("dk_old", "dk_new", "dk_undelivered", "dk_card_open", "dk_open"):
        store.reserve(ask_item(item_id, state=ItemState.OPEN))
    clock.now = 1_100.0
    for item_id in ("dk_old", "dk_undelivered", "dk_card_open"):
        store.transition(item_id, ItemState.OPEN, ItemState.CANCELLED, revision=0)
    clock.now = 5_000.0
    store.transition("dk_new", ItemState.OPEN, ItemState.CANCELLED, revision=0)
    for item_id in ("dk_old", "dk_new", "dk_card_open"):
        store.mark_delivered(item_id, 1)
    store.set_card_ref("dk_card_open", {"channel": "D0OWNER", "ts": "1.1"})
    assert store.prune(settled_before=2_000.0) == 1
    assert store.get("dk_old") is None
    assert all(store.get(i) is not None for i in ("dk_new", "dk_undelivered", "dk_card_open", "dk_open"))
    store.mark_card_closed("dk_card_open")
    assert store.prune(settled_before=2_000.0) == 1
