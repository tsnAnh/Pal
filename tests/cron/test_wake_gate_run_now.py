from unittest.mock import patch

import pytest

GATED_OUTPUT = '{"wakeAgent": false}'


@pytest.fixture
def gated_job(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    from cron.jobs import create_job

    return create_job(prompt="triage", schedule="every 5m", name="gated", script="gate.py")


def _claim_via(path, job):
    import tools.cronjob_tools as tools
    from cron import jobs

    if path == "schedule":
        return jobs.claim_job_for_fire(job["id"], return_job=True)
    if path == "queued_run_now":
        jobs.trigger_job(job["id"])
        return jobs.claim_job_for_fire(job["id"], return_job=True)
    claimed = []

    def capture(claimed_job, **_):
        claimed.append(claimed_job)
        return True

    run = {"run_now": tools._execute_job_now, "webhook": lambda j: tools.execute_job_for_event(j["id"])}[path]
    with patch("cron.scheduler.run_one_job", side_effect=capture):
        run(job)
    return claimed[0]


def _gate_outcome(claimed):
    from cron import scheduler

    with patch.object(scheduler, "_run_job_script_with_claim_heartbeat", return_value=(True, GATED_OUTPUT)):
        early, prompt = scheduler._prepare_job_prompt(claimed, claimed["id"], "gated", None, None)
    return early, prompt


@pytest.mark.parametrize("path", ["run_now", "queued_run_now"])
def test_human_run_now_wakes_a_gated_job_with_the_script_output(gated_job, path):
    early, prompt = _gate_outcome(_claim_via(path, gated_job))

    assert early is None
    assert GATED_OUTPUT in prompt


@pytest.mark.parametrize("path", ["schedule", "webhook"])
def test_scheduled_and_webhook_fires_stay_gated(gated_job, path):
    early, prompt = _gate_outcome(_claim_via(path, gated_job))

    assert prompt is None
    assert early[2] == "[SILENT]"
