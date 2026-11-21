from __future__ import annotations

from unittest.mock import patch

import pytest

from cron.scheduler import _build_job_prompt, _cron_failure_marker_error

JOB = {"id": "ee34fe86fa97", "name": "pal-mac-build-when-merged", "prompt": "Build Pal on the Mac when the PR merged."}
REFUSAL = "The device tool is not available in a scheduled run; run this task in a chat turn instead, for example with /loop in the chat."


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = tmp_path / ".hermes"
    (path / "cron" / "output").mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(path))
    return path


def _prompt(job):
    with patch("tools.skills_tool.skill_view", return_value='{"success": false, "error": "not found"}'):
        return _build_job_prompt(job)


def _register_mac(home):
    from gateway import device_connectors
    device_connectors.register_device(home, "mac-device-0001", "Work Mac", kind="mac")


def test_a_profile_with_a_registered_device_tells_the_cron_run_the_device_tool_is_not_offered(home):
    _register_mac(home)
    prompt = _prompt(JOB)
    assert REFUSAL in prompt
    assert prompt.index("[CRON_FAILURE]") < prompt.index(JOB["prompt"])


def test_a_profile_without_a_device_gets_no_device_paragraph(home):
    assert "device tool" not in _prompt(JOB)


def test_a_job_that_names_the_iphone_toolset_is_not_told_the_device_tool_is_missing(home):
    _register_mac(home)
    assert "device tool" not in _prompt({**JOB, "enabled_toolsets": ["iphone", "terminal"]})


def test_the_refusal_line_is_a_strict_agent_declared_failure():
    response = f"[CRON_FAILURE]\n{REFUSAL}"
    assert _cron_failure_marker_error(response) == REFUSAL
