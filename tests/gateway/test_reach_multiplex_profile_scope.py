"""One gateway process serves several profiles: presence evidence, the offer log and the policy must never
cross a profile boundary, including when a ticker thread issues the offer."""

import asyncio
import threading
import time
from pathlib import Path

import pytest

import hermes_state
from gateway import reach, reach_log, reach_routes
from gateway.reach_policy import Attention, load_policy
from gateway.run import _profile_runtime_scope
from gateway.session_cron import bind_owner, unbind_owner
from tests.gateway.reach_harness import (
    FakeAppTransport, FakeRunner, add_chat_message, make_authority, make_home, offer_item, rows, telegram_runner,
)
from tests.waiting import wait_until

ENABLED = "proactive:\n  enabled: true\n  quiet_hours: null\n  min_gap_minutes: 0\n"
DISABLED = "proactive:\n  quiet_hours: null\n"


@pytest.fixture
def two_profiles(tmp_path, monkeypatch):
    from agent.secret_scope import set_multiplex_active
    root = tmp_path / "hermes"
    root.mkdir()
    home_a = make_home(root / "profiles", "alpha", DISABLED)
    home_b = make_home(root / "profiles", "beta", ENABLED)
    monkeypatch.setenv("HERMES_HOME", str(root))
    monkeypatch.setattr(hermes_state, "DEFAULT_DB_PATH", hermes_state._IMPORT_DEFAULT_DB_PATH)
    set_multiplex_active(True)
    reach_log._recovered.clear()
    try:
        yield home_a, home_b
    finally:
        set_multiplex_active(False)


@pytest.fixture
def owner_loop():
    loop = asyncio.new_event_loop()
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()
    bound = []

    def bind(authority):
        async def go():
            bind_owner(authority)
        asyncio.run_coroutine_threadsafe(go(), loop).result(timeout=10)
        bound.append(authority)

    yield loop, bind
    for authority in bound:
        unbind_owner(authority)
    loop.call_soon_threadsafe(loop.stop)
    thread.join(timeout=10)
    loop.close()


def multiplex_authority(home, runner=None):
    runner = runner or FakeRunner(multiplex=True)
    runner.config.multiplex_profiles = True
    return make_authority(home, runner)


def test_a_profile_bound_transport_is_never_a_route_for_another_profile(two_profiles):
    home_a, home_b = two_profiles
    authority_a, authority_b = multiplex_authority(home_a), multiplex_authority(home_b)
    on_b = FakeAppTransport(home_b, "iPhone (beta)")
    host_scoped = FakeAppTransport(home_a, "Desktop")
    authority_b.events["t-ios"] = on_b
    authority_a.events["t-desktop-a"] = host_scoped
    authority_b.events["t-desktop-b"] = host_scoped
    policy = load_policy({})
    labels_a = [r.label for r in reach_routes.routes(authority_a, home_a, policy)]
    labels_b = [r.label for r in reach_routes.routes(authority_b, home_b, policy)]
    assert labels_a == ["Desktop"]
    assert sorted(labels_b) == ["Desktop", "iPhone (beta)"]


def test_a_messaging_chat_in_one_profile_is_not_a_route_for_another(two_profiles):
    home_a, home_b = two_profiles
    runner_a, runner_b = telegram_runner("home-a"), telegram_runner("home-b")
    add_chat_message(home_a, "telegram", "chat-in-alpha", at=time.time() - 30)
    policy = load_policy({})
    chats_b = [r.channel.chat_id for r in reach_routes.routes(multiplex_authority(home_b, runner_b), home_b, policy)]
    chats_a = [r.channel.chat_id for r in reach_routes.routes(multiplex_authority(home_a, runner_a), home_a, policy)]
    assert chats_b == ["home-b"] and chats_a == ["chat-in-alpha", "home-a"]
    assert all(r.attention is Attention.REACHABLE for r in reach_routes.routes(
        multiplex_authority(home_a, runner_a), home_a, policy))


def test_an_offer_writes_only_its_own_profiles_state_db_and_alerts_only_its_own_sockets(two_profiles, owner_loop):
    home_a, home_b = two_profiles
    loop, bind = owner_loop
    authority_a, authority_b = multiplex_authority(home_a), multiplex_authority(home_b)
    socket_a, socket_b = FakeAppTransport(home_a, "Desktop (alpha)"), FakeAppTransport(home_b, "Desktop (beta)")
    socket_a.loop = socket_b.loop = loop
    authority_a.events["t-a"], authority_b.events["t-b"] = socket_a, socket_b
    bind(authority_a)
    bind(authority_b)
    delivery = asyncio.run_coroutine_threadsafe(
        reach.offer(home_b, offer_item("cron:job:1"), ack_timeout=2.0), loop).result(timeout=30)
    assert delivery.disposition is reach.Disposition.ALERTED
    assert [len(socket_a.frames), len(socket_b.frames)] == [0, 1]
    assert rows(home_a) == [] and [r["status"] for r in rows(home_b)] == ["alerted"]


def test_a_ticker_thread_offer_under_one_scope_reads_that_profiles_policy_and_slots_only(two_profiles, owner_loop):
    home_a, home_b = two_profiles
    loop, bind = owner_loop
    authority_a, authority_b = multiplex_authority(home_a), multiplex_authority(home_b)
    socket_a, socket_b = FakeAppTransport(home_a, "Desktop (alpha)"), FakeAppTransport(home_b, "Desktop (beta)")
    socket_a.loop = socket_b.loop = loop
    authority_a.events["t-a"], authority_b.events["t-b"] = socket_a, socket_b
    bind(authority_a)
    bind(authority_b)
    initiated = offer_item("cron:agent-made:1", consent=reach.Consent.INITIATED)
    results = {}

    def ticker(name, home):
        with _profile_runtime_scope(Path(home)):
            results[name] = reach.offer_threadsafe(home, initiated, timeout=30)

    threads = [threading.Thread(target=ticker, args=("alpha", home_a)), threading.Thread(target=ticker, args=("beta", home_b))]
    for thread in threads:
        thread.start()
    wait_until(lambda: len(results) == 2, what="both ticker offers settled")
    for thread in threads:
        thread.join()
    assert results["alpha"].disposition is reach.Disposition.SUPPRESSED and results["alpha"].reason == "disabled"
    assert results["beta"].disposition is reach.Disposition.ALERTED
    assert socket_a.frames == [] and len(socket_b.frames) == 1
    assert [r["status"] for r in rows(home_a)] == ["suppressed"] and [r["status"] for r in rows(home_b)] == ["alerted"]


def test_the_same_producer_key_in_two_profiles_is_two_independent_offers(two_profiles, owner_loop):
    home_a, home_b = two_profiles
    loop, bind = owner_loop
    for home in (home_a, home_b):
        (home / "config.yaml").write_text(ENABLED, encoding="utf-8")
    authorities = {home: multiplex_authority(home) for home in (home_a, home_b)}
    sockets = {home: FakeAppTransport(home, f"Desktop {home.name}") for home in authorities}
    for home, authority in authorities.items():
        sockets[home].loop = loop
        authority.events["t"] = sockets[home]
        bind(authority)
    for home in authorities:
        asyncio.run_coroutine_threadsafe(reach.offer(home, offer_item("cron:daily:1"), ack_timeout=2.0), loop).result(timeout=30)
    assert all(len(socket.frames) == 1 for socket in sockets.values())


def test_acting_on_a_suggestion_records_the_outcome_in_the_offering_profile_only(two_profiles, owner_loop):
    from cron import jobs, suggestions
    home_a, home_b = two_profiles
    loop, bind = owner_loop
    with _profile_runtime_scope(home_b):
        record = suggestions.add_suggestion(
            title="Beta digest", description="d", source="catalog", dedup_key="beta-digest",
            job_spec={"prompt": "digest", "schedule": "every 1d", "name": "Beta digest", "deliver": "local"})
    authority_b = multiplex_authority(home_b)
    socket_b = FakeAppTransport(home_b, "Desktop (beta)")
    socket_b.loop = loop
    authority_b.events["t-b"] = socket_b
    bind(authority_b)
    suggestion = offer_item(f"suggestion:{record['id']}", consent=reach.Consent.INITIATED, domain="suggestions",
                            kind=reach.OfferKind.SUGGEST, title="Beta digest", body="d")

    async def act():
        delivery = await reach.offer(home_b, suggestion, ack_timeout=2.0)
        await reach.record_outcome(home_b, delivery.offer_id, reach.Outcome.ACTED, socket_b.device)

    asyncio.run_coroutine_threadsafe(act(), loop).result(timeout=30)
    assert [r["outcome"] for r in rows(home_b)] == ["acted"] and rows(home_a) == []
    for home in (home_a, home_b):
        with _profile_runtime_scope(home):
            assert jobs.list_jobs(include_disabled=True) == []
    with _profile_runtime_scope(home_b):
        assert suggestions.get_suggestion(record["id"])["status"] == "pending"


def test_a_host_scoped_socket_answering_through_its_own_profile_settles_a_sibling_profiles_offer(
        two_profiles, owner_loop):
    home_a, home_b = two_profiles
    loop, bind = owner_loop
    authority_a, authority_b = multiplex_authority(home_a), multiplex_authority(home_b)
    host_scoped = FakeAppTransport(home_a, "Desktop")
    host_scoped.loop = loop
    authority_a.events["t-desktop"] = host_scoped
    authority_b.events["t-desktop"] = host_scoped
    bind(authority_a)
    bind(authority_b)
    started = time.monotonic()
    delivery = asyncio.run_coroutine_threadsafe(
        reach.offer(home_b, offer_item("cron:job:host"), ack_timeout=20.0), loop).result(timeout=30)
    assert delivery.disposition is reach.Disposition.ALERTED and time.monotonic() - started < 10
    acted = asyncio.run_coroutine_threadsafe(reach.record_outcome(
        home_a, delivery.offer_id, reach.Outcome.ACTED, host_scoped.device, transport=host_scoped), loop).result(30)
    assert acted and rows(home_a) == []
    assert [(r["status"], r["outcome"]) for r in rows(home_b)] == [("alerted", "acted")]
    stranger = FakeAppTransport(home_a, "Other")
    refused = asyncio.run_coroutine_threadsafe(reach.record_outcome(
        home_a, delivery.offer_id, reach.Outcome.DISMISSED, stranger.device, transport=stranger), loop).result(30)
    assert refused is False and rows(home_b)[0]["outcome"] == "acted"
