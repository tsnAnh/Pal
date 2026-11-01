"""Reply-to and @everyone through the real room service: who is woken, with what context."""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from gateway import hosted_room_discussion as discussion
from tui_gateway.hosted_room_service import HostedRoomService
from tests.tui_gateway.test_hosted_room_service import _FakeRPC, _server

MEMBERS = [
    {"member_id": "default", "profile": "default", "handle": "hermes"},
    {"member_id": "ops", "profile": "ops", "handle": "ops"},
    {"member_id": "docs", "profile": "docs", "handle": "docs"},
]


class _PromptRPC(_FakeRPC):
    def __init__(self) -> None:
        super().__init__()
        self.prompts: list[tuple[str, str]] = []

    def submit(self, **kwargs):
        self.prompts.append((kwargs["profile"], kwargs["prompt"]))
        return super().submit(**kwargs)


@pytest.fixture
def service(tmp_path: Path):
    svc = HostedRoomService(_server(), db_path=tmp_path / "state.db")
    svc.rpc = _PromptRPC()
    svc.runtime.rpc = svc.rpc
    svc.local_profiles = lambda: ("default", "ops", "docs")
    svc.create_room(room_id="room-1", name="Release room", members=MEMBERS)
    svc.start()
    yield svc
    svc.stop(timeout=5.0)


def _settled(service, expected_members: int) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        events = service._events("room-1")
        if sum(e["kind"] == "message.member" for e in events) >= expected_members and not service.status(
                "room-1")["working"]:
            return
        time.sleep(0.02)
    raise AssertionError("room did not settle")


def test_everyone_is_answered_by_each_member_exactly_once(service):
    service.send(room_id="room-1", event_id="u1", payload={"text": "@everyone status?", "thread_id": "t1"})
    _settled(service, 3)

    assert sorted(profile for profile, _ in service.rpc.prompts) == ["default", "docs", "ops"]


def _first_member_message(service, member_id: str) -> dict:
    return next(
        e for e in service._events("room-1")
        if e["kind"] == "message.member" and e["payload"]["member_id"] == member_id)


def _ops_answered(service) -> dict:
    service.send(room_id="room-1", event_id="u0", payload={"text": "@ops status?", "thread_id": "t1"})
    _settled(service, 1)
    service.rpc.prompts.clear()
    return _first_member_message(service, "ops")


def test_reply_to_a_member_message_wakes_only_that_member_with_the_quote(service):
    target = _ops_answered(service)
    reply_to = {"event_id": target["event_id"], "member_id": "ops", "quote": "we should ship friday"}
    service.send(room_id="room-1", event_id="u1", payload={"text": "why that choice?", "thread_id": "t1", "reply_to": reply_to})
    _settled(service, 2)

    assert [profile for profile, _ in service.rpc.prompts] == ["ops"]
    assert '[replying to @ops: "we should ship friday"]' in service.rpc.prompts[0][1]
    user = next(e for e in service._events("room-1") if e["payload"].get("text") == "why that choice?")
    assert user["payload"]["reply_to"] == reply_to


def test_reply_to_an_event_that_is_not_in_the_room_log_is_refused(service):
    with pytest.raises(discussion.DiscussionValidationError, match="not in this room's log"):
        service.send(room_id="room-1", event_id="u1", payload={
            "text": "hi", "thread_id": "t1",
            "reply_to": {"event_id": "dmessage:missing", "member_id": "ops", "quote": "q"}})

    assert not [e for e in service._events("room-1") if e["kind"] == "message.user"]


def test_reply_to_credits_the_event_author_not_a_claimed_member(service):
    target = _ops_answered(service)
    before = len(service._events("room-1"))

    with pytest.raises(discussion.DiscussionValidationError, match="not written by"):
        service.send(room_id="room-1", event_id="u1", payload={
            "text": "hi", "thread_id": "t1",
            "reply_to": {"event_id": target["event_id"], "member_id": "docs", "quote": "q"}})

    assert len(service._events("room-1")) == before


def test_reply_to_a_user_message_is_refused(service):
    service.send(room_id="room-1", event_id="u0", payload={"text": "@ops status?", "thread_id": "t1"})
    _settled(service, 1)
    user = next(e for e in service._events("room-1") if e["kind"] == "message.user")

    with pytest.raises(discussion.DiscussionValidationError, match="not written by"):
        service.send(room_id="room-1", event_id="u1", payload={
            "text": "hi", "thread_id": "t1",
            "reply_to": {"event_id": user["event_id"], "member_id": "ops", "quote": "q"}})


def test_reply_to_a_member_outside_the_room_is_refused_before_anything_is_stored(service):
    with pytest.raises(discussion.DiscussionValidationError, match="not in this room"):
        service.send(room_id="room-1", event_id="u1", payload={
            "text": "hi", "thread_id": "t1",
            "reply_to": {"event_id": "dmessage:1", "member_id": "stranger", "quote": "q"}})

    assert not [e for e in service._events("room-1") if e["kind"] == "message.user"]
