"""Updating Pal's host from the app (``methods_host_update.py``). Owner-only: never a model tool.

The update runs as a detached process that outlives the gateway restart it ends with; ``host.update.status``
is how a reconnecting client learns the result. No result carries a path, an environment value or a token.
"""

from __future__ import annotations

from typing import Literal

from .base import Params, Result
from .registry import method

UpdateBlocker = Literal["turn_running", "dirty_install", "update_running", "no_network"]
UpdatePhase = Literal["preparing", "downloading", "applying", "installing", "restarting", "finished"]
UpdateRunState = Literal["idle", "running", "succeeded", "failed", "needs_recovery"]


class HostUpdateCheckParams(Params):
    pass


class HostUpdateCheckResult(Result):
    """``error`` is set only when ``status`` is ``unknown``. ``commits_behind`` is null when the channel pins a
    release or the count is unknown. ``release_notes_url`` is null unless the install tracks a GitHub remote."""

    version: str
    commit: str | None = None
    status: Literal["up_to_date", "update_available", "unknown"]
    commits_behind: int | None = None
    error: Literal["no_network", "check_failed"] | None = None
    release_notes_url: str | None = None
    active_runs: int
    blockers: list[UpdateBlocker]


class HostUpdateState(Result):
    """``failure`` is a code (``no_network``, ``update_failed``, ``interrupted``, ``not_started``,
    ``needs_recovery``); ``left_behind`` says what a failure left on disk (``nothing``, ``old_version_running``,
    ``tree_needs_recovery``). ``tail`` is a bounded, redacted slice of the update's output. ``version`` is the
    running gateway's own, so a changed value after a reconnect is the proof the new gateway is up."""

    run_id: str | None = None
    state: UpdateRunState
    phase: UpdatePhase | None = None
    started_at: float | None = None
    finished_at: float | None = None
    from_commit: str | None = None
    tail: list[str]
    failure: str | None = None
    left_behind: str | None = None
    version: str


method("host.update.check", params=HostUpdateCheckParams, result=HostUpdateCheckResult,
       doc="Owner only: compare this install with the latest on its update channel and list what blocks an update.")


class HostUpdateApplyParams(Params):
    """``confirm_turns`` is set only after the owner taps Update anyway while a chat is running."""

    confirm_turns: bool | None = None


class HostUpdateApplyResult(Result):
    outcome: Literal["started", "already_running", "refused", "failed"]
    blockers: list[UpdateBlocker]
    update: HostUpdateState


method("host.update.apply", params=HostUpdateApplyParams, result=HostUpdateApplyResult,
       doc="Owner only: start the host update, or return the one already running. Refused while a chat runs unless confirmed.")

method("host.update.status", params=HostUpdateCheckParams, result=HostUpdateState,
       doc="Owner only: the latest update run's phase, output tail and result; survives the gateway restart.")
