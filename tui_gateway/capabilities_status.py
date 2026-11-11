from __future__ import annotations

from tui_gateway.contracts.capabilities import CapabilityId, CapabilityRow, CapabilityState
from tui_gateway.speech_memory_settings import MEMORY_KEYS, TTS_KEYS

YOUTUBE_KEY = "YOUTUBE_API_KEY"
MAPS_KEY = "GOOGLE_MAPS_API_KEY"
WEB_PROVIDER_KEYS = "TAVILY_API_KEY, PERPLEXITY_API_KEY, EXA_API_KEY, FIRECRAWL_API_KEY, BRAVE_SEARCH_API_KEY or SEARXNG_URL"
DEEP_SEARCH_SKILL = "deep-search"
YOUTUBE_SKILL = "youtube-content"
MAPS_SKILL = "maps"
BROWSER_LABEL = "Browser"


WEB_KEYS = ["TAVILY_API_KEY", "PERPLEXITY_API_KEY", "EXA_API_KEY", "FIRECRAWL_API_KEY", "BRAVE_SEARCH_API_KEY",
            "SEARXNG_URL"]
BROWSER_KEYS = ["BROWSER_USE_API_KEY", "BROWSERBASE_API_KEY", "BROWSERBASE_PROJECT_ID"]
SETTABLE_KEYS = frozenset([YOUTUBE_KEY, MAPS_KEY, *WEB_KEYS, *BROWSER_KEYS, *TTS_KEYS, *MEMORY_KEYS])


def _row(cap: CapabilityId, label: str, state: CapabilityState, reason: str | None = None, *,
         key_name: str | None = None, key_choices: list[str] | None = None,
         setting: str | None = None) -> CapabilityRow:
    return CapabilityRow(id=cap, label=label, state=state, reason=reason, key_name=key_name,
                         key_choices=key_choices or [], setting=setting)


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
                f"No web search provider is set. Set one of {WEB_PROVIDER_KEYS}, "
                "or pick a provider with web.search_backend.", key_choices=WEB_KEYS, setting="web.search_backend")


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
                f"Transcripts only. Search and channel stats need {YOUTUBE_KEY}.",
                key_name=YOUTUBE_KEY)


def _maps_row(disabled: set[str]) -> CapabilityRow:
    label = "Maps and opening hours"
    if MAPS_SKILL in disabled:
        return _skill_off(CapabilityId.MAPS, label, MAPS_SKILL)
    if _key_set(MAPS_KEY):
        return _row(CapabilityId.MAPS, label, CapabilityState.ON)
    return _row(CapabilityId.MAPS, label, CapabilityState.ON,
                f"OpenStreetMap only. Google Places needs {MAPS_KEY}.", key_name=MAPS_KEY)


BROWSER_PROVIDER_KEYS = "BROWSER_USE_API_KEY, or BROWSERBASE_API_KEY and BROWSERBASE_PROJECT_ID"
BROWSER_PROVIDER_SETTING = "browser.cloud_provider"


def _browser_off(reason: str) -> CapabilityRow:
    return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.OFF, reason, key_choices=BROWSER_KEYS,
                setting=BROWSER_PROVIDER_SETTING)


def _browser_row() -> CapabilityRow:
    from tools.browser_session_cdp import get_cdp_override_raw
    from tools.browser_session_cloud import browser_cfg, get_cloud_provider
    from tools.browser_use_cli import browser_exec_available
    from tools.tool_backend_helpers import normalize_browser_cloud_provider

    if not browser_exec_available():
        return _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.UNAVAILABLE,
                    "This computer cannot run a browser for the bot: the browser engine is not installed.")
    ready = _row(CapabilityId.BROWSER, BROWSER_LABEL, CapabilityState.ON)
    selected = normalize_browser_cloud_provider(browser_cfg("cloud_provider", None))
    if get_cdp_override_raw() or selected in ("local", "camofox"):
        return ready
    try:
        provider = get_cloud_provider()
    except ValueError:
        return _browser_off(f"The {selected} browser provider is selected but is not installed. "
                            "Pick another with browser.cloud_provider.")
    if provider is not None and provider.is_available():
        return ready
    return _browser_off(f"The {selected} browser provider is selected but its credentials are missing. "
                        f"Set {BROWSER_PROVIDER_KEYS}, or use the local browser.")


def capability_rows() -> list[CapabilityRow]:
    disabled = _skills_disabled()
    web = _web_row()
    return [web, _deep_search_row(disabled, web), _youtube_row(disabled), _maps_row(disabled), _browser_row()]
