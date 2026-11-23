import argparse
import json
import logging
import stat
import subprocess
import types

import pytest

from gateway import public_address
from hermes_cli import tailnet_access as tn
from hermes_cli.config import get_env_path, get_env_value, load_config, save_config, save_env_value
from hermes_cli.subcommands.tailnet import build_tailnet_parser
from hermes_constants import get_hermes_home

SECRET_ENV = "HERMES_DASHBOARD_BASIC_AUTH_SECRET"
SESSION_ENV = "HERMES_DASHBOARD_SESSION_TOKEN"
URL = "https://pal-host.tail1234.ts.net"
PASSWORD_MARKER = "PASSWORD-MARKER-0123456789"


def _status(**overrides):
    document = {"BackendState": "Running", "Self": {"DNSName": "Pal-Host.tail1234.ts.net."},
                "CertDomains": ["pal-host.tail1234.ts.net"]}
    document.update(overrides)
    return json.dumps(document)


class FakeTailscale:
    def __init__(self, *, status=None, serve_config=None, serve_stderr="", serve_returncode=0, present=True,
                 status_returncode=0, off_returncode=0, serve_times_out=False):
        self.off_returncode = off_returncode
        self.serve_times_out = serve_times_out
        self.status = status if status is not None else _status()
        self.status_returncode = status_returncode
        self.serve_config = serve_config or {}
        self.serve_stderr = serve_stderr
        self.serve_returncode = serve_returncode
        self.present = present
        self.calls = []

    def install(self, monkeypatch):
        from hermes_platform import resolver
        monkeypatch.setattr(resolver, "locate_command", lambda name, ctx=None, known_dirs=(): types.SimpleNamespace(
            command=("/usr/bin/tailscale",) if self.present else ()))

    def serve_calls(self, *, off=None):
        calls = [c[1:] for c in self.calls if c[1] == "serve" and c[2] != "status"]
        return [c for c in calls if off is None or (c[-1] == "off") == off]

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        sub = argv[1:]
        if sub == ["status", "--json"]:
            return subprocess.CompletedProcess(argv, self.status_returncode, self.status, "")
        if sub == ["serve", "status", "--json"]:
            return subprocess.CompletedProcess(argv, 0, json.dumps(self.serve_config) if self.serve_config else "{}", "")
        if sub[0] == "serve" and sub[-1] == "off":
            if self.off_returncode:
                return subprocess.CompletedProcess(argv, self.off_returncode, "", "off failed")
            self.serve_config = {}
            return subprocess.CompletedProcess(argv, 0, "", "")
        if sub[0] == "serve":
            if self.serve_returncode:
                return subprocess.CompletedProcess(argv, self.serve_returncode, "", self.serve_stderr)
            self.serve_config = serving(sub[-1])
            if self.serve_times_out:
                raise subprocess.TimeoutExpired(argv, 20)
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(argv)


def serving(proxy):
    return {"TCP": {"443": {"HTTPS": True}},
            "Web": {"pal-host.tail1234.ts.net:443": {"Handlers": {"/": {"Proxy": proxy}}}}}


class Restarts:
    def __init__(self, ok=True):
        self.ok = ok
        self.count = 0

    def __call__(self):
        self.count += 1
        return self.ok


def reachable(url):
    return public_address.Outcome.reachable


def unreachable(url):
    return public_address.Outcome.not_reachable


@pytest.fixture(autouse=True)
def _clean_secret_env(monkeypatch):
    for name in (SECRET_ENV, SESSION_ENV):
        monkeypatch.setenv(name, "")
        monkeypatch.delenv(name)


@pytest.fixture
def home():
    path = get_hermes_home()
    config = load_config()
    config["webapp"] = {**config.get("webapp", {}), "enabled": True, "port": 9120}
    save_config(config)
    return path


@pytest.fixture
def tailscale(monkeypatch):
    fake = FakeTailscale()
    fake.install(monkeypatch)
    return fake


def enable(home, tailscale, *, restart=None, check=reachable):
    return tn.enable(home, run=tailscale, check=check, restart=restart or Restarts(), sleep=lambda s: None)


def record_path(home):
    return home / "webapp" / "tailnet.json"


def nothing_written(home):
    assert not record_path(home).exists()
    config = load_config()
    assert not config["webapp"].get("public_url")
    assert not config.get("dashboard", {}).get("basic_auth", {}).get("username")
    env_text = get_env_path().read_text() if get_env_path().exists() else ""
    assert SECRET_ENV not in env_text and SESSION_ENV not in env_text


def test_enable_writes_credentials_serves_and_records(home, tailscale):
    restarts = Restarts()
    result = enable(home, tailscale, restart=restarts)

    assert result["enabled"] is True and result["url"] == URL and result["username"] == "pal"
    assert result["reachable"] is True and len(result["password"]) >= 24
    assert tailscale.serve_calls() == [["serve", "--bg", "--https=443", "http://127.0.0.1:9120"]]
    assert restarts.count == 1
    basic = load_config()["dashboard"]["basic_auth"]
    from plugins.dashboard_auth.basic import _verify_password
    assert basic["username"] == "pal" and _verify_password(result["password"], basic["password_hash"])
    assert load_config()["webapp"]["public_url"] == URL
    record = json.loads(record_path(home).read_text())
    assert record == {"url": URL, "port": 9120, "added_session_token": True}
    assert stat.S_IMODE(record_path(home).stat().st_mode) == 0o600


def test_signing_secret_lives_in_env_not_config(home, tailscale):
    result = enable(home, tailscale)
    env_text = get_env_path().read_text()
    secret = next(line.split("=", 1)[1].strip().strip("'\"") for line in env_text.splitlines()
                  if line.startswith(SECRET_ENV))
    assert len(secret) >= 32
    config_text = (home / "config.yaml").read_text()
    assert secret not in config_text and result["password"] not in config_text
    assert not load_config()["dashboard"]["basic_auth"].get("secret")


def test_reenable_rotates_password_and_keeps_serve_and_secret(home, tailscale):
    restarts = Restarts()
    first = enable(home, tailscale, restart=restarts)
    first_hash = load_config()["dashboard"]["basic_auth"]["password_hash"]
    secret = get_env_path().read_text()
    second = enable(home, tailscale, restart=restarts)

    from plugins.dashboard_auth.basic import _verify_password
    assert second["password"] != first["password"]
    new_hash = load_config()["dashboard"]["basic_auth"]["password_hash"]
    assert new_hash != first_hash
    assert _verify_password(second["password"], new_hash) and not _verify_password(first["password"], new_hash)
    assert len(tailscale.serve_calls(off=False)) == 1
    assert restarts.count == 2
    assert get_env_path().read_text() == secret


def test_disabled_basic_plugin_is_enabled_by_the_config_write(home, tailscale):
    config = load_config()
    config["plugins"] = {**config.get("plugins", {}), "disabled": ["basic", "other"]}
    save_config(config)
    enable(home, tailscale)
    assert load_config()["plugins"]["disabled"] == ["other"]


def test_unreachable_check_is_still_success(home, tailscale):
    result = enable(home, tailscale, check=unreachable)
    assert result["enabled"] is True and result["reachable"] is False


def test_webapp_not_enabled_writes_nothing_and_never_calls_tailscale(tailscale):
    config = load_config()
    config["webapp"] = {**config.get("webapp", {}), "enabled": False}
    save_config(config)
    with pytest.raises(tn.TailnetError) as caught:
        tn.enable(get_hermes_home(), run=tailscale, check=reachable, restart=Restarts(), sleep=lambda s: None)
    assert str(caught.value) == "Pal isn't running on this Mac yet."
    assert tailscale.calls == []
    nothing_written(get_hermes_home())


def test_tailscale_missing(home, monkeypatch):
    fake = FakeTailscale(present=False)
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, fake)
    assert str(caught.value) == "Install Tailscale on this Mac first."
    nothing_written(home)


@pytest.mark.parametrize("kwargs", [
    {"status": _status(BackendState="Stopped")},
    {"status": _status(BackendState="NeedsLogin")},
    {"status": "", "status_returncode": 1},
    {"status": _status(Self={"DNSName": ""})},
    {"status": _status(Self={})},
])
def test_tailscale_not_running_or_nameless(home, monkeypatch, kwargs):
    fake = FakeTailscale(**kwargs)
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, fake)
    assert str(caught.value) == "Tailscale isn't running on this Mac. Open Tailscale and sign in, then try again."
    assert fake.serve_calls() == []
    nothing_written(home)


def test_https_certificates_off_in_status(home, monkeypatch):
    fake = FakeTailscale(status=_status(CertDomains=None))
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, fake)
    assert str(caught.value) == "Turn on HTTPS certificates in your Tailscale admin console, then try again."
    assert fake.serve_calls() == []
    nothing_written(home)


def test_https_certificates_off_reported_by_serve(home, monkeypatch):
    document = json.loads(_status())
    del document["CertDomains"]
    fake = FakeTailscale(status=json.dumps(document), serve_returncode=1,
                         serve_stderr="Serve is not enabled on your tailnet.\nTo enable, visit: https://login.tailscale.com/f/serve")
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, fake)
    assert str(caught.value) == "Turn on HTTPS certificates in your Tailscale admin console, then try again."
    nothing_written(home)


@pytest.mark.parametrize("config", [
    serving("http://127.0.0.1:3000"),
    {"TCP": {"443": {"TCPForward": "127.0.0.1:22"}}},
])
def test_foreign_serve_on_443_writes_nothing(home, monkeypatch, config):
    fake = FakeTailscale(serve_config=config)
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, fake)
    assert str(caught.value) == "Tailscale already serves something at this address. Turn it off first."
    assert fake.serve_calls() == []
    nothing_written(home)


def test_other_ports_do_not_count_as_foreign(home, monkeypatch):
    fake = FakeTailscale(serve_config={"TCP": {"8443": {"HTTPS": True}}})
    fake.install(monkeypatch)
    assert enable(home, fake)["enabled"] is True


def test_serve_failure_rolls_everything_back(home, monkeypatch):
    fake = FakeTailscale(serve_returncode=1, serve_stderr="listener failed")
    fake.install(monkeypatch)
    restarts = Restarts()
    with pytest.raises(tn.TailnetError):
        enable(home, fake, restart=restarts)
    nothing_written(home)
    assert restarts.count == 0
    assert fake.serve_calls(off=True) == [["serve", "--https=443", "off"]]


def test_restart_failure_rolls_everything_back_including_serve(home, tailscale):
    with pytest.raises(tn.TailnetError):
        enable(home, tailscale, restart=Restarts(ok=False))
    nothing_written(home)
    assert tailscale.serve_calls(off=True) == [["serve", "--https=443", "off"]]
    assert tailscale.serve_config == {}


def test_rotation_failure_restores_the_previous_password(home, tailscale):
    first = enable(home, tailscale)
    first_hash = load_config()["dashboard"]["basic_auth"]["password_hash"]
    with pytest.raises(tn.TailnetError):
        enable(home, tailscale, restart=Restarts(ok=False))
    assert load_config()["dashboard"]["basic_auth"]["password_hash"] == first_hash
    assert tailscale.serve_calls(off=True) == []
    assert record_path(home).exists() and first["enabled"]


def test_password_never_reaches_logs_or_error_output(home, monkeypatch, caplog, capsys):
    monkeypatch.setattr(tn.secrets, "token_urlsafe", lambda n: PASSWORD_MARKER if n == 18 else "s" * 43)
    fake = FakeTailscale(serve_returncode=1, serve_stderr=f"failed for {PASSWORD_MARKER} at /Users/x/.hermes")
    fake.install(monkeypatch)
    args = argparse.Namespace(tailnet_command="on", json=True)
    with caplog.at_level(logging.DEBUG):
        code = tn.tailnet_command(args, run=fake, check=reachable, restart=Restarts(), sleep=lambda s: None)
    out = capsys.readouterr()
    assert code == 1
    assert PASSWORD_MARKER not in caplog.text and PASSWORD_MARKER not in out.out + out.err
    payload = json.loads(out.out)
    assert list(payload) == ["error"]
    assert "/Users" not in payload["error"] and "failed for" not in payload["error"] and "basic_auth" not in payload["error"]


def test_success_logs_do_not_contain_the_password(home, tailscale, monkeypatch, caplog):
    monkeypatch.setattr(tn.secrets, "token_urlsafe", lambda n: PASSWORD_MARKER if n == 18 else "s" * 43)
    with caplog.at_level(logging.DEBUG):
        result = enable(home, tailscale)
    assert result["password"] == PASSWORD_MARKER
    assert PASSWORD_MARKER not in caplog.text


def test_off_without_a_record_never_runs_serve_off_or_clears_the_address(home, tailscale):
    config = load_config()
    config["webapp"]["public_url"] = "https://elsewhere.example.com"
    save_config(config)
    result = tn.disable(home, run=tailscale, restart=Restarts(), sleep=lambda s: None)
    assert result == {"enabled": False, "url": None, "username": None, "reachable": None}
    assert tailscale.serve_calls() == []
    assert load_config()["webapp"]["public_url"] == "https://elsewhere.example.com"


def test_off_with_a_record_removes_only_the_443_entry_and_keeps_credentials(home, tailscale):
    enable(home, tailscale)
    restarts = Restarts()
    result = tn.disable(home, run=tailscale, restart=restarts, sleep=lambda s: None)
    assert result == {"enabled": False, "url": None, "username": None, "reachable": None}
    assert tailscale.serve_calls(off=True) == [["serve", "--https=443", "off"]]
    assert not any("reset" in call for call in tailscale.calls)
    assert not load_config()["webapp"].get("public_url")
    assert not record_path(home).exists()
    assert load_config()["dashboard"]["basic_auth"]["username"] == "pal"
    assert load_config()["dashboard"]["basic_auth"]["password_hash"]
    assert restarts.count == 1


def test_status_reports_enabled_and_disabled(home, tailscale):
    off = tn.status(home, check=reachable)
    assert off == {"enabled": False, "url": None, "username": None, "reachable": None}
    enable(home, tailscale)
    on = tn.status(home, check=unreachable)
    assert on == {"enabled": True, "url": URL, "username": "pal", "reachable": False}
    assert tn.status(home, check=reachable)["reachable"] is True


def test_command_prints_one_json_object(home, tailscale, capsys):
    args = argparse.Namespace(tailnet_command="status", json=True)
    assert tn.tailnet_command(args, run=tailscale, check=reachable, restart=Restarts(), sleep=lambda s: None) == 0
    assert json.loads(capsys.readouterr().out) == {"enabled": False, "url": None, "username": None, "reachable": None}


def test_command_on_prints_password_once_and_exit_zero(home, tailscale, capsys):
    args = argparse.Namespace(tailnet_command="on", json=True)
    assert tn.tailnet_command(args, run=tailscale, check=reachable, restart=Restarts(), sleep=lambda s: None) == 0
    payload = json.loads(capsys.readouterr().out)
    assert set(payload) == {"enabled", "url", "username", "password", "reachable"}


def test_parser_routes_each_subcommand_with_json_flag():
    parser = argparse.ArgumentParser()
    build_tailnet_parser(parser.add_subparsers(dest="command", required=True))
    for name in ("status", "on", "off"):
        args = parser.parse_args(["tailnet", name, "--json"])
        assert (args.tailnet_command, args.json) == (name, True)
    assert parser.parse_args(["tailnet", "status"]).json is False


def session_env_line():
    text = get_env_path().read_text() if get_env_path().exists() else ""
    return next((line for line in text.splitlines() if line.startswith(SESSION_ENV)), None)


def disable(home, tailscale, *, restart=None):
    return tn.disable(home, run=tailscale, restart=restart or Restarts(), sleep=lambda s: None)


def test_enable_points_the_session_token_provider_at_the_webapp_token_file(home, tailscale):
    enable(home, tailscale)
    token_file = home / "webapp" / "session-token"
    assert token_file.read_text().strip()
    assert get_env_value(SESSION_ENV) == f"file:{token_file}"
    assert json.loads(record_path(home).read_text())["added_session_token"] is True


def test_existing_session_token_setting_is_left_alone_on_enable_and_off(home, tailscale):
    save_env_value(SESSION_ENV, "operator-chosen-token-value")
    enable(home, tailscale)
    assert get_env_value(SESSION_ENV) == "operator-chosen-token-value"
    assert json.loads(record_path(home).read_text())["added_session_token"] is False
    disable(home, tailscale)
    assert get_env_value(SESSION_ENV) == "operator-chosen-token-value"


def test_off_removes_the_session_token_setting_only_when_enable_added_it(home, tailscale):
    enable(home, tailscale)
    enable(home, tailscale)
    assert json.loads(record_path(home).read_text())["added_session_token"] is True
    disable(home, tailscale)
    assert session_env_line() is None and not get_env_value(SESSION_ENV)


def test_rollback_removes_the_session_token_setting_it_added(home, tailscale):
    with pytest.raises(tn.TailnetError):
        enable(home, tailscale, restart=Restarts(ok=False))
    nothing_written(home)


def test_a_different_public_url_is_refused_and_nothing_is_written(home, tailscale):
    config = load_config()
    config["webapp"]["public_url"] = "https://pal.example.com"
    save_config(config)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, tailscale)
    assert str(caught.value) == "Pal already uses a different web address. Remove it first, then try again."
    assert tailscale.calls == []
    assert load_config()["webapp"]["public_url"] == "https://pal.example.com"
    assert not record_path(home).exists()
    assert session_env_line() is None


def test_off_keeps_a_public_url_that_is_no_longer_ours(home, tailscale):
    enable(home, tailscale)
    config = load_config()
    config["webapp"]["public_url"] = "https://pal.example.com"
    save_config(config)
    disable(home, tailscale)
    assert load_config()["webapp"]["public_url"] == "https://pal.example.com"
    assert not record_path(home).exists()


def test_tailscale_app_binary_is_found_when_not_on_path(home, monkeypatch, tmp_path):
    binary = tmp_path / "tailscale"
    binary.write_text("#!/bin/sh\n")
    binary.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    monkeypatch.setattr(tn, "_TAILSCALE_KNOWN_DIRS", (str(tmp_path),))
    fake = FakeTailscale()
    seen = []

    def run(argv, **kwargs):
        seen.append(argv[0])
        return fake(argv, **kwargs)

    assert enable(home, run)["enabled"] is True
    assert set(seen) == {str(binary)}


def test_the_macos_app_directory_is_a_known_location():
    assert "/Applications/Tailscale.app/Contents/MacOS" in tn._TAILSCALE_KNOWN_DIRS


def test_serve_that_timed_out_after_applying_is_still_undone(home, monkeypatch):
    fake = FakeTailscale(serve_times_out=True)
    fake.install(monkeypatch)
    with pytest.raises(tn.TailnetError):
        enable(home, fake)
    assert fake.serve_calls(off=True) == [["serve", "--https=443", "off"]]
    assert fake.serve_config == {}
    nothing_written(home)


def test_serve_targets_the_configured_bind_host(home, tailscale):
    config = load_config()
    config["webapp"]["host"] = "::1"
    save_config(config)
    enable(home, tailscale)
    assert tailscale.serve_calls(off=False) == [["serve", "--bg", "--https=443", "http://[::1]:9120"]]


def test_serve_entry_for_an_older_port_is_not_ours(home, tailscale):
    enable(home, tailscale)
    config = load_config()
    config["webapp"]["port"] = 9200
    save_config(config)
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, tailscale)
    assert str(caught.value) == "Tailscale already serves something at this address. Turn it off first."
    assert len(tailscale.serve_calls()) == 1


def test_off_runs_in_order_and_a_failed_serve_off_keeps_the_record_for_a_retry(home, monkeypatch):
    fake = FakeTailscale()
    fake.install(monkeypatch)
    enable(home, fake)
    fake.off_returncode = 1
    with pytest.raises(tn.TailnetError):
        disable(home, fake)
    assert record_path(home).exists()
    assert not load_config()["webapp"].get("public_url")
    assert session_env_line() is None
    assert tn.status(home, check=reachable)["enabled"] is False
    fake.off_returncode = 0
    restarts = Restarts()
    disable(home, fake, restart=restarts)
    assert not record_path(home).exists() and fake.serve_config == {}
    assert restarts.count == 1


def test_off_never_removes_a_foreign_serve_entry(home, tailscale):
    enable(home, tailscale)
    tailscale.serve_config = serving("http://127.0.0.1:3000")
    disable(home, tailscale)
    assert tailscale.serve_calls(off=True) == []
    assert tailscale.serve_config == serving("http://127.0.0.1:3000")
    assert not record_path(home).exists()
    assert not load_config()["webapp"].get("public_url")


def test_restart_refused_for_a_live_chat_rolls_back_with_a_plain_message(home, tailscale, monkeypatch):
    from hermes_cli import web_server_gateway
    monkeypatch.setattr(web_server_gateway, "_restart_gateway_after", lambda *a, **k: {
        "restart_started": False, "restart_error": "a chat is running", "restart_busy": True})
    with pytest.raises(tn.TailnetError) as caught:
        tn.enable(home, run=tailscale, check=reachable, restart=tn._restart_gateway, sleep=lambda s: None)
    assert str(caught.value) == "Pal is busy with a chat right now. Try again when it finishes."
    nothing_written(home)
    assert tailscale.serve_config == {}


def test_off_refused_restart_still_reports_that_access_is_off(home, tailscale, monkeypatch):
    enable(home, tailscale)
    from hermes_cli import web_server_gateway
    monkeypatch.setattr(web_server_gateway, "_restart_gateway_after", lambda *a, **k: {
        "restart_started": False, "restart_busy": True})
    with pytest.raises(tn.TailnetError) as caught:
        tn.disable(home, run=tailscale, restart=tn._restart_gateway, sleep=lambda s: None)
    assert str(caught.value) == "Tailscale access is off, but Pal couldn't restart. Restart Pal to finish."


def test_funnel_on_for_the_address_is_refused_by_enable_and_off(home, tailscale):
    enable(home, tailscale)
    tailscale.serve_config = {**tailscale.serve_config, "AllowFunnel": {"pal-host.tail1234.ts.net:443": True}}
    expected = "Tailscale Funnel is on for this address. Turn it off first, then try again."
    with pytest.raises(tn.TailnetError) as caught:
        enable(home, tailscale)
    assert str(caught.value) == expected
    with pytest.raises(tn.TailnetError) as caught:
        disable(home, tailscale)
    assert str(caught.value) == expected
    assert record_path(home).exists()
    assert load_config()["webapp"]["public_url"] == URL
    assert tailscale.serve_calls(off=True) == []
