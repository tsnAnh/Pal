from __future__ import annotations

from pydantic import Field

from .base import Params, Payload, Result, WireEnum
from .registry import canonical_method, event

AUTH_REQUEST_ID_PATTERN = r"^[A-Za-z0-9-]{8,64}$"


class AuthReason(WireEnum):
    MISSING = "missing"
    EXPIRED = "expired"
    REVOKED = "revoked"


class AuthFlow(WireEnum):
    DEVICE_CODE = "device_code"
    OAUTH = "oauth"
    API_KEY = "api_key"
    HEADER = "header"
    MANUAL = "manual"


class AuthOutcome(WireEnum):
    SIGNED_IN = "signed_in"
    FAILED = "failed"
    DECLINED = "declined"
    TIMED_OUT = "timed_out"


class AuthRequiredPayload(Payload):
    request_id: str
    service: str
    service_name: str
    bot: str
    bots: list[str]
    reason: AuthReason
    flow: AuthFlow
    user_code: str | None = None
    verification_uri: str | None = None
    expires_in: int | None = None
    server: str | None = None


event("auth.required", AuthRequiredPayload,
      doc="A bot's tool call failed because a credential for service is missing, expired or revoked. Show one "
          "sign-in dialog per service: a repeat with the same request_id lists more waiting bots. device_code "
          "carries user_code and verification_uri to open in the system browser; oauth is started with "
          "auth.signin; api_key asks for the key for MCP server `server` (store it with mcp.servers.set_api_key, then "
          "call auth.signin); header and manual have no in-app sign-in. The payload never carries a token.")


class AuthResolvedPayload(Payload):
    request_id: str
    outcome: AuthOutcome


event("auth.resolved", AuthResolvedPayload,
      doc="The sign-in request ended: signed_in (the waiting calls retry), failed, declined or timed_out.")


class AuthSigninParams(Params):
    request_id: str = Field(pattern=AUTH_REQUEST_ID_PATTERN)


class AuthSigninResult(Result):
    recorded: bool
    authorization_url: str | None = None


canonical_method("auth.signin", params=AuthSigninParams, result=AuthSigninResult,
                 doc="The user chose Sign in on an auth.required request. For oauth the gateway starts the flow "
                     "and returns authorization_url to open in the system browser; for device_code it only "
                     "acknowledges (the gateway is already polling). recorded is false for an unknown, finished "
                     "or foreign request.")


class AuthDeclineParams(Params):
    request_id: str = Field(pattern=AUTH_REQUEST_ID_PATTERN)


class AuthDeclineResult(Result):
    recorded: bool


canonical_method("auth.decline", params=AuthDeclineParams, result=AuthDeclineResult,
                 doc="The user chose Not now on an auth.required request; the waiting bots are told the user "
                     "declined sign-in.")
