from __future__ import annotations

import os
import stat

import pytest

import hermes_cli.auth
import providers
from hermes_cli import models
from hermes_cli.plugin_catalog import get_catalog_entry
from providers import register_provider
from providers.base import ProviderProfile
from tests.tui_gateway.model_providers_support import canary, home, ok, row

__all__ = ["canary", "home"]

PROVIDER_ID = "claude-subscription-directsdk-experimental"
CATALOG_NAME = "claude-subscription-directsdk"
NO_CLI_HINT = "Install Claude Code on the computer running Hermes, then sign in by running claude there."
NO_PLUGIN_HINT = "Install the Claude Direct SDK plugin."
SIGNED_OUT_HINT = "Sign in to Claude Code on the computer running Hermes."


class _EvidenceProfile(ProviderProfile):
    evidence: tuple[bool, str | None] | None = (True, "token")

    def external_auth_evidence(self):
        return type(self).evidence


def _register(name, *, command="claude", evidence=(True, "token"), request=None):
    profile_cls = type(f"_{name.replace('-', '_')}", (_EvidenceProfile,), {"evidence": evidence})
    register_provider(profile_cls(name=name, display_name="Claude Direct SDK", auth_type="external_process",
                                  base_url=f"process://{name}", process_command=command))
    request.addfinalizer(lambda: _unregister(name))


def _unregister(name):
    providers._REGISTRY.pop(name, None)
    providers._PROVIDER_LIST_CACHE = None
    hermes_cli.auth.PROVIDER_REGISTRY.pop(name, None)
    models.CANONICAL_PROVIDERS[:] = [p for p in models.CANONICAL_PROVIDERS if p.slug != name]


def _make_cli(directory, name="claude"):
    directory.mkdir(parents=True, exist_ok=True)
    exe = directory / name
    exe.write_text("#!/bin/sh\nexit 0\n")
    exe.chmod(exe.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def cli(monkeypatch, tmp_path):
    _make_cli(tmp_path / "bin")
    monkeypatch.setenv("PATH", f"{tmp_path / 'bin'}{os.pathsep}/usr/bin{os.pathsep}/bin")
    monkeypatch.setattr("agent.anthropic_adapter.find_claude_code_cli", lambda command: None)


@pytest.fixture
def no_cli(monkeypatch, tmp_path):
    (tmp_path / "empty").mkdir()
    monkeypatch.setenv("PATH", str(tmp_path / "empty"))
    monkeypatch.setattr("agent.anthropic_adapter.find_claude_code_cli", lambda command: None)


@pytest.fixture
def plugin_dir(monkeypatch, tmp_path):
    state = {"dir": None, "sidecar": None}
    monkeypatch.setattr("hermes_cli.plugins_cmd._catalog_installed_dir", lambda name: state["dir"])
    monkeypatch.setattr("hermes_cli.plugins_cmd_catalog.read_catalog_sidecar", lambda directory: state["sidecar"])
    state["install"] = lambda: state.update(dir=tmp_path / "plugins" / CATALOG_NAME)
    return state


def test_the_subscription_row_is_listed_before_the_plugin_exists(home, no_cli, plugin_dir):
    listed = row(PROVIDER_ID)
    assert (listed["name"], listed["kind"], listed["state"], listed["scope"]) == (
        "Claude Direct SDK", "cli_plan", "not_set", "profile")
    assert listed["base_url_editable"] is False and listed["can_remove"] is False
    assert listed["base_url"] is None and listed["default_base_url"] is None
    assert listed["reason"] == NO_CLI_HINT


def test_the_row_is_set_only_when_the_cli_the_plugin_and_a_sign_in_are_all_there(home, cli, plugin_dir, request):
    missing = row(PROVIDER_ID)
    assert missing["state"] == "not_set" and missing["reason"] == NO_PLUGIN_HINT
    _register(PROVIDER_ID, request=request)
    plugin_dir["install"]()
    listed = row(PROVIDER_ID)
    assert listed["kind"] == "cli_plan" and listed["state"] == "set" and listed["reason"] is None
    type(providers.get_provider_profile(PROVIDER_ID)).evidence = (False, None)
    signed_out = row(PROVIDER_ID)
    assert signed_out["state"] == "not_set" and signed_out["reason"] == SIGNED_OUT_HINT


def test_a_subscription_row_cannot_be_removed_and_has_no_sign_in_flow(home, cli, plugin_dir, request):
    _register(PROVIDER_ID, request=request)
    plugin_dir["install"]()
    assert row(PROVIDER_ID)["state"] == "set"
    result = ok("model.providers.remove", {"provider": PROVIDER_ID})
    assert result["outcome"] == "nothing_to_remove" and result["provider"]["state"] == "set"


def test_other_external_process_providers_stay_unsupported(home, cli, plugin_dir, request):
    _register("acme-acp", command="acme-cli", request=request)
    listed = row("acme-acp")
    assert listed["kind"] == "unsupported" and listed["state"] == "unsupported"
    assert listed["reason"] and "command-line tool" in listed["reason"]


def test_existing_kinds_are_unchanged(home, no_cli, plugin_dir):
    kinds = {p["id"]: p["kind"] for p in ok("model.providers.list")["providers"]}
    assert kinds["deepseek"] == "api_key" and kinds["nous"] == "device_code" and kinds["bedrock"] == "unsupported"
    assert kinds[PROVIDER_ID] == "cli_plan"


def _host_check(provider=PROVIDER_ID):
    return ok("model.providers.host_check", {"provider": provider})


def test_host_check_without_the_cli_or_the_plugin(home, no_cli, plugin_dir):
    result = _host_check()
    assert result["cli_found"] is False and result["signed_in"] is False and result["plugin_installed"] is False
    assert result["install_hint"] == NO_CLI_HINT
    assert result.get("cli_version") is None and result.get("plan") is None


def test_host_check_with_the_cli_but_no_plugin_carries_the_disclosure(home, cli, plugin_dir):
    result = _host_check()
    assert result["cli_found"] is True and result["plugin_installed"] is False and result["signed_in"] is False
    assert result["install_hint"] == NO_PLUGIN_HINT
    description = " ".join(get_catalog_entry(CATALOG_NAME).description.split())
    assert result["disclosure"] == description.split("Disclosure — ", 1)[1]


def test_host_check_signed_out_and_signed_in(home, cli, plugin_dir, request):
    _register(PROVIDER_ID, evidence=(False, None), request=request)
    plugin_dir["install"]()
    signed_out = _host_check()
    assert (signed_out["cli_found"], signed_out["plugin_installed"], signed_out["signed_in"]) == (True, True, False)
    assert signed_out["install_hint"] == SIGNED_OUT_HINT
    type(providers.get_provider_profile(PROVIDER_ID)).evidence = (True, "token")
    signed_in = _host_check()
    assert signed_in["signed_in"] is True and signed_in.get("install_hint") is None


def test_the_plugin_version_is_reported_only_at_the_catalog_pin(home, cli, plugin_dir, request):
    _register(PROVIDER_ID, request=request)
    plugin_dir["install"]()
    entry = get_catalog_entry(CATALOG_NAME)
    plugin_dir["sidecar"] = {"catalog_name": CATALOG_NAME, "sha": entry.sha, "pin": entry.sha}
    assert _host_check()["plugin_version"] == entry.version
    plugin_dir["sidecar"] = {"catalog_name": CATALOG_NAME, "sha": "0" * 40, "pin": "0" * 40}
    assert _host_check().get("plugin_version") is None


def test_host_check_for_a_provider_without_one(home, no_cli, plugin_dir):
    for provider in ("deepseek", "nope"):
        result = _host_check(provider)
        assert (result["cli_found"], result["signed_in"], result["plugin_installed"]) == (False, False, False)
        assert result["install_hint"] == "This provider has no host check."


@pytest.fixture
def installer(monkeypatch, plugin_dir, request):
    calls: list[dict] = []
    outcome: dict = {"result": {"ok": True, "plugin_name": CATALOG_NAME, "enabled": True}}

    def install(identifier, **kwargs):
        calls.append({"identifier": identifier, **kwargs})
        result = outcome["result"]
        if isinstance(result, Exception):
            raise result
        if result.get("ok"):
            plugin_dir["install"]()
            _register(PROVIDER_ID, request=request)
        return result

    monkeypatch.setattr("hermes_cli.plugins_cmd.dashboard_install_plugin", install)
    install.calls, install.outcome = calls, outcome
    return install


def _install(provider=PROVIDER_ID):
    return ok("model.providers.install_plugin", {"provider": provider})


def test_install_is_unsupported_for_other_providers(home, cli, installer):
    assert _install("deepseek")["outcome"] == "unsupported" and _install("nope")["outcome"] == "unsupported"
    assert installer.calls == []


def test_install_is_refused_when_the_cli_is_missing(home, no_cli, installer):
    result = _install()
    assert result["outcome"] == "refused" and result["reason"] == NO_CLI_HINT
    assert result["provider"]["id"] == PROVIDER_ID and installer.calls == []


def test_install_is_refused_on_a_managed_host(home, cli, installer, monkeypatch):
    monkeypatch.setattr("hermes_cli.config.is_managed", lambda: True)
    result = _install()
    assert result["outcome"] == "refused" and result["reason"] and installer.calls == []


def test_install_uses_the_catalog_installer_once_and_is_idempotent(home, cli, installer):
    result = _install()
    assert result["outcome"] == "installed" and result["provider"]["state"] == "set"
    assert installer.calls == [{"identifier": "", "force": False, "enable": True, "catalog_name": CATALOG_NAME}]
    again = _install()
    assert again["outcome"] == "already_installed" and again["provider"]["state"] == "set"
    assert len(installer.calls) == 1


@pytest.mark.parametrize("outcome", [
    {"ok": False, "error": "git clone failed at /srv/hermes/plugins/tmp-1234: permission denied"},
    RuntimeError("secret detail at /srv/hermes/plugins"),
])
def test_a_failed_install_reports_a_plain_reason(home, cli, installer, outcome):
    installer.outcome["result"] = outcome
    result = _install()
    assert result["outcome"] == "failed" and result["reason"]
    assert "/srv" not in result["reason"] and "permission denied" not in result["reason"]
    assert "secret detail" not in result["reason"]
    assert result["provider"]["state"] == "not_set"
