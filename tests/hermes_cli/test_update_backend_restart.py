import subprocess

import pytest

from hermes_cli import dashboard_procs, main_dashboard

UNIT = "hermes-backend.service"
SYSTEM_CG = f"/system.slice/{UNIT}"
USER_CG = f"/user.slice/user-1000.slice/user@1000.service/app.slice/{UNIT}"
ARGV = ["hermes", "-p", "default", "serve", "--host", "127.0.0.1", "--port", "9119", "--skip-build"]
PLAIN = ["systemctl", "restart", UNIT]
USER_PLAIN = ["systemctl", "--user", "restart", UNIT]
SUDO = ["sudo", "-n", "systemctl", "restart", UNIT]
SYSTEM_MANUAL = f"sudo systemctl restart {UNIT}"


class FakeSystem:
    def __init__(self, *, plain=0, sudo=0, active="active", sudo_stderr="", answers=True):
        self.plain, self.sudo, self.active = plain, sudo, active
        self.sudo_stderr, self.answers = sudo_stderr, answers
        self.argvs: list[list[str]] = []
        self.probes: list[tuple[str, int]] = []

    def run(self, cmd, *, timeout):
        self.argvs.append(list(cmd))
        if cmd[0] == "sudo":
            return subprocess.CompletedProcess(cmd, self.sudo, "", self.sudo_stderr)
        if "restart" in cmd:
            return subprocess.CompletedProcess(cmd, self.plain, "", "Access denied" if self.plain else "")
        if "is-active" in cmd:
            return subprocess.CompletedProcess(cmd, 0 if self.active == "active" else 3, self.active + "\n", "")
        raise AssertionError(f"unexpected command {cmd}")

    def answer(self, host, port):
        self.probes.append((host, port))
        return self.answers

    @property
    def sudo_argvs(self):
        return [a for a in self.argvs if a and a[0] == "sudo"]


@pytest.fixture
def system(monkeypatch):
    def install(**kw):
        fake = FakeSystem(**kw)
        monkeypatch.setattr(main_dashboard, "_run_probe", fake.run)
        monkeypatch.setattr(main_dashboard, "_backend_answers", fake.answer)
        monkeypatch.setattr(main_dashboard.time, "sleep", lambda s: None)
        monkeypatch.setattr(main_dashboard, "_STARTUP_WAIT_SECONDS", 0.0)
        return fake
    return install


def restart(cgroup=SYSTEM_CG, stopped=frozenset({UNIT}), unit=UNIT, argv=ARGV):
    return main_dashboard._restart_stopped_systemd_unit(unit, cgroup, set(stopped), argv)


def test_plain_restart_ok_never_runs_sudo(system, capsys):
    fake = system()
    assert restart() is None
    assert fake.argvs[0] == PLAIN
    assert fake.sudo_argvs == []
    assert fake.probes == [("127.0.0.1", 9119)]
    assert f"✓ {UNIT} active and 127.0.0.1:9119 answering" in capsys.readouterr().out


def test_plain_fails_then_sudo_n_restarts(system, capsys):
    fake = system(plain=1)
    assert restart() is None
    assert fake.sudo_argvs == [SUDO]
    assert fake.argvs.index(SUDO) == fake.argvs.index(PLAIN) + 1
    assert "running: sudo -n systemctl restart hermes-backend.service" in capsys.readouterr().out


def test_plain_and_sudo_fail_report_manual_command(system):
    fake = system(plain=1, sudo=1)
    failure = restart()
    assert fake.sudo_argvs == [SUDO]
    assert "restart failed" in failure and SYSTEM_MANUAL in failure
    assert fake.probes == []


def test_sudo_needing_a_password_is_a_failure(system, capsys):
    fake = system(plain=1, sudo=1, sudo_stderr="sudo: a password is required")
    failure = restart()
    assert fake.sudo_argvs == [SUDO]
    assert SYSTEM_MANUAL in failure
    assert "a password is required" in capsys.readouterr().out


def test_sudo_missing_is_a_failure(system, monkeypatch):
    fake = system(plain=1)
    real = fake.run

    def run(cmd, *, timeout):
        if cmd[0] == "sudo":
            fake.argvs.append(list(cmd))
            raise FileNotFoundError("sudo")
        return real(cmd, timeout=timeout)

    monkeypatch.setattr(main_dashboard, "_run_probe", run)
    assert SYSTEM_MANUAL in restart()
    assert fake.sudo_argvs == [SUDO]


def test_user_scope_unit_never_uses_sudo(system):
    fake = system(plain=1)
    failure = restart(cgroup=USER_CG)
    assert fake.argvs == [USER_PLAIN]
    assert f"systemctl --user restart {UNIT}" in failure


def test_unknown_scope_never_uses_sudo(system):
    fake = system(plain=1)
    restart(cgroup=None)
    assert fake.sudo_argvs == []


def test_unit_the_update_did_not_stop_never_uses_sudo(system):
    fake = system(plain=1)
    failure = restart(stopped=frozenset({"other.service"}))
    assert fake.argvs == [PLAIN]
    assert SYSTEM_MANUAL in failure


@pytest.mark.parametrize("unit", ["-oops.service", "a b.service", "x;rm.service", "hermes\\x2d.service",
                                  "hermes-backend", "../x.service", ""])
def test_unsafe_unit_name_is_rejected_and_nothing_runs(system, unit):
    fake = system()
    assert "unsafe unit name" in restart(unit=unit, stopped={unit})
    assert fake.argvs == []


def test_active_but_port_not_answering_fails(system):
    fake = system(answers=False)
    failure = restart()
    assert "127.0.0.1:9119 did not answer" in failure and SYSTEM_MANUAL in failure
    assert fake.sudo_argvs == []


def test_inactive_after_restart_fails(system):
    fake = system(active="inactive")
    failure = restart()
    assert "not active after restart" in failure and SYSTEM_MANUAL in failure
    assert fake.probes == []


def test_wildcard_bind_probes_loopback(system):
    fake = system()
    assert restart(argv=["hermes", "serve", "--host", "0.0.0.0", "--port", "8000"]) is None
    assert fake.probes == [("127.0.0.1", 8000)]


def test_unknown_listen_address_checks_the_unit_only(system, capsys):
    fake = system()
    assert restart(argv=None) is None
    assert fake.probes == []
    assert "listen address unknown" in capsys.readouterr().out


def _killed_backend(monkeypatch, outcome):
    recorded = []
    monkeypatch.setattr(main_dashboard, "_restart_stopped_systemd_unit", lambda *a, **k: outcome)
    monkeypatch.setattr("hermes_cli.update_receipt.record_user_action", lambda *a: recorded.append(a))
    unrecovered = dashboard_procs._restart_killed_backends(
        [7], {7: UNIT}, {7: SYSTEM_CG}, {}, {}, pid_service_argv={7: ARGV})
    return unrecovered, recorded


def test_unrecovered_unit_is_recorded_as_a_user_action(monkeypatch):
    unrecovered, recorded = _killed_backend(monkeypatch, f"{UNIT} is not active after restart; run `{SYSTEM_MANUAL}`")
    assert unrecovered == [7]
    assert recorded == [("backend_restart", f"{UNIT}: {UNIT} is not active after restart; run `{SYSTEM_MANUAL}`")]


def test_recovered_unit_records_nothing(monkeypatch):
    unrecovered, recorded = _killed_backend(monkeypatch, None)
    assert unrecovered == [] and recorded == []


@pytest.mark.parametrize("backend_down, exit_code", [(True, 1), (False, 0)])
def test_completion_exits_nonzero_when_a_stopped_backend_stays_down(monkeypatch, tmp_path, backend_down, exit_code):
    from hermes_cli import update_completion, update_receipt

    update_receipt.begin_update_receipt()
    receipt = update_receipt._current.get()
    request = {"receipt": receipt.data, "pm_receipt": None, "gateway_mode": False, "windows_resume": None}
    update_receipt._current.reset(receipt.current_token)

    def settle_like_verification(_request):
        if backend_down:
            update_receipt.record_user_action("backend_restart", f"{UNIT}: not active")
        update_receipt.finalize_update_receipt("success")
        return True

    monkeypatch.setattr(update_completion, "_complete_selected", settle_like_verification)
    result_path = tmp_path / "result.json"
    assert update_completion._finish(request, result_path) == exit_code
    import json
    written = json.loads(result_path.read_text())
    assert written["exit_code"] == exit_code
    assert written["receipt"]["outcome"] == ("partial" if backend_down else "success")
