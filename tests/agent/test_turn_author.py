"""Tests for agent.turn_author: the per-turn author carried from a dispatcher to memory hooks."""


import pytest

from agent.turn_author import (
    TURN_AUTHOR_ENV,
    parse_turn_author,
    take_turn_author_from_env,
    turn_author_env,
    turn_author_from_env,
)

FAMILY = "\U0001F468\u200D\U0001F469\u200D\U0001F467"


class TestParseTurnAuthor:

    @pytest.mark.parametrize("raw", [
        None, 42, [], ["bot:alpha"], "not json", '"a string"', "[1, 2]", b"\xff",
        {}, {"is_bot": True}, {"id": "", "name": "   "},
    ])
    def test_junk_and_authors_without_id_or_name_return_none(self, raw):
        assert parse_turn_author(raw) is None


class TestEnvCarrier:
    def test_round_trip_through_env(self):
        author = {"id": "bot:alpha", "name": "Alpha", "is_bot": True}
        env = turn_author_env(author)
        assert set(env) == {TURN_AUTHOR_ENV}
        assert turn_author_from_env(env) == author


    def test_take_removes_the_variable(self):
        author = {"id": "bot:alpha", "name": "Alpha", "is_bot": True}
        env = dict(turn_author_env(author), OTHER="kept")
        assert take_turn_author_from_env(env) == author
        assert env == {"OTHER": "kept"}
        assert take_turn_author_from_env(env) is None


class TestOwnerTurnReachesTools:
    @pytest.mark.parametrize("turn,owner", [
        ({}, True),
        ({"turn_author": {"id": "bot:helper", "name": "Helper", "is_bot": True}}, False),
        ({"turn_author": {"id": "42", "name": "Owner", "is_bot": False}}, True),
        ({"synthetic_turn": True}, False),
        ({"persist_user_display_kind": "wake"}, False),
        ({"platform": "cron"}, False),
        ({"delegate_depth": 1}, False),
    ], ids=["typed", "bot", "human-author", "synthetic", "wake", "cron", "delegated"])
    def test_run_conversation_binds_who_authored_the_turn_for_its_tools(self, monkeypatch, turn, owner):
        from types import SimpleNamespace

        from agent import conversation_loop
        from agent.turn_author import is_owner_turn

        seen = []
        monkeypatch.setattr(conversation_loop, "_run_conversation_turn",
                            lambda agent, *a, **kw: seen.append(is_owner_turn()) or {})
        monkeypatch.setattr(conversation_loop, "_close_durable_failed_turn", lambda *a, **kw: None)
        agent = SimpleNamespace(platform=turn.get("platform", "telegram"), _delegate_depth=turn.get("delegate_depth", 0))
        kwargs = {k: v for k, v in turn.items() if k in {"turn_author", "synthetic_turn", "persist_user_display_kind"}}
        conversation_loop.run_conversation(agent, "hi", **kwargs)
        assert seen == [owner]
        assert is_owner_turn() is False
