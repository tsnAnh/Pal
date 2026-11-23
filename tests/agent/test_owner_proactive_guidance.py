import re
import textwrap
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from agent.prompt_builder import (
    OPENAI_MODEL_EXECUTION_GUIDANCE,
    OWNER_PROACTIVE_GUIDANCE,
    TASK_COMPLETION_GUIDANCE,
)
from agent.system_prompt import build_system_prompt_parts
from tools import bot_mode_probe

HEADING = "# Working for your owner"
PRECEDENCE = "never acting past an approval gate"
GATED_SOUL = "# Upwork Manager\n\nNever send a proposal without the owner.\n"


def _agent(**overrides):
    base = dict(
        load_soul_identity=False,
        skip_context_files=False,
        valid_tool_names=["terminal", "read_file"],
        _task_completion_guidance=True,
        _tool_use_enforcement=False,
        _environment_probe=False,
        _kanban_worker_guidance="",
        _memory_store=None,
        _memory_manager=None,
        model="",
        provider="",
        platform="",
        pass_session_id=False,
        session_id="",
        _emit_status=lambda *_a, **_k: None,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


def _stable(agent):
    with (
        patch("agent.prompt_builder.load_soul_md", return_value=""),
        patch("agent.prompt_builder.build_environment_hints", return_value=""),
        patch("agent.prompt_builder.build_context_files_prompt", return_value=""),
    ):
        return build_system_prompt_parts(agent)["stable"]


def _whole_prompt(agent) -> str:
    parts = build_system_prompt_parts(agent)
    return "\n\n".join(parts[tier] for tier in ("stable", "context", "volatile") if parts[tier])


def _sentences(text: str) -> set[str]:
    return {s.strip() for s in re.split(r"(?<=[.;:])\s+|\n+", text) if len(s.split()) >= 5}


SESSION_KINDS = {
    "cli": dict(platform="cli"),
    "desktop": dict(platform="desktop"),
    "bot_chat_telegram": dict(platform="telegram"),
    "cron": dict(platform="cron"),
    "subagent_child": dict(platform="cli", valid_tool_names=["terminal"], _kanban_worker_guidance=""),
    "toolless_oneshot": dict(platform="cli", valid_tool_names=[]),
}


@pytest.mark.parametrize("kind", sorted(SESSION_KINDS))
def test_every_session_kind_carries_the_block_once(kind):
    stable = _stable(_agent(**SESSION_KINDS[kind]))
    assert stable.count(HEADING) == 1
    assert stable.count(OWNER_PROACTIVE_GUIDANCE) == 1
    assert "do the likeliest best thing now" in stable
    assert "Bring the solution, not the question" in stable
    assert "Never hand your owner your stuck work or a terminal command" in stable
    assert "Never ask your owner which model or effort" in stable
    assert stable.count("Every ask offers choices") == 1
    assert "plus at most one alternative" not in stable
    assert "ONE short question line" not in stable
    assert PRECEDENCE in stable


@pytest.fixture
def hermes_home(tmp_path, monkeypatch) -> Path:
    root = tmp_path / ".hermes"
    root.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def _soul_agent(**overrides):
    return _agent(load_soul_identity=True, skip_context_files=True, **overrides)


def test_a_new_bot_without_soul_gets_the_block_once(hermes_home):
    prompt = _whole_prompt(_soul_agent())

    assert prompt.count(OWNER_PROACTIVE_GUIDANCE) == 1
    assert "You are Hermes Agent" in prompt


def test_an_existing_bot_with_an_older_soul_gets_the_block_without_a_soul_edit(hermes_home):
    soul = hermes_home / "SOUL.md"
    soul.write_text(GATED_SOUL, encoding="utf-8")

    prompt = _whole_prompt(_soul_agent())

    assert prompt.count(OWNER_PROACTIVE_GUIDANCE) == 1
    assert GATED_SOUL.strip() in prompt
    assert prompt.index(GATED_SOUL.strip()) < prompt.index(HEADING)
    assert PRECEDENCE in prompt
    assert soul.read_text(encoding="utf-8") == GATED_SOUL


def test_block_shares_no_sentence_with_the_other_guidance():
    block = _sentences(OWNER_PROACTIVE_GUIDANCE)
    assert block
    assert not block & _sentences(TASK_COMPLETION_GUIDANCE)
    assert not block & _sentences(OPENAI_MODEL_EXECUTION_GUIDANCE)


@pytest.mark.parametrize("path_hint", [".env", "auth.json", "credentials", ".ssh", ".config/gh", "keychain", "~/."])
def test_rule_text_names_no_secret_path(path_hint):
    assert path_hint not in OWNER_PROACTIVE_GUIDANCE


def test_rule_text_stays_short():
    assert len(OWNER_PROACTIVE_GUIDANCE.split()) < 345


@pytest.fixture
def bot_mode_home(tmp_path, monkeypatch) -> Path:
    bot_mode_probe._reset_cache_for_tests()
    root = tmp_path / ".hermes"
    profile = root / "profiles" / "upwork-manager"
    profile.mkdir(parents=True)
    (profile / "profile.yaml").write_text(
        textwrap.dedent(
            """\
            description: upwork manager for tests
            ui_meta:
              hermes-bots:
                shape: cloud
            """
        ),
        encoding="utf-8",
    )
    (root / "SOUL.md").write_text(GATED_SOUL, encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(root))
    yield root
    bot_mode_probe._reset_cache_for_tests()


def _bot_chat_agent():
    return _soul_agent(_session_title_hint=bot_mode_probe.BOT_CHAT_TITLE)


def test_a_bot_mode_bot_gets_the_block_exactly_once_across_the_assembled_prompt(bot_mode_home):
    prompt = _whole_prompt(_bot_chat_agent())

    assert "## How you talk" in prompt
    assert prompt.count(OWNER_PROACTIVE_GUIDANCE) == 1
    assert prompt.count(HEADING) == 1
    assert GATED_SOUL.strip() in prompt
    assert PRECEDENCE in prompt
    assert not _sentences(bot_mode_probe._HOUSE_STYLE) & _sentences(OWNER_PROACTIVE_GUIDANCE)


def test_house_style_no_longer_tells_the_bot_to_leave_every_choice_to_the_owner(bot_mode_home):
    prompt = _whole_prompt(_bot_chat_agent())

    assert "do not decide for them" not in prompt
    assert "ask what you should own" not in prompt
    assert "propose the job your name and role imply" in bot_mode_probe._own_job_paragraph("upwork-manager", "")
    assert "as a single yes or no, and set it up only after they agree" in prompt


def test_the_protocol_bump_makes_a_stored_bot_chat_prompt_stale_once(bot_mode_home):
    with patch.object(bot_mode_probe, "_BOT_MODE_PROTOCOL_VERSION", 6):
        bot_mode_probe._reset_cache_for_tests()
        stored = _whole_prompt(_bot_chat_agent())
    bot_mode_probe._reset_cache_for_tests()

    assert bot_mode_probe.stored_prompt_capability_stale(stored, bot_mode_home)
    rebuilt = _whole_prompt(_bot_chat_agent())
    assert not bot_mode_probe.stored_prompt_capability_stale(rebuilt, bot_mode_home)
    assert (bot_mode_home / "SOUL.md").read_text(encoding="utf-8") == GATED_SOUL


def test_the_choices_rule_lives_in_the_block_once_and_the_clarify_text_points_at_it():
    from tools.clarify_tool import CLARIFY_SCHEMA

    assert OWNER_PROACTIVE_GUIDANCE.count("Every ask offers choices") == 1
    assert OWNER_PROACTIVE_GUIDANCE.count("suggested default") == 1
    assert "Every ask offers choices" not in CLARIFY_SCHEMA["description"]
    assert "`default`" in CLARIFY_SCHEMA["description"]
    assert not _sentences(OWNER_PROACTIVE_GUIDANCE) & _sentences(CLARIFY_SCHEMA["description"])
