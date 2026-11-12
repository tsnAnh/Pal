"""Google Workspace sign-in for the google-workspace skill (``methods_google_workspace.py``).

Host-level by design: the skill's token and client files live in the launch profile's home, so there is no
``profile`` param. No result carries the client secret, a token, a pasted address or a credential path.
"""

from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Params, Result, WireEnum
from .registry import method


class GoogleWorkspaceState(WireEnum):
    not_configured = "not_configured"
    needs_sign_in = "needs_sign_in"
    signed_in = "signed_in"
    reauth_needed = "reauth_needed"


class GoogleService(WireEnum):
    gmail = "gmail"
    calendar = "calendar"
    drive = "drive"
    contacts = "contacts"
    sheets = "sheets"
    docs = "docs"


class GoogleWorkspaceStatus(Result):
    """``services`` have at least read access, ``write_services`` also have write access, both read from the
    token's scope list. ``reauth_reason`` is set with ``reauth_needed``: ``token_missing``, ``token_unreadable``,
    ``revoked`` or ``client_rejected``."""

    state: GoogleWorkspaceState
    email: str | None = None
    services: list[GoogleService]
    write_services: list[GoogleService]
    reauth_reason: str | None = None


class GoogleClientSetParams(Params):
    client_json: str | None = Field(default=None, max_length=16384)
    client_id: str | None = Field(default=None, max_length=256)
    client_secret: str | None = Field(default=None, max_length=256)


class GoogleSignoutParams(Params):
    remove_setup: bool = False


class GoogleSigninStartParams(Params):
    services: list[GoogleService]
    write_services: list[GoogleService] = Field(default_factory=list)


class GoogleSigninStartResult(Result):
    flow_id: str
    auth_url: str
    expires_in: int


class GoogleSigninFinishParams(Params):
    flow_id: str
    pasted: str = Field(max_length=4096)


class GoogleSigninFinishResult(Result):
    state: Literal["signed_in", "retry", "denied", "failed"]
    code: str | None = None
    message: str | None = None
    status: GoogleWorkspaceStatus | None = None


class GoogleSigninCancelParams(Params):
    flow_id: str


class GoogleSigninCancelResult(Result):
    ok: bool


method("google_workspace.status", params=Params, result=GoogleWorkspaceStatus,
       doc="Sign-in state of the google-workspace skill, read from its local files only (never calls Google): "
           "not_configured, needs_sign_in, signed_in or reauth_needed, with the account email and granted services. "
           "Owner only; 4403 secondary profile.")
method("google_workspace.verify", params=Params, result=GoogleWorkspaceStatus,
       doc="Explicit check: refresh the access token if stale and ask Google who is signed in, once. A revoked "
           "grant becomes reauth_needed for every device. 5321 data.code unreachable leaves the state unchanged.")
method("google_workspace.client.set", params=GoogleClientSetParams, result=GoogleWorkspaceStatus,
       doc="Save the Desktop OAuth client (pasted client file, or client ID and secret) where the skill reads it. "
           "4101 data.code invalid_client or not_desktop_client. A different client ID signs the account out.")
method("google_workspace.signout", params=GoogleSignoutParams, result=GoogleWorkspaceStatus,
       doc="Sign out: revoke at Google best effort and delete the token only. With remove_setup the client file goes too.")
method("google_workspace.signin.start", params=GoogleSigninStartParams, result=GoogleSigninStartResult,
       doc="Start a PKCE sign-in for the ticked services (read-only unless listed in write_services) and return "
           "the Google URL to open. The verifier stays on the gateway under flow_id; finish from any owner device.")
method("google_workspace.signin.finish", params=GoogleSigninFinishParams, result=GoogleSigninFinishResult,
       doc="Complete the sign-in from the address the browser ended on. state retry: ask for the paste again. "
           "Single use; the paste is never kept.")
method("google_workspace.signin.cancel", params=GoogleSigninCancelParams, result=GoogleSigninCancelResult,
       doc="Drop a pending Google sign-in.")
