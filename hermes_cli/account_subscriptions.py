from __future__ import annotations

import logging
import re
import time
from dataclasses import asdict, dataclass
from typing import Any, Callable, Iterable, Optional

from agent.account_usage_cache import UsageFetchOutcome, UsageFetchRequest

logger = logging.getLogger(__name__)

SPEND_PERIOD_DAYS = 7
FETCH_DEADLINE_S = 10.0

KIND_SUBSCRIPTION = "subscription"
KIND_API_KEY = "api_key"
_KIND_RANK = {KIND_SUBSCRIPTION: 0, KIND_API_KEY: 1}

_PROVIDER_LABEL_OVERRIDES = {"openai-codex": "ChatGPT", "copilot": "GitHub Copilot"}
_SUBSCRIPTION_PROVIDERS = frozenset({"openai-codex", "copilot"})
_TOKEN_SHAPED_LABEL = re.compile(r"^(sk-|gh[opusr]_|github_pat_|xox[abprs]-|AIza)", re.IGNORECASE)
_MIN_SECRET_LENGTH = 8

REASON_DEAD = "This credential was rejected and needs to be signed in again."
REASON_LIMITED = "This credential is rate limited right now."
REASON_UNSUPPORTED = "This provider does not report usage limits."
REASON_NOT_LOADED = "Usage has not been loaded yet."
REASON_STALE = "Usage data is out of date."
REASON_FETCH_FAILED = "Usage could not be fetched."
REASON_TIMED_OUT = "Usage lookup timed out."
REASON_UNREADABLE = "Credentials for this provider could not be read."


@dataclass(frozen=True)
class Credential:
    id: str
    provider: str
    kind: str
    entry: Optional[Any] = None
    pool_size: int = 1
    live_count: int = 1
    unreadable: bool = False


@dataclass(frozen=True)
class UsageReading:
    state: str
    windows: list[dict]
    plan: Optional[str] = None
    fetched_at: Optional[str] = None
    reason: Optional[str] = None


@dataclass(frozen=True)
class Subscription:
    id: str
    provider: str
    provider_label: str
    account_label: Optional[str]
    kind: str
    plan: Optional[str]
    active: bool
    state: str
    windows: list[dict]
    spend: Optional[dict]
    unavailable_reason: Optional[str]
    fetched_at: Optional[str]


FetchNow = Callable[..., dict[tuple[str, str], UsageFetchOutcome]]


def build_account_subscriptions(*, refresh: bool = False, fetch_now: Optional[FetchNow] = None) -> dict:
    from agent.account_usage_cache import fetch_account_usage_now, has_account_usage
    from hermes_cli.account_spend import empty_spend, spend_by_provider

    fetch_now = fetch_now or fetch_account_usage_now
    now = time.time()
    credentials = [*_pooled_credentials(), *_standalone_credentials()]
    secrets = _credential_secrets(credentials)
    supports_usage = {c.provider: has_account_usage(c.provider) for c in credentials if not c.unreadable}
    outcomes: dict[tuple[str, str], UsageFetchOutcome] = {}
    if refresh:
        requests = list(_fetch_requests(credentials, supports_usage, now))
        if requests:
            outcomes = fetch_now(requests, deadline_s=FETCH_DEADLINE_S)
    spend = spend_by_provider(SPEND_PERIOD_DAYS)
    active_provider = _active_provider()
    rows: list[Subscription] = []
    for credential in credentials:
        reading = _read_usage(credential, supports_usage.get(credential.provider, False), now, refresh, outcomes)
        rows.append(Subscription(
            id=credential.id, provider=credential.provider, provider_label=_provider_label(credential.provider),
            account_label=_account_label(credential, secrets), kind=credential.kind, plan=reading.plan,
            active=credential.provider == active_provider, state=reading.state, windows=reading.windows,
            spend=_spend_for(credential, spend, empty_spend), unavailable_reason=reading.reason,
            fetched_at=reading.fetched_at,
        ))
    rows.sort(key=lambda row: (not row.active, _KIND_RANK[row.kind]))
    return {"subscriptions": [_scrubbed(asdict(row), secrets) for row in rows]}


def _pooled_credentials() -> list[Credential]:
    from agent.credential_pool import STATUS_DEAD, load_pool
    from hermes_cli.auth import read_credential_pool

    credentials: list[Credential] = []
    for provider, rows in read_credential_pool().items():
        slug = str(provider or "").strip().lower()
        if not slug or not rows:
            continue
        try:
            entries = list(load_pool(slug).entries())
        except Exception:
            logger.debug("Credential pool read failed for %s", slug, exc_info=True)
            credentials.append(Credential(id=slug, provider=slug, kind=_provider_kind(slug), unreadable=True))
            continue
        live = sum(1 for entry in entries if entry.last_status != STATUS_DEAD)
        for entry in entries:
            credentials.append(Credential(
                id=str(entry.id), provider=slug, kind=_entry_kind(slug, entry), entry=entry,
                pool_size=len(entries), live_count=live))
    return credentials


def _standalone_credentials() -> list[Credential]:
    from hermes_cli.auth import PROVIDER_REGISTRY, _load_auth_store, get_api_key_provider_status, read_credential_pool

    pooled = {str(provider).strip().lower() for provider, rows in read_credential_pool().items() if rows}
    found: dict[str, str] = {}
    for slug, config in list(PROVIDER_REGISTRY.items()):
        if slug in pooled or config.auth_type != "api_key":
            continue
        try:
            status = get_api_key_provider_status(slug)
        except Exception:
            logger.debug("Credential status read failed for %s", slug, exc_info=True)
            continue
        if status.get("logged_in") and status.get("key_source") != "local-offline":
            found[slug] = KIND_API_KEY
    for provider, rows in read_credential_pool().items():
        slug = str(provider or "").strip().lower()
        if slug in _SUBSCRIPTION_PROVIDERS and not rows and slug not in found:
            found[slug] = KIND_SUBSCRIPTION
    signed_in = _load_auth_store().get("providers")
    for slug, state in (signed_in.items() if isinstance(signed_in, dict) else ()):
        slug = str(slug).strip().lower()
        if slug and slug not in pooled and isinstance(state, dict) and state:
            found[slug] = KIND_SUBSCRIPTION
    return [Credential(id=slug, provider=slug, kind=kind) for slug, kind in found.items()]


def _provider_kind(provider: str) -> str:
    return KIND_SUBSCRIPTION if provider in _SUBSCRIPTION_PROVIDERS else KIND_API_KEY


def _entry_kind(provider: str, entry: Any) -> str:
    from agent.credential_pool import AUTH_TYPE_OAUTH

    if entry.auth_type == AUTH_TYPE_OAUTH:
        return KIND_SUBSCRIPTION
    return _provider_kind(provider)


def _provider_label(provider: str) -> str:
    if provider in _PROVIDER_LABEL_OVERRIDES:
        return _PROVIDER_LABEL_OVERRIDES[provider]
    from hermes_cli.models_catalog_static import _PROVIDER_LABELS
    from providers import get_provider_profile

    profile = get_provider_profile(provider)
    if profile is not None and profile.display_name:
        return profile.display_name
    return _PROVIDER_LABELS.get(provider) or provider.replace("-", " ").replace("_", " ").title()


def _active_provider() -> str:
    from hermes_cli.auth import get_active_provider
    from hermes_cli.inventory import load_picker_context
    from hermes_cli.models import normalize_provider

    try:
        configured = load_picker_context().current_provider
    except Exception:
        logger.debug("Active provider read from config failed", exc_info=True)
        configured = ""
    provider = str(configured or get_active_provider() or "").strip()
    return normalize_provider(provider) if provider else ""


def _credential_secrets(credentials: Iterable[Credential]) -> frozenset[str]:
    secrets: set[str] = set()
    for credential in credentials:
        entry = credential.entry
        if entry is None:
            continue
        for name in ("access_token", "refresh_token", "agent_key"):
            value = str(getattr(entry, name, "") or "").strip()
            if len(value) >= _MIN_SECRET_LENGTH:
                secrets.add(value)
    return frozenset(secrets)


def _mentions_secret(text: str, secrets: frozenset[str]) -> bool:
    return any(secret in text or (len(text) >= _MIN_SECRET_LENGTH and text in secret) for secret in secrets)


def _account_label(credential: Credential, secrets: frozenset[str]) -> Optional[str]:
    if credential.entry is None:
        return None
    label = str(credential.entry.label or "").strip()
    if not label or _TOKEN_SHAPED_LABEL.match(label) or _mentions_secret(label, secrets):
        return None
    return label


def _scrubbed(row: dict, secrets: frozenset[str]) -> dict:
    for field in ("account_label", "plan", "unavailable_reason"):
        value = row[field]
        if isinstance(value, str) and _mentions_secret(value, secrets):
            row[field] = None
    return row


def _spend_for(credential: Credential, spend: Optional[dict], empty_spend: Callable[[int], Any]) -> Optional[dict]:
    if spend is None or credential.pool_size > 1 or credential.unreadable:
        return None
    return spend.get(credential.provider, empty_spend(SPEND_PERIOD_DAYS)).to_wire()


def _fetch_requests(
    credentials: Iterable[Credential], supports_usage: dict[str, bool], now: float,
) -> Iterable[UsageFetchRequest]:
    from hermes_cli.inventory_usage import entry_usage, pool_entry_route_base_url

    for credential in credentials:
        if credential.unreadable or not supports_usage.get(credential.provider):
            continue
        entry = credential.entry
        if entry is None:
            yield UsageFetchRequest(provider=credential.provider)
            continue
        usage = entry_usage(
            credential.provider, entry, sole=credential.live_count <= 1, supports_usage=True, now=now)
        token = str(entry.runtime_api_key or "").strip()
        if usage.is_dead or not token:
            continue
        yield UsageFetchRequest(
            provider=credential.provider, identity_id=usage.identity_id,
            base_url=pool_entry_route_base_url(credential.provider, entry), api_key=token)


def _read_usage(
    credential: Credential, supports_usage: bool, now: float, refreshed: bool,
    outcomes: dict[tuple[str, str], UsageFetchOutcome],
) -> UsageReading:
    if credential.unreadable:
        return UsageReading(state="unknown", windows=[], reason=REASON_UNREADABLE)
    if credential.entry is None:
        return _read_provider_usage(credential, supports_usage, refreshed, outcomes)
    from hermes_cli.inventory_usage import entry_usage

    usage = entry_usage(
        credential.provider, credential.entry, sole=credential.live_count <= 1,
        supports_usage=supports_usage, now=now)
    if usage.is_dead:
        return UsageReading(state="unavailable", windows=[], reason=REASON_DEAD)
    if usage.windows:
        return UsageReading(
            state=usage.state, windows=usage.windows, plan=usage.snapshot.plan,
            fetched_at=usage.snapshot.fetched_at.isoformat())
    if usage.state == "limited":
        return UsageReading(state="limited", windows=[], reason=REASON_LIMITED)
    outcome = outcomes.get((credential.provider, usage.identity_id))
    return UsageReading(
        state="unknown", windows=[],
        reason=_missing_usage_reason(supports_usage, usage.snapshot is not None, usage.stale, refreshed, outcome))


def _read_provider_usage(
    credential: Credential, supports_usage: bool, refreshed: bool,
    outcomes: dict[tuple[str, str], UsageFetchOutcome],
) -> UsageReading:
    from agent.account_usage_cache import cached_account_usage, snapshot_is_stale
    from hermes_cli.inventory_usage import windows_exhausted, wire_windows

    snapshot = cached_account_usage(credential.provider) if supports_usage else None
    stale = snapshot_is_stale(snapshot)
    windows = wire_windows(snapshot) if not stale else []
    if windows:
        return UsageReading(
            state="limited" if windows_exhausted(windows) else "ready", windows=windows, plan=snapshot.plan,
            fetched_at=snapshot.fetched_at.isoformat())
    outcome = outcomes.get((credential.provider, ""))
    return UsageReading(
        state="unknown", windows=[],
        reason=_missing_usage_reason(supports_usage, snapshot is not None, stale, refreshed, outcome))


def _missing_usage_reason(
    supports_usage: bool, has_snapshot: bool, stale: bool, refreshed: bool, outcome: Optional[UsageFetchOutcome],
) -> str:
    if not supports_usage:
        return REASON_UNSUPPORTED
    if outcome is not None:
        if outcome.timed_out:
            return REASON_TIMED_OUT
        if outcome.snapshot is not None and outcome.snapshot.unavailable_reason:
            return outcome.snapshot.unavailable_reason
    if refreshed:
        return REASON_FETCH_FAILED
    return REASON_STALE if has_snapshot and stale else REASON_NOT_LOADED
