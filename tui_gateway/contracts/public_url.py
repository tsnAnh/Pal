from __future__ import annotations

from .base import Params, Result, WireEnum
from .registry import method


class PublicUrlProblem(WireEnum):
    too_long = "too_long"
    invalid = "invalid"
    not_https = "not_https"
    userinfo = "userinfo"
    ip_host = "ip_host"
    invalid_host = "invalid_host"
    path = "path"
    query_or_fragment = "query_or_fragment"


class PublicUrlCheckOutcome(WireEnum):
    reachable = "reachable"
    not_reachable = "not_reachable"
    wrong_service = "wrong_service"
    no_address = "no_address"


class PublicUrlGetParams(Params):
    pass


class PublicUrlSetParams(Params):
    url: str


class PublicUrlState(Result):
    url: str | None = None
    routes_enabled: bool
    suggestion: str | None = None


class PublicUrlCheckResult(Result):
    outcome: PublicUrlCheckOutcome
    url: str | None = None


method("webapp.public_url.get", params=PublicUrlGetParams, result=PublicUrlState,
       doc="Owner only. The gateway's saved public https address (webapp.public_url), whether the Webapp routes "
           "that serve the sign-in callbacks are enabled, and a read-only suggestion from the tailnet "
           "(null when the Tailscale CLI is absent or fails).")
method("webapp.public_url.set", params=PublicUrlSetParams, result=PublicUrlState,
       doc="Owner only. Save the address: https only, a host name (never an IP), no userinfo, path beyond /, "
           "query or fragment, at most 255 characters; stored lower-cased without a trailing slash. An empty "
           "url clears it. A refusal carries data.problem. A running gateway applies it within seconds.")
method("webapp.public_url.check", params=PublicUrlGetParams, result=PublicUrlCheckResult,
       doc="Owner only. One request from the gateway to <public_url>/webapp/mcp-oauth/callback with a state "
           "nobody issued; Pal's own route answers 400. outcome says reachable, not_reachable, wrong_service or "
           "no_address.")
