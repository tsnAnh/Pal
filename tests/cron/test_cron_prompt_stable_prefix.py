from __future__ import annotations

from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest

from agent import prompt_cache_boundary
from agent.prompt_cache_boundary import find_stable_prefix
from cron.scheduler import _build_job_prompt

PDT = timezone(timedelta(hours=-7), "PDT")
FIRE_1 = datetime(2026, 10, 31, 7, 0, tzinfo=PDT)
FIRE_2 = datetime(2026, 10, 31, 8, 1, tzinfo=PDT)
RUN_TIME_1 = "[CURRENT RUN TIME: Saturday, 2026-10-31 07:00 PDT (UTC-07:00)]"
RUN_TIME_2 = "[CURRENT RUN TIME: Saturday, 2026-10-31 08:01 PDT (UTC-07:00)]"


@pytest.fixture(autouse=True)
def _isolated_registry():
    with prompt_cache_boundary._lock:
        prompt_cache_boundary._prefixes.clear()
    yield
    with prompt_cache_boundary._lock:
        prompt_cache_boundary._prefixes.clear()


@pytest.fixture
def cron_env(tmp_path, monkeypatch):
    import cron.jobs as jobs_mod
    import cron.notepad as notepad_mod

    home = tmp_path / ".hermes"
    (home / "cron" / "output").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(jobs_mod, "HERMES_DIR", home)
    monkeypatch.setattr(jobs_mod, "CRON_DIR", home / "cron")
    monkeypatch.setattr(jobs_mod, "JOBS_FILE", home / "cron" / "jobs.json")
    monkeypatch.setattr(jobs_mod, "OUTPUT_DIR", home / "cron" / "output")
    monkeypatch.setattr(notepad_mod, "NOTEPAD_FILE", home / "cron" / "notepad.db")
    return home


def _render(job, when, **kwargs):
    with patch("cron.scheduler_prompt._hermes_now", return_value=when), patch(
        "tools.skills_tool.skill_view", return_value='{"success": false, "error": "not found"}'
    ):
        return _build_job_prompt(job, **kwargs)


def _boundary(message):
    boundary = find_stable_prefix(message)
    assert boundary is not None, "no stable-prefix boundary registered for this cron message"
    assert message.startswith(boundary)
    return boundary


def _first_difference(a, b):
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))


def test_two_fires_share_the_prefix_and_differ_only_after_the_boundary():
    job = {"id": "abc123", "prompt": "Check the feed and report new items."}
    first, second = _render(job, FIRE_1), _render(job, FIRE_2)

    boundary = _boundary(first)
    assert second.startswith(boundary)
    assert _first_difference(first, second) >= len(boundary)
    assert first[len(boundary):] != second[len(boundary):]


def test_run_time_with_zone_is_still_given_to_the_model_after_the_boundary():
    job = {"id": "abc123", "prompt": "Morning brief"}
    first, second = _render(job, FIRE_1), _render(job, FIRE_2)

    assert RUN_TIME_1 in first[len(_boundary(first)):]
    assert RUN_TIME_2 in second[len(_boundary(second)):]
    assert first.index("You are running as a scheduled cron job") < first.index("Morning brief")


def test_editing_the_job_prompt_moves_the_boundary():
    before = _render({"id": "abc123", "prompt": "Check the feed."}, FIRE_1)
    after = _render({"id": "abc123", "prompt": "Check the feed and the forum."}, FIRE_2)

    assert _boundary(before) != _boundary(after)
    assert "Check the feed and the forum." in _boundary(after)
    assert not after.startswith(_boundary(before))


def test_per_run_inputs_stay_in_the_tail_and_reach_the_model(cron_env):
    from cron import notepad
    from cron.jobs import create_job

    job = {**create_job(prompt="Summarize new tickets.", schedule="every 1h", context_from="self"),
           "script": "gate.py"}
    out_dir = cron_env / "cron" / "output" / job["id"]
    out_dir.mkdir(parents=True)
    (out_dir / "2026-10-31_06-00-00.md").write_text("PREVIOUS-RUN-ANSWER", encoding="utf-8")
    notepad.set_note(job["id"], "cursor", "ticket-41")

    first = _render(
        job, FIRE_1, prerun_script=(True, "SCRIPT-ROWS-1"), extra_prompt="CLIENT=acme",
        runtime_data_prompt="MONITOR-DIFF-1",
    )
    notepad.set_note(job["id"], "cursor", "ticket-77")
    (out_dir / "2026-10-31_07-00-00.md").write_text("NEWER-RUN-ANSWER", encoding="utf-8")
    second = _render(
        job, FIRE_2, prerun_script=(True, "SCRIPT-ROWS-2"), extra_prompt="CLIENT=globex",
        runtime_data_prompt="MONITOR-DIFF-2",
    )

    boundary = _boundary(first)
    assert second.startswith(boundary)
    for volatile in (
        "SCRIPT-ROWS-1", "CLIENT=acme", "MONITOR-DIFF-1", "ticket-41", "PREVIOUS-RUN-ANSWER", RUN_TIME_1,
    ):
        assert volatile not in boundary
        assert volatile in first[len(boundary):]
    for volatile in (
        "SCRIPT-ROWS-2", "CLIENT=globex", "MONITOR-DIFF-2", "ticket-77", "NEWER-RUN-ANSWER", RUN_TIME_2,
    ):
        assert volatile in second[len(_boundary(second)):]
    assert "Summarize new tickets." in boundary


def test_failed_script_report_stays_in_the_tail():
    job = {"id": "abc123", "prompt": "Check the feed.", "script": "gate.py"}
    message = _render(job, FIRE_1, prerun_script=(False, "boom: exit 2"))

    tail = message[len(_boundary(message)):]
    assert "Script Error" in tail and "boom: exit 2" in tail


def test_script_with_no_output_still_skips_the_model_call():
    job = {"id": "abc123", "prompt": "Check the feed.", "script": "gate.py"}
    assert _render(job, FIRE_1, prerun_script=(True, "")) is None


def test_prompt_less_script_job_still_gets_a_boundary():
    job = {"id": "abc123", "prompt": "", "script": "gate.py"}
    message = _render(job, FIRE_1, prerun_script=(True, "rows"))

    assert "rows" in message[len(_boundary(message)):]


def test_skill_job_keeps_skills_and_job_prompt_in_the_prefix(tmp_path, monkeypatch):
    from agent import skill_bundles, skill_commands
    from tools import skills_tool

    skills_dir = tmp_path / "skills"
    skill_dir = skills_dir / "triage"
    skill_dir.mkdir(parents=True)
    (skill_dir / "SKILL.md").write_text(
        "---\nname: triage\ndescription: Triage tickets\n---\n\n# triage\n\nSKILL-BODY-LINE\n"
    )
    monkeypatch.setattr(skills_tool, "SKILLS_DIR", skills_dir)
    monkeypatch.setattr(skill_commands, "_skill_commands_by_key", {})
    monkeypatch.setattr(skill_bundles, "_bundles_cache", {})
    monkeypatch.setattr(skill_bundles, "_bundles_cache_mtime", None)
    skill_commands.scan_skill_commands()
    job = {"id": "abc123", "prompt": "Triage the queue.", "skills": ["triage"], "script": "gate.py"}

    def render(when, script_output):
        with patch("cron.scheduler_prompt._hermes_now", return_value=when):
            return _build_job_prompt(job, prerun_script=(True, script_output))

    first, second = render(FIRE_1, "ROWS-1"), render(FIRE_2, "ROWS-2")

    boundary = _boundary(first)
    assert second.startswith(boundary)
    assert "SKILL-BODY-LINE" in boundary and "Triage the queue." in boundary
    assert "ROWS-1" not in boundary and RUN_TIME_1 not in boundary
    assert "ROWS-1" in first[len(boundary):] and RUN_TIME_1 in first[len(boundary):]


def test_a_scanner_rewrite_never_leaves_a_boundary_that_is_not_a_byte_prefix():
    job = {"id": "abc123", "prompt": "Check the feed.", "script": "gate.py"}
    message = _render(job, FIRE_1, prerun_script=(True, "row\u200bwith zero-width"))

    boundary = find_stable_prefix(message)
    assert boundary is None or message.startswith(boundary)


def test_run_now_extra_prompt_does_not_touch_the_stored_prefix():
    job = {"id": "abc123", "prompt": "Check the feed."}
    scheduled = _render(job, FIRE_1)
    run_now = _render(job, FIRE_2, extra_prompt="focus on billing")

    assert run_now.startswith(_boundary(scheduled))
    assert "focus on billing" in run_now[len(_boundary(scheduled)):]
