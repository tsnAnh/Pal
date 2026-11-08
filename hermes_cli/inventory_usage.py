from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import TYPE_CHECKING, Any, Optional

if TYPE_CHECKING:
    from agent.account_usage import AccountUsageSnapshot

EXHAUSTED_WINDOW_PERCENT = 100.0


def iso_from_epoch(epoch: float) -> str:
    return datetime.fromtimestamp(float(epoch), UTC).isoformat()


def wire_windows(snapshot: Optional[AccountUsageSnapshot]) -> list[dict]:
    return [
        {"label": w.label, "used_percent": float(w.used_percent),
         "resets_at": w.reset_at.isoformat() if w.reset_at else None,
         "scope": w.scope}
        for w in (snapshot.windows if snapshot else ()) if w.used_percent is not None
    ]


def account_resets_at(snapshot: Optional[AccountUsageSnapshot], live_cooldown_until: float | None) -> str | None:
    resets: list[str] = []
    if live_cooldown_until:
        resets.append(iso_from_epoch(live_cooldown_until))
    for window in (snapshot.windows if snapshot else ()):
        if window.scope != "account" or window.used_percent is None or window.reset_at is None:
            continue
        if float(window.used_percent) >= EXHAUSTED_WINDOW_PERCENT:
            resets.append(window.reset_at.isoformat())
    return max(resets) if resets else None


def windows_exhausted(windows: list[dict]) -> bool:
    return any(
        w.get("scope") == "account" and w.get("used_percent") is not None
        and float(w["used_percent"]) >= EXHAUSTED_WINDOW_PERCENT for w in windows)


def pool_entry_host(slug: str, entry: Any) -> str:
    from agent.credential_pool import _norm_url

    if slug == "openai-codex":
        from hermes_cli.auth_codex import _codex_pool_route_base_url

        return _norm_url(_codex_pool_route_base_url(entry.runtime_base_url))
    return _norm_url(getattr(entry, "runtime_base_url", None))


def pool_entry_route_base_url(slug: str, entry: Any) -> Optional[str]:
    if slug == "openai-codex":
        from hermes_cli.auth_codex import _codex_pool_route_base_url

        return _codex_pool_route_base_url(entry.runtime_base_url)
    return getattr(entry, "runtime_base_url", None) or None


@dataclass(frozen=True)
class EntryUsage:
    identity_id: str
    host: str
    is_dead: bool
    stale: bool
    snapshot: Optional[AccountUsageSnapshot]
    windows: list[dict]
    state: str
    resets_at: str | None


def entry_usage(slug: str, entry: Any, *, sole: bool, supports_usage: bool, now: float) -> EntryUsage:
    from agent.account_usage_cache import _identity_id_for, cached_account_usage, snapshot_is_stale
    from agent.credential_pool import STATUS_DEAD, _exhausted_until

    identity_id = _identity_id_for(slug, entry)
    is_dead = entry.last_status == STATUS_DEAD
    snapshot = cached_account_usage(slug, identity_id=identity_id) if supports_usage and not is_dead else None
    stale = snapshot_is_stale(snapshot)
    windows = wire_windows(snapshot) if not stale else []
    cooldown_until = None if is_dead else _exhausted_until(entry, sole_credential=sole)
    live_cooldown = cooldown_until if cooldown_until and cooldown_until > now else None
    quota_exhausted = windows_exhausted(windows)
    if is_dead:
        state = "unavailable"
    elif live_cooldown is not None or quota_exhausted:
        state = "limited"
    elif snapshot is None or stale or not windows:
        state = "unknown"
    else:
        state = "ready"
    return EntryUsage(
        identity_id=identity_id, host=pool_entry_host(slug, entry), is_dead=is_dead, stale=stale,
        snapshot=snapshot, windows=windows, state=state,
        resets_at=account_resets_at(snapshot, live_cooldown),
    )
