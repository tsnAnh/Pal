import hashlib
import json
import logging
import re
import threading
import time
from pathlib import Path
from typing import Any, Iterable

from agent.skill_utils import (
    CONNECTOR_KIND_HOSTED, CONNECTOR_KIND_MCP, ConnectorRef, skill_connector_requirements)
from hermes_constants import get_hermes_home

logger = logging.getLogger(__name__)

CONNECTOR_NOT_CONNECTED = "connector_not_connected"
CONNECTOR_BLOCKED_PREFIX = "Connector not connected for skill "
_HOSTED_TTL_SECONDS = 30.0
_HOSTED_FAILURE_TTL_SECONDS = 60.0
_HOSTED_LIST_TIMEOUT_SECONDS = 5.0
_HOSTED_BLOCKING_DEADLINE_SECONDS = 5.0
_HOSTED_PROMPT_DEADLINE_SECONDS = 2.0
_HOSTED_CACHE_MAX = 64
_HOSTED_REFRESH_MAX_INFLIGHT = 4

_hosted_cache: dict[tuple[str, str], tuple[float, frozenset[str]]] = {}
_hosted_inflight: dict[tuple[str, str], threading.Event] = {}
_hosted_lock = threading.Lock()


def _mcp_connected(names: Iterable[str], home: Path) -> frozenset[str]:
    wanted = set(names)
    if not wanted:
        return frozenset()
    try:
        from tools.mcp_oauth import HermesTokenStorage
        from tools.mcp_tool_common import mcp_server_enabled
        from tools.mcp_tool_config import _load_mcp_config
        servers = _load_mcp_config(interpolate=False)
    except Exception:
        logger.debug("MCP connector state unavailable", exc_info=True)
        return frozenset()
    connected: set[str] = set()
    for name in wanted:
        cfg = servers.get(name)
        if not isinstance(cfg, dict) or not mcp_server_enabled(cfg):
            continue
        try:
            if str(cfg.get("auth") or "").lower().strip() == "oauth" and not HermesTokenStorage(
                    name, hermes_home=home).has_cached_tokens():
                continue
        except Exception:
            logger.debug("MCP token check failed for server %r", name, exc_info=True)
            continue
        connected.add(name)
    return frozenset(connected)


def _token_fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


def _fetch_hosted_slugs(key: tuple[str, str]) -> frozenset[str]:
    now = time.monotonic()
    try:
        from tools.connectors.managed import managed_client
        items = managed_client(creates_guest=False).list_connectors(timeout=_HOSTED_LIST_TIMEOUT_SECONDS)
        slugs = frozenset(
            str(item.get("connector", "")).lower() for item in items
            if isinstance(item, dict) and item.get("connected") and item.get("enabled", True))
        expires = now + _HOSTED_TTL_SECONDS
    except Exception as exc:  # health: allow BLE001 -- fail-closed boundary; logs only the type, the message may echo credentials
        logger.debug("Hosted connector list failed: %s", type(exc).__name__)
        slugs, expires = frozenset(), now + _HOSTED_FAILURE_TTL_SECONDS
    with _hosted_lock:
        if key not in _hosted_cache and len(_hosted_cache) >= _HOSTED_CACHE_MAX:
            _hosted_cache.clear()
        _hosted_cache[key] = (expires, slugs)
    return slugs


def _start_hosted_refresh(key: tuple[str, str]) -> threading.Event | None:
    with _hosted_lock:
        flight = _hosted_inflight.get(key)
        if flight is not None:
            return flight
        if len(_hosted_inflight) >= _HOSTED_REFRESH_MAX_INFLIGHT:
            return None
        flight = _hosted_inflight[key] = threading.Event()

    def _run() -> None:
        try:
            _fetch_hosted_slugs(key)
        finally:
            with _hosted_lock:
                _hosted_inflight.pop(key, None)
            flight.set()

    try:
        from agent.memory_provider import spawn_context_thread
        spawn_context_thread(_run, name="skill-connector-refresh").start()
    except Exception:
        with _hosted_lock:
            _hosted_inflight.pop(key, None)
        flight.set()
        logger.debug("Hosted connector refresh could not start", exc_info=True)
        return None
    return flight


def _hosted_key(home: Path) -> tuple[str, str] | None:
    try:
        from tools.managed_tool_gateway import peek_nous_access_token
        token = peek_nous_access_token()
    except Exception:
        logger.debug("Hosted connector token probe failed", exc_info=True)
        return None
    return (str(home), _token_fingerprint(token)) if token else None


def _hosted_connected_slugs(home: Path, *, blocking: bool) -> frozenset[str]:
    key = _hosted_key(home)
    if key is None:
        return frozenset()
    with _hosted_lock:
        hit = _hosted_cache.get(key)
    if hit is not None and hit[0] > time.monotonic():
        return hit[1]
    flight = _start_hosted_refresh(key)
    if not blocking:
        return hit[1] if hit is not None else frozenset()
    settled_in_time = flight is not None and flight.wait(_HOSTED_BLOCKING_DEADLINE_SECONDS)
    with _hosted_lock:
        settled = _hosted_cache.get(key)
        now = time.monotonic()
        if settled is not None and settled[0] > now and (settled_in_time or settled is not hit):
            return settled[1]
        _hosted_cache[key] = (now + _HOSTED_FAILURE_TTL_SECONDS, frozenset())
    return frozenset()


def warm_hosted_connectors(refs: Iterable[ConnectorRef], *, deadline: float = _HOSTED_PROMPT_DEADLINE_SECONDS) -> None:
    if not any(r.kind == CONNECTOR_KIND_HOSTED for r in refs):
        return
    key = _hosted_key(get_hermes_home())
    if key is None:
        return
    with _hosted_lock:
        if key in _hosted_cache:
            return
    flight = _start_hosted_refresh(key)
    if flight is not None:
        flight.wait(deadline)


def clear_connector_cache() -> None:
    with _hosted_lock:
        _hosted_cache.clear()


def connected_among(refs: Iterable[ConnectorRef], *, blocking: bool = False) -> frozenset[ConnectorRef]:
    wanted = frozenset(refs)
    if not wanted:
        return frozenset()
    home = get_hermes_home()
    mcp = _mcp_connected((r.name for r in wanted if r.kind == CONNECTOR_KIND_MCP), home)
    hosted_wanted = [r for r in wanted if r.kind == CONNECTOR_KIND_HOSTED]
    hosted = _hosted_connected_slugs(home, blocking=blocking) if hosted_wanted else frozenset()
    return frozenset(
        r for r in wanted
        if (r.kind == CONNECTOR_KIND_MCP and r.name in mcp) or (r.kind == CONNECTOR_KIND_HOSTED and r.name in hosted))


def unmet_refs(refs: Iterable[ConnectorRef], *, blocking: bool = False) -> tuple[ConnectorRef, ...]:
    refs = tuple(refs)
    connected = connected_among(refs, blocking=blocking)
    return tuple(r for r in refs if r not in connected)


def unmet_connectors(frontmatter: dict[str, Any], *, blocking: bool = False) -> tuple[ConnectorRef, ...]:
    return unmet_refs(skill_connector_requirements(frontmatter), blocking=blocking)


def connector_state_key(refs: Iterable[ConnectorRef]) -> tuple[str, ...]:
    return tuple(sorted(r.label for r in connected_among(refs)))


def refs_from_labels(labels: Any) -> tuple[ConnectorRef, ...]:
    return skill_connector_requirements({"connector": labels})


def unmet_summary(unmet: tuple[ConnectorRef, ...]) -> str:
    names = [r.display_name for r in unmet]
    if len(names) == 1:
        return f"the {names[0]} connector"
    joined = ", ".join(names[:-1]) + f" and {names[-1]}" if len(names) > 2 else " and ".join(names)
    return f"the {joined} connectors"


def connector_denial(skill_name: str, unmet: tuple[ConnectorRef, ...]) -> str:
    verb = "isn't" if len(unmet) == 1 else "aren't"
    return json.dumps({
        "success": False,
        "reason": CONNECTOR_NOT_CONNECTED,
        "error": f"Skill '{skill_name}' requires {unmet_summary(unmet)}, which {verb} connected for this bot.",
        "connectors": [r.display_name for r in unmet],
        "hint": "Connect it in this bot's connector settings, then try again.",
    }, ensure_ascii=False)


def connector_blocked_label(identifier: str, payload: dict) -> str | None:
    if payload.get("reason") != CONNECTOR_NOT_CONNECTED:
        return None
    names = payload.get("connectors") or []
    needs = f"the {' and '.join(map(str, names))} connector" + ("s" if len(names) > 1 else "") if names else "a connector"
    return f"{CONNECTOR_BLOCKED_PREFIX}{identifier}: needs {needs}"


_BLOCKED_LABEL = re.compile(rf"^{re.escape(CONNECTOR_BLOCKED_PREFIX)}(?P<skill>.+?): needs (?P<needs>.+)$")


def connector_blocked_notice(label: str) -> str | None:
    match = _BLOCKED_LABEL.match(label)
    if match is None:
        return None
    return f"Skipped {match['skill']}: connect {match['needs']} to use it."
