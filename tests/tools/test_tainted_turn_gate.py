"""A turn made of someone else's words runs in the owner's lane only with the owner's yes on each exact call."""

import pytest

from gateway.audience import Audience
from gateway.config import Platform
from gateway.platforms.event import MessageEvent
from gateway.session import SessionSource, build_session_key
from gateway.session_context import clear_session_vars, set_session_vars
from tools import approval
from tools.tainted_turn_gate import (
    GATE_FAILED,
    OWNER_DENIED,
    OWNER_UNREACHABLE,
    CallGrant,
    admit_tainted_call,
    bound_call_grant,
    spend_call_grant,
)

OWNER = "U0OWNER"
COMMAND = {"command": "rm -rf /tmp/x"}


class Cards(list):
    def __init__(self):
        super().__init__()
        self.answers = {"approved": True}


@pytest.fixture
def cards(monkeypatch):
    seen = Cards()

    def request_draft_approval(**card):
        seen.append(card)
        return dict(seen.answers)

    monkeypatch.setattr(approval, "request_draft_approval", request_draft_approval)
    monkeypatch.setenv("SLACK_ALLOWED_USERS", OWNER)
    monkeypatch.setenv("SLACK_HOME_CHANNEL", "D0OWNER")
    return seen


@pytest.fixture
def turn():
    tokens: list = []

    def enter(*, internal=True, tainted=True, audience=Audience.OWNER, platform="slack"):
        source = SessionSource(platform=Platform(platform), chat_id="D0OWNER", chat_type="dm", user_id=OWNER,
                               scope_id="T0", thread_id="1.0", audience=audience)
        event = MessageEvent(text="go", source=source, internal=internal, carries_member_content=tainted)
        tokens.append(set_session_vars(platform=platform, chat_id="D0OWNER", chat_type="dm", user_id=OWNER,
                                       scope_id="T0", session_key=build_session_key(source), actor_id="",
                                       turn_event=event))

    yield enter
    for token in tokens:
        clear_session_vars(token)


def test_an_ordinary_owner_turn_passes_straight_through_without_a_card(cards, turn):
    turn(internal=False, tainted=False)
    assert admit_tainted_call("terminal", COMMAND) == (None, None)
    turn(internal=True, tainted=False)
    assert admit_tainted_call("terminal", COMMAND) == (None, None)
    assert cards == []


def test_no_bound_turn_passes_straight_through(cards):
    assert admit_tainted_call("terminal", COMMAND) == (None, None)
    assert cards == []


def test_a_tool_that_cannot_act_on_the_world_is_exempt(cards, turn):
    turn()
    assert admit_tainted_call("web_search", {"query": "weather"}) == (None, None)
    assert cards == []


def test_the_member_lane_is_not_this_gates_business(cards, turn):
    turn(audience=Audience.MEMBER)
    assert admit_tainted_call("terminal", COMMAND) == (None, None)
    assert cards == []


def test_a_tainted_call_asks_once_and_the_grant_covers_exactly_that_call_once(cards, turn):
    turn()
    refusal, grant = admit_tainted_call("terminal", COMMAND)
    assert refusal is None and isinstance(grant, CallGrant) and len(cards) == 1
    assert grant.spend("terminal", COMMAND) is True
    assert grant.spend("terminal", COMMAND) is False, "a grant is spent once"


def test_a_grant_does_not_cover_other_arguments_or_another_tool(cards, turn):
    turn()
    _, grant = admit_tainted_call("terminal", COMMAND)
    assert grant.spend("terminal", {"command": "rm -rf /"}) is False
    assert grant.spend("write_file", COMMAND) is False
    assert grant.spend("terminal", COMMAND) is True


def test_a_bound_grant_is_spendable_by_the_inner_gates_and_only_by_name(cards, turn):
    turn()
    _, grant = admit_tainted_call("terminal", COMMAND)
    assert spend_call_grant("terminal") is False, "nothing is bound outside the call"
    with bound_call_grant(grant):
        assert spend_call_grant("mcp_", prefix=True) is False
        assert spend_call_grant("terminal") is True
        assert spend_call_grant("terminal") is False
    assert spend_call_grant("terminal") is False


def test_a_prefix_grant_covers_an_mcp_tool_of_that_family(cards, turn):
    turn()
    _, grant = admit_tainted_call("mcp_files_delete", {"path": "/x"})
    with bound_call_grant(grant):
        assert spend_call_grant("mcp_", prefix=True) is True


def test_a_denied_call_is_refused_with_a_code_and_nothing_is_granted(cards, turn):
    turn()
    cards.answers["approved"] = False
    refusal, grant = admit_tainted_call("terminal", COMMAND)
    assert grant is None and OWNER_DENIED in refusal and "NOT run" in refusal


def test_a_gate_that_cannot_ask_blocks_the_call(monkeypatch, cards, turn):
    turn()

    def broken(**_card):
        raise RuntimeError("no way to reach the owner: secret-detail")

    monkeypatch.setattr(approval, "request_draft_approval", broken)
    refusal, grant = admit_tainted_call("terminal", COMMAND)
    assert grant is None and GATE_FAILED in refusal and "secret-detail" not in refusal


def test_yolo_never_waives_the_owners_yes(monkeypatch, cards, turn):
    monkeypatch.setenv("HERMES_YOLO_MODE", "1")
    turn()
    admit_tainted_call("terminal", COMMAND)
    assert len(cards) == 1


def test_a_tainted_call_with_no_reachable_owner_is_refused_not_waved_through(monkeypatch, cards, turn):
    monkeypatch.delenv("SLACK_ALLOWED_USERS")
    monkeypatch.delenv("SLACK_HOME_CHANNEL")
    turn()
    refusal, grant = admit_tainted_call("terminal", COMMAND)
    assert grant is None and OWNER_UNREACHABLE in refusal and not cards
