from types import SimpleNamespace
from unittest.mock import patch

import pytest

from agent.prompt_builder import OWNER_SELF_FIX_GUIDANCE
from agent.system_prompt import build_system_prompt_parts


def _agent(**overrides):
    base = dict(
        load_soul_identity=False,
        skip_context_files=False,
        valid_tool_names=["terminal", "read_file"],
        _task_completion_guidance=False,
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


SESSION_KINDS = {
    "cli": dict(platform="cli"),
    "desktop": dict(platform="desktop"),
    "bot_chat_telegram": dict(platform="telegram"),
    "cron": dict(platform="cron"),
    "subagent_child": dict(platform="cli", valid_tool_names=["terminal"], _kanban_worker_guidance=""),
    "toolless_oneshot": dict(platform="cli", valid_tool_names=[]),
}


@pytest.mark.parametrize("kind", sorted(SESSION_KINDS))
def test_every_session_kind_carries_both_rules(kind):
    stable = _stable(_agent(**SESSION_KINDS[kind]))
    assert "run it yourself and report the result" in stable
    assert "never hand your owner a terminal command" in stable
    assert "sign-in flow" in stable
    assert "Never ask your owner which model or reasoning effort" in stable


@pytest.mark.parametrize("path_hint", [".env", "auth.json", "credentials", ".ssh", ".config/gh", "keychain", "~/."])
def test_rule_text_names_no_secret_path(path_hint):
    assert path_hint not in OWNER_SELF_FIX_GUIDANCE


def test_rule_text_stays_short():
    assert len(OWNER_SELF_FIX_GUIDANCE.split()) < 120
