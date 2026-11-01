"""cron.manage routine actions (run now, history, schedule preview, add) through the real RPC dispatch,
bound to a secondary profile's home the way Desktop calls them."""

import threading
from datetime import datetime, timedelta

import pytest

from cron import executions, jobs
from hermes_constants import get_hermes_home, reset_hermes_home_override, set_hermes_home_override
from tui_gateway import server

PROFILE = "botA"


@pytest.fixture
def profile_home(tmp_path, monkeypatch):
    home = tmp_path / "profiles" / PROFILE
    home.mkdir(parents=True)
    from hermes_cli import profiles

    monkeypatch.setattr(profiles, "get_profile_dir", lambda name: home)
    return home


def call(action, **params):
    response = server.handle_request(
        {"id": "1", "method": "cron.manage", "params": {"action": action, "profile": PROFILE, **params}})
    assert "result" in response, response
    return response["result"]


def make_job(profile_home, name="[bot:botA] brief", schedule="every 30m"):
    token = set_hermes_home_override(profile_home)
    try:
        return jobs.create_job("say hello", schedule, name=name)
    finally:
        reset_hermes_home_override(token)


class BlockedRun:
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.home = None
        self.job_id = None

    def __call__(self, job, adapters=None, loop=None, extra_prompt=None):
        self.home = get_hermes_home()
        self.job_id = job["id"]
        self.entered.set()
        self.release.wait(15)
        return True


@pytest.fixture
def blocked_run(monkeypatch):
    run = BlockedRun()
    monkeypatch.setattr("cron.scheduler.run_one_job", run)
    yield run
    run.release.set()
    for thread in threading.enumerate():
        if thread.name.startswith("cron-run-"):
            thread.join(15)


def test_list_advertises_the_routine_actions(profile_home):
    actions = call("list")["actions"]
    assert {"run", "history", "history_output", "schedule_preview", "trigger_status", "trigger_issue",
            "trigger_remove"} <= set(actions)


def test_run_returns_before_the_run_ends_and_runs_in_the_bots_profile(profile_home, blocked_run):
    job = make_job(profile_home)
    result = call("run", name=job["id"])
    assert result["started"] is True and result["success"] is True
    assert blocked_run.entered.wait(15)
    assert blocked_run.job_id == job["id"]
    assert blocked_run.home.resolve() == profile_home.resolve()
    assert not blocked_run.release.is_set()


def test_a_run_already_in_flight_is_refused_not_started_twice(profile_home, blocked_run):
    job = make_job(profile_home)
    assert call("run", name=job["id"])["started"] is True
    assert blocked_run.entered.wait(15)
    again = call("run", name=job["id"])
    assert again["started"] is False
    assert again["reason"] == "already_running"


def test_a_paused_routine_is_refused_with_a_reason(profile_home, blocked_run):
    job = make_job(profile_home)
    call("pause", name=job["id"])
    refused = call("run", name=job["id"])
    assert refused["started"] is False and refused["success"] is False
    assert refused["reason"] == "paused"
    assert not blocked_run.entered.is_set()


def test_an_unknown_routine_fails_to_start(profile_home, blocked_run):
    refused = call("run", name="no-such-routine")
    assert refused["started"] is False
    assert refused["reason"] == "not_found"


def test_a_worker_that_cannot_start_releases_the_claim(profile_home, monkeypatch):
    job = make_job(profile_home)

    class Broken:
        def start(self):
            raise RuntimeError("can't start new thread")

    monkeypatch.setattr("agent.memory_provider.spawn_context_thread", lambda *a, **kw: Broken())
    refused = call("run", name=job["id"])
    assert refused["started"] is False
    assert refused["reason"] == "unavailable"
    token = set_hermes_home_override(profile_home)
    try:
        assert jobs.claim_job_for_fire(job["id"], manual=True, return_job=True)
    finally:
        reset_hermes_home_override(token)


def test_history_reads_the_bots_own_ledger_and_hides_other_profiles(profile_home, tmp_path):
    job = make_job(profile_home)
    token = set_hermes_home_override(profile_home)
    try:
        record = executions.create_execution(job["id"], source="test")
        executions.finish_execution(record["id"], success=False, error="provider timeout")
    finally:
        reset_hermes_home_override(token)
    runs = call("history", name=job["id"])["runs"]
    assert [run["status"] for run in runs] == ["failed"]
    assert runs[0]["reason"] == "provider timeout"
    assert str(tmp_path) not in str(runs)
    launch_ledger = executions.list_executions(job_id=job["id"])
    assert launch_ledger == []


def test_history_output_round_trip_and_missing_output(profile_home):
    job = make_job(profile_home)
    token = set_hermes_home_override(profile_home)
    try:
        with_output = executions.create_execution(job["id"], source="test")
        jobs.save_job_output(job["id"], "# Cron Job\n\nall done")
        executions.finish_execution(with_output["id"], success=True)
        silent = executions.create_execution(job["id"], source="test")
        silent_claimed = datetime.now().astimezone() + timedelta(hours=1)
        with executions._transaction() as conn:
            conn.execute("UPDATE executions SET claimed_at=? WHERE id=?", (silent_claimed.isoformat(), silent["id"]))
        executions.finish_execution(silent["id"], success=False, error="no output")
    finally:
        reset_hermes_home_override(token)
    shown = call("history_output", name=job["id"], run_id=with_output["id"])
    assert shown["success"] is True and "all done" in shown["output"]
    missing = call("history_output", name=job["id"], run_id=silent["id"])
    assert missing["success"] is False and missing["reason"] == "no_output"


def test_schedule_preview_normalizes_and_rejects(profile_home):
    ok = call("schedule_preview", schedule="every weekday at 9am")
    assert ok["success"] is True and ok["schedule"] == "0 9 * * 1-5" and ok["kind"] == "cron"
    fast = call("schedule_preview", schedule="every minute")
    assert fast["success"] is False and fast["reason"] == "too_frequent"
    junk = call("schedule_preview", schedule="when pigs fly")
    assert junk["success"] is False and junk["reason"] == "unrecognized"


def test_add_stores_the_normalized_schedule_and_refuses_too_frequent(profile_home):
    created = call("add", name="[bot:botA] standup", schedule="every weekday at 9am", prompt="stand up")
    assert created["success"] is True
    assert created["job"]["schedule"] == "every weekday at 9am"
    refused = call("add", name="[bot:botA] spam", schedule="every 2 minutes", prompt="spam")
    assert refused["success"] is False and refused["reason"] == "too_frequent"
    listed = call("list", include_disabled=True)["jobs"]
    assert [job["name"] for job in listed] == ["[bot:botA] standup"]


def test_add_keeps_the_human_wording_in_every_listing(profile_home):
    created = call("add", name="[bot:botA] daily", schedule="every day at 9am", prompt="hi")
    assert created["job"]["schedule"] == "every day at 9am"
    listed = call("list", include_disabled=True)["jobs"]
    assert listed[0]["schedule"] == "every day at 9am"
    token = set_hermes_home_override(profile_home)
    try:
        stored = next(job for job in jobs.load_jobs() if job["name"] == "[bot:botA] daily")
    finally:
        reset_hermes_home_override(token)
    assert stored["schedule"]["expr"] == "0 9 * * *"


def test_add_stores_an_interval_phrase_as_the_parser_displays_it(profile_home):
    created = call("add", name="[bot:botA] hourly", schedule="every 2 hours", prompt="hi")
    assert created["job"]["schedule"] == "every 120m"


@pytest.fixture
def trigger_removals(monkeypatch):
    from hermes_cli import webhook_routine_trigger

    removed = []
    monkeypatch.setattr(
        webhook_routine_trigger, "remove_routine_trigger", lambda profile, job_id: removed.append(job_id) or True)
    return removed


def test_a_failed_remove_keeps_the_routines_webhook_trigger(profile_home, trigger_removals, monkeypatch):
    job = make_job(profile_home)
    monkeypatch.setattr("tools.cronjob_tools.remove_job", lambda job_id: False)

    result = call("remove", name=job["id"])

    assert result["success"] is False
    assert trigger_removals == []


def test_a_successful_remove_drops_the_routines_webhook_trigger(profile_home, trigger_removals):
    job = make_job(profile_home)

    result = call("remove", name=job["id"])

    assert result["success"] is True
    assert trigger_removals == [job["id"]]
