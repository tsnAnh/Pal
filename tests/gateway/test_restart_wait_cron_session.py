"""A cron fire's session turn and its scheduler claim are one unit of restart-wait work.

Regression for a restart after-turn wait held ~10 minutes by a restart-safe (scoped) cron run: the
scheduler excluded it, but the SAME run's executing session in the owning profile's authority was
counted again as anonymous managed work.
"""
import asyncio
import json
from types import SimpleNamespace

import pytest

import cron.scheduler as sched
from gateway.config import Platform
from hermes_state_keys import CRON_PRINCIPAL_ID
from tests.gateway.restart_test_helpers import make_restart_runner


def _cron_session(home, job_id, *, user_id=CRON_PRINCIPAL_ID, source="cron"):
    task = asyncio.get_running_loop().create_future()
    live = SimpleNamespace(
        task=SimpleNamespace(done=lambda: task.done()), route=f"route-{job_id}",
        source=SimpleNamespace(user_id=user_id),
        event_stream=SimpleNamespace(execution={"execution_generation": 1}))
    policy = SimpleNamespace(source=source, request_json=json.dumps({"cron_job": {"id": job_id}}))
    adapter = SimpleNamespace(policies={"sid": policy})
    runner = SimpleNamespace(adapters={Platform.LOCAL: adapter}, _running_agents={})
    return SimpleNamespace(
        sessions={"sid": live}, _managed_workers={}, runner=runner,
        db=SimpleNamespace(db_path=str(home / "state.db")))


def _gateway_runner(monkeypatch, home, authority):
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr("cron.jobs.load_jobs", list)
    runner, _ = make_restart_runner()
    runner.session_authority = authority
    runner.session_authorities = None
    return runner


@pytest.mark.asyncio
async def test_restart_safe_cron_session_turn_does_not_hold_the_wait(monkeypatch, tmp_path):
    authority = _cron_session(tmp_path, "babysit")
    runner = _gateway_runner(monkeypatch, tmp_path, authority)
    assert sched.try_register_running_job("babysit")
    try:
        sched._record_external_cron_worker("babysit", 4321, scope_isolated=True)
        assert runner._awaitable_work_count() == 0
        assert [u for u in runner._describe_active_work() if u.get("session") == "sid"] == []
    finally:
        sched.release_running_job("babysit")


@pytest.mark.asyncio
async def test_degraded_cron_session_turn_is_awaited_exactly_once(monkeypatch, tmp_path):
    authority = _cron_session(tmp_path, "babysit")
    runner = _gateway_runner(monkeypatch, tmp_path, authority)
    assert sched.try_register_running_job("babysit")
    try:
        sched._record_external_cron_worker("babysit", 4322, scope_isolated=False)
        assert runner._awaitable_work_count() == 1
    finally:
        sched.release_running_job("babysit")


@pytest.mark.asyncio
async def test_cron_session_without_a_scheduler_claim_here_is_still_awaited_and_named(monkeypatch, tmp_path):
    authority = _cron_session(tmp_path, "babysit")
    runner = _gateway_runner(monkeypatch, tmp_path, authority)
    assert runner._awaitable_work_count() == 1
    unit = next(u for u in runner._describe_active_work() if u.get("session") == "sid")
    assert unit["cron_job_id"] == "babysit" and unit["kind"] == "managed"


@pytest.mark.asyncio
async def test_other_profiles_restart_safe_run_of_same_job_id_does_not_hide_this_session(monkeypatch, tmp_path):
    mine, other = tmp_path / "mine", tmp_path / "other"
    mine.mkdir()
    other.mkdir()
    authority = _cron_session(mine, "babysit")
    runner = _gateway_runner(monkeypatch, mine, authority)
    monkeypatch.setenv("HERMES_HOME", str(other))
    assert sched.try_register_running_job("babysit")
    try:
        sched._record_external_cron_worker("babysit", 4323, scope_isolated=True)
        monkeypatch.setenv("HERMES_HOME", str(mine))
        assert runner._awaitable_work_count() == 1
    finally:
        monkeypatch.setenv("HERMES_HOME", str(other))
        sched.release_running_job("babysit")


@pytest.mark.asyncio
async def test_ordinary_executing_session_is_still_awaited(monkeypatch, tmp_path):
    authority = _cron_session(tmp_path, "babysit", user_id="someone", source="cli")
    runner = _gateway_runner(monkeypatch, tmp_path, authority)
    assert sched.try_register_running_job("babysit")
    try:
        sched._record_external_cron_worker("babysit", 4324, scope_isolated=True)
        assert runner._awaitable_work_count() == 1
    finally:
        sched.release_running_job("babysit")
