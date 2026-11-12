"""Host GitHub sign-in and git/gh health (``methods_github.py``).

Host-level by design: the gh login belongs to the host user and is shared by every profile, so there is
no ``profile`` param. No result carries a token, a token prefix or a credential path.
"""

from __future__ import annotations

from typing import Literal

from .base import Params, Result, WireEnum
from .registry import method


class GithubProblemId(WireEnum):
    gh_signed_out = "gh_signed_out"
    git_ssh_unknown_host = "git_ssh_unknown_host"


class GithubProblemFix(WireEnum):
    signin = "github.signin"
    git_protocol_fix = "github.git_protocol.fix"


class GithubProblem(Result):
    id: GithubProblemId
    message: str
    fix: GithubProblemFix


class GithubStatus(Result):
    """``git_protocol`` is gh's value for github.com (``unset`` when gh cannot say). A field that could not
    be read degrades to null, ``unset`` or false."""

    signed_in: bool
    login: str | None = None
    host: Literal["github.com"]
    git_protocol: Literal["https", "ssh", "unset"]
    ssh_host_key_known: bool
    problems: list[GithubProblem]


class GithubSigninStartResult(Result):
    """The one-time device code and where to enter it. ``expires_in`` and ``interval`` are seconds."""

    session_id: str
    user_code: str
    verification_uri: str
    expires_in: int
    interval: int


class GithubSigninSessionParams(Params):
    session_id: str


class GithubSigninPollResult(Result):
    state: Literal["pending", "signed_in", "expired", "failed"]
    login: str | None = None
    message: str | None = None


class GithubSigninCancelResult(Result):
    ok: bool


method("github.status", params=Params, result=GithubStatus,
       doc="GitHub sign-in and git/gh health on the host: the host user's single gh login and its problems.")
method("github.signin.start", params=Params, result=GithubSigninStartResult,
       doc="Start GitHub's device flow through gh; a pending sign-in is returned again instead of a second one.")
method("github.signin.poll", params=GithubSigninSessionParams, result=GithubSigninPollResult,
       doc="State of the sign-in; on signed_in the git protocol fix is already applied.")
method("github.signin.cancel", params=GithubSigninSessionParams, result=GithubSigninCancelResult,
       doc="Stop a pending GitHub sign-in and its gh process.")
method("github.git_protocol.fix", params=Params, result=GithubStatus,
       doc="Set git and gh to HTTPS for github.com (idempotent) and return the fresh status.")
