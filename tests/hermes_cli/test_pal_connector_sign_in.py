"""Which Pal connectors sign in on the owner's device (``sign_in: device`` in ``pal_connectors.yaml``).

Invariants: the five vendors whose authorization server registers only loopback redirects say so on the
catalog row, every other row says ``gateway``; the field is only valid on an ``mcp_oauth`` entry with an
address; the packaged MCP manifest of each device connector names the same endpoint as its catalog entry, so a
hand-over lands on the server the app signed in to.
"""

import copy

import pytest

from hermes_cli import mcp_catalog
from hermes_cli.pal_connectors import (
    ConnectionMethod,
    PalCatalogError,
    SignIn,
    _parse_entry,
    device_sign_in_urls,
    load_pal_connectors,
)

DEVICE_SIGN_IN = {"circleci", "gamma", "intercom", "vercel", "upwork"}

BASE = {
    "id": "acme", "name": "Acme", "description": "Do things.", "icon": "acme", "category": "Other",
    "method": "mcp_oauth", "verified": True, "source": "https://acme.example/docs", "mcp_url": "https://mcp.acme.example/mcp",
}


def test_exactly_the_loopback_only_vendors_sign_in_on_the_device():
    rows = {entry.id: entry.sign_in for entry in load_pal_connectors()}
    assert {slug for slug, sign_in in rows.items() if sign_in is SignIn.DEVICE} == DEVICE_SIGN_IN
    assert {sign_in for slug, sign_in in rows.items() if slug not in DEVICE_SIGN_IN} == {SignIn.GATEWAY}


def test_a_device_connector_is_an_addressed_oauth_entry_with_accounts():
    for entry in load_pal_connectors():
        if entry.sign_in is SignIn.DEVICE:
            assert entry.method is ConnectionMethod.MCP_OAUTH and entry.mcp_url and entry.multi_account, entry.id


def test_each_device_connector_names_the_endpoint_its_packaged_manifest_installs():
    urls = device_sign_in_urls()
    assert set(urls) == DEVICE_SIGN_IN
    for slug, url in urls.items():
        entry = mcp_catalog.get_entry(slug)
        assert entry is not None and entry.auth.type == "oauth" and entry.transport.url == url, slug


@pytest.mark.parametrize("override,reason", [
    ({"sign_in": "phone"}, "unknown sign_in"),
    ({"sign_in": "device", "method": "none"}, "sign_in device needs"),
    ({"sign_in": "device", "mcp_url": None}, "sign_in device needs"),
    ({"sign_in": True}, "unknown sign_in"),
])
def test_a_malformed_sign_in_is_refused_when_the_catalog_loads(override, reason):
    raw = {**copy.deepcopy(BASE), **override}
    with pytest.raises(PalCatalogError, match=reason):
        _parse_entry(raw)


def test_no_field_means_the_gateway_signs_in():
    assert _parse_entry(copy.deepcopy(BASE)).sign_in is SignIn.GATEWAY
    assert _parse_entry({**copy.deepcopy(BASE), "sign_in": "device"}).sign_in is SignIn.DEVICE
