import argparse
import json
import plistlib
import subprocess
from types import SimpleNamespace

import pytest

import hermes_cli.gateway as gateway_cli
from hermes_cli import gateway_service_owner
from hermes_cli.subcommands.gateway import build_gateway_parser

LABEL = "ai.hermes.gateway-0a1b2c3d"
DOMAIN = "gui/501"
KICKSTART = ["launchctl", "kickstart", f"{DOMAIN}/{LABEL}"]
BOOTOUT = ["launchctl", "bootout", f"{DOMAIN}/{LABEL}"]


def _parse(*argv):
    parser = argparse.ArgumentParser()
    build_gateway_parser(
        parser.add_subparsers(dest="command"),
        cmd_gateway=lambda a: None, cmd_proxy=lambda a: None, cmd_gateway_enroll=lambda a: None,
    )
    return parser.parse_args(["gateway", *argv])


@pytest.fixture
def launchd(tmp_path, monkeypatch):
    state = SimpleNamespace(
        plist=tmp_path / "LaunchAgents" / f"{LABEL}.plist", supervised_pid=None,
        bootstraps=[], launchctl=[], refreshes=[], listed_pid=None,
    )
    monkeypatch.setattr(gateway_cli, "_service_backend", lambda *a, **k: "launchd")
    monkeypatch.setattr(gateway_cli, "is_managed", lambda: False)
    monkeypatch.setattr(gateway_cli, "is_termux", lambda: False)
    monkeypatch.setattr(gateway_cli, "_guard_named_profile_under_multiplexer", lambda **k: None)
    monkeypatch.setattr(gateway_cli, "get_launchd_plist_path", lambda: state.plist)
    monkeypatch.setattr(gateway_cli, "get_launchd_label", lambda: LABEL)
    monkeypatch.setattr(gateway_cli, "_launchd_domain", lambda: DOMAIN)
    monkeypatch.setattr(gateway_service_owner, "refuse_temp_home_service_write", lambda *a: False)
    monkeypatch.setattr(gateway_cli, "_clear_launchd_unsupported_marker", lambda: None)
    monkeypatch.setattr(gateway_cli, "_launchctl_supervised_pid", lambda label: state.supervised_pid)
    monkeypatch.setattr(gateway_cli, "_launchctl_bootstrap", lambda *a, **k: state.bootstraps.append(a))
    monkeypatch.setattr(gateway_cli, "refresh_launchd_plist_if_needed", lambda: state.refreshes.append(1) or True)

    def fake_run(cmd, *a, **k):
        state.launchctl.append(cmd)
        if cmd[:2] == ["launchctl", "list"]:
            pid = f'    "PID" = {state.listed_pid};\n' if state.listed_pid else ""
            return SimpleNamespace(returncode=0 if state.listed_pid is not None else 113, stdout="{\n" + pid + "}", stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)
    return state


def _plist(state):
    return plistlib.loads(state.plist.read_bytes())


def test_install_with_start_on_login_off_kickstarts_a_job_that_a_login_does_not_start(launchd):
    gateway_cli.gateway_command(_parse("install", "--no-start-on-login"))

    definition = _plist(launchd)
    assert definition["RunAtLoad"] is False
    assert definition["KeepAlive"] == {"SuccessfulExit": False, "AfterInitialDemand": True}
    assert len(launchd.bootstraps) == 1
    assert KICKSTART in launchd.launchctl


def test_a_plain_install_starts_at_login_and_needs_no_kickstart(launchd):
    gateway_cli.gateway_command(_parse("install"))

    definition = _plist(launchd)
    assert definition["RunAtLoad"] is True
    assert definition["KeepAlive"] == {"SuccessfulExit": False}
    assert KICKSTART not in launchd.launchctl


def test_turning_start_at_login_off_rewrites_the_file_and_leaves_the_running_job_alone(launchd, capsys):
    gateway_cli.gateway_command(_parse("install"))
    launchd.bootstraps.clear()
    launchd.launchctl.clear()
    launchd.supervised_pid = 4242

    gateway_cli.gateway_command(_parse("install", "--no-start-on-login"))

    assert _plist(launchd)["RunAtLoad"] is False
    assert launchd.bootstraps == []
    assert launchd.refreshes == []
    assert BOOTOUT not in launchd.launchctl
    assert KICKSTART not in launchd.launchctl
    assert "Start at login off" in capsys.readouterr().out

    gateway_cli.gateway_command(_parse("install", "--start-on-login"))

    assert _plist(launchd)["RunAtLoad"] is True
    assert launchd.bootstraps == []


def test_a_reinstall_and_a_plist_refresh_keep_the_choice(launchd):
    gateway_cli.gateway_command(_parse("install", "--no-start-on-login"))
    launchd.bootstraps.clear()

    gateway_cli.gateway_command(_parse("install"))

    assert _plist(launchd)["RunAtLoad"] is False
    assert launchd.bootstraps == []
    assert gateway_cli.launchd_plist_is_current() is True
    assert plistlib.loads(gateway_cli.generate_launchd_plist().encode())["RunAtLoad"] is False


def test_status_json_reports_the_job_for_the_app(launchd, capsys):
    gateway_cli.gateway_command(_parse("install", "--no-start-on-login"))
    launchd.listed_pid = 777
    capsys.readouterr()

    gateway_cli.gateway_command(_parse("status", "--json"))

    assert json.loads(capsys.readouterr().out) == {
        "installed": True, "loaded": True, "running": True, "pid": 777, "start_on_login": False, "label": LABEL,
    }


def test_status_json_before_install_and_when_stopped(launchd, capsys):
    launchd.listed_pid = None

    gateway_cli.gateway_command(_parse("status", "--json"))

    assert json.loads(capsys.readouterr().out) == {
        "installed": False, "loaded": False, "running": False, "pid": None, "start_on_login": True, "label": LABEL,
    }


def test_status_json_refuses_a_host_without_launchd(launchd, monkeypatch, capsys):
    monkeypatch.setattr(gateway_cli, "_service_backend", lambda *a, **k: "systemd")

    with pytest.raises(SystemExit) as raised:
        gateway_cli.gateway_command(_parse("status", "--json"))

    assert raised.value.code == 1
    assert json.loads(capsys.readouterr().out) == {"error": {"code": "unsupported_platform"}}
