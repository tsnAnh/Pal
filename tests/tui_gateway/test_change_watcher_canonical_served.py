"""A canonical multiplexed runner's served profiles are watched like legacy-hosted ones."""

import sqlite3
from types import SimpleNamespace

import pytest

from gateway.run_profile_reconcile import GatewayProfileReconcileMixin
from tui_gateway import server, served_homes


@pytest.fixture()
def canonical_watcher(tmp_path, monkeypatch):
    home = tmp_path / "home"
    bot_home = home / "profiles" / "bot"
    bot_home.mkdir(parents=True)
    (home / "config.yaml").write_text("display: {}\n")
    monkeypatch.setattr(server, "_hermes_home", str(home))
    monkeypatch.setattr(server, "_cfg_cache", None)
    monkeypatch.setattr(server, "_change_sigs", {})
    monkeypatch.setattr(server, "_change_checked_at", {})
    monkeypatch.setattr(server, "_change_broadcast_at", {})
    monkeypatch.setattr(server, "_sessions_db_sig_cache", {})
    monkeypatch.setattr(server, "_served_profile_homes", set())
    events = []
    monkeypatch.setattr(server, "_broadcast_global_event", lambda ev, payload=None: events.append((ev, payload)))
    served_homes.replace({})
    yield home, bot_home, events
    served_homes.replace({})


def _runner():
    return SimpleNamespace(_served_profile_homes=None, _served_profile_signatures={})


def _write_session(db_path, title):
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, title TEXT, last_activity_at REAL, message_count INTEGER)")
    conn.execute("INSERT OR REPLACE INTO sessions(id, title, last_activity_at, message_count) VALUES ('s1', ?, 1, 1)", (title,))
    conn.commit()
    conn.close()


def test_turn_in_a_runner_served_profile_broadcasts_sessions_changed(canonical_watcher):
    home, bot_home, events = canonical_watcher
    GatewayProfileReconcileMixin._note_served_profiles(_runner(), [("default", home), ("bot", bot_home)])
    server._broadcast_watched_changes(now=0.0)

    _write_session(bot_home / "state.db", "created")
    server._broadcast_watched_changes(now=10.0)

    assert ("sessions.changed", {}) in events


@pytest.mark.asyncio
async def test_unserved_profile_leaves_the_watched_set(canonical_watcher):
    from gateway.runtime_ownership import process_ownership

    home, bot_home, _events = canonical_watcher
    runner = _runner()
    GatewayProfileReconcileMixin._note_served_profiles(runner, [("default", home), ("bot", bot_home)])
    assert bot_home in server._watched_roots(home)

    process_ownership.reserve([bot_home])
    runner._profile_failed_platforms = {}
    runner._profile_adapters = {}
    runner._agent_cache = {}
    runner._evict_cached_agent = lambda key: None
    runner.config = SimpleNamespace(_runtime_profile_homes=(("bot", str(bot_home)),))
    try:
        await GatewayProfileReconcileMixin._unserve_profile(runner, "bot", bot_home)
    finally:
        process_ownership.release(bot_home)

    assert bot_home not in server._watched_roots(home)
