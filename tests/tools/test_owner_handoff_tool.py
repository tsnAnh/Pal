"""request_owner_action: a teammate's request the owner must approve, recorded once on the owner's desk."""

import json

import pytest

import toolsets
from gateway.audience import Audience
from gateway.config import Platform
from gateway.desk import ItemKind, ItemState
from gateway.desk.service import Desk
from gateway.session import SessionSource, build_session_key
from gateway.session_context import clear_session_vars, set_session_vars
from tools import owner_handoff_tool
from tools.approval_context import set_current_observability_context

OWNER, ALICE = "U0OWNER", "U0ALICE"


@pytest.fixture(autouse=True)
def owner(monkeypatch):
    monkeypatch.setenv("SLACK_ALLOWED_USERS", OWNER)
    monkeypatch.setenv("SLACK_HOME_CHANNEL", "D0OWNER")


@pytest.fixture
def lane():
    tokens: list = []

    def enter(audience=Audience.MEMBER, call_id="call-1"):
        source = SessionSource(platform=Platform.SLACK, chat_id="C0OPS", chat_type="group", user_id=ALICE,
                               user_name="Alice", scope_id="T0", thread_id="1.0", audience=audience)
        tokens.append(set_session_vars(platform="slack", chat_id="C0OPS", chat_type="group", chat_name="ops",
                                       thread_id="1.0", user_id=ALICE, user_name="Alice", scope_id="T0",
                                       session_key=build_session_key(source)))
        set_current_observability_context(turn_id="turn-1", tool_call_id=call_id, session_id="sess-1")

    yield enter
    for token in tokens:
        clear_session_vars(token)
    set_current_observability_context()


def call(args: dict) -> dict:
    return json.loads(owner_handoff_tool._handle(args))


def handoffs() -> list:
    return Desk.in_turn().store.listing(frozenset(ItemState), frozenset({ItemKind.HANDOFF}))


def test_the_tool_exists_only_for_the_member_toolset():
    assert "request_owner_action" in toolsets.resolve_toolset("member")
    for name, spec in toolsets.TOOLSETS.items():
        if name != "member":
            assert "request_owner_action" not in spec.get("tools", ()), name


def test_a_member_request_is_recorded_for_the_owner_with_who_where_and_why(lane):
    lane()
    result = call({"request": "Restart staging", "why": "it is stuck"})
    assert result["requested"] is True and "nothing has been done" in result["note"]
    (item,) = handoffs()
    payload = item.payload
    assert item.state is ItemState.OPEN and item.owner_id == OWNER
    assert (payload.request, payload.why, payload.requester_id, payload.requester_name) == (
        "Restart staging", "it is stuck", ALICE, "Alice")
    assert payload.conversation_id == "C0OPS" and payload.thread_ts == "1.0" and payload.where == "ops"
    assert item.origin.session_key.endswith("~member")


def test_the_owner_lane_cannot_use_it(lane):
    lane(Audience.OWNER)
    assert call({"request": "Restart staging"})["code"] == "not_a_member_lane"
    assert handoffs() == []


@pytest.mark.parametrize("request_text, code", [("", "request_empty"), ("   ", "request_empty"),
                                                ("x" * 1501, "request_too_long")])
def test_an_empty_or_oversized_request_is_refused(lane, request_text, code):
    lane()
    assert call({"request": request_text})["code"] == code
    assert handoffs() == []


def test_the_same_tool_call_repeated_records_one_request(lane):
    lane()
    first, second = call({"request": "Restart staging"}), call({"request": "Restart staging"})
    assert first["request"] == second["request"] and len(handoffs()) == 1


def test_a_person_cannot_pile_up_more_than_three_open_requests(lane):
    for index in range(3):
        lane(call_id=f"call-{index}")
        assert call({"request": f"Do thing {index}"})["requested"] is True
    lane(call_id="call-4")
    assert call({"request": "Do thing 4"})["code"] == "too_many_requests"
    assert len(handoffs()) == 3
