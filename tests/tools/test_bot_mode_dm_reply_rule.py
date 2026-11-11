"""A bot answering a bot writes terse English; only the owner line keeps the owner's language."""

import pytest

from tools import bot_mode_dm, bot_mode_probe

from tests.tools.test_bot_mode_dm import _FakeAgent, _canonical_target, _capture_spawn, _fresh_probe_cache, _managed_home

RULE_PHRASES = (
    "Replying to a bot: write English only, a few terse factual lines: result, evidence (link or id), blocker.",
    "No greeting, no owner name, no honorific, no emoji, no chat tone.",
    "The one line you write to your owner at the start of this turn stays in the owner's language; nothing else does.",
    "A message you compose for another bot follows the same rule.",
)


def _assert_rule(text):
    missing = [phrase for phrase in RULE_PHRASES if phrase not in text]
    assert not missing, missing


def test_delivered_wrapper_carries_the_rule_after_the_body(tmp_path, monkeypatch):
    home = _managed_home(tmp_path)
    authority = _canonical_target(monkeypatch, home / "profiles" / "researcher")
    _capture_spawn(monkeypatch)

    bot_mode_dm.message_agent_tool("researcher", "Summarize the Q3 report.", agent=_FakeAgent(home))

    delivered = authority.calls[0][1]["message"]
    _assert_rule(delivered)
    assert delivered.split(": ", 1)[1].startswith("Summarize the Q3 report.")


def test_notify_only_wrapper_has_no_reply_rule(tmp_path, monkeypatch):
    home = _managed_home(tmp_path)
    authority = _canonical_target(monkeypatch, home / "profiles" / "researcher")
    _capture_spawn(monkeypatch)

    bot_mode_dm.message_agent_tool("researcher", "FYI deploy done.", agent=_FakeAgent(home), expects_reply=False)

    assert "Replying to a bot" not in authority.calls[0][1]["message"]


def test_message_agent_description_carries_the_rule():
    _assert_rule(bot_mode_dm.message_agent_tool_schema()["function"]["description"])


@pytest.mark.usefixtures("_fresh_probe_cache")
def test_protocol_paragraph_carries_the_rule(tmp_path):
    _assert_rule(bot_mode_probe.get_bot_mode_protocol_section(_managed_home(tmp_path)))
