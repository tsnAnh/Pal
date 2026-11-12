"""Webhook routes and their public reachability (``methods_webhook_routes.py``).

Host-level and owner-only: the subscriptions file belongs to the gateway's home. No result carries a stored
secret; ``webhook.routes.add`` returns a generated secret once, in that one response.
"""

from __future__ import annotations

from pydantic import Field

from .base import Params, Result
from .registry import method


class WebhookRoute(Result):
    name: str
    profile: str
    path: str
    public_url: str | None = None
    events: list[str]
    deliver: str
    description: str
    created_at: str | None = None
    enabled: bool


class WebhookRoutesListResult(Result):
    enabled: bool
    public_base_url: str | None = None
    public_url_setting: str
    routes: list[WebhookRoute]


class WebhookRouteAddParams(Params):
    name: str = Field(max_length=64)
    profile: str | None = None
    events: list[str] = Field(default_factory=list, max_length=32)
    deliver: str | None = Field(default=None, max_length=64)
    secret: str | None = Field(default=None, max_length=256, repr=False)
    generate_secret: bool = False


class WebhookRouteAddResult(Result):
    route: WebhookRoute
    secret: str | None = Field(default=None, repr=False)


class WebhookRouteNameParams(Params):
    name: str = Field(max_length=64)


class WebhookRouteRemoveResult(Result):
    ok: bool


class WebhookHop(Result):
    status: int | None = None
    ms: int | None = None
    error: str | None = None


class WebhookDiagnosis(Result):
    code: str
    message: str


class WebhookTunnel(Result):
    resolves: bool | None = None
    tls_expires_at: str | None = None


class WebhookProbeResult(Result):
    local: WebhookHop
    public: WebhookHop
    diagnosis: WebhookDiagnosis
    tunnel: WebhookTunnel


method("webhook.routes.list", params=Params, result=WebhookRoutesListResult,
       doc="Webhook routes of this gateway with their local path and public URL, never a secret. public_base_url "
           "is webapp.public_url, or null when unset. 4403 secondary profile.")
method("webhook.routes.add", params=WebhookRouteAddParams, result=WebhookRouteAddResult,
       doc="Create a route. Give secret or generate_secret, not both; a generated secret is returned once. The "
           "gateway loads the route on its next request, no restart. 4101 invalid, 4409 name taken, 5321 "
           "data.code webhook_disabled. 4403 secondary profile.")
method("webhook.routes.remove", params=WebhookRouteNameParams, result=WebhookRouteRemoveResult,
       doc="Remove a route created through this API or the CLI. 4404 unknown route. 4403 secondary profile.")
method("webhook.routes.probe", params=WebhookRouteNameParams, result=WebhookProbeResult,
       doc="Probe one stored route: an unsigned POST to the gateway's own listener, then to the public URL built "
           "from webapp.public_url (no redirects, TLS verified). The client names a route, never a URL. "
           "4404 unknown route. 4403 secondary profile.")
