from __future__ import annotations

import sqlite3
from pathlib import Path

from tui_gateway.contracts.capabilities import CapabilityId, CapabilityRow, CapabilityState

YOUTUBE_KEY = "YOUTUBE_API_KEY"
MAPS_KEY = "GOOGLE_MAPS_API_KEY"
WEB_PROVIDER_KEYS = "TAVILY_API_KEY, PERPLEXITY_API_KEY, EXA_API_KEY, FIRECRAWL_API_KEY, BRAVE_SEARCH_API_KEY or SEARXNG_URL"
DEEP_SEARCH_SKILL = "deep-search"
YOUTUBE_SKILL = "youtube-content"
MAPS_SKILL = "maps"
BROWSER_LABEL = "Browser on your machine"


def _row(cap: CapabilityId, label: str, state: CapabilityState, reason: str | None = None, *,
         key_name: str | None = None, setting: str | None = None) -> CapabilityRow:
    return CapabilityRow(id=cap, label=label, state=state, reason=reason, key_name=key_name, setting=setting)


def _key_set(name: str) -> bool:
    from hermes_cli.config import get_env_value
    return bool((get_env_value(name) or "").strip())


def _web_usable() -> bool:
    from tools import web_tools
    return bool(web_tools.check_web_api_key())


def _skills_disabled() -> set[str]:
    from agent.skill_utils import get_disabled_skill_names
    return set(get_disabled_skill_names())


def _web_row() -> CapabilityRow:
    label = "Web search and reading pages"
    if _web_usable():
        return _row(CapabilityId.WEB, label, CapabilityState.ON)
    return _row(CapabilityId.WEB, label, CapabilityState.OFF,
                f"No web search provider is set. Set one of {WEB_PROVIDER_KEYS} from your terminal, "
                "or pick a provider with web.search_backend.", setting="web.search_backend")


def _skill_off(cap: CapabilityId, label: str, skill: str) -> CapabilityRow:
    return _row(cap, label, CapabilityState.OFF, f"The {skill} skill is turned off in this bot's skills settings.",
                setting="skills.disabled")


def _deep_search_row(disabled: set[str], web: CapabilityRow) -> CapabilityRow:
    label = "Deep search"
    if DEEP_SEARCH_SKILL in disabled:
        return _skill_off(CapabilityId.DEEP_SEARCH, label, DEEP_SEARCH_SKILL)
    if web.state is not CapabilityState.ON:
        return _row(CapabilityId.DEEP_SEARCH, label, CapabilityState.OFF, "Deep search needs web search, which is off.",
                    setting=web.setting)
    return _row(CapabilityId.DEEP_SEARCH, label, CapabilityState.ON)


def _youtube_row(disabled: set[str]) -> CapabilityRow:
    label = "YouTube"
    if YOUTUBE_SKILL in disabled:
        return _skill_off(CapabilityId.YOUTUBE, label, YOUTUBE_SKILL)
    if _key_set(YOUTUBE_KEY):
        return _row(CapabilityId.YOUTUBE, label, CapabilityState.ON)
    return _row(CapabilityId.YOUTUBE, label, CapabilityState.ON,
                f"Transcripts only. Search and channel stats need {YOUTUBE_KEY}; set it from your terminal.",
                key_name=YOUTUBE_KEY)


def _maps_row(disabled: set[str]) -> CapabilityRow:
    label = "Maps and opening hours"
    if MAPS_SKILL in disabled:
        return _skill_off(CapabilityId.MAPS, label, MAPS_SKILL)
    if _key_set(MAPS_KEY):
        return _row(CapabilityId.MAPS, label, CapabilityState.ON)
    return _row(CapabilityId.MAPS, label, CapabilityState.ON,
                f"OpenStreetMap only. Google Places needs {MAPS_KEY}; set it from your terminal.", key_name=MAPS_KEY)


def _browser_connector():
    from gateway.device_actions import Connector
    return getattr(Connector, "BROWSER", None)


def _browser_row(home: Path) -> CapabilityRow:
    connector = _browser_connector()
    if connector is None:
        return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.NOT_YET_AVAILABLE,
                    "Not available yet in this version.")
    from gateway import device_connectors
    try:
        known = device_connectors.known_device_ids(home)
        enabled = device_connectors.open_devices(home, connector)
    except device_connectors.StoreUnreadable:
        return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.UNAVAILABLE, "Device list could not be read.")
    if enabled:
        return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.ON)
    if not known:
        return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.UNAVAILABLE, "No device online.")
    labels = _device_labels(home, known)
    return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.OFF,
                f"Browser connector off on {', '.join(labels)}.")


def _device_labels(home: Path, device_ids: list[str]) -> list[str]:
    from gateway import device_registry
    from hermes_constants import profile_name_for_home
    try:
        records = {r.device_id: r.label for r in device_registry.list_devices(device_registry.install_root(profile_name_for_home(home) or "default"))}
    except (OSError, sqlite3.Error):
        records = {}
    return [records.get(device_id) or device_id for device_id in device_ids]


def capability_rows(home: Path) -> list[CapabilityRow]:
    disabled = _skills_disabled()
    web = _web_row()
    return [web, _deep_search_row(disabled, web), _youtube_row(disabled), _maps_row(disabled), _browser_row(home)]
