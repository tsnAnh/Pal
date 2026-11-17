import copy
import threading

import pytest

from hermes_cli.config_defaults import DEFAULT_CONFIG
from tools import clarify_gateway as cm
from tools.environments import base as env_base


class _FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now


class _ClockedEvent(threading.Event):
    def __init__(self, clock, on_tick):
        super().__init__()
        self._clock = clock
        self._on_tick = on_tick

    def wait(self, timeout=None):
        if not self.is_set():
            self._clock.now += float(timeout or 0)
            self._on_tick(self._clock.now)
        return self.is_set()


@pytest.fixture
def clock(monkeypatch):
    fake = _FakeClock()
    monkeypatch.setattr(cm.time, "monotonic", fake.monotonic)
    monkeypatch.setattr(env_base.time, "monotonic", fake.monotonic)
    return fake


def _pending(clock, clarify_id, on_tick):
    entry = cm.register(clarify_id, f"sess-{clarify_id}", "Pick one", ["A", "B"])
    entry.event = _ClockedEvent(clock, on_tick)
    return entry


def test_default_config_waits_past_ten_minutes_then_resolves(clock, monkeypatch):
    beats = []
    monkeypatch.setattr(env_base, "get_activity_callback", lambda: beats.append)
    timeout = cm.resolve_clarify_timeout(copy.deepcopy(DEFAULT_CONFIG))

    def answer_after_ten_minutes(now):
        if now >= 601:
            cm.resolve_gateway_clarify("unlimited", "B")

    _pending(clock, "unlimited", answer_after_ten_minutes)
    assert cm.wait_for_response("unlimited", timeout=float(timeout)) == "B"
    assert clock.now >= 601
    assert len(beats) >= 59, "inactivity heartbeat keeps firing while the question waits"


def test_explicit_clarify_timeout_still_expires(clock):
    timeout = cm.resolve_clarify_timeout({"agent": {"clarify_timeout": 5}})
    _pending(clock, "bounded", lambda now: None)
    assert cm.wait_for_response("bounded", timeout=float(timeout)) is None
    assert clock.now == 5


def test_dismiss_resolves_as_skipped(clock):
    _pending(clock, "dismissed", lambda now: cm.resolve_gateway_clarify("dismissed", cm.SKIPPED))
    assert cm.wait_for_response("dismissed", timeout=0) == cm.SKIPPED


def test_get_clarify_timeout_defaults_to_unlimited(monkeypatch):
    monkeypatch.setattr("hermes_cli.config.load_config", lambda: copy.deepcopy(DEFAULT_CONFIG))
    assert cm.get_clarify_timeout() == 0
