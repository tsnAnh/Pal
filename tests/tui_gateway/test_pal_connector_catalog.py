"""The Pal app's Connect Apps list: ``connectors.catalog`` serves the Pal-owned catalog with a per-profile
status joined from the direct MCP connections, and each direct method connects through the existing
``mcp.servers.*`` path. Nothing on that path may reach the Nous Portal.

Real gateway handlers against a temp ``HERMES_HOME`` with a named profile; no network.
"""

from __future__ import annotations

import pytest

import hermes_yaml as yaml
from hermes_cli.pal_connectors import ConnectionMethod, load_pal_connectors
from tui_gateway import server

PROFILE = "work"
ENTRIES = {entry.id: entry for entry in load_pal_connectors()}


@pytest.fixture
def work_home(tmp_path, monkeypatch):
    root = tmp_path / "hermes_home"
    (root / "profiles" / PROFILE).mkdir(parents=True)
    monkeypatch.setenv("HERMES_HOME", str(root))
    return root / "profiles" / PROFILE


@pytest.fixture
def root_home(work_home):
    return work_home.parents[1]


@pytest.fixture(autouse=True)
def portal_forbidden(monkeypatch):
    def refuse(*_args, **_kwargs):
        raise AssertionError("the Pal connect path reached the Nous Portal")

    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.__init__", refuse)
    monkeypatch.setattr("tools.connectors.portal.client._default_transport", refuse)


def _ok(method, **params):
    response = server._methods[method](1, {"profile": PROFILE, **params})
    assert "error" not in response, response
    return response["result"]


def _rows():
    return {row["slug"]: row for row in _ok("connectors.catalog")["connectors"]}


def _first(method):
    return next(entry for entry in ENTRIES.values() if entry.method is method and entry.mcp_url)


def test_catalog_lists_every_pal_entry_with_its_method_and_nothing_connected(work_home):
    rows = _rows()

    assert set(rows) == set(ENTRIES)
    for cid, entry in ENTRIES.items():
        row = rows[cid]
        assert (row["name"], row["category"], row["method"], row["verified"], row["mcp_url"], row["icon"]) == (
            entry.name, entry.category, entry.method.value, entry.verified, entry.mcp_url, entry.icon)
    assert {row["status"] for cid, row in rows.items()
            if ENTRIES[cid].method is not ConnectionMethod.OAUTH_CLIENT and not ENTRIES[cid].cimd} == {"not_connected"}


def test_owner_registered_oauth_clients_need_setup(work_home):
    assert _rows()["google-workspace"]["status"] == "needs_setup"


def test_slack_is_a_per_bot_app_that_never_reads_connected_from_the_catalog(work_home):
    row = _rows()["slack"]

    assert (row["method"], row["mcp_url"], row["status"]) == ("bot_app", None, "not_connected")


def test_a_no_auth_entry_added_through_the_mcp_path_shows_connected(work_home):
    entry = _first(ConnectionMethod.NONE)

    _ok("mcp.servers.add", name=entry.id, config={"url": entry.mcp_url, "transport": "http"})

    assert _rows()[entry.id]["status"] == "connected"


def test_an_api_key_entry_keeps_the_key_out_of_config_and_shows_connected(work_home, root_home):
    entry = _first(ConnectionMethod.API_KEY)
    key = "fake-key-for-test"

    _ok("mcp.servers.add", name=entry.id, config={"url": entry.mcp_url, "transport": "http"}, bearer_token=key)

    assert _rows()[entry.id]["status"] == "connected"
    assert key not in (root_home / "config.yaml").read_text()
    assert not (work_home / "config.yaml").exists() or key not in (work_home / "config.yaml").read_text()


def test_an_oauth_entry_with_a_rejected_token_needs_reconnect_and_a_disabled_one_is_not_connected(
        root_home, monkeypatch):
    entry = _first(ConnectionMethod.MCP_OAUTH)
    _ok("mcp.servers.add", name=entry.id, config={"url": entry.mcp_url, "transport": "http"})
    monkeypatch.setattr("tools.mcp_oauth.pending_reauth_reason", lambda name: "expired" if name == entry.id else None)

    assert _rows()[entry.id]["status"] == "needs_reconnect"

    config = yaml.safe_load((root_home / "config.yaml").read_text())
    config["mcp_servers"][entry.id]["enabled"] = False
    (root_home / "config.yaml").write_text(yaml.safe_dump(config))

    assert _rows()[entry.id]["status"] == "not_connected"


T3_URL = "http://100.101.102.103:3773/mcp"


def test_t3code_is_not_connected_until_a_t3code_server_is_configured(work_home):
    row = _rows()["t3code"]

    assert (row["method"], row["mcp_url"], row["status"], row["icon"]) == ("mcp_oauth", None, "not_connected", "plugin_glyph")


def test_t3code_is_connected_once_signed_in_and_needs_reconnect_when_sign_in_expired(work_home, monkeypatch):
    import asyncio

    from mcp.shared.auth import OAuthToken

    from tools.mcp_oauth import HermesTokenStorage

    _ok("mcp.servers.add", name="t3code", config={"url": T3_URL, "transport": "http"})

    assert _rows()["t3code"]["status"] == "not_connected"

    asyncio.run(HermesTokenStorage("t3code", hermes_home=work_home).set_tokens(
        OAuthToken(access_token="tok", token_type="Bearer", expires_in=3600)))

    assert _rows()["t3code"]["status"] == "connected"

    monkeypatch.setattr("tools.mcp_oauth.pending_reauth_reason", lambda name: "expired" if name == "t3code" else None)

    assert _rows()["t3code"]["status"] == "needs_reconnect"


def test_every_featured_connector_id_is_in_the_catalog():
    from hermes_cli.pal_connectors import FEATURED_CONNECTOR_IDS

    assert set(FEATURED_CONNECTOR_IDS) <= set(ENTRIES)


def test_catalog_marks_exactly_the_featured_connectors(work_home):
    from hermes_cli.pal_connectors import FEATURED_CONNECTOR_IDS

    rows = _rows()

    assert {cid for cid, row in rows.items() if row["featured"]} == set(FEATURED_CONNECTOR_IDS)
