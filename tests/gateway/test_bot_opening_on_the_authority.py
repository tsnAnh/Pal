from __future__ import annotations

from types import SimpleNamespace

import pytest

from gateway.session_onboarding import arm_onboarding_turn
from hermes_constants import reset_hermes_home_override, set_hermes_home_override
from tests.fixtures.bot_opening_world import MODEL_REPLY, SESSION_ID, BotWorld

OWNER = (SimpleNamespace(sessions={}), SESSION_ID, 1)


@pytest.fixture
def world_factory(tmp_path, monkeypatch):
    worlds = []

    def make(**kwargs):
        worlds.append(BotWorld(tmp_path, monkeypatch, **kwargs))
        return worlds[-1]

    yield make
    for world in worlds:
        world.close()


def test_the_authority_turn_plays_the_card_then_the_model_continues_on_the_answer(world_factory):
    world = world_factory()

    result = world.play(arm_onboarding_turn(world.agent, OWNER, [], hidden=True))

    assistant = next(row for row in world.rows() if row["role"] == "assistant")
    assert assistant["content"].startswith("Hi Sam, I'm Ada.")
    assert world.events == ["card", "model"]
    assert result["final_response"] == MODEL_REPLY
    assert not world.pending


def test_the_authority_plays_nothing_on_a_relaunch_a_typed_turn_or_without_an_owner(world_factory):
    world = world_factory()

    assert arm_onboarding_turn(world.agent, OWNER, [{"role": "assistant", "content": "hi"}], hidden=True) is None
    assert arm_onboarding_turn(world.agent, OWNER, [], hidden=False) is None
    assert arm_onboarding_turn(world.agent, None, [], hidden=True) is None
    assert world.pending


def test_a_turn_bound_to_a_bot_reads_that_bots_flag_even_when_the_store_is_the_launch_homes(world_factory):
    world = world_factory(shared_launch_store=True)
    assert arm_onboarding_turn(world.agent, OWNER, [], hidden=True) is None

    token = set_hermes_home_override(str(world.profile))
    try:
        prelude = arm_onboarding_turn(world.agent, OWNER, [], hidden=True)
    finally:
        reset_hermes_home_override(token)
    world.play(prelude)

    assert world.events == ["card", "model"]
    assert not world.pending
