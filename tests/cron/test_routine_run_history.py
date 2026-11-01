import json
import subprocess
import sys
from datetime import datetime, timedelta

import pytest

from cron import executions, jobs
from cron.run_history import HISTORY_LIMIT, REASON_MAX_CHARS, RunNotFound, list_job_runs, read_run_output


@pytest.fixture(autouse=True)
def _system_local_zone(monkeypatch):
    import hermes_time

    monkeypatch.setattr(hermes_time, "get_timezone", lambda: None)


@pytest.fixture
def job():
    return jobs.create_job("summarize the news", "every 30m", name="news")


def _dead_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    return child.pid


def add_run(job_id, minutes_ago, state="completed", error=None, output=None, seconds=30, live=False):
    claimed = datetime.now().astimezone() - timedelta(minutes=minutes_ago)
    finished = claimed + timedelta(seconds=seconds)
    record = executions.create_execution(job_id, source="test")
    terminal = state not in ("claimed", "running")
    with executions._transaction() as conn:
        conn.execute(
            "UPDATE executions SET claimed_at=?, started_at=?, finished_at=?, status=?, error=? WHERE id=?",
            (claimed.isoformat(), claimed.isoformat(), finished.isoformat() if terminal else None, state, error,
             record["id"]))
        if not live and not terminal:
            conn.execute("UPDATE executions SET process_id='gone', pid=?, process_started_at=NULL WHERE id=?",
                         (_dead_pid(), record["id"]))
    if output is not None:
        directory = jobs._job_output_dir(job_id)
        directory.mkdir(parents=True, exist_ok=True)
        stamp = (finished - timedelta(seconds=1)).strftime("%Y-%m-%d_%H-%M-%S")
        (directory / f"{stamp}.md").write_text(output, encoding="utf-8")
    return record["id"]


def test_history_is_bounded_to_the_twenty_most_recent_runs_newest_first(job):
    for age in range(25, 0, -1):
        add_run(job["id"], minutes_ago=age * 10)
    runs = list_job_runs(job["id"], limit=500)
    assert len(runs) == HISTORY_LIMIT == 20
    starts = [datetime.fromisoformat(run["started_at"]) for run in runs]
    assert starts == sorted(starts, reverse=True)
    newest = datetime.now().astimezone() - timedelta(minutes=10)
    assert abs((starts[0] - newest).total_seconds()) < 5


def test_each_status_is_reported_with_its_reason(job):
    ok = add_run(job["id"], 50, "completed")
    failed = add_run(job["id"], 40, "failed", error="The provider returned 500")
    cancelled = add_run(job["id"], 30, "cancelled", error="cancelled on request (Stop)")
    interrupted = add_run(job["id"], 20, "running", live=False)
    running = add_run(job["id"], 10, "running", live=True)
    add_run(job["id"], 5, "missed", error="missed x3")
    by_id = {run["run_id"]: run for run in list_job_runs(job["id"])}
    assert len(by_id) == 5
    assert by_id[ok]["status"] == "succeeded" and by_id[ok]["reason"] is None
    assert by_id[failed]["status"] == "failed" and by_id[failed]["reason"] == "The provider returned 500"
    assert by_id[cancelled]["status"] == "cancelled"
    assert by_id[interrupted]["status"] == "failed" and by_id[interrupted]["reason"]
    assert by_id[running]["status"] == "running" and by_id[running]["finished_at"] is None
    assert by_id[ok]["duration_seconds"] == pytest.approx(30, abs=1)


def test_a_failure_reason_is_short_and_never_carries_a_credential(job):
    secret = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
    add_run(job["id"], 10, "failed", error=f"401 for key {secret} " + "x" * 2000)
    reason = list_job_runs(job["id"])[0]["reason"]
    assert secret not in reason
    assert len(reason) <= REASON_MAX_CHARS


def test_outputs_pair_with_their_own_run_and_nothing_else(job):
    first = add_run(job["id"], 120, output="# Run one\nalpha")
    second = add_run(job["id"], 60, output="# Run two\nbeta")
    silent = add_run(job["id"], 30, "failed", error="boom")
    by_id = {run["run_id"]: run for run in list_job_runs(job["id"])}
    assert by_id[first]["has_output"] and by_id[second]["has_output"]
    assert by_id[silent]["has_output"] is False
    assert "alpha" in read_run_output(job["id"], first)["output"]
    assert "beta" in read_run_output(job["id"], second)["output"]
    with pytest.raises(RunNotFound):
        read_run_output(job["id"], silent)


def test_output_is_bounded_and_flagged_when_truncated(job):
    run = add_run(job["id"], 10, output="line\n" * 20000)
    result = read_run_output(job["id"], run, max_chars=1000)
    assert len(result["output"]) == 1000
    assert result["truncated"] is True
    small = add_run(job["id"], 5, output="short")
    assert read_run_output(job["id"], small)["truncated"] is False


def test_a_run_of_another_job_cannot_be_read(job):
    other = jobs.create_job("other", "every 30m", name="other")
    foreign = add_run(other["id"], 10, output="private")
    add_run(job["id"], 20, output="mine")
    with pytest.raises(RunNotFound):
        read_run_output(job["id"], foreign)
    with pytest.raises(RunNotFound):
        read_run_output(job["id"], "no-such-run")


def test_history_never_exposes_a_filesystem_path(job, tmp_path):
    add_run(job["id"], 10, output="text")
    payload = json.dumps(list_job_runs(job["id"]))
    assert str(tmp_path) not in payload
    assert ".md" not in payload
