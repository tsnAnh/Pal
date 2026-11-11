from __future__ import annotations

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class SpeechMemoryArea(WireEnum):
    TTS = "tts"
    MEMORY = "memory"


class SpeechMemoryProvider(Result):
    """One text-to-speech or memory provider. ``key_name`` is the name of the secret that powers it (absent
    when none is needed here), ``key_set`` whether any source supplies it, ``can_remove`` whether the bot's own
    secret store holds one that ``capabilities.set_key`` can remove. ``ready`` is whether the provider works
    now. ``note`` is one line on a shared or optional key. No key value is ever carried."""

    id: str
    name: str
    description: str | None = None
    key_name: str | None = None
    key_required: bool = False
    key_set: bool = False
    can_remove: bool = False
    ready: bool = False
    selectable: bool = True
    note: str | None = None


class SpeechVoiceOption(Result):
    id: str
    label: str


class SpeechProviderGroup(Result):
    selected: str
    providers: list[SpeechMemoryProvider]


class SpeechVoice(Result):
    current: str
    options: list[SpeechVoiceOption]


class SpeechSettings(SpeechProviderGroup):
    voice: SpeechVoice | None = None


class SpeechMemorySettings(Result):
    profile: str
    tts: SpeechSettings
    memory: SpeechProviderGroup


method("speech_memory.settings.get", params=ProfileParams, result=SpeechMemorySettings,
       doc="The bot's text-to-speech and memory providers: which is chosen, which are installed on this computer, "
           "and whether the key each needs is set. Read-only; never carries a key value. Keys are set and removed "
           "with capabilities.set_key.")


class SpeechMemorySetParams(ProfileParams):
    area: SpeechMemoryArea
    provider: str
    voice: str | None = None


class SpeechMemorySetOutcome(WireEnum):
    SAVED = "saved"
    NEEDS_KEY = "needs_key"
    UNSUPPORTED = "unsupported"
    INVALID = "invalid"
    FAILED = "failed"


class SpeechMemorySetResult(Result):
    outcome: SpeechMemorySetOutcome
    reason: str | None = None
    settings: SpeechMemorySettings | None = None


method("speech_memory.settings.set", params=SpeechMemorySetParams, result=SpeechMemorySetResult,
       doc="Choose the bot's text-to-speech provider (and the Edge voice) or memory provider (empty string for the "
           "built-in memory only). needs_key: the provider's key is not set yet. Applies to new conversations.")
