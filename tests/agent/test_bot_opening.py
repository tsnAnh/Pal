from __future__ import annotations

import pytest

from agent.onboarding_session import opening_prelude
from tests.fixtures.bot_opening_world import MODEL_REPLY, BotWorld

CHOICES = ["Everyday personal assistant", "Help with my apps and work", "A specific new job"]
PITCH = "You haven't given me a job yet, so let's figure out where I'd help you most."


@pytest.fixture
def world_factory(tmp_path, monkeypatch):
    worlds = []

    def make(**kwargs):
        worlds.append(BotWorld(tmp_path, monkeypatch, **kwargs))
        return worlds[-1]

    yield make
    for world in worlds:
        world.close()


@pytest.mark.parametrize(("owner", "greeting"), [
    ("Sam", f"Hi Sam, I'm Ada. {PITCH}"),
    (None, f"Hi, I'm Ada. {PITCH}"),
])
def test_the_first_hidden_turn_opens_with_the_greeting_card_and_waits_for_the_owner(world_factory, owner, greeting):
    world = world_factory(owner=owner)

    result = world.play(opening_prelude(world.agent, [], hidden=True))

    assistant = next(row for row in world.rows() if row["role"] == "assistant")
    assert assistant["content"] == greeting
    assert world.clarify_call()["questions"][0]["question"] == "What do you want me for?"
    assert world.clarify_call()["questions"][0]["choices"] == CHOICES
    [shown] = world.asked
    assert shown["choices"] == CHOICES
    assert world.events == ["card", "model"]
    tool_result = next(m for m in world.model_requests[0] if m["role"] == "tool")
    assert "Help with my apps and work" in tool_result["content"]
    assert result["final_response"] == MODEL_REPLY
    assert not world.pending


@pytest.mark.parametrize("answer", [None, ""])
def test_a_card_nobody_answered_keeps_the_flag(world_factory, answer):
    world = world_factory(answer=answer)

    world.play(opening_prelude(world.agent, [], hidden=True))

    assert world.events == ["card", "model"]
    assert world.pending


@pytest.mark.parametrize(("history", "hidden"), [([{"role": "user", "content": "hi"}], True), ([], False)])
def test_nothing_plays_after_the_first_turn_or_for_a_typed_message(world_factory, history, hidden):
    world = world_factory()

    assert opening_prelude(world.agent, history, hidden=hidden) is None
    assert world.pending


def test_a_bot_that_already_has_a_job_gets_no_opening_and_its_flag_clears(world_factory):
    world = world_factory(role=True)

    assert opening_prelude(world.agent, [], hidden=True) is None
    assert not world.pending


def test_a_profile_without_the_flag_gets_no_opening(world_factory):
    world = world_factory(pending=False)

    assert opening_prelude(world.agent, [], hidden=True) is None
    assert world.asked == []
