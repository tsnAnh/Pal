"""One real request against a model provider, before anything is saved.

The request goes through the provider client the agent itself uses, one attempt only: no retries, no
fallback to another provider or credential, no credential-pool rotation. A staged key lives in this
process's memory for the call and is never written anywhere."""

from __future__ import annotations

import concurrent.futures
import contextvars
import logging
import socket
import ssl
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx
import openai

from agent.error_classifier import FailoverReason, classify_api_error
from hermes_cli.auth_constants import AuthError

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_S = 30.0
MAX_TIMEOUT_S = 60.0
MAX_MODEL_CHARS = 256
PREVIEW_CHARS = 40
REASON_CHARS = 300
RESULT_GRACE_S = 2.0
MAX_TOKENS = 16
PROBE_MESSAGES = [{"role": "user", "content": "Reply with OK"}]
KEYED_KINDS = frozenset({"api_key"})

# Not the 2-4 worker readiness pool: a 60 s test there would starve the readiness polls.
_pool = concurrent.futures.ThreadPoolExecutor(max_workers=4, thread_name_prefix="provider-probe")


class InvalidProbeParams(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class ProbeParams:
    provider: str
    model: str
    base_url: Optional[str]
    api_key: Optional[str] = field(repr=False)
    timeout_s: float


@dataclass(frozen=True, slots=True)
class ProbeError:
    code: str
    reason: str
    retryable: bool
    kind: str


@dataclass(frozen=True, slots=True)
class ProbeResult:
    ok: bool
    provider: str
    model: str
    latency_ms: int
    reply_preview: Optional[str] = None
    error: Optional[ProbeError] = None

    def wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {"ok": self.ok, "provider": self.provider, "model": self.model,
                                "latency_ms": self.latency_ms}
        if self.reply_preview:
            wire["reply_preview"] = self.reply_preview
        if self.error is not None:
            wire["error"] = {"code": self.error.code, "reason": self.error.reason,
                             "retryable": self.error.retryable, "kind": self.error.kind}
        return wire


class MissingCredentials(Exception):
    pass


def _text(value: object, what: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidProbeParams(f"{what} is required")
    return value.strip()


def _timeout(value: object) -> float:
    if value is None:
        return DEFAULT_TIMEOUT_S
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not value > 0:
        raise InvalidProbeParams("timeout_s must be a number above zero")
    return min(value, MAX_TIMEOUT_S)


def parse_params(params: dict, *, base_url_editable: bool) -> ProbeParams:
    from hermes_cli import model_provider_control as control
    provider = _text(params.get("provider"), "provider")
    model = _text(params.get("model"), "model")
    if len(model) > MAX_MODEL_CHARS or not model.isprintable():
        raise InvalidProbeParams("model is not a valid model name")
    api_key = params.get("api_key")
    if api_key is not None and (api_key := control.pasted_credential(api_key)) is None:
        raise InvalidProbeParams("api_key is not a valid key")
    base_url = params.get("base_url")
    if base_url is not None:
        if not base_url_editable or not isinstance(base_url, str) or (base_url := control.valid_base_url(base_url)) is None:
            raise InvalidProbeParams("base_url is not allowed for this provider or is not an http(s) address")
    return ProbeParams(provider=provider, model=model, base_url=base_url, api_key=api_key,
                       timeout_s=_timeout(params.get("timeout_s")))


def _scrub(text: str, api_key: Optional[str]) -> str:
    from agent.redact import redact_sensitive_text
    for secret in {api_key, (api_key or "").strip()} - {None, ""}:
        text = text.replace(secret, "[redacted]")
    text = redact_sensitive_text(text, force=True, redact_url_credentials=True)
    return " ".join(text.split())[:REASON_CHARS]


_REASON_KINDS: dict[FailoverReason, tuple[str, bool]] = {
    FailoverReason.auth: ("auth", False),
    FailoverReason.auth_permanent: ("auth", False),
    FailoverReason.billing: ("quota", False),
    FailoverReason.rate_limit: ("quota", True),
    FailoverReason.upstream_rate_limit: ("quota", True),
    FailoverReason.model_not_found: ("model", False),
    FailoverReason.model_entitlement: ("model", False),
    FailoverReason.timeout: ("timeout", True),
    FailoverReason.ssl_cert_verification: ("network", False),
    FailoverReason.overloaded: ("other", True),
    FailoverReason.server_error: ("other", True),
}
_TIMEOUT_TYPES = (TimeoutError, httpx.TimeoutException, openai.APITimeoutError)
_CONNECTION_TYPES = (ConnectionError, socket.gaierror, httpx.ConnectError, httpx.NetworkError, openai.APIConnectionError)
_MAX_CHAIN = 8


def _chain(exc: BaseException):
    seen: set[int] = set()
    while exc is not None and id(exc) not in seen and len(seen) < _MAX_CHAIN:
        seen.add(id(exc))
        yield exc
        exc = exc.__cause__ or exc.__context__


def _transport_error(exc: BaseException) -> Optional[tuple[str, str, bool]]:
    links = list(_chain(exc))
    if any(isinstance(link, ssl.SSLError) for link in links):
        return "network", "ssl_error", False
    if any(isinstance(link, _TIMEOUT_TYPES) for link in links):
        return "timeout", "timeout", True
    if any(isinstance(link, _CONNECTION_TYPES) for link in links):
        return "network", "network", True
    return None


def classify_failure(exc: BaseException, *, provider: str, model: str, base_url: str,
                     api_key: Optional[str]) -> ProbeError:
    key = api_key or ""

    def error(kind: str, code: str, retryable: bool, text: str) -> ProbeError:
        return ProbeError(code=code, reason=_scrub(text, key) or "The provider did not accept the request.",
                          retryable=retryable, kind=kind)

    auth_error = next((link for link in _chain(exc) if isinstance(link, AuthError)), None)
    if auth_error is not None:
        code = auth_error.code or "auth_error"
        return error("unsupported" if code == "missing_external_process_cli" else "auth", code, False, str(auth_error))
    if isinstance(exc, MissingCredentials):
        return error("auth", "no_credentials", False, "No credential is set for this provider.")
    if (transport := _transport_error(exc)) is not None:
        kind, code, retryable = transport
        return error(kind, code, retryable, str(exc) or "The provider could not be reached.")
    classified = classify_api_error(exc, provider=provider, model=model, base_url=base_url, api_key=key or None)
    kind, retryable = _REASON_KINDS.get(classified.reason, ("other", classified.retryable))
    return error(kind, classified.reason.value, retryable, classified.message or str(exc))


def _attempt(params: ProbeParams) -> str:
    from agent import auxiliary_client as aux
    client, _ = aux.resolve_provider_client(
        params.provider, model=params.model, explicit_base_url=params.base_url, explicit_api_key=params.api_key)
    if client is None:
        raise MissingCredentials()
    if callable(with_options := getattr(client, "with_options", None)):
        client = with_options(max_retries=0)
    base_url = str(getattr(client, "base_url", "") or "")
    kwargs = aux._build_call_kwargs(params.provider, params.model, PROBE_MESSAGES, max_tokens=MAX_TOKENS,
                                    timeout=params.timeout_s, base_url=base_url)
    response = aux._create_with_progress(
        client, kwargs, None, provider=params.provider,
        force_stream=aux._provider_requires_stream(params.provider, base_url))
    return aux.extract_content_or_reasoning(response)


def _preflight(params: ProbeParams, kind: str) -> Optional[ProbeError]:
    from hermes_cli.model_provider_cli_plan import CLI_PLAN_PROVIDERS, host_check
    if kind != "cli_plan":
        return None
    check = host_check(CLI_PLAN_PROVIDERS[params.provider], detail=False)
    if not check.cli_found:
        return ProbeError("cli_missing", check.install_hint or "", False, "unsupported")
    if not check.plugin_installed:
        return ProbeError("plugin_missing", check.install_hint or "", False, "unsupported")
    if not check.signed_in:
        return ProbeError("signed_out", check.install_hint or "", False, "auth")
    return None


def unsupported_result(params: ProbeParams, reason: str) -> ProbeResult:
    return ProbeResult(ok=False, provider=params.provider, model=params.model, latency_ms=0, error=ProbeError(
        code="unsupported_provider", reason=reason, retryable=False, kind="unsupported"))


def run_probe(params: ProbeParams, kind: str) -> ProbeResult:
    """Run the test for a provider row of ``kind``. A staged key only applies to API-key providers: the
    sign-in kinds are tested with their stored login."""
    started = time.monotonic()

    def done(**fields: Any) -> ProbeResult:
        latency_ms = int((time.monotonic() - started) * 1000)
        error = fields.get("error")
        logger.info("model provider test: provider=%s outcome=%s latency_ms=%d",
                    params.provider, error.kind if error else "ok", latency_ms)
        return ProbeResult(provider=params.provider, model=params.model, latency_ms=latency_ms, **fields)

    if (blocked := _preflight(params, kind)) is not None:
        return done(ok=False, error=blocked)
    effective = params if kind in KEYED_KINDS else ProbeParams(
        params.provider, params.model, params.base_url, None, params.timeout_s)
    future = _pool.submit(contextvars.copy_context().run, _attempt, effective)
    try:
        reply = future.result(timeout=effective.timeout_s + RESULT_GRACE_S)
    except Exception as exc:  # health: allow BLE001 -- the SDK raises arbitrary types; each is classified and reported, never re-raised
        if not future.done():
            future.cancel()
            return done(ok=False, error=ProbeError("timeout", "The provider did not answer in time.", True, "timeout"))
        return done(ok=False, error=classify_failure(
            exc, provider=effective.provider, model=effective.model, base_url=effective.base_url or "",
            api_key=effective.api_key))
    preview = _scrub(reply.strip(), effective.api_key)[:PREVIEW_CHARS] or None
    return done(ok=True, reply_preview=preview)
