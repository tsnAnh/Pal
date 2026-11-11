from __future__ import annotations

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class CapabilityId(WireEnum):
    WEB = "web"
    DEEP_SEARCH = "deep_search"
    YOUTUBE = "youtube"
    MAPS = "maps"
    BROWSER = "browser"


class CapabilityState(WireEnum):
    ON = "on"
    OFF = "off"
    UNAVAILABLE = "unavailable"
    NOT_YET_AVAILABLE = "not_yet_available"


class CapabilityRow(Result):
    """``reason`` is one line and is set whenever the capability is not fully usable; an ``on`` row may carry
    it for a limit that still leaves it working (``OpenStreetMap only``). ``key_name`` is the name of the
    environment variable that would lift the limit, never its value. ``setting`` is the config.yaml path
    when a setting, not a key, is what is missing."""

    id: CapabilityId
    label: str
    state: CapabilityState
    reason: str | None = None
    key_name: str | None = None
    setting: str | None = None


class CapabilitiesStatusResult(Result):
    profile: str
    capabilities: list[CapabilityRow]


method("capabilities.status", params=ProfileParams, result=CapabilitiesStatusResult,
       doc="Which of the five bot capabilities (web, deep search, YouTube, maps, own-machine browser) are usable "
           "for one bot, with the reason and the key name or setting when not. Read-only; never carries a key value.")
