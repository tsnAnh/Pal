"""Host GitHub token and its OAuth sign-in (``methods_github_token.py``).

Host-level by design: one gh login serves every profile and bot, so there is no ``profile`` param. No
result carries the token, a prefix, a hash, a length or a credential path.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result, WireEnum
from .registry import method


class GithubTokenState(WireEnum):
    set = "set"
    missing = "missing"
    invalid = "invalid"
    expired = "expired"
    missing_scopes = "missing_scopes"
    oauth_app_not_configured = "oauth_app_not_configured"
    unknown = "unknown"


class GithubTokenStatus(Result):
    """A field that could not be read degrades to null, an empty list, ``unknown`` or ``unset``. An OAuth App
    token has no expiry, so ``expires_at`` is null. ``oauth_app_not_configured``: no token and no client ID."""

    state: GithubTokenState
    login: str | None = None
    scopes: list[str]
    missing_scopes: list[str]
    expires_at: str | None = None
    token_kind: Literal["classic", "fine_grained", "unknown"]
    git_protocol: Literal["https", "ssh", "unset"]


class GithubOauthStartResult(Result):
    session_id: str
    user_code: str
    verification_uri: str
    expires_in: int
    interval: int


class GithubOauthSessionParams(Params):
    session_id: str


class GithubOauthPollResult(Result):
    state: Literal["pending", "signed_in", "denied", "expired", "org_approval_needed", "failed"]
    login: str | None = None
    message: str | None = None
    code: str | None = None
    missing_scopes: list[str] = Field(default_factory=list)


class GithubOauthCancelResult(Result):
    ok: bool


class GithubOauthConfigSetParams(Params):
    client_id: str | None = Field(default=None, max_length=64)


class GithubOauthConfig(Result):
    client_id: str | None = None


method("github.token.status", params=Params, result=GithubTokenStatus,
       doc="The host's single GitHub token, read through gh without reading the token back: state, account, "
           "scope names, expiry and the git protocol. Never carries the token. 4403 secondary profile.")
method("github.oauth.start", params=Params, result=GithubOauthStartResult,
       doc="Start GitHub's device flow with Pal's own OAuth App; a pending sign-in is returned again instead of "
           "a second one. Error 5311 carries data.code: oauth_app_not_configured, oauth_app_rejected or "
           "unreachable. 4403 secondary profile.")
method("github.oauth.poll", params=GithubOauthSessionParams, result=GithubOauthPollResult,
       doc="State of the sign-in. On signed_in the token is already applied to gh and git is set to HTTPS. A "
           "failed state carries code: missing_scopes (with missing_scopes; nothing applied), apply_failed, "
           "oauth_app_rejected, unreachable or failed. org_approval_needed: an organization owner must "
           "approve Pal.")
method("github.oauth.cancel", params=GithubOauthSessionParams, result=GithubOauthCancelResult,
       doc="Drop a pending GitHub sign-in.")
method("github.oauth.config.get", params=Params, result=GithubOauthConfig,
       doc="The OAuth App client ID (public, not a secret), or null when it is not set.")
method("github.oauth.config.set", params=GithubOauthConfigSetParams, result=GithubOauthConfig,
       doc="Save (client_id set) or clear (null or empty) the OAuth App client ID in the host's config and drop "
           "any pending sign-in. 4101 invalid client ID.")
