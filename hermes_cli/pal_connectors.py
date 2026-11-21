from __future__ import annotations

import functools
import re
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from urllib.parse import urlparse

import hermes_yaml as yaml

CATALOG_PATH = Path(__file__).parent / "data" / "pal_connectors.yaml"
FEATURED_CONNECTOR_IDS: tuple[str, ...] = ("github", "linear", "slack", "notion", "sentry")


NON_MULTI_ACCOUNT_ID = "t3code"


class ConnectionMethod(str, Enum):
    MCP_OAUTH = "mcp_oauth"
    OAUTH_CLIENT = "oauth_client"
    BOT_APP = "bot_app"
    BOT_TOKEN_STDIO = "bot_token_stdio"
    API_KEY = "api_key"
    NATIVE = "native"
    NONE = "none"


class SignIn(str, Enum):
    GATEWAY = "gateway"
    DEVICE = "device"


MULTI_ACCOUNT_METHODS = frozenset({ConnectionMethod.MCP_OAUTH, ConnectionMethod.OAUTH_CLIENT, ConnectionMethod.API_KEY})


@dataclass(frozen=True)
class OAuthEndpoints:
    authorization_url: str
    token_url: str


@dataclass(frozen=True)
class SetupLink:
    label: str
    url: str


@dataclass(frozen=True)
class SetupCopy:
    label: str
    value: str


@dataclass(frozen=True)
class SetupField:
    id: str
    label: str
    secret: bool
    prefixes: tuple[str, ...] = ()
    suffix: str | None = None


@dataclass(frozen=True)
class SetupFallback:
    label: str
    body: str
    links: tuple[SetupLink, ...] = ()


@dataclass(frozen=True)
class SetupStep:
    id: str
    kind: str
    title: str
    body: str
    links: tuple[SetupLink, ...] = ()
    copies: tuple[SetupCopy, ...] = ()
    fields: tuple[SetupField, ...] = ()
    check: str | None = None
    fallback: SetupFallback | None = None


@dataclass(frozen=True)
class StdioRecipe:
    command: str
    args: tuple[str, ...]
    env: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class SetupGuide:
    steps: tuple[SetupStep, ...]


@dataclass(frozen=True)
class ActionPolicy:
    read_tools: tuple[str, ...] = ()
    refused_tools: tuple[str, ...] = ()
    refused_message: str = ""

    def config(self) -> dict:
        return {"read_tools": list(self.read_tools), "refused_tools": list(self.refused_tools),
                "refused_message": self.refused_message}


@dataclass(frozen=True)
class PalConnector:
    id: str
    name: str
    icon: str
    category: str
    method: ConnectionMethod
    verified: bool
    source: str
    description: str
    mcp_url: str | None = None
    oauth: OAuthEndpoints | None = None
    scopes: tuple[str, ...] = ()
    notes: str | None = None
    setup: SetupGuide | None = None
    stdio: StdioRecipe | None = None
    sign_in: SignIn = SignIn.GATEWAY
    cimd: bool = False
    action_policy: ActionPolicy | None = None

    @property
    def multi_account(self) -> bool:
        return (self.method in MULTI_ACCOUNT_METHODS and self.mcp_url is not None and self.stdio is None
                and self.id != NON_MULTI_ACCOUNT_ID)


class PalCatalogError(ValueError):
    pass


_REQUIRED = ("id", "name", "description", "icon", "category", "method", "verified", "source")
_OPTIONAL = ("mcp_url", "oauth", "scopes", "notes", "setup", "stdio", "sign_in", "cimd", "action_policy")


def _https(value: object, field: str, cid: str) -> str:
    if not isinstance(value, str) or urlparse(value).scheme not in ("https", "http") or not urlparse(value).netloc:
        raise PalCatalogError(f"{cid}: {field} must be an absolute URL")
    return value


STEP_KINDS = ("public_url", "open_page", "paste", "server_picker", "access")
STEP_CHECKS = ("google_client", "github_token", "canva_client", "discord_bot")
_PINNED_PACKAGE = re.compile(r"^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*(@|==)\d+\.\d+\.\d+$")


def _text(raw: object, key: str, where: str) -> str:
    if not isinstance(raw, dict) or not isinstance(raw.get(key), str) or not raw[key].strip():
        raise PalCatalogError(f"{where}: {key} must be a non-empty string")
    return raw[key]


def _items(raw: dict, key: str, where: str) -> list:
    items = raw.get(key, [])
    if not isinstance(items, list):
        raise PalCatalogError(f"{where}: {key} must be a list")
    return items


def _parse_fallback(raw: object, cid: str, where: str) -> SetupFallback | None:
    if raw is None:
        return None
    if not isinstance(raw, dict) or set(raw) - {"label", "body", "links"}:
        raise PalCatalogError(f"{where}: fallback needs label, body and optional links")
    return SetupFallback(
        _text(raw, "label", where), _text(raw, "body", where),
        tuple(SetupLink(_text(l, "label", where), _https(l.get("url"), "link", cid)) for l in _items(raw, "links", where)))


def _parse_step(raw: object, cid: str) -> SetupStep:
    where = f"{cid}: setup step {raw.get('id') if isinstance(raw, dict) else '?'}"
    if not isinstance(raw, dict):
        raise PalCatalogError(f"{where} must be a mapping")
    unknown = sorted(set(raw) - {"id", "kind", "title", "body", "links", "copies", "fields", "check", "fallback"})
    if unknown:
        raise PalCatalogError(f"{where}: unknown {unknown}")
    kind = _text(raw, "kind", where)
    if kind not in STEP_KINDS:
        raise PalCatalogError(f"{where}: unknown kind {kind!r}")
    check = raw.get("check")
    if check is not None and check not in STEP_CHECKS:
        raise PalCatalogError(f"{where}: unknown check {check!r}")
    fields = tuple(
        SetupField(_text(f, "id", where), _text(f, "label", where), f.get("secret") is True,
                   tuple(f.get("prefixes") or ()), f.get("suffix"))
        for f in _items(raw, "fields", where))
    if (kind == "paste") != bool(fields):
        raise PalCatalogError(f"{where}: only paste steps carry fields, and paste steps need them")
    if check and kind != "paste":
        raise PalCatalogError(f"{where}: check belongs to a paste step")
    return SetupStep(
        id=_text(raw, "id", where), kind=kind, title=_text(raw, "title", where), body=_text(raw, "body", where),
        links=tuple(SetupLink(_text(l, "label", where), _https(l.get("url"), "link", cid))
                    for l in _items(raw, "links", where)),
        copies=tuple(SetupCopy(_text(c, "label", where), _text(c, "value", where)) for c in _items(raw, "copies", where)),
        fields=fields, check=check, fallback=_parse_fallback(raw.get("fallback"), cid, where))


def _parse_setup(raw: object, cid: str) -> SetupGuide:
    if not isinstance(raw, dict) or set(raw) != {"steps"} or not isinstance(raw["steps"], list) or not raw["steps"]:
        raise PalCatalogError(f"{cid}: setup needs exactly a non-empty steps list")
    steps = tuple(_parse_step(s, cid) for s in raw["steps"])
    if len({s.id for s in steps}) != len(steps):
        raise PalCatalogError(f"{cid}: duplicate setup step id")
    return SetupGuide(steps)


def _parse_stdio(raw: object, cid: str) -> StdioRecipe:
    where = f"{cid}: stdio"
    if not isinstance(raw, dict) or set(raw) != {"command", "args", "env"}:
        raise PalCatalogError(f"{where} needs exactly command, args and env")
    args, env = raw["args"], raw["env"]
    if not isinstance(args, list) or not all(isinstance(a, str) and a for a in args):
        raise PalCatalogError(f"{where}: args must be a list of strings")
    if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        raise PalCatalogError(f"{where}: env must map names to strings")
    if sum(bool(_PINNED_PACKAGE.match(a)) for a in args) != 1:
        raise PalCatalogError(f"{where}: args need exactly one package pinned to an exact version")
    return StdioRecipe(_text(raw, "command", where), tuple(args), tuple(env.items()))


def _parse_sign_in(raw: object, cid: str, method: ConnectionMethod, mcp_url: str | None) -> SignIn:
    if raw is None:
        return SignIn.GATEWAY
    try:
        sign_in = SignIn(raw)
    except ValueError as exc:
        raise PalCatalogError(f"{cid}: unknown sign_in {raw!r}") from exc
    if sign_in is SignIn.DEVICE and (method is not ConnectionMethod.MCP_OAUTH or mcp_url is None):
        raise PalCatalogError(f"{cid}: sign_in device needs an mcp_oauth entry with an mcp_url")
    return sign_in


def _parse_action_policy(raw: object, cid: str) -> ActionPolicy:
    where = f"{cid}: action_policy"
    if not isinstance(raw, dict) or set(raw) - {"read_tools", "refused_tools", "refused_message"}:
        raise PalCatalogError(f"{where} takes read_tools, refused_tools and refused_message")
    lists: dict[str, tuple[str, ...]] = {}
    for key in ("read_tools", "refused_tools"):
        names = raw.get(key, [])
        if not isinstance(names, list) or not all(isinstance(n, str) and n for n in names):
            raise PalCatalogError(f"{where}: {key} must be a list of tool names")
        lists[key] = tuple(names)
    if not lists["refused_tools"]:
        raise PalCatalogError(f"{where}: refused_tools must name at least one tool")
    return ActionPolicy(lists["read_tools"], lists["refused_tools"], _text(raw, "refused_message", where).strip())


def _parse_entry(raw: object) -> PalConnector:
    if not isinstance(raw, dict):
        raise PalCatalogError("connector entry must be a mapping")
    cid = str(raw.get("id") or "?")
    missing = [k for k in _REQUIRED if k not in raw]
    unknown = sorted(set(raw) - set(_REQUIRED) - set(_OPTIONAL))
    if missing or unknown:
        raise PalCatalogError(f"{cid}: missing {missing}, unknown {unknown}")
    for key in ("id", "name", "description", "icon", "category"):
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
    stdio = _parse_stdio(raw["stdio"], cid) if raw.get("stdio") is not None else None
    if (method is ConnectionMethod.BOT_TOKEN_STDIO) and stdio is None:
        raise PalCatalogError(f"{cid}: bot_token_stdio entries carry a stdio recipe")
    if stdio is not None and method not in (ConnectionMethod.BOT_TOKEN_STDIO, ConnectionMethod.OAUTH_CLIENT):
        raise PalCatalogError(f"{cid}: only bot_token_stdio and oauth_client entries carry a stdio recipe")
    sign_in = _parse_sign_in(raw.get("sign_in"), cid, method, mcp_url)
    cimd = raw.get("cimd", False)
    if not isinstance(cimd, bool) or (cimd and (method is not ConnectionMethod.MCP_OAUTH or mcp_url is None)):
        raise PalCatalogError(f"{cid}: cimd is a boolean for mcp_oauth entries with an mcp_url")
    policy = _parse_action_policy(raw["action_policy"], cid) if raw.get("action_policy") is not None else None
    if policy is not None and mcp_url is None:
        raise PalCatalogError(f"{cid}: action_policy needs an mcp_url")
    return PalConnector(
        id=raw["id"], name=raw["name"], icon=raw["icon"], category=raw["category"], method=method,
        verified=raw["verified"], source=_https(raw["source"], "source", cid), description=raw["description"].strip(),
        mcp_url=mcp_url, oauth=oauth,
        scopes=tuple(scopes), notes=raw.get("notes"),
        setup=_parse_setup(raw["setup"], cid) if raw.get("setup") is not None else None, stdio=stdio, sign_in=sign_in,
        cimd=cimd, action_policy=policy,
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


@functools.cache
def device_sign_in_urls() -> dict[str, str]:
    return {e.id: e.mcp_url for e in load_pal_connectors() if e.sign_in is SignIn.DEVICE and e.mcp_url}
