from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_cli import gateway_service_control as control
from hermes_cli.profiles import create_profile
from tui_gateway import server
from tui_gateway.contracts import METHODS
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed


class FakeHost:
    def __init__(self, backend="systemd", installed=True, running=True, active_runs=0, code_stale=False):
        self._backend, self._installed, self._running = backend, installed, running
        self.active, self.code_stale = active_runs, code_stale
        self.generation = 1
        self.restarts: list[tuple] = []
        self.install_ok = True

    def backend(self):
        return self._backend

    def installed(self):
        return self._installed

    def running(self):
        return self._running

    def identity(self):
        return {"instance": f"gen-{self.generation}", "started_at": 1000.0 + self.generation, "code_stale": self.code_stale}

    def active_runs(self):
        return self.active

    def install(self):
        self._installed = self.install_ok
        return self.install_ok

    def spawn_restart(self, profile, interrupt):
        self.restarts.append((profile, interrupt))


@pytest.fixture
def fake(monkeypatch, tmp_path):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(server, "_hermes_home", home)
    create_profile("scout", no_alias=True, no_skills=True)
    host = FakeHost()
    monkeypatch.setattr(control, "HostServiceControl", lambda: host)
    return host


def _rpc(method: str, params: dict | None = None) -> dict:
    return server.handle_request({"id": "1", "method": method, "params": params or {}})


def _ok(method: str, params: dict | None = None) -> dict:
    response = _rpc(method, params)
    assert "error" not in response, response.get("error")
    METHODS[method].params.model_validate(params or {})
    METHODS[method].result.model_validate(response["result"])
    return response["result"]


@pytest.mark.parametrize("kwargs,state", [
    ({}, "running"),
    ({"code_stale": True}, "restart_needed"),
    ({"running": False}, "stopped"),
    ({"running": False, "installed": False}, "not_installed"),
    ({"backend": "none", "running": False, "installed": False}, "unsupported"),
])
def test_status_reports_each_service_state(fake, kwargs, state):
    for key, value in kwargs.items():
        setattr(fake, f"_{key}" if key in {"backend", "installed", "running"} else key, value)
    status = _ok("gateway.service.status")
    assert status["state"] == state
    assert status["restart_needed"] is (state == "restart_needed")
    if state == "unsupported":
        assert status["reason"]


def test_status_payload_carries_no_paths_or_secrets(fake):
    text = json.dumps(_ok("gateway.service.status"))
    assert "/" not in text.replace("gen-1", "") and "token" not in text.lower()


def test_restart_when_idle_asks_the_supervisor(fake):
    result = _ok("gateway.service.restart")
    assert result["outcome"] == "started" and fake.restarts == [("default", False)]
    assert result["status"]["instance"] == "gen-1"


def test_restart_is_refused_while_a_chat_is_running(fake):
    fake.active = 2
    result = _ok("gateway.service.restart")
    assert result["outcome"] == "busy" and "chats are running" in result["reason"]
    assert fake.restarts == []


def test_force_interrupts_only_for_the_main_connection(fake):
    fake.active = 1
    token = _connection_profile_home.set(str(server._profile_home("scout")))
    try:
        refused = _ok("gateway.service.restart", {"force": True})
    finally:
        _connection_profile_home.reset(token)
    assert refused["outcome"] == "refused" and fake.restarts == []
    forced = _ok("gateway.service.restart", {"force": True})
    assert forced["outcome"] == "started" and fake.restarts == [("default", True)]


def test_a_caller_without_the_interactive_grant_never_reaches_the_method():
    weak = SimpleNamespace(capabilities=("worker:adopt",))
    assert not legacy_fallback_allowed(weak, "gateway.service.restart")
    assert not legacy_fallback_allowed(SimpleNamespace(capabilities=()), "gateway.service.install")


def test_an_unknown_profile_is_refused(fake):
    for name in ("status", "restart", "install"):
        assert _rpc(f"gateway.service.{name}", {"profile": "ghost"})["error"]["code"] == 4064
    assert fake.restarts == []


def test_a_named_profile_restart_targets_that_profile(fake):
    _ok("gateway.service.restart", {"profile": "scout"})
    assert fake.restarts == [("scout", False)]


def test_restart_and_install_are_unsupported_without_a_service_manager(fake):
    fake._backend, fake._running, fake._installed = "none", False, False
    assert _ok("gateway.service.restart")["outcome"] == "unsupported"
    assert _ok("gateway.service.install")["outcome"] == "unsupported"
    assert fake.restarts == []


def test_restart_needs_an_installed_service(fake):
    fake._running, fake._installed = False, False
    assert _ok("gateway.service.restart")["outcome"] == "not_installed"


def test_install_installs_once_and_reports_failure(fake):
    fake._installed, fake._running = False, False
    fake.install_ok = False
    assert _ok("gateway.service.install")["outcome"] == "failed"
    fake.install_ok = True
    assert _ok("gateway.service.install")["outcome"] == "installed"
    assert _ok("gateway.service.install")["outcome"] == "already_installed"


def test_spawn_failure_is_a_failed_outcome_not_an_error(fake):
    def boom(profile, interrupt):
        raise RuntimeError("secret detail")
    fake.spawn_restart = boom
    result = _ok("gateway.service.restart")
    assert result["outcome"] == "failed" and "secret" not in json.dumps(result)


def test_a_restart_that_drops_the_connection_reports_pending_then_the_new_instance(fake):
    before = _ok("gateway.service.status")["instance"]
    assert _ok("gateway.service.restart")["outcome"] == "started"
    fake._running = False
    assert _ok("gateway.service.status")["state"] == "stopped"
    fake._running, fake.generation = True, 2
    after = _ok("gateway.service.status")
    assert after["state"] == "running" and after["instance"] != before and after["started_at"] == 1002.0
