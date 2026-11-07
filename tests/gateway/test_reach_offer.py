"""reach.offer end to end against a real per-profile state.db and fake transports: ranked fall-through,
ack/decline-by-silence, policy gating, quiet-hours deferral, and the suggestion outcome bridge."""

import asyncio
import time

import pytest

from gateway import reach, reach_log
from gateway.reach_presence import Attention, AttentionState, ClientKind
from tests.gateway.reach_harness import (
    FakeAppTransport, add_chat_message, attach, attempts, make_authority, make_home, offer_item, rows,
    run_with_owner, telegram_runner,
)
from tests.waiting import async_wait_until

ACK = 0.3


@pytest.fixture
def home(tmp_path, monkeypatch):
    path = make_home(tmp_path, "profile")
    monkeypatch.setenv("HERMES_HOME", str(path))
    import hermes_time
    hermes_time.reset_cache()
    reach_log._recovered.clear()
    return path


def offer_once(home, authority, item, **kwargs):
    async def scenario():
        return await reach.offer(home, item, ack_timeout=ACK, **kwargs)
    return run_with_owner(authority, scenario)


def test_an_acknowledged_app_alert_stops_the_walk(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop", attention=AttentionState.FOREGROUND)
    ios = FakeAppTransport(home, "iPhone", attention=AttentionState.BACKGROUND, kind=ClientKind.IOS)

    async def scenario():
        attach(authority, desktop, "t-desktop")
        attach(authority, ios, "t-ios")
        return await reach.offer(home, offer_item(), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.ALERTED and delivery.route.label == "Desktop"
    assert len(desktop.frames) == 1 and ios.frames == []
    payload = desktop.frames[0]["params"]["payload"]
    from tui_gateway.contracts.canonical_reach import ReachOfferPayload
    assert ReachOfferPayload.model_validate(payload).offer_id == delivery.offer_id
    assert desktop.frames[0]["params"]["type"] == "reach.offer"
    assert payload["title"] == "Daily digest" and payload["kind"] == "notify" and payload["domain"] == "cron"
    [row] = rows(home)
    assert row["status"] == "alerted" and row["outcome"] == "shown" and row["outcome_device"] == desktop.device.device_id
    assert attempts(row) == ["ack"]


def test_a_silent_app_socket_falls_through_after_the_timeout_to_the_next_route(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop", acks=False)
    ios = FakeAppTransport(home, "iPhone", attention=AttentionState.BACKGROUND, kind=ClientKind.IOS)

    async def scenario():
        attach(authority, desktop, "t-desktop")
        attach(authority, ios, "t-ios")
        return await reach.offer(home, offer_item(), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.route.label == "iPhone" and [r.label for r in delivery.tried] == ["Desktop", "iPhone"]
    assert len(desktop.frames) == 1 and len(ios.frames) == 1
    assert attempts(rows(home)[0]) == ["no_ack", "ack"]


def test_nobody_acknowledging_lands_silent_and_records_every_attempt(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop", acks=False)

    async def scenario():
        attach(authority, desktop, "t-desktop")
        return await reach.offer(home, offer_item(), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.LANDED_SILENT and delivery.reason == "unacknowledged"
    [row] = rows(home)
    assert row["status"] == "landed_silent" and attempts(row) == ["no_ack"] and row["alerted_at"] is None


def test_transports_that_decline_offers_or_went_silent_are_never_tried(home):
    authority = make_authority(home)
    declining = FakeAppTransport(home, "Old client", accepts=False)
    stale = FakeAppTransport(home, "Stale")
    stale.last_frame_at = time.time() - 600

    async def scenario():
        attach(authority, declining, "t-declining")
        attach(authority, stale, "t-stale")
        return await reach.offer(home, offer_item(), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.reason == "no_route" and declining.frames == [] and stale.frames == []


def test_an_unreachable_app_falls_back_to_the_most_recent_messaging_chat_before_the_home_channel(home):
    runner = telegram_runner("home-chat")
    authority = make_authority(home, runner)
    add_chat_message(home, "telegram", "recent-chat", at=time.time() - 60)
    delivery = offer_once(home, authority, offer_item())
    assert delivery.disposition is reach.Disposition.ALERTED
    assert runner.sent[0][:2] == ("telegram", "recent-chat")
    assert delivery.route.attention is Attention.REACHABLE


def test_a_messaging_chat_outside_the_window_is_not_a_route_and_the_home_channel_takes_over(home):
    runner = telegram_runner("home-chat")
    authority = make_authority(home, runner)
    add_chat_message(home, "telegram", "stale-chat", at=time.time() - 3 * 3600)
    add_chat_message(home, "local", "desktop-chat", at=time.time() - 30)
    offer_once(home, authority, offer_item())
    assert [(platform, chat) for platform, chat, _ in runner.sent] == [("telegram", "home-chat")]


def test_the_messaging_window_comes_from_the_profile_config(home):
    (home / "config.yaml").write_text(
        "proactive:\n  enabled: true\n  quiet_hours: null\n  messaging_window_minutes: 240\n", encoding="utf-8")
    runner = telegram_runner("home-chat")
    authority = make_authority(home, runner)
    add_chat_message(home, "telegram", "two-hours-ago", at=time.time() - 2 * 3600)
    offer_once(home, authority, offer_item())
    assert runner.sent[0][1] == "two-hours-ago"


def test_an_app_ack_beats_messaging_and_a_failed_messaging_send_falls_to_the_next_home(home):
    runner = telegram_runner("home-chat")
    runner.send_ok = False
    authority = make_authority(home, runner)
    delivery = offer_once(home, authority, offer_item())
    assert delivery.disposition is reach.Disposition.LANDED_SILENT
    assert attempts(rows(home)[0]) == ["send_failed"]


def test_an_acknowledgement_from_another_transport_does_not_settle_the_alert(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop", acks=False)
    bystander = FakeAppTransport(home, "Bystander", acks=False, accepts=False)

    async def scenario():
        attach(authority, desktop, "t-desktop")
        attach(authority, bystander, "t-bystander")
        task = asyncio.ensure_future(reach.offer(home, offer_item(), ack_timeout=ACK))
        frame = await async_wait_until(lambda: desktop.frames and desktop.frames[0], what="alert written")
        await reach.record_outcome(home, frame["params"]["payload"]["offer_id"], reach.Outcome.SHOWN,
                                   bystander.device, transport=bystander)
        return await task

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.LANDED_SILENT and attempts(rows(home)[0]) == ["no_ack"]


def test_the_same_producer_key_alerts_once(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        first = await reach.offer(home, offer_item("cron:job:7"), ack_timeout=ACK)
        second = await reach.offer(home, offer_item("cron:job:7"), ack_timeout=ACK)
        return first, second

    first, second = run_with_owner(authority, scenario)
    assert first.offer_id == second.offer_id and second.disposition is reach.Disposition.ALERTED
    assert len(desktop.frames) == 1 and len(rows(home)) == 1


def test_a_hermes_initiated_offer_is_suppressed_while_proactive_is_off_and_lands_nothing(home):
    (home / "config.yaml").write_text("proactive:\n  quiet_hours: null\n", encoding="utf-8")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")
    landed = []

    async def scenario():
        attach(authority, desktop, "t-desktop")
        lane = reach.DurableLane(land=lambda: landed.append("landed"))
        return await reach.offer(
            home, offer_item(consent=reach.Consent.INITIATED, lane=lane), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.SUPPRESSED and delivery.reason == "disabled"
    assert desktop.frames == [] and landed == []
    assert rows(home)[0]["status"] == "suppressed"


def test_a_user_requested_offer_alerts_while_proactive_is_off_and_lands_in_its_lane(home):
    (home / "config.yaml").write_text("proactive:\n  quiet_hours: null\n", encoding="utf-8")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")
    landed = []

    async def scenario():
        attach(authority, desktop, "t-desktop")
        lane = reach.DurableLane(land=lambda: landed.append("landed"))
        return await reach.offer(home, offer_item(lane=lane), ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.ALERTED and landed == ["landed"]


def test_the_local_chat_lane_receives_the_content_once_through_the_existing_delivery(home, monkeypatch):
    calls = []
    monkeypatch.setattr("gateway.session_cron.deliver_to_local_chat",
                        lambda h, chat, text, **kw: calls.append((str(h), chat, text)))
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        item = offer_item(lane=reach.DurableLane(session_id="chat-1"))
        return await reach.offer(home, item, ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert calls == [(str(home), "chat-1", "Three things changed.")] and delivery.error is None
    assert desktop.frames[0]["params"]["payload"]["session_id"] == "chat-1"


def test_a_lane_failure_is_reported_to_the_producer_even_when_the_alert_went_out(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        return await reach.offer(home, offer_item(lane=reach.DurableLane(land=lambda: "no committed route")),
                                 ack_timeout=ACK)

    delivery = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.ALERTED and delivery.error == "no committed route"


def test_without_an_owning_gateway_nothing_is_claimed(home):
    delivery = asyncio.run(reach.offer(home, offer_item(), ack_timeout=ACK))
    assert delivery.disposition is reach.Disposition.UNKNOWN and delivery.reason == "no_owner"
    assert rows(home) == []


def quiet_config(window: str) -> str:
    return f"proactive:\n  enabled: true\n  min_gap_minutes: 0\n  quiet_hours: {window}\n"


def test_quiet_hours_land_now_and_re_alert_once_when_the_window_ends(home):
    (home / "config.yaml").write_text(quiet_config("{start: '00:00', end: '23:59'}"), encoding="utf-8")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")
    landed = []

    async def scenario():
        attach(authority, desktop, "t-desktop")
        item = offer_item(lane=reach.DurableLane(land=lambda: landed.append("landed")))
        first = await reach.offer(home, item, ack_timeout=ACK)
        assert desktop.frames == [] and await reach.drain_deferred(home, ack_timeout=ACK) == 0
        (home / "config.yaml").write_text(quiet_config("null"), encoding="utf-8")
        reach_log_conn = reach_log._connect(home)
        reach_log_conn.execute("UPDATE reach_offers SET not_before = ?", (time.time() - 1,))
        reach_log_conn.commit()
        reach_log_conn.close()
        resumed = await reach.drain_deferred(home, ack_timeout=ACK)
        again = await reach.drain_deferred(home, ack_timeout=ACK)
        return first, resumed, again

    first, resumed, again = run_with_owner(authority, scenario)
    assert first.disposition is reach.Disposition.DEFERRED and first.reason == "quiet_hours" and landed == ["landed"]
    assert (resumed, again) == (1, 0) and len(desktop.frames) == 1
    assert desktop.frames[0]["params"]["payload"]["body"] == "Three things changed."
    assert rows(home)[0]["status"] == "alerted"


def test_a_deferred_offer_already_shown_is_not_re_alerted(home):
    (home / "config.yaml").write_text(quiet_config("{start: '00:00', end: '23:59'}"), encoding="utf-8")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        first = await reach.offer(home, offer_item(), ack_timeout=ACK)
        await reach.record_outcome(home, first.offer_id, reach.Outcome.SHOWN, desktop.device)
        (home / "config.yaml").write_text(quiet_config("null"), encoding="utf-8")
        conn = reach_log._connect(home)
        conn.execute("UPDATE reach_offers SET not_before = ?", (time.time() - 1,))
        conn.commit()
        conn.close()
        return await reach.drain_deferred(home, ack_timeout=ACK)

    assert run_with_owner(authority, scenario) == 0 and desktop.frames == []


def make_suggestion(home, title="Daily inbox digest"):
    from cron import suggestions
    record = suggestions.add_suggestion(
        title=title, description="Summarise unread mail each morning.", source="catalog",
        job_spec={"prompt": "Summarise unread mail", "schedule": "every 1d", "name": title, "deliver": "local"},
        dedup_key=f"test:{title}")
    return record


def suggestion_offer(record):
    return offer_item(f"suggestion:{record['id']}", consent=reach.Consent.INITIATED, domain="suggestions",
                      kind=reach.OfferKind.SUGGEST, title=record["title"], body=record["description"])


def test_acting_on_a_suggestion_alert_records_the_outcome_without_accepting_it(home):
    from cron import jobs, suggestions
    record = make_suggestion(home)
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        delivery = await reach.offer(home, suggestion_offer(record), ack_timeout=ACK)
        recorded = await reach.record_outcome(home, delivery.offer_id, reach.Outcome.ACTED, desktop.device)
        replay = await reach.record_outcome(home, delivery.offer_id, reach.Outcome.ACTED, desktop.device)
        return delivery, recorded, replay

    delivery, recorded, replay = run_with_owner(authority, scenario)
    assert delivery.disposition is reach.Disposition.ALERTED and recorded and replay
    assert jobs.list_jobs(include_disabled=True) == []
    assert suggestions.get_suggestion(record["id"])["status"] == "pending"
    assert rows(home)[0]["outcome"] == "acted"


def test_dismissing_a_suggestion_alert_leaves_the_suggestion_pending(home):
    from cron import jobs, suggestions
    record = make_suggestion(home, "Weekly digest")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        delivery = await reach.offer(home, suggestion_offer(record), ack_timeout=ACK)
        await reach.record_outcome(home, delivery.offer_id, reach.Outcome.DISMISSED, desktop.device)
        return await reach.record_outcome(home, "unknown-offer", reach.Outcome.SHOWN, desktop.device)

    assert run_with_owner(authority, scenario) is False
    assert suggestions.get_suggestion(record["id"])["status"] == "pending"
    assert rows(home)[0]["outcome"] == "dismissed"
    assert jobs.list_jobs(include_disabled=True) == []


def test_adding_a_suggestion_in_the_gateway_process_offers_it_through_the_policy(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        await asyncio.to_thread(make_suggestion, home, "Standup digest")
        await async_wait_until(lambda: desktop.frames, what="suggestion alert written")
        return desktop.frames[0]["params"]["payload"]

    payload = run_with_owner(authority, scenario)
    assert payload["kind"] == "suggest" and payload["domain"] == "suggestions" and payload["title"] == "Standup digest"


def test_adding_a_suggestion_with_proactive_off_alerts_nobody(home):
    (home / "config.yaml").write_text("proactive:\n  quiet_hours: null\n", encoding="utf-8")
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        await asyncio.to_thread(make_suggestion, home, "Quiet digest")
        await async_wait_until(lambda: rows(home), what="offer judged")

    run_with_owner(authority, scenario)
    assert desktop.frames == [] and rows(home)[0]["status"] == "suppressed"


def test_a_producer_on_the_owner_loop_does_not_deadlock(home):
    authority = make_authority(home)
    desktop = FakeAppTransport(home, "Desktop")

    async def scenario():
        attach(authority, desktop, "t-desktop")
        assert reach.offer_threadsafe(home, offer_item(), wait=True) is None
        await async_wait_until(lambda: desktop.frames, what="alert written")

    run_with_owner(authority, scenario)

