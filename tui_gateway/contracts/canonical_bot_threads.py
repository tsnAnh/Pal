from __future__ import annotations

from typing import Literal

from pydantic import Field, model_validator

from .base import JsonValue, Result, WireEnum
from .common import ProfileParams
from .registry import canonical_method, event

THREAD_ID_PATTERN = r"^bt_[0-9a-f]{20}$"
EXCHANGE_ID_PATTERN = r"^(out|in):[0-9a-f]{32,64}$"


class BotThreadStatus(WireEnum):
    pending = "pending"
    delivered = "delivered"
    unknown = "unknown"
    answered = "answered"
    failed = "failed"


class BotThreadAvatar(Result):
    has_asset: bool
    ui_meta: JsonValue | None = None


class BotThreadParticipant(Result):
    """``local_profile`` names a bot on this install (its avatar asset is ``profiles.get_asset`` of
    that profile); a remote bot has none and is drawn from its ``key``."""

    key: str
    is_self: bool
    local_profile: str | None = None
    display_name: str
    handle: str
    avatar: BotThreadAvatar


class BotThreadMessage(Result):
    id: str
    exchange_id: str
    sender_key: str
    text: str
    at: str
    part: Literal["message", "reply"]
    status: BotThreadStatus
    status_text: str | None = None


class BotThreadSummary(Result):
    thread_id: str
    counterpart: BotThreadParticipant
    last_at: str
    last_preview: str
    last_sender_key: str
    message_count: int


class BotThreadListParams(ProfileParams):
    pass


class BotThreadListResult(Result):
    threads: list[BotThreadSummary]


canonical_method("bot.thread.list", params=BotThreadListParams, result=BotThreadListResult,
                 doc="This profile's bot-to-bot threads, newest first. Requires session:read on its Bot Chat.")


class BotThreadReadParams(ProfileParams):
    """At most one of ``focus`` (an exchange a main-chat link opens), ``before`` / ``after`` (a
    message ``seq`` cursor from a previous page) or ``since_rev`` (catch-up after
    ``bot_threads.changed``: new messages and status changes). None reads the newest page."""

    thread_id: str = Field(pattern=THREAD_ID_PATTERN)
    focus: str | None = Field(default=None, pattern=EXCHANGE_ID_PATTERN)
    before: int | None = Field(default=None, ge=1)
    after: int | None = Field(default=None, ge=1)
    since_rev: int | None = Field(default=None, ge=0)
    limit: int = Field(default=50, ge=1, le=100)

    @model_validator(mode="after")
    def _one_mode(self) -> BotThreadReadParams:
        modes = [value for value in (self.focus, self.before, self.after, self.since_rev) if value is not None]
        if len(modes) > 1:
            raise ValueError("at most one of focus, before, after, since_rev")
        return self


class BotThreadReadResult(Result):
    """Oldest first. ``before`` / ``after`` are the cursors for the next older / newer page (null at
    either end); ``coverage`` is ``own_side`` when the counterpart may answer where this profile
    cannot see it (a peer gateway's open chat). There is no write verb: threads are read-only."""

    thread_id: str
    participants: list[BotThreadParticipant]
    messages: list[BotThreadMessage]
    focus_index: int | None = None
    before: int | None = None
    after: int | None = None
    rev: int
    coverage: Literal["both_sides", "own_side"]
    history_since: str | None = None
    read_only: Literal[True] = True


canonical_method("bot.thread.read", params=BotThreadReadParams, result=BotThreadReadResult,
                 doc="Read one bot-to-bot thread from this profile's own ledger. not_found when the profile "
                     "has no exchange in it. Requires session:read on the profile's Bot Chat.")


class BotThreadLinksParams(ProfileParams):
    session_id: str = Field(min_length=1)
    limit: int = Field(default=200, ge=1, le=500)


class BotThreadLink(Result):
    """One compact main-chat row at ``anchor_uid`` (a row's ``message_uid``) replacing
    ``covered_uids``. ``count`` 1 renders "Messaged X" / "Message from X"; more renders "N messages
    with X". Tapping opens ``bot.thread.read`` with ``focus=exchange_id``."""

    anchor_uid: str
    thread_id: str
    exchange_id: str
    kind: Literal["messaged", "message_from"]
    counterpart: BotThreadParticipant
    covered_uids: list[str]
    count: int


class BotThreadLinksResult(Result):
    links: list[BotThreadLink]
    truncated: bool


canonical_method("bot.thread.links", params=BotThreadLinksParams, result=BotThreadLinksResult,
                 doc="Main-chat entry rows for every bot-to-bot exchange anchored in this Bot Chat's "
                     "compression lineage, oldest first. Requires session:read on session_id.")


event("bot_threads.changed", None,
      doc="A served profile's bot thread ledger moved (any process). Re-read open threads with since_rev "
          "and the open Bot Chat's bot.thread.links.")
