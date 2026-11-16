"""The owner's name is for greetings and real need, never a required prefix on routine replies.

These tests prove instruction wiring in the assembled prompt, not model compliance; no generation eval runs.
"""

import re
import textwrap
from pathlib import Path
from types import SimpleNamespace

import pytest

from agent.system_prompt import build_system_prompt_parts
from tools import bot_mode_probe
from tools.bot_dm_wire import BOT_REPLY_RULE

KIT_STYLE_SOUL = "# Scout\n\nAddress the owner by their name, as a junior would.\n"


@pytest.fixture(autouse=True)
def _fresh_cache():
    bot_mode_probe._reset_cache_for_tests()
    yield
    bot_mode_probe._reset_cache_for_tests()


@pytest.fixture
def home(tmp_path, monkeypatch) -> Path:
    root = tmp_path / ".hermes"
    profile = root / "profiles" / "scout"
    profile.mkdir(parents=True)
    (profile / "profile.yaml").write_text(
        textwrap.dedent(
            """\
            description: scout for tests
            ui_meta:
              hermes-bots:
                shape: cloud
            """
        ),
        encoding="utf-8",
    )
    (root / "SOUL.md").write_text(KIT_STYLE_SOUL, encoding="utf-8")
    (root / "bot-mode").mkdir()
    (root / "bot-mode" / "about-you.yaml").write_text("name: Quillon\n", encoding="utf-8")
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root


def _agent(title: str):
    return SimpleNamespace(
        load_soul_identity=True, skip_context_files=True, valid_tool_names=[], _task_completion_guidance=False,
        _tool_use_enforcement=False, _environment_probe=False, _kanban_worker_guidance="", _memory_store=None,
        _memory_manager=None, model="", provider="", platform="", pass_session_id=False, session_id="",
        _session_title_hint=title, _emit_status=lambda *_a, **_k: None,
    )


def _prompt(title: str = bot_mode_probe.BOT_CHAT_TITLE) -> str:
    parts = build_system_prompt_parts(_agent(title))
    return "\n\n".join(parts[tier] for tier in ("stable", "context", "volatile") if parts[tier])


def _style(prompt: str) -> str:
    return prompt[prompt.index("## How you talk"):prompt.index("## Steps only a person can do")]


def test_bot_chat_prompt_orders_identity_before_house_style(home):
    prompt = _prompt()

    assert KIT_STYLE_SOUL.strip() in prompt
    assert prompt.index(KIT_STYLE_SOUL.strip()) < prompt.index("## How you talk")


def test_house_style_scopes_the_name_to_greetings_and_need_not_routine_replies(home):
    style = _style(_prompt())

    assert "in a real greeting, or when the context needs it" in style
    for routine in ("Routine answers", "acknowledgments", "progress updates", "results"):
        assert routine in style
    assert "not the name or a title" in style
    assert "required prefix on every message" in style


def test_house_style_keeps_respectful_forms_language_and_owner_facts(home):
    prompt = _prompt()
    style = _style(prompt)

    assert "respectful forms of address" in style
    assert "em with anh or chị" in style
    assert "Answer in your owner's language" in style
    assert '"Quillon"' in prompt


def test_bot_reply_rule_is_unchanged_and_still_bans_name_and_honorific(home):
    prompt = _prompt()

    assert BOT_REPLY_RULE in prompt
    assert "write English only" in BOT_REPLY_RULE
    assert "No greeting, no owner name, no honorific" in BOT_REPLY_RULE
    assert "owner's language" in BOT_REPLY_RULE


def test_house_style_adds_no_name_requirement_to_bot_replies(home):
    style = _style(_prompt())

    assert not re.search(r"(?i)\b(must|always|every)\b[^.]*\b(address|use)\b[^.]*\bname\b", style)


@pytest.mark.parametrize("title", ["", "Some other chat"])
def test_non_bot_chat_sessions_get_no_house_style_and_keep_identity(home, title):
    prompt = _prompt(title)

    assert "## How you talk" not in prompt
    assert KIT_STYLE_SOUL.strip() in prompt


def test_prompt_is_byte_stable_within_an_unchanged_epoch(home):
    first = _prompt()
    bot_mode_probe._reset_cache_for_tests()

    assert _prompt() == first
    assert not bot_mode_probe.stored_prompt_capability_stale(first, home)


def test_policy_change_refreshes_stored_prompts_exactly_once(home, monkeypatch):
    stored = _prompt()
    monkeypatch.setattr(bot_mode_probe, "_BOT_MODE_PROTOCOL_VERSION", bot_mode_probe._BOT_MODE_PROTOCOL_VERSION + 1)

    assert bot_mode_probe.stored_prompt_capability_stale(stored, home)
    assert not bot_mode_probe.stored_prompt_capability_stale(_prompt(), home)
