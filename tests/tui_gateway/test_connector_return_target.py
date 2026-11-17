"""A connect from the desktop Connectors page asks the vendor's done page to return to the desktop
app; the same connect from Pal (owner ``source: ios``, on Mac and iPhone) asks for no return target,
so the vendor keeps its own done page and Pal finishes by polling."""

import pytest

from tools.connectors import live
from tui_gateway import server


@pytest.fixture
def connect_calls(monkeypatch):
    monkeypatch.delenv("HERMES_DESKTOP", raising=False)
    monkeypatch.delenv("HERMES_DESKTOP_DEV_SERVER", raising=False)
    monkeypatch.setattr("tools.connectors.connectors_available", lambda: True)
    monkeypatch.setattr("tools.connectors.ensure_guest_identity", lambda: None)
    monkeypatch.setattr("tools.connectors.managed.ensure_guest_identity", lambda: None)
    calls = []

    class Client:
        def __init__(self, **_):
            pass

        def connections(self, names, **kwargs):
            calls.append(kwargs)
            return {"results": [{"connector": n, "status": "initiated", "redirect_url": "https://vendor.example/c"}
                                for n in names]}

    monkeypatch.setattr("tools.connectors.portal.client.PortalConnectorClient.require_authentication", lambda self: None)
    monkeypatch.setattr("tools.connectors.gateway.client.ConnectorClient", Client)
    live.reset_for_tests()
    yield calls
    live.reset_for_tests()


def _connect(owner):
    return server.handle_request({"jsonrpc": "2.0", "id": 1, "method": "connectors.connect",
                                  "params": {"owner": owner, "connectors": ["gmail"]}})


def test_desktop_page_connect_returns_to_the_desktop(connect_calls):
    assert "result" in _connect({"type": "account"})
    assert connect_calls[0]["return_to"] == "hermes-desktop"
    assert connect_calls[0]["op"]


def test_pal_connect_sends_no_hermes_return_target(connect_calls):
    assert "result" in _connect({"type": "account", "source": "ios"})
    assert "return_to" not in connect_calls[0] and "op" not in connect_calls[0]
