from __future__ import annotations

from pydantic import Field

from .base import Result
from .common import ProfileParams
from .registry import method


class BotKeyRow(Result):
    name: str
    label: str
    is_set: bool


class BotKeyGroup(Result):
    id: str
    label: str
    keys: list[BotKeyRow]


class BotKeysStatusResult(Result):
    profile: str
    groups: list[BotKeyGroup]


method("bot_keys.status", params=ProfileParams, result=BotKeysStatusResult,
       doc="Which of the extra tool, memory, app and messaging keys one bot has set, by name. Owner connections only; "
           "never carries a key value. 4403 for a bot's own connection.")


class BotKeysSetParams(ProfileParams):
    key_name: str = Field(pattern=r"^[A-Z][A-Z0-9_]{2,63}$")
    value: str | None = Field(default=None, max_length=4096, repr=False)


class BotKeysSetResult(Result):
    profile: str
    key_name: str
    is_set: bool
    groups: list[BotKeyGroup]


method("bot_keys.set", params=BotKeysSetParams, result=BotKeysSetResult,
       doc="Save (value set) or remove (value null) one key listed by bot_keys.status in the named bot's own secret "
           "store. The value travels only in this request and is never echoed, logged or shown to the model. "
           "4101 invalid key name or value; 4403 not an owner connection; 5103 not saved, the previous value is kept.")
