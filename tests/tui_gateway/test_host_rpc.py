from __future__ import annotations

import json
import subprocess
import types

import pytest

from tui_gateway import host_health, host_logs, server
from tui_gateway.contracts import METHODS
from tui_gateway.contracts.registry import ContractViolation
from tui_gateway.ws_legacy_fallback import _connection_profile_home, legacy_fallback_allowed

NAMES = {"host.health", "host.logs.tail"}
CANARIES = {
    "ghp": "ghp_CANARYTOKEN0123456789abcdefghijklmnop",
    "gho": "gho_CANARYACCESS0123456789abcdefghijklmn",
    "ghs": "ghs_CANARYSERVER0123456789abcdefghijklmn",
    "pat": "github_pat_11CANARY0123456789_abcdefghijklmnopqrstuvwxyz0123456789",
    "sk": "sk-CANARY0123456789abcdefghijklmnop",
    "bearer": "Authorization: Bearer CANARYbearer0123456789abcd",
    "jwt": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJDQU5BUlkifQ.CANARYsignature0123456789",
    "keyed": "api_key=CANARYkeyvalue0123456789abcdefghij",
    "colon": "client_secret: CANARYsecret0123456789abcdefghijk",
    "hex": "digest 0123456789abcdef0123456789abcdef0123456789abcdef",
    "url": "https://octocat:CANARYpassw0rd@example.com/repo.git",
}
SECRET_PARTS = ("CANARY", "0123456789abcdef0123456789abcdef", "octocat:")


def call(method, params=None):
    try:
        return _dispatch(method, params)
    except ContractViolation as exc:
        return {"error": {"code": 4000, "message": str(exc)}}


def _dispatch(method, params=None):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})


@pytest.fixture
def logfile(tmp_path, monkeypatch):
    path = tmp_path / "gateway.log"
    monkeypatch.setattr(host_logs, "log_path", lambda name: path if name in host_logs.LOG_NAMES else None)
    return path


def write(path, lines):
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


@pytest.mark.parametrize("shape", sorted(CANARIES))
def test_each_token_shape_is_masked_entirely(shape):
    out = host_logs.redact(f"2026-01-01 INFO run: seen {CANARIES[shape]} done")
    assert not any(part in out for part in SECRET_PARTS), out
    assert out.startswith("2026-01-01 INFO run:")


def test_ordinary_log_lines_survive_redaction():
    line = "2026-01-01 12:00:00 INFO gateway.run: platform telegram connected in 1.2s"
    assert host_logs.redact(line) == line


def test_tail_redacts_before_returning(logfile):
    write(logfile, ["start", *CANARIES.values(), "end"])
    result = call("host.logs.tail", {"name": "gateway", "lines": 50})["result"]
    METHODS["host.logs.tail"].result.model_validate(result)
    blob = json.dumps(result)
    assert not any(part in blob for part in SECRET_PARTS)
    assert result["lines"][0] == "start" and result["lines"][-1] == "end"


@pytest.mark.parametrize("name", ["../../etc/passwd", "gateway.log", "/etc/passwd", "update", "desktop", "", "GATEWAY"])
def test_unknown_names_and_paths_are_refused(logfile, name):
    response = call("host.logs.tail", {"name": name})
    assert "error" in response
    assert host_logs.log_path(name) is None or name in host_logs.LOG_NAMES


def test_log_allow_list_is_fixed():
    assert host_logs.LOG_NAMES == ("gateway", "agent", "errors")
    for name in host_logs.LOG_NAMES:
        assert host_logs.log_path(name).name == f"{name}.log"


def test_line_bounds_are_enforced(logfile):
    write(logfile, [f"line {i}" for i in range(900)])
    for lines in (0, 501, -1):
        assert "error" in call("host.logs.tail", {"lines": lines})
    assert "error" in call("host.logs.tail", {"skip": -1})
    assert len(host_logs.tail("gateway", 10_000, 0, path=logfile).lines) == host_logs.MAX_LINES
    result = call("host.logs.tail", {"lines": 500})["result"]
    assert len(result["lines"]) == 500 and result["lines"][-1] == "line 899" and result["has_more"]


def test_byte_and_line_length_caps(logfile):
    write(logfile, ["x" * 5000] * 100)
    result = call("host.logs.tail", {"lines": 500})["result"]
    assert sum(len(line.encode()) + 1 for line in result["lines"]) <= host_logs.MAX_BYTES
    assert all(len(line) <= host_logs.MAX_LINE_CHARS for line in result["lines"])
    assert result["truncated"] and result["has_more"]


def test_pages_by_line_count_cover_the_log_exactly_once(logfile):
    write(logfile, [f"line {i}" for i in range(25)])
    seen, skip = [], 0
    while True:
        page = call("host.logs.tail", {"lines": 10, "skip": skip})["result"]
        seen = page["lines"] + seen
        skip += len(page["lines"])
        if not page["has_more"]:
            break
    assert seen == [f"line {i}" for i in range(25)]


def test_missing_and_empty_logs_are_not_errors(logfile):
    missing = call("host.logs.tail", {})["result"]
    assert missing["lines"] == [] and missing["available"] is False
    logfile.write_text("")
    empty = call("host.logs.tail", {})["result"]
    assert empty["lines"] == [] and empty["available"] is True and not empty["has_more"]


def test_a_file_larger_than_the_scan_window_still_returns_the_newest(logfile, monkeypatch):
    monkeypatch.setattr(host_logs, "MAX_SCAN_BYTES", 4096)
    monkeypatch.setattr(host_logs, "CHUNK", 1024)
    write(logfile, [f"line {i:05d}" for i in range(5000)])
    result = call("host.logs.tail", {"lines": 5})["result"]
    assert result["lines"][-1] == "line 04999" and len(result["lines"]) == 5 and result["has_more"]


def doctor_ok(monkeypatch, report):
    monkeypatch.setattr(host_health, "run_doctor", lambda: report)


def test_health_reports_fields_and_problems(monkeypatch):
    doctor_ok(monkeypatch, {"issues": ["Cron store is not writable"], "manual_issues": ["Missing key " + CANARIES["sk"]]})
    result = call("host.health")["result"]
    METHODS["host.health"].result.model_validate(result)
    assert result["doctor_ran"] and result["python_version"]
    assert result["problems"][0] == {"severity": "warning", "message": "Cron store is not writable"}
    assert result["problems"][1]["severity"] == "error"
    assert "CANARY" not in json.dumps(result)


def test_health_degrades_to_null_instead_of_failing(monkeypatch):
    def boom(*a, **k):
        raise OSError("unreadable")

    for name in ("_version", "_disk", "_uptime_seconds", "_profile_counts"):
        monkeypatch.setattr(host_health, name, boom)
    monkeypatch.setattr(host_health, "run_doctor", boom)
    result = call("host.health")["result"]
    METHODS["host.health"].result.model_validate(result)
    assert result["version"] is None and result["disk_free_bytes"] is None
    assert result["host_uptime_seconds"] is None and result["profile_count"] is None
    assert result["doctor_ran"] is False and result["problems"] == []


def test_doctor_runs_a_fixed_argv_with_a_timeout(monkeypatch):
    seen = {}

    def fake(argv, **kwargs):
        seen.update(argv=argv, kwargs=kwargs)
        return subprocess.CompletedProcess(argv, 0, '{"issues": [], "manual_issues": []}\n', "")

    monkeypatch.setattr(host_health.subprocess, "run", fake)
    assert host_health.run_doctor() == {"issues": [], "manual_issues": []}
    assert seen["argv"][1:] == ["-m", "hermes_cli.doctor_summary"]
    assert seen["kwargs"]["timeout"] == host_health.DOCTOR_TIMEOUT_SECONDS
    assert seen["kwargs"]["stdin"] == subprocess.DEVNULL
    assert "shell" not in seen["kwargs"]


def test_problems_are_capped(monkeypatch):
    doctor_ok(monkeypatch, {"issues": ["x" * 1000] * 50, "manual_issues": []})
    problems = call("host.health")["result"]["problems"]
    assert len(problems) == host_health.MAX_PROBLEMS
    assert all(len(p["message"]) <= host_health.MAX_PROBLEM_CHARS for p in problems)


def test_methods_are_declared_and_not_model_tools():
    from model_tools import get_all_tool_names
    assert NAMES <= set(METHODS)
    tools = set(get_all_tool_names())
    assert not any(name in tools or name.replace(".", "_") in tools for name in NAMES)


def test_worker_and_capability_less_connections_cannot_reach_the_host_methods():
    from gateway.runtime_bootstrap import _PURPOSE_CAPABILITIES
    worker = types.SimpleNamespace(capabilities=frozenset({"worker:adopt"}))
    owner = types.SimpleNamespace(capabilities=frozenset(_PURPOSE_CAPABILITIES["interactive"]))
    for name in NAMES:
        assert not legacy_fallback_allowed(worker, name)
        assert not legacy_fallback_allowed(types.SimpleNamespace(capabilities=frozenset()), name)
        assert legacy_fallback_allowed(owner, name)


def test_secondary_profile_ticket_is_refused(logfile, monkeypatch):
    doctor_ok(monkeypatch, {"issues": [], "manual_issues": []})
    token = _connection_profile_home.set("/some/profiles/bee")
    try:
        for name in NAMES:
            assert call(name)["error"]["code"] == 4403
    finally:
        _connection_profile_home.reset(token)
