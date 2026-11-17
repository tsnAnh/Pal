from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from urllib.parse import urlparse

import hermes_yaml as yaml

CATALOG_PATH = Path(__file__).parent / "data" / "pal_connectors.yaml"


class ConnectionMethod(str, Enum):
    MCP_OAUTH = "mcp_oauth"
    OAUTH_CLIENT = "oauth_client"
    API_KEY = "api_key"
    NATIVE = "native"
    NONE = "none"


@dataclass(frozen=True)
class OAuthEndpoints:
    authorization_url: str
    token_url: str


@dataclass(frozen=True)
class PalConnector:
    id: str
    name: str
    icon: str
    category: str
    method: ConnectionMethod
    verified: bool
    source: str
    mcp_url: str | None = None
    oauth: OAuthEndpoints | None = None
    scopes: tuple[str, ...] = ()
    replaces_portal_slug: str | None = None
    notes: str | None = None


class PalCatalogError(ValueError):
    pass


_REQUIRED = ("id", "name", "icon", "category", "method", "verified", "source")
_OPTIONAL = ("mcp_url", "oauth", "scopes", "replaces_portal_slug", "notes")


def _https(value: object, field: str, cid: str) -> str:
    if not isinstance(value, str) or urlparse(value).scheme not in ("https", "http") or not urlparse(value).netloc:
        raise PalCatalogError(f"{cid}: {field} must be an absolute URL")
    return value


def _parse_entry(raw: object) -> PalConnector:
    if not isinstance(raw, dict):
        raise PalCatalogError("connector entry must be a mapping")
    cid = str(raw.get("id") or "?")
    missing = [k for k in _REQUIRED if k not in raw]
    unknown = sorted(set(raw) - set(_REQUIRED) - set(_OPTIONAL))
    if missing or unknown:
        raise PalCatalogError(f"{cid}: missing {missing}, unknown {unknown}")
    for key in ("id", "name", "icon", "category"):
        if not isinstance(raw[key], str) or not raw[key].strip():
            raise PalCatalogError(f"{cid}: {key} must be a non-empty string")
    if not isinstance(raw["verified"], bool):
        raise PalCatalogError(f"{cid}: verified must be a boolean")
    try:
        method = ConnectionMethod(raw["method"])
    except ValueError as exc:
        raise PalCatalogError(f"{cid}: unknown method {raw['method']!r}") from exc
    oauth = None
    if (o := raw.get("oauth")) is not None:
        if not isinstance(o, dict) or set(o) != {"authorization_url", "token_url"}:
            raise PalCatalogError(f"{cid}: oauth needs exactly authorization_url and token_url")
        oauth = OAuthEndpoints(_https(o["authorization_url"], "oauth", cid), _https(o["token_url"], "oauth", cid))
    scopes = raw.get("scopes", [])
    if not isinstance(scopes, list) or not all(isinstance(s, str) and s for s in scopes):
        raise PalCatalogError(f"{cid}: scopes must be a list of strings")
    mcp_url = _https(raw["mcp_url"], "mcp_url", cid) if raw.get("mcp_url") is not None else None
    if method is ConnectionMethod.OAUTH_CLIENT and oauth is None and mcp_url is None:
        raise PalCatalogError(f"{cid}: oauth_client needs oauth endpoints or an mcp_url")
    return PalConnector(
        id=raw["id"], name=raw["name"], icon=raw["icon"], category=raw["category"], method=method,
        verified=raw["verified"], source=_https(raw["source"], "source", cid), mcp_url=mcp_url, oauth=oauth,
        scopes=tuple(scopes), replaces_portal_slug=raw.get("replaces_portal_slug"), notes=raw.get("notes"),
    )


def load_pal_connectors(path: Path = CATALOG_PATH) -> tuple[PalConnector, ...]:
    doc = yaml.safe_load(path.read_text(encoding="utf-8-sig"))
    if not isinstance(doc, dict) or doc.get("version") != 1 or not isinstance(doc.get("connectors"), list):
        raise PalCatalogError("catalog needs version: 1 and a connectors list")
    entries = tuple(_parse_entry(raw) for raw in doc["connectors"])
    seen: set[str] = set()
    for entry in entries:
        if entry.id in seen:
            raise PalCatalogError(f"duplicate connector id {entry.id}")
        seen.add(entry.id)
    return entries
