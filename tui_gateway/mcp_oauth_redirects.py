"""Redirect chain planning for the Pal app's MCP sign-in (``mcp.servers.oauth.start``).

The app asks for its own private-use redirect; a vendor that refuses it is retried on the gateway's https
callback, then on loopback. What reached approval is remembered per server in the profile's token state.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from tools.connectors.mcp_oauth_redirect import CHAIN, GATEWAY_CALLBACK_PATH

NOTICE = (
    "This service only accepts secure web or local-address sign-in returns, and this gateway has no secure "
    "public address set up, so after you approve you may need to switch back to Pal yourself.")


def gateway_redirect_uri(hermes_home: str) -> Optional[str]:
    """The profile's https callback URL, or None when its Webapp has no https public address."""
    from gateway.webapp_listener import webapp_settings
    public_url = webapp_settings(Path(hermes_home)).public_url or ""
    return public_url.rstrip("/") + GATEWAY_CALLBACK_PATH if public_url.startswith("https://") else None


def steps_from(preferred: object) -> tuple[str, ...]:
    """The chain, starting at the kind that reached approval last time (still falling forward on refusal)."""
    return CHAIN[CHAIN.index(preferred):] if preferred in CHAIN else CHAIN


def _storage(hermes_home: str, server_name: str):
    from tools.mcp_oauth import HermesTokenStorage
    return HermesTokenStorage(server_name, hermes_home=hermes_home)


def load_pref(hermes_home: str, server_name: str) -> dict:
    return _storage(hermes_home, server_name).redirect_pref()


def save_pref(hermes_home: str, server_name: str, **fields) -> None:
    _storage(hermes_home, server_name).update_redirect_pref(**fields)
