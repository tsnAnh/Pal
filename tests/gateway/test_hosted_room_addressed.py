"""Direct user addresses must not disappear as ordinary Discussion silence."""

import pytest

from gateway import hosted_room_discussion as discussion
from gateway import hosted_rooms
from tests.gateway.test_hosted_room_discussion import (
    GATEWAY_ID,
    LOCAL_PROFILES,
    MEMBERS,
    ROOM_ID,
    _append_publication,
    _append_user,
    _events,
    _next_task,
    _settle_next,
)


@pytest.fixture
def room_db(tmp_path):
    db = tmp_path / "state.db"
    room = hosted_rooms.create_room(
        db,
        room_id=ROOM_ID,
        name="Release",
        members=MEMBERS,
        authority_gateway_id=GATEWAY_ID,
        now=1,
    )
    return db, room


@pytest.mark.parametrize("address", ["@research", "@RESEARCH", "@everyone", "@all"])
@pytest.mark.parametrize("reply", ["(pass)", "", "pass."])
def test_addressed_pass_is_visible_and_does_not_schedule_a_second_attempt(
    room_db, address, reply
):
    db, room = room_db
    _append_user(db, event_id="user-1", text=f"{address} continue the task")
    task = _next_task(room, db)
    assert "concrete blocker" in task.payload["prompt"]
    assert 'reply with exactly "(pass)"' not in task.payload["prompt"]
    publication = discussion.plan_publication(
        room,
        _events(db),
        task,
        status="settled",
        result={"text": reply},
        local_profiles=LOCAL_PROFILES,
    )
    assert publication.terminal_kind == "turn.failed"
    assert len(publication.events) == 1
    assert "directly addressed" in publication.events[0].payload["error"]
    _append_publication(db, publication)
    next_decision = discussion.plan_next_task(
        room, _events(db), local_profiles=LOCAL_PROFILES
    )
    assert next_decision.task is None or next_decision.task.member != task.member


@pytest.mark.parametrize("message", ["Continue the task", "@unknown continue"])
def test_unaddressed_collaborative_pass_stays_silent(room_db, message):
    db, room = room_db
    _append_user(db, event_id="user-1", text=message)
    task = _next_task(room, db)
    assert 'reply with exactly "(pass)"' in task.payload["prompt"]
    result = discussion.plan_publication(
        room,
        _events(db),
        task,
        status="settled",
        result={"text": "(pass)"},
        local_profiles=LOCAL_PROFILES,
    )
    assert result.terminal_kind == "turn.settled"
    assert result.events[0].payload["passed"] is True


def test_answered_member_can_pass_on_a_later_peer_handoff(room_db):
    db, room = room_db
    _append_user(db, event_id="user-1", text="@research check the release")
    _settle_next(room, db, text="Checked. @build please confirm.")
    _settle_next(room, db, text="Confirmed. @research anything else?")
    task = _next_task(room, db)
    assert task.member.handle == "research" and task.round_index > 0
    result = discussion.plan_publication(
        room,
        _events(db),
        task,
        status="settled",
        result={"text": "(pass)"},
        local_profiles=LOCAL_PROFILES,
    )
    assert result.terminal_kind == "turn.settled"
    assert result.events[0].payload["passed"] is True


def test_superseded_addressed_pass_remains_cancelled(room_db):
    db, room = room_db
    _append_user(db, event_id="user-1", text="@research inspect")
    task = _next_task(room, db)
    _append_user(db, event_id="user-2", text="Never mind")
    result = discussion.plan_publication(
        room,
        _events(db),
        task,
        status="settled",
        result={"text": "(pass)"},
        local_profiles=LOCAL_PROFILES,
    )
    assert result.terminal_kind == "turn.cancelled"
    assert result.events[0].payload["reason"] == "superseded_by_newer_user_event"


def test_peer_member_address_is_checked_against_handle_not_profile(room_db):
    db, room = room_db
    room["members"][0] = {
        "member_id": "remote-member",
        "profile": "default",
        "handle": "remote",
        "target": {
            "kind": "peer",
            "profile": "default",
            "peer_id": "peer-1",
            "installation_id": "remote-install",
            "capability_digest": "a" * 64,
        },
    }
    _append_user(db, event_id="user-1", text="@remote report your blocker")
    task = _next_task(room, db)
    assert task.member.member_id == "remote-member"
    result = discussion.plan_publication(
        room,
        _events(db),
        task,
        status="settled",
        result={"text": "(pass)"},
        local_profiles=LOCAL_PROFILES,
    )
    assert result.terminal_kind == "turn.failed"
    assert "@remote" in result.events[0].payload["error"]


def _round_zero_members(room, db):
    seen = []
    for _ in range(len(MEMBERS) + 1):
        decision = discussion.plan_next_task(room, _events(db), local_profiles=LOCAL_PROFILES)
        if decision.task is None:
            return seen, decision
        seen.append(decision.task.member.profile)
        _append_publication(
            db,
            discussion.plan_publication(
                room, _events(db), decision.task, status="settled",
                result={"text": f"answer from {decision.task.member.profile}"},
                local_profiles=LOCAL_PROFILES))
    return seen, decision


def test_everyone_wakes_each_member_once_and_triggers_no_continuation(room_db):
    db, room = room_db
    _append_user(db, event_id="user-1", text="@everyone status please")

    seen, decision = _round_zero_members(room, db)

    assert sorted(seen) == sorted(m["profile"] for m in MEMBERS)
    assert len(seen) == len(MEMBERS)
    assert decision.status == "settled"


def _append_reply(db, *, text, member_id, quote="the earlier answer", event_id="user-r"):
    return hosted_rooms.append_event(
        db, room_id=ROOM_ID, event_id=event_id, kind="message.user",
        actor={"kind": "user", "id": "local-user"}, authority_gateway_id=GATEWAY_ID, authority_epoch=1,
        payload={"text": text, "thread_id": "thread-1",
                 "reply_to": {"event_id": "dmessage:abc", "member_id": member_id, "quote": quote}})


def test_reply_to_wakes_only_the_replied_author_and_demands_an_answer(room_db):
    db, room = room_db
    _append_reply(db, text="why did you pick that?", member_id="member-build")

    seen, _ = _round_zero_members(room, db)

    assert seen == ["build"]


def test_reply_prompt_quotes_the_replied_message_and_requires_a_direct_reply(room_db):
    db, room = room_db
    _append_reply(db, text="why?", member_id="member-build", quote="we ship\nfriday")

    task = _next_task(room, db)

    assert task.member.profile == "build"
    assert '[replying to @build: "we ship friday"]' in task.payload["prompt"]
    assert "concrete blocker" in task.payload["prompt"]


def test_reply_to_adds_its_author_to_explicit_mentions(room_db):
    db, room = room_db
    _append_reply(db, text="@research and also you", member_id="member-build")

    seen, _ = _round_zero_members(room, db)

    assert sorted(seen) == ["build", "research"]


@pytest.mark.parametrize("reply_to", [
    {"event_id": "e", "member_id": "member-build"},
    {"event_id": "e", "member_id": "member-build", "quote": "x" * 281},
    {"event_id": "e", "member_id": "member-build", "quote": "ok", "extra": 1},
    {"event_id": "e", "member_id": "", "quote": "ok"},
])
def test_malformed_reply_to_is_refused(reply_to):
    with pytest.raises(discussion.DiscussionValidationError):
        discussion.validate_user_payload({"text": "hi", "thread_id": "t", "reply_to": reply_to})


def test_reply_to_a_non_member_is_refused_by_the_policy(room_db):
    db, room = room_db
    _append_reply(db, text="hi", member_id="member-stranger")

    with pytest.raises(discussion.DiscussionValidationError, match="not in this room"):
        discussion.plan_next_task(room, _events(db), local_profiles=LOCAL_PROFILES)
