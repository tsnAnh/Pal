import logging
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from gateway.autonomy import DEFAULTS, ActionClass, Level, load_autonomy, prompt_line

DEFAULT_LINE = (
    "Autonomy by action class: act on reversible edits, running tools and creating files without asking; "
    "act on scheduling jobs, then tell your owner; ask your owner before spending money and messaging people."
)


def _cfg(autonomy):
    return {"proactive": {"autonomy": autonomy}}


def test_the_owner_approved_defaults():
    autonomy = load_autonomy({})
    assert dict(autonomy.levels) == {
        ActionClass.REVERSIBLE_EDITS: Level.ACT,
        ActionClass.RUN_TOOLS: Level.ACT,
        ActionClass.CREATE_FILES: Level.ACT,
        ActionClass.SCHEDULE_JOBS: Level.ACT_AND_TELL,
        ActionClass.SPEND_MONEY: Level.ASK,
        ActionClass.MESSAGE_PEOPLE: Level.ASK,
    }
    assert autonomy.clamped == frozenset()


def test_the_shipped_config_defaults_match_the_table():
    from hermes_cli.config_defaults import DEFAULT_CONFIG

    assert DEFAULT_CONFIG["proactive"]["autonomy"] == {str(k): str(v) for k, v in DEFAULTS.items()}
    assert load_autonomy(DEFAULT_CONFIG).clamped == frozenset()


@pytest.mark.parametrize("action", ["spend_money", "message_people"])
@pytest.mark.parametrize("lower", ["act", "act_and_tell"])
def test_a_hard_floor_is_clamped_and_reported(action, lower, caplog):
    with caplog.at_level(logging.WARNING, logger="gateway.autonomy"):
        autonomy = load_autonomy(_cfg({action: lower}))
    assert autonomy.levels[ActionClass(action)] is Level.ASK
    assert autonomy.clamped == {ActionClass(action)}
    assert "clamped" in caplog.text


def test_the_owner_can_tighten_or_loosen_a_class_without_a_floor():
    autonomy = load_autonomy(_cfg({"run_tools": "ask", "schedule_jobs": "act"}))
    assert autonomy.levels[ActionClass.RUN_TOOLS] is Level.ASK
    assert autonomy.levels[ActionClass.SCHEDULE_JOBS] is Level.ACT
    assert autonomy.clamped == frozenset()


def test_unknown_classes_and_levels_are_ignored_with_a_warning(caplog):
    with caplog.at_level(logging.WARNING, logger="gateway.autonomy"):
        autonomy = load_autonomy(_cfg({"launch_rockets": "act", "create_files": "sometimes", "run_tools": None}))
    assert dict(autonomy.levels) == dict(DEFAULTS)
    assert "launch_rockets" in caplog.text and "sometimes" in caplog.text


@pytest.mark.parametrize("raw", [None, "act", ["ask"], {"proactive": "on"}])
def test_a_malformed_section_falls_back_to_the_defaults(raw):
    cfg = raw if isinstance(raw, dict) else _cfg(raw)
    assert dict(load_autonomy(cfg).levels) == dict(DEFAULTS)


def test_the_derived_prompt_line_is_exact():
    assert prompt_line(load_autonomy({})) == DEFAULT_LINE


def test_the_derived_line_follows_the_table_and_omits_an_empty_level():
    line = prompt_line(load_autonomy(_cfg({c: "ask" for c in ActionClass})))
    assert line == ("Autonomy by action class: ask your owner before reversible edits, running tools, creating files, "
                    "scheduling jobs, spending money and messaging people.")


def _agent():
    return SimpleNamespace(
        load_soul_identity=False, skip_context_files=False, valid_tool_names=["terminal"],
        _task_completion_guidance=True, _tool_use_enforcement=False, _environment_probe=False,
        _kanban_worker_guidance="", _memory_store=None, _memory_manager=None, model="", provider="",
        platform="cli", pass_session_id=False, session_id="", _emit_status=lambda *_a, **_k: None)


def _stable():
    from agent.system_prompt import build_system_prompt_parts

    with (
        patch("agent.prompt_builder.load_soul_md", return_value=""),
        patch("agent.prompt_builder.build_environment_hints", return_value=""),
        patch("agent.prompt_builder.build_context_files_prompt", return_value=""),
    ):
        return build_system_prompt_parts(_agent())["stable"]


def test_the_owner_config_file_reaches_the_prompt_once_and_keeps_the_floor(tmp_path, monkeypatch):
    from agent.prompt_builder import OWNER_PROACTIVE_GUIDANCE

    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    (tmp_path / "config.yaml").write_text(
        "proactive:\n  autonomy:\n    schedule_jobs: ask\n    message_people: act\n", encoding="utf-8")
    stable = _stable()
    expected = ("Autonomy by action class: act on reversible edits, running tools and creating files without asking; "
                "ask your owner before scheduling jobs, spending money and messaging people.")
    assert stable.count(expected) == 1
    assert stable.index(OWNER_PROACTIVE_GUIDANCE) < stable.index(expected)
    assert stable.count("Autonomy by action class") == 1
