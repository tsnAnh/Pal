"""The local terminal backend's prompt block names the machine the tools run on; remote backends keep
the gateway host hidden."""
from __future__ import annotations

import pytest

import agent.prompt_builder as pb
from agent import machine_hint
from agent.surface_switch import runtime_host_value, split_runtime_boundary

FACTS = {"os_family": "darwin", "native_arch": "arm64", "cpu_model": "Apple M4 Pro", "ram_gb": 48, "container": False}


@pytest.fixture(autouse=True)
def _fresh_machine_line():
    machine_hint.machine_line.cache_clear()
    yield
    machine_hint.machine_line.cache_clear()


def _summary(monkeypatch, facts, calls=None):
    import hermes_platform.host.summary as host_summary

    def fake():
        if calls is not None:
            calls.append(1)
        return {"machine": facts}
    monkeypatch.setattr(host_summary, "summary", fake)


def _local(monkeypatch):
    monkeypatch.setattr(pb, "is_wsl", lambda: False)
    monkeypatch.delenv("TERMINAL_ENV", raising=False)
    pb._BACKEND_PROBE_CACHE.clear()


def test_local_backend_names_the_machine_before_the_home_directory(monkeypatch):
    _summary(monkeypatch, {**FACTS, "container": True})
    _local(monkeypatch)
    hints = pb.build_environment_hints()
    lines = hints.splitlines()
    machine = next(line for line in lines if line.startswith("Machine:"))
    assert machine.startswith("Machine: macOS arm64, CPU Apple M4 Pro, ") and "48 GB RAM" in machine
    assert machine.endswith("inside a container")
    assert lines.index(machine) + 1 == next(i for i, line in enumerate(lines) if line.startswith("User home directory:"))
    assert lines[lines.index(machine) - 1].startswith("Host:")


def test_the_machine_line_carries_no_hostname_or_network_identity(monkeypatch):
    import platform
    import socket
    monkeypatch.setattr(socket, "gethostname", lambda: "zz-secret-box")
    monkeypatch.setattr(platform, "node", lambda: "zz-secret-box")
    _local(monkeypatch)
    assert "zz-secret-box" not in pb.build_environment_hints()


def test_real_host_facts_produce_a_measured_line(monkeypatch):
    _local(monkeypatch)
    line = machine_hint.machine_line()
    assert line.startswith("Machine: ") and "GB RAM" in line and "cores" in line


@pytest.mark.parametrize("backend", ["docker", "ssh", "modal"])
def test_remote_backends_never_name_the_gateway_machine(monkeypatch, backend):
    _summary(monkeypatch, FACTS)
    monkeypatch.setattr(pb, "is_wsl", lambda: False)
    monkeypatch.setenv("TERMINAL_ENV", backend)
    monkeypatch.setattr(pb, "_probe_remote_backend", lambda _t: None)
    pb._BACKEND_PROBE_CACHE.clear()
    result = pb.build_environment_hints()
    assert "Machine:" not in result and "Apple M4 Pro" not in result and f"Terminal backend: {backend}" in result


def test_summary_is_measured_once_per_process(monkeypatch):
    calls = []
    _summary(monkeypatch, FACTS, calls)
    assert machine_hint.machine_line() == machine_hint.machine_line() != ""
    assert len(calls) == 1


def test_unavailable_host_facts_drop_the_line_without_breaking_the_prompt(monkeypatch):
    import hermes_platform.host.summary as host_summary

    def broken():
        raise OSError("sysctl failed")
    monkeypatch.setattr(host_summary, "summary", broken)
    _local(monkeypatch)
    hints = pb.build_environment_hints()
    assert "Machine:" not in hints and "User home directory:" in hints


def test_persisted_prompt_host_parsing_and_end_marker_still_work(monkeypatch, tmp_path):
    _summary(monkeypatch, FACTS)
    _local(monkeypatch)
    monkeypatch.setenv("TERMINAL_CWD", str(tmp_path))
    prompt = (f"Identity.\n\nPlatform: desktop\n\n{pb.RUNTIME_ENVIRONMENT_HEADING}\n\n"
              f"{pb.build_environment_hints()}\n\n{pb.RUNTIME_ENVIRONMENT_END}")
    assert prompt.endswith(pb.RUNTIME_ENVIRONMENT_END)
    assert split_runtime_boundary(prompt)[0] == "Identity.\n\nPlatform: desktop"
    assert runtime_host_value(prompt, "Current working directory") == str(tmp_path)
