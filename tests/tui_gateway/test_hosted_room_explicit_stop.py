"""Stop now on a room is the explicit-stop family: it ends background work and handed-off Bot Chat turns."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from tools import bot_handoff_ledger
from tools.process_registry import process_registry
from tui_gateway.hosted_room_service import HostedRoomService
from tests.tui_gateway.test_hosted_room_service import _FakeRPC, _server

MEMBERS = [
    {"member_id": "default", "profile": "default", "handle": "hermes"},
    {"member_id": "ops", "profile": "ops", "handle": "ops"},
    {"member_id": "docs", "profile": "docs", "handle": "docs"},
]


@pytest.fixture(autouse=True)
def _clean_ledger():
    bot_handoff_ledger._by_origin.clear()
    yield
    bot_handoff_ledger._by_origin.clear()


@pytest.fixture
def room_service(tmp_path: Path):
    server = _server()
    service = HostedRoomService(server, db_path=tmp_path / "state.db")
    service.rpc = _FakeRPC()
    service.local_profiles = lambda: ("default", "ops", "docs")
    service.create_room(room_id="room-1", name="Release room", members=MEMBERS)
    service.runtime = SimpleNamespace(cancel=lambda *_a, **_k: {"status": "cancelled"}, wakeup=lambda: None)
    title = "Group: room-1"
    for profile in ("default", "ops", "docs"):
        service.rpc.sessions[(profile, title)] = {"session_id": f"{profile}-room-session", "title": title}
    return service


def _capture(monkeypatch):
    stopped, interrupted = [], []
    monkeypatch.setattr(
        "tools.bot_live_delivery.authority_stop", lambda home, params: stopped.append((home, params)) or {})
    monkeypatch.setattr(
        "tools.async_delegation.interrupt_for_session", lambda **kw: interrupted.append(kw) or 1)
    return stopped, interrupted


def test_stop_now_stops_handoffs_of_every_member_even_an_idle_one(room_service, monkeypatch):
    stopped, interrupted = _capture(monkeypatch)
    for member, delivery in (("default", "d1"), ("ops", "d2"), ("ops", "d3")):
        bot_handoff_ledger.record_handoff(
            f"{member}-room-session", delivery_id=delivery * 16, profile_home=f"/homes/{member}-target",
            profile="docs")
    bot_handoff_ledger.record_handoff(
        "someone-elses-session", delivery_id="x" * 32, profile_home="/homes/other", profile="docs")

    room_service.stop_room("room-1", cancel_id="stop-now")

    assert sorted(params["id"] for _, params in stopped) == sorted(["d1" * 16, "d2" * 16, "d3" * 16])
    assert all(params["profile"] == "docs" for _, params in stopped)
    assert {kw["parent_session_id"] for kw in interrupted} == {
        "default-room-session", "ops-room-session", "docs-room-session"}
    assert [h["delivery_id"] for h in bot_handoff_ledger.take_handoffs(["someone-elses-session"])] == ["x" * 32]


def test_stop_now_is_idempotent_and_does_not_replay_a_handoff(room_service, monkeypatch):
    stopped, _ = _capture(monkeypatch)
    bot_handoff_ledger.record_handoff(
        "ops-room-session", delivery_id="a" * 32, profile_home="/homes/t", profile="docs")

    room_service.stop_room("room-1", cancel_id="one")
    room_service.stop_room("room-1", cancel_id="two")

    assert len(stopped) == 1


def test_stop_now_survives_an_unreachable_handoff_target(room_service, monkeypatch):
    _, interrupted = _capture(monkeypatch)
    attempts = []

    def refuse(home, params):
        attempts.append(params["id"])
        raise ConnectionError("authority is not ready")

    monkeypatch.setattr("tools.bot_live_delivery.authority_stop", refuse)
    for member in ("default", "ops"):
        bot_handoff_ledger.record_handoff(
            f"{member}-room-session", delivery_id=member[0] * 32, profile_home="/h", profile="docs")

    assert room_service.stop_room("room-1", cancel_id="stop") == 0
    assert sorted(attempts) == ["d" * 32, "o" * 32]
    assert len(interrupted) == 3


def test_stop_now_kills_only_the_members_own_background_processes(room_service, monkeypatch):
    _capture(monkeypatch)
    killed = []
    monkeypatch.setattr(
        process_registry, "kill_process",
        lambda pid, **kw: killed.append(pid) or {"status": "killed"})
    live = SimpleNamespace(
        id="proc-mine", exited=False, session_key="ops-room-session", owner_task_id="ops-room-session", task_id="")
    foreign = SimpleNamespace(
        id="proc-foreign", exited=False, session_key="user-chat", owner_task_id="user-chat", task_id="")
    done = SimpleNamespace(
        id="proc-done", exited=True, session_key="ops-room-session", owner_task_id="ops-room-session", task_id="")
    monkeypatch.setattr(process_registry, "_running", {p.id: p for p in (live, foreign, done)})

    room_service.stop_room("room-1", cancel_id="stop")

    assert killed == ["proc-mine"]


def test_peer_members_are_left_to_their_own_cancellation(room_service, monkeypatch):
    stopped, interrupted = _capture(monkeypatch)
    room_service._room = lambda room_id: {"members": [
        {"member_id": "far", "profile": "far", "handle": "far",
         "target": {"kind": "peer", "peer_id": "p", "installation_id": "i", "profile": "far",
                    "capability_digest": "c"}}]}

    from tui_gateway.hosted_room_stop import stop_room_member_work

    assert stop_room_member_work(room_service, "room-1") == {"delegations": 0, "processes": 0, "handoffs": 0}
    assert stopped == [] and interrupted == []
