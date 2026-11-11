from __future__ import annotations

from pydantic import Field

from .base import Params, Result, WireEnum
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


class CapabilityRow(Result):
    """``reason`` is one line and is set whenever the capability is not fully usable; an ``on`` row may carry
    it for a limit that still leaves it working (``OpenStreetMap only``). ``key_name`` is the name of the
    environment variable that would lift the limit, never its value. ``setting`` is the config.yaml path
    when a setting, not a key, is what is missing. ``key_choices`` lists the settable key names when any one of
    several providers' keys would turn the capability on (web search, the cloud browser)."""

    id: CapabilityId
    label: str
    state: CapabilityState
    reason: str | None = None
    key_name: str | None = None
    key_choices: list[str] = Field(default_factory=list)
    setting: str | None = None


class CapabilitiesStatusResult(Result):
    profile: str
    capabilities: list[CapabilityRow]


method("capabilities.status", params=ProfileParams, result=CapabilitiesStatusResult,
       doc="Which of the five bot capabilities (web, deep search, YouTube, maps, the bot's own browser) are usable "
           "for one bot, with the reason and the key name or setting when not. Read-only; never carries a key value.")


class CapabilitySetKeyParams(ProfileParams):
    key_name: str = Field(pattern=r"^[A-Z][A-Z0-9_]{2,63}$")
    value: str | None = Field(default=None, max_length=4096, repr=False)


class CapabilitySetKeyResult(Result):
    profile: str
    key_name: str
    is_set: bool
    capabilities: list[CapabilityRow]


method("capabilities.set_key", params=CapabilitySetKeyParams, result=CapabilitySetKeyResult,
       doc="Save (value set) or remove (value null) one capability key in the named bot's own secret store. "
           "key_name must be one a capabilities.status row names in key_name or key_choices; anything else is "
           "refused with 4101. The value travels only in this request and is never echoed, logged, broadcast or "
           "shown to the model; the answer carries only whether the key is set and the refreshed rows. 4101 "
           "invalid key name or value; 5103 not saved, the previous value is kept.")
