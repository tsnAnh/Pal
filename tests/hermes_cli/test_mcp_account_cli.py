from __future__ import annotations

import hermes_yaml as yaml
import pytest

from hermes_cli import mcp_config
from hermes_cli.mcp_config import _get_mcp_servers, _lookup_connection
from hermes_constants import get_hermes_home

TEMPLATE = {"url": "https://mcp.linear.app/mcp", "transport": "http", "auth": "oauth", "enabled": True}


def write_servers(servers: dict) -> None:
    (get_hermes_home() / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": servers}, sort_keys=False))


def test_an_account_name_resolves_to_that_accounts_connection():
    write_servers({"linear": {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})

    name, cfg = _lookup_connection("linear@home", _get_mcp_servers())

    assert name == "linear@home" and cfg["url"] == TEMPLATE["url"] and "accounts" not in cfg


def test_a_connector_with_one_account_resolves_without_a_suffix():
    write_servers({"linear": {**TEMPLATE, "accounts": {"work": {}}}})

    assert _lookup_connection("linear", _get_mcp_servers())[0] == "linear@work"


def test_several_accounts_without_a_suffix_print_which_ones_exist(capsys):
    write_servers({"linear": {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})

    assert _lookup_connection("linear", _get_mcp_servers()) is None

    out = capsys.readouterr().out
    assert "linear@<account>" in out and "work, home" in out


def test_a_plain_server_and_an_unknown_name_behave_as_before(capsys):
    write_servers({"custom": {"url": "https://custom.example/mcp"}})

    assert _lookup_connection("custom", _get_mcp_servers())[0] == "custom"
    assert _lookup_connection("nope", _get_mcp_servers()) is None
    assert "not found" in capsys.readouterr().out


def test_login_and_test_run_against_the_named_account(monkeypatch):
    write_servers({"linear": {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    seen = []
    monkeypatch.setattr(mcp_config, "_reauth_oauth_server", lambda name, cfg, flow=None: seen.append((name, cfg.get("url"))) or True)

    mcp_config.cmd_mcp_login(type("Args", (), {"name": "linear@home"})())

    assert seen == [("linear@home", TEMPLATE["url"])]


def test_remove_by_account_name_removes_only_that_account(monkeypatch):
    write_servers({"linear": {**TEMPLATE, "accounts": {"work": {}, "home": {}}}})
    monkeypatch.setattr(mcp_config, "_confirm", lambda *a, **k: True)

    mcp_config.cmd_mcp_remove(type("Args", (), {"name": "linear@work"})())

    assert list(yaml.safe_load((get_hermes_home() / "config.yaml").read_text())["mcp_servers"]["linear"]["accounts"]) == ["home"]
