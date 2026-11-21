from __future__ import annotations

import hermes_yaml as yaml
import pytest

from tests.tui_gateway.test_oauth_client_connect import (
    FIGMA_CLIENT_ID, OWNER_SECRET, _call, _ok, _save, public_url, root)

__all__ = ["public_url", "root"]


@pytest.fixture
def started(monkeypatch):
    flows = []

    def fake_start(home, name, cfg, client_redirect_uri=None):
        flows.append({"name": name, "cfg": cfg})
        return {"session_id": f"s{len(flows)}", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    def fake_gateway(home, name, cfg, redirect_uri):
        flows.append({"name": name, "cfg": cfg})
        return {"session_id": f"s{len(flows)}", "auth_url": "https://www.figma.com/oauth?x=1", "flow": "pkce"}

    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_flow", fake_start)
    monkeypatch.setattr("tui_gateway.mcp_oauth_sessions.start_gateway_flow", fake_gateway)
    return flows


def _config(root):
    return yaml.safe_load((root / "profiles" / "work" / "config.yaml").read_text()).get("mcp_servers") or {}


def _write_accounts(root, *aliases):
    template = {"url": "https://mcp.figma.com/mcp", "transport": "http", "auth": "oauth", "enabled": True,
                "accounts": {alias: {} for alias in aliases}}
    (root / "profiles" / "work" / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {"figma": template}}))


def test_the_first_connect_signs_in_to_the_default_account_with_no_secret_in_the_flow(root, public_url, started):
    _save("figma", FIGMA_CLIENT_ID)

    _ok("connectors.oauth_client.connect", slug="figma")

    assert started[0]["name"] == "figma@default"
    assert started[0]["cfg"]["oauth"]["client_id"] == FIGMA_CLIENT_ID
    assert OWNER_SECRET not in str(started[0]["cfg"])
    assert "prompt" not in started[0]["cfg"]["oauth"]


def test_a_second_account_signs_in_under_its_own_name_with_the_account_prompt(root, public_url, started):
    _save("figma", FIGMA_CLIENT_ID)
    _write_accounts(root, "default")

    _ok("connectors.oauth_client.connect", slug="figma", account="work", create=True)

    assert started[0]["name"] == "figma@work"
    assert started[0]["cfg"]["oauth"]["prompt"] == "select_account login"
    assert OWNER_SECRET not in (root / "profiles" / "work" / "config.yaml").read_text()
    assert FIGMA_CLIENT_ID in str(_config(root)["figma"]["oauth"])


def test_an_account_name_that_is_taken_is_refused_before_anything_starts(root, public_url, started):
    _save("figma", FIGMA_CLIENT_ID)
    _write_accounts(root, "default", "work")

    response = _call("connectors.oauth_client.connect", "work", slug="figma", account="work", create=True)

    assert response["error"]["code"] == 4090 and response["error"]["data"]["reason"] == "ALIAS_TAKEN"
    assert started == []


def test_removing_one_account_keeps_the_client_secret_and_the_last_removal_forgets_it(root, public_url, started):
    _save("figma", FIGMA_CLIENT_ID)
    _ok("connectors.oauth_client.connect", slug="figma")
    _write_accounts(root, "default", "work")
    env_file = root / "profiles" / "work" / ".env"
    assert "FIGMA_CLIENT_SECRET" in env_file.read_text()

    assert _ok("connectors.oauth_client.remove", slug="figma", account="work")["removed"] is True
    assert list(_config(root)["figma"]["accounts"]) == ["default"]
    assert "FIGMA_CLIENT_SECRET" in env_file.read_text()

    assert _ok("connectors.oauth_client.remove", slug="figma", account="default")["removed"] is True
    assert "figma" not in _config(root)
    assert "FIGMA_CLIENT_SECRET" not in env_file.read_text()
    assert _call("connectors.oauth_client.remove", "work", slug="figma", account="ghost")["error"]["code"] == 4064
