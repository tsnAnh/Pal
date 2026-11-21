"""A Pal-originated MCP sign-in registers through DCR and never carries a Nous-hosted client document or link.

The authorization server in the double advertises ``client_id_metadata_document_supported``. The card
sign-in path runs for real against it with a temp ``HERMES_HOME``.
"""

from __future__ import annotations

import urllib.request
from urllib.parse import parse_qs, urlsplit

import pytest

from hermes_cli.mcp_config import _get_mcp_servers
from tests.tools.t3code_double import T3CodeDouble
from tests.waiting import wait_until
from tools.connectors import mcp_oauth as connector_oauth
from tools.mcp_oauth import _maybe_use_cimd
from tui_gateway import mcp_oauth_sessions as sessions
from tui_gateway import server

pytest.importorskip("mcp.client.auth.oauth2")

NAME = "t3code"


@pytest.fixture(autouse=True)
def _fresh_state(monkeypatch):
    from tools.mcp_oauth_manager import reset_manager_for_tests
    reset_manager_for_tests()
    monkeypatch.setattr(sessions, "_sessions", {})


def sign_in_from_pal(double: T3CodeDouble) -> dict:
    added = server._methods["mcp.servers.add"](
        1, {"name": NAME, "config": {"url": double.mcp_url, "transport": "http"}})
    assert "error" not in added, added
    attempt = connector_oauth.start(NAME)
    urllib.request.urlopen(attempt.auth_url, timeout=10).read()
    wait_until(lambda: attempt.flow.snapshot().get("status") == "approved", what="sign-in approved")
    return {k: v[0] for k, v in parse_qs(urlsplit(attempt.auth_url).query).items()}


def test_pal_sign_in_registers_dynamically_even_when_the_server_offers_client_id_documents():
    with T3CodeDouble(advertises_cimd=True) as double:
        authorize = sign_in_from_pal(double)

        assert len(double.registrations) == 1
        assert authorize["client_id"].startswith("client-")
        assert "nousresearch" not in authorize["client_id"]


def test_pal_sign_in_leaves_the_server_unable_to_fall_back_to_a_client_id_document_later():
    with T3CodeDouble(advertises_cimd=True) as double:
        sign_in_from_pal(double)

        saved = _get_mcp_servers()[NAME]

        assert saved["oauth"]["cimd"] is False
        assert _maybe_use_cimd(saved["oauth"]) is None


def test_the_remote_session_hint_of_a_pal_sign_in_names_no_nous_host(monkeypatch):
    monkeypatch.setenv("SSH_CLIENT", "203.0.113.9 50000 22")

    detail = connector_oauth._ssh_detail("http://127.0.0.1:27890/callback")

    assert "ssh -N -L 27890:127.0.0.1:27890" in detail
    assert "nousresearch" not in detail
