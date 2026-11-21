from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping

from tools.connectors.mcp_oauth_redirect import (
    GATEWAY_CALLBACK_PATH,
    client_metadata_document,
    client_metadata_url,
)
from tools.mcp_accounts import registration_name

UNAVAILABLE_MESSAGE = "This app needs your Pal's public web address. Set it up on your Pal first."


class PublicAddressRequired(RuntimeError):
    def __init__(self) -> None:
        super().__init__(UNAVAILABLE_MESSAGE)


def public_base(hermes_home: str | Path) -> str | None:
    from gateway.webapp_listener import webapp_settings
    url = webapp_settings(Path(hermes_home)).public_url or ""
    return url.rstrip("/") if url.startswith("https://") else None


def entry_for(server_name: str, cfg: Mapping[str, Any] | None):
    from hermes_cli.pal_connectors import load_pal_connectors
    name = registration_name(server_name)
    entry = next((e for e in load_pal_connectors() if e.id == name and e.cimd), None)
    return entry if entry is not None and (cfg or {}).get("url") == entry.mcp_url else None


def document_url(hermes_home: str | Path) -> str:
    base = public_base(hermes_home)
    if base is None:
        raise PublicAddressRequired()
    return client_metadata_url(base)


def callback_url(hermes_home: str | Path) -> str:
    base = public_base(hermes_home)
    if base is None:
        raise PublicAddressRequired()
    return base + GATEWAY_CALLBACK_PATH


def document(hermes_home: str | Path) -> dict | None:
    base = public_base(hermes_home)
    return client_metadata_document(base) if base else None
