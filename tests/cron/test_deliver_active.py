"""``deliver: active`` — target resolution, provenance-derived consent, the external-worker hand-off through
the durable queue, resolution on the gateway drain, and the outward gates it must sit behind."""

import asyncio
import json
import threading
import time

import pytest

from cron import delivery_queue, jobs, scheduler, scheduler_delivery, scheduler_tick
from gateway import reach, reach_log
from gateway.session_cron import bind_owner, unbind_owner
from tests.gateway.reach_harness import FakeAppTransport, make_authority, make_home, rows
from tests.waiting import wait_until

ENABLED = "proactive:\n  enabled: true\n  quiet_hours: null\n  min_gap_minutes: 0\n"


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = make_home(tmp_path, "profile", ENABLED)
    monkeypatch.setenv("HERMES_HOME", str(path))
    monkeypatch.delenv("_HERMES_CRON_EXTERNAL_WORKER", raising=False)
    monkeypatch.setattr(delivery_queue, "DELIVERY_DB", tmp_path / "deliveries.db")
    import hermes_time
    hermes_time.reset_cache()
    reach_log._recovered.clear()
    return path


@pytest.fixture
def landed(monkeypatch):
    recorded = []
    monkeypatch.setattr("gateway.session_cron.deliver_to_local_chat",
                        lambda h, chat, text, **kw: recorded.append((chat, text)))
    return recorded


@pytest.fixture
def gateway_owner(home, landed):
    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    authority = make_authority(home)
    transport = FakeAppTransport(home, "Desktop")
    transport.loop = loop
    authority.events["t-desktop"] = transport

    async def bind():
        bind_owner(authority)

    asyncio.run_coroutine_threadsafe(bind(), loop).result(timeout=10)
    yield authority, transport, loop
    unbind_owner(authority)
    loop.call_soon_threadsafe(loop.stop)
    thread.join(timeout=10)
    loop.close()


def job_for(deliver="active", **extra):
    return {"id": "job-1", "name": "Morning digest", "execution_id": "exec-1", "deliver": deliver,
            "origin": {"platform": "local", "chat_id": "chat-1"}, **extra}


def test_active_resolves_to_a_routing_target_not_a_platform_and_combines_with_explicit_targets():
    [target] = scheduler_delivery._resolve_delivery_targets(job_for("active"))
    assert target["platform"] == "reach" and target["chat_id"] == ""
    platforms = [t["platform"] for t in scheduler_delivery._resolve_delivery_targets(job_for("active,bot-chat"))]
    assert platforms == ["reach", "bot-chat"]


def test_an_active_job_is_not_blocked_by_the_delivery_preflight():
    from cron import scheduler_preflight
    assert scheduler_preflight._preflight_check_delivery(job_for("active")) is None


def test_the_creator_decides_consent(monkeypatch):
    seen = []
    monkeypatch.setattr("gateway.reach.offer_threadsafe", lambda h, item, **kw: seen.append(item) or reach.Delivery(
        "id", reach.Disposition.ALERTED, None, (), ""))
    from cron import scheduler_delivery_reach as active
    for created_by, expected in (("user", "requested"), (None, "requested"), ("agent", "initiated"),
                                 ("suggestion", "initiated"), ("bogus", "requested")):
        job = job_for(**({"created_by": created_by} if created_by else {}))
        job["execution_id"] = f"exec-{created_by}"
        assert active.deliver_active(job, "raw", lane_text="lane", alert_text="alert") is None
    assert [item.consent.value for item in seen] == ["requested", "requested", "initiated", "initiated", "requested"]
    assert seen[0].producer_key == "cron:job-1:exec-user" and seen[0].domain == "cron"
    assert (seen[0].title, seen[0].body, seen[0].lane_text) == ("Morning digest", "alert", "lane")
    assert seen[0].lane.session_id == "chat-1"


def test_a_failure_notice_gets_its_own_idempotency_key(monkeypatch):
    seen = []
    monkeypatch.setattr("gateway.reach.offer_threadsafe", lambda h, item, **kw: seen.append(item.producer_key))
    from cron import scheduler_delivery_reach as active
    active.deliver_active(job_for(), "raw", lane_text="l", alert_text="a")
    active.deliver_active(job_for(), "raw", lane_text="l", alert_text="a", for_failure=True)
    assert seen == ["cron:job-1:exec-1", "cron:job-1:exec-1:failure"]


def test_without_a_gateway_owning_the_profile_the_error_is_reported_not_swallowed(home):
    error = scheduler._deliver_result(job_for(), "result text", adapters=None, loop=None)
    assert "gateway" in error and "last output" in error


def test_the_active_lane_goes_through_the_redaction_gate_before_the_offer(home, monkeypatch):
    seen = []
    monkeypatch.setattr("gateway.reach.offer_threadsafe", lambda h, item, **kw: seen.append(item) or reach.Delivery(
        "id", reach.Disposition.ALERTED, None, (), ""))
    secret = "sk-" + "a1B2c3D4" * 6
    assert scheduler._deliver_result(job_for(), f"Key leaked: {secret} done", adapters=None, loop=None) is None
    assert secret not in seen[0].body and secret not in seen[0].lane_text


def test_active_inside_an_external_worker_becomes_a_queue_row_resolved_by_the_gateway_drain(
        home, gateway_owner, landed, monkeypatch):
    _authority, transport, _loop = gateway_owner
    monkeypatch.setenv("_HERMES_CRON_EXTERNAL_WORKER", "exec-1")
    worker_offers = []
    real_offer = reach.offer_threadsafe
    monkeypatch.setattr("gateway.reach.offer_threadsafe", lambda *a, **kw: worker_offers.append(a) or None)
    monkeypatch.setattr(
        "cron.delivery_queue.enqueue_and_wait",
        lambda execution_id, job, content, **kw: delivery_queue.enqueue(execution_id, job, content, **kw) and None)
    assert scheduler._deliver_result(job_for(created_by="user"), "The digest body", adapters=None, loop=None) is None
    assert worker_offers == [] and transport.frames == []
    queued = delivery_queue.get_status("exec-1")
    assert queued["status"] == "pending"

    monkeypatch.delenv("_HERMES_CRON_EXTERNAL_WORKER")
    monkeypatch.setattr("gateway.reach.offer_threadsafe", real_offer)
    assert scheduler.drain_delivery_queue({}, None) == 1
    assert delivery_queue.get_status("exec-1")["status"] == "delivered"
    payload = transport.frames[0]["params"]["payload"]
    assert payload["title"] == "Morning digest" and payload["body"] == "The digest body"
    assert landed[0][0] == "chat-1" and "The digest body" in landed[0][1]
    [row] = rows(home)
    assert row["producer_key"] == "cron:job-1:exec-1" and row["consent"] == "requested" and row["status"] == "alerted"


def test_a_redelivered_queue_row_for_the_same_execution_alerts_once(home, gateway_owner):
    _authority, transport, _loop = gateway_owner
    job = job_for(created_by="user")
    assert scheduler._deliver_result(job, "once", adapters={}, loop=None) is None
    scheduler._deliver_result(dict(job), "once", adapters={}, loop=None)
    assert len(transport.frames) == 1 and len(rows(home)) == 1


def test_the_cron_tick_re_alerts_a_deferred_offer_through_the_owning_gateway(home, gateway_owner):
    _authority, transport, _loop = gateway_owner
    (home / "config.yaml").write_text(
        "proactive:\n  enabled: true\n  min_gap_minutes: 0\n  quiet_hours: {start: '00:00', end: '23:59'}\n",
        encoding="utf-8")
    job = job_for(created_by="user")
    assert scheduler._deliver_result(job, "later", adapters={}, loop=None) is None
    assert transport.frames == [] and rows(home)[0]["status"] == "deferred"
    (home / "config.yaml").write_text(ENABLED, encoding="utf-8")
    conn = reach_log._connect(home)
    conn.execute("UPDATE reach_offers SET not_before = ?", (time.time() - 1,))
    conn.commit()
    conn.close()
    scheduler_tick._drain_deferred_reach_alerts(scheduler)
    wait_until(lambda: transport.frames, what="deferred alert written by the tick")
    scheduler_tick._drain_deferred_reach_alerts(scheduler)
    wait_until(lambda: rows(home)[0]["status"] == "alerted", what="offer finalized")
    assert len(transport.frames) == 1


def test_created_by_is_stored_validated_and_defaults_to_user():
    from cron.job_provenance import created_by_of
    stored = jobs.create_job(prompt="p", schedule="every 1h", created_by="agent")
    assert stored["created_by"] == "agent" and jobs.get_job(stored["id"])["created_by"] == "agent"
    plain = jobs.create_job(prompt="p", schedule="every 1h")
    assert "created_by" not in plain and created_by_of(plain) == "user"
    with pytest.raises(ValueError):
        jobs.create_job(prompt="p", schedule="every 1h", created_by="robot")


def test_a_distribution_import_keeps_who_created_the_job():
    from cron.job_definition import JOB_DEFINITION_FIELDS
    assert "created_by" in JOB_DEFINITION_FIELDS


def test_the_model_tool_marks_jobs_made_with_a_person_present_as_user_jobs():
    from tools import cronjob_tools
    by_model = json.loads(cronjob_tools._cronjob_handler(
        {"action": "create", "prompt": "check build", "schedule": "every 1h", "deliver": "local"}))
    created = {job["id"]: job for job in jobs.list_jobs(include_disabled=True)}
    assert created[by_model["job_id"]]["created_by"] == "user"


def test_the_model_tool_marks_jobs_made_inside_an_unattended_cron_run_as_agent_jobs(monkeypatch):
    from tools import cronjob_tools
    monkeypatch.setenv("HERMES_CRON_SESSION", "1")
    out = json.loads(cronjob_tools._cronjob_handler(
        {"action": "create", "prompt": "x", "schedule": "every 1h", "deliver": "local", "created_by": "user"}))
    assert next(j for j in jobs.list_jobs(include_disabled=True) if j["id"] == out["job_id"])["created_by"] == "agent"


def test_a_failing_offer_is_reported_as_a_delivery_error(monkeypatch):
    def boom(*args, **kwargs):
        raise TimeoutError("owner stalled")
    monkeypatch.setattr("gateway.reach.offer_threadsafe", boom)
    from cron import scheduler_delivery_reach as active
    error = active.deliver_active(job_for(), "raw", lane_text="l", alert_text="a")
    assert "TimeoutError" in error and "owner stalled" in error
