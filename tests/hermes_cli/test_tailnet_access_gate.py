import json
import types

import pytest
from starlette.testclient import TestClient

from hermes_cli import tailnet_access as tn
from hermes_cli.config import get_env_path, load_config, load_env, save_config
from hermes_constants import get_hermes_home
from tests.hermes_cli.test_tailnet_access import FakeTailscale, Restarts, reachable

URL = "https://pal-host.tail1234.ts.net"
PROVIDER_ENV = ("HERMES_DASHBOARD_BASIC_AUTH_SECRET", "HERMES_DASHBOARD_SESSION_TOKEN")


@pytest.fixture
def enabled_home(monkeypatch):
    for name in PROVIDER_ENV:
        monkeypatch.setenv(name, "")
        monkeypatch.delenv(name)
    home = get_hermes_home()
    config = load_config()
    config["webapp"] = {**config.get("webapp", {}), "enabled": True, "port": 9120}
    save_config(config)
    fake = FakeTailscale()
    fake.install(monkeypatch)
    tn.enable(home, run=fake, check=reachable, restart=Restarts(), sleep=lambda s: None)
    return home


def _gate_the_webapp(home, monkeypatch, *, load_provider_env=True):
    from gateway.webapp_listener import browser_session_token, webapp_settings
    from hermes_cli import web_server
    from hermes_cli.dashboard_auth import clear_providers, registry
    from plugins.dashboard_auth import basic, session_token

    if load_provider_env:
        for name, value in load_env().items():
            if name in PROVIDER_ENV:
                monkeypatch.setenv(name, value)
    settings = webapp_settings(home)
    state = web_server.app.state
    for name in ("auth_required", "trusted_public_hosts", "trusted_public_origins", "listener_public_url",
                 "ui_surface", "webapp_home", "withhold_session_token", "bound_host", "bound_port"):
        monkeypatch.setattr(state, name, getattr(state, name, None), raising=False)
    clear_providers()
    context = types.SimpleNamespace(register_dashboard_auth_provider=registry.register_provider)
    basic.register(context)
    session_token.register(context)
    token = browser_session_token(home)
    monkeypatch.setattr(web_server, "_SESSION_TOKEN", token)
    state.listener_public_url = settings.public_url
    state.ui_surface = "webapp"
    state.webapp_home = home
    state.withhold_session_token = True
    web_server._configure_auth_gate(settings.host, False, None, None)
    state.bound_host, state.bound_port = settings.host, settings.port
    return settings, token, TestClient(web_server.app, base_url=settings.public_url)


@pytest.fixture(autouse=True)
def _providers_cleared():
    from hermes_cli.dashboard_auth import clear_providers
    from hermes_cli.dashboard_auth.ws_tickets import _reset_for_tests
    yield
    clear_providers()
    _reset_for_tests()


def test_enable_leaves_the_loopback_webapp_gated_and_the_local_token_accepted(enabled_home, monkeypatch):
    settings, token, client = _gate_the_webapp(enabled_home, monkeypatch)

    assert settings.enabled and settings.host in {"127.0.0.1", "localhost", "::1"}
    assert settings.public_url == URL
    assert load_config()["dashboard"]["basic_auth"]["username"] == "pal"
    assert load_env()["HERMES_DASHBOARD_SESSION_TOKEN"] == f"file:{enabled_home / 'webapp' / 'session-token'}"
    from hermes_cli import web_server
    assert web_server.app.state.auth_required is True

    accepted = client.get("/api/profiles", headers={"Authorization": f"Bearer {token}"})
    assert accepted.status_code == 200, accepted.text
    assert client.get("/api/profiles").status_code == 401
    assert client.get("/api/profiles", headers={"Authorization": "Bearer " + "x" * 43}).status_code == 401

    providers = client.get("/api/auth/providers")
    assert providers.status_code == 200
    assert any(p["supports_password"] for p in providers.json()["providers"])


def test_without_the_session_token_setting_the_local_token_is_refused_behind_the_gate(enabled_home, monkeypatch):
    env_path = get_env_path()
    env_path.write_text("".join(line for line in env_path.read_text().splitlines(keepends=True)
                                if not line.startswith("HERMES_DASHBOARD_SESSION_TOKEN")))
    monkeypatch.delenv("HERMES_DASHBOARD_SESSION_TOKEN", raising=False)
    _, token, client = _gate_the_webapp(enabled_home, monkeypatch)
    assert client.get("/api/profiles", headers={"Authorization": f"Bearer {token}"}).status_code == 401
    assert json.loads((enabled_home / "webapp" / "tailnet.json").read_text())["added_session_token"] is True
