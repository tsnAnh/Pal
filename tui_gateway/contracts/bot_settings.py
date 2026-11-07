from __future__ import annotations

from .base import Params, Result
from .registry import method


class ProfilesRenameParams(Params):
    name: str
    new_name: str


class ProfilesRenameResult(Result):
    """``name`` is the canonical id after the rename; the primary bot keeps ``default`` and carries the
    new label in ``display_name``."""

    ok: bool
    name: str
    path: str
    display_name: str | None = None


method("profiles.rename", params=ProfilesRenameParams, result=ProfilesRenameResult,
       doc="Rename a bot (ws twin of PATCH /api/profiles/{name}); the primary bot only changes its display name.")


class ProfilesDeleteParams(Params):
    name: str


class ProfilesDeleteResult(Result):
    """``settlement_pending`` means the home is already gone and only the durable identity cleanup is
    outstanding; ``retry_command`` finishes it."""

    ok: bool
    name: str
    path: str
    identity_settled: bool | None = None
    settlement_pending: bool | None = None
    retry_command: str | None = None


method("profiles.delete", params=ProfilesDeleteParams, result=ProfilesDeleteResult,
       doc="Delete a bot and its home (ws twin of DELETE /api/profiles/{name}); refuses the primary bot and the bot serving the connection.")
