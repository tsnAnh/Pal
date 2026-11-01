"""Teach a bot a skill by demonstration (``methods_teach.py``, ``tools/bot_desktop/teach*.py``).

The owner holds the Bot Desktop lease and shows a browser workflow; the gateway records structured events
(never video, secrets redacted), then ``bot.teach.stop`` returns the hidden-turn ``prompt`` the client submits to
the bot's Bot Chat. The bot writes a DRAFT skill that stays in ``skills.disabled`` until ``bot.teach.approve``.
Every method rides ``profile`` and answers for that profile's bot.
"""

from __future__ import annotations

from .base import Result
from .common import ProfileParams
from .registry import method


class BotTeachPending(Result):
    """The profile's one unresolved draft: ``drafting`` until the bot has written SKILL.md, then ``ready``."""

    teach_id: str
    skill_name: str
    event_count: int
    truncated: bool
    state: str


class BotTeachStatus(Result):
    available: bool
    reason: str | None = None  # why not: unsupported | sandbox | no_browser
    max_seconds: int
    now: float  # the gateway's clock, so a client counts the time left without trusting its own
    recording: bool
    capture: str  # waiting (no browser yet) | attached | idle
    ended: str | None = None  # owner | limit | control_returned: a recording that ended and awaits bot.teach.stop
    teach_id: str | None = None
    started_at: float | None = None
    deadline_at: float | None = None
    event_count: int
    truncated: bool
    pending: BotTeachPending | None = None


method("bot.teach.status", params=ProfileParams, result=BotTeachStatus,
       doc="Whether this bot can be taught, the live recording and the unresolved draft, if any.")


class BotTeachStartParams(ProfileParams):
    viewer_id: str


method("bot.teach.start", params=BotTeachStartParams, result=BotTeachStatus,
       doc="Start recording for the viewer that holds the lease (5310, code not_in_control / draft_pending / ...).")


class BotTeachStopParams(ProfileParams):
    discard: bool | None = None


class BotTeachStopResult(Result):
    empty: bool
    reason: str | None = None
    teach_id: str | None = None
    skill_name: str | None = None
    event_count: int | None = None
    truncated: bool | None = None
    prompt: str | None = None  # submit as a hidden turn (display_kind hidden) to the bot's Bot Chat


method("bot.teach.stop", params=BotTeachStopParams, result=BotTeachStopResult,
       doc="End the recording; creates the disabled draft and returns the prompt that asks the bot to write it.")


class BotTeachIdParams(ProfileParams):
    teach_id: str


class BotTeachPromptResult(Result):
    prompt: str


method("bot.teach.prompt", params=BotTeachIdParams, result=BotTeachPromptResult,
       doc="The hidden-turn prompt again (the bot's first turn failed); refused once the draft exists.")


class BotTeachDraft(Result):
    teach_id: str
    skill_name: str
    event_count: int
    truncated: bool
    state: str
    content: str | None = None  # the draft SKILL.md once the bot wrote it
    content_hash: str | None = None  # send back with approve when the owner did not edit: what they read is what is enabled
    extra_files: list[str] = []  # anything beside SKILL.md: such a draft cannot be approved (5310, code extra_files)


method("bot.teach.draft", params=BotTeachIdParams, result=BotTeachDraft,
       doc="The draft's state and SKILL.md. Once it exists the recording is deleted.")


class BotTeachDraftSaveParams(BotTeachIdParams):
    content: str


method("bot.teach.draft.save", params=BotTeachDraftSaveParams, result=BotTeachDraft,
       doc="The owner's edit of the draft SKILL.md; stays disabled.")


class BotTeachApproveParams(BotTeachIdParams):
    content: str | None = None  # the owner's edit, saved first
    content_hash: str | None = None  # required without content: refused (code draft_changed) if the draft moved on


class BotTeachApproveResult(Result):
    teach_id: str
    skill_name: str
    enabled: bool


method("bot.teach.approve", params=BotTeachApproveParams, result=BotTeachApproveResult,
       doc="Approve: optionally save an edit, validate, then enable the skill (the only path that does).")


class BotTeachDiscardResult(Result):
    teach_id: str
    discarded: bool


method("bot.teach.discard", params=BotTeachIdParams, result=BotTeachDiscardResult,
       doc="Delete the draft skill and its recording.")
