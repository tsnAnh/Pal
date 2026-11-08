from __future__ import annotations

import logging
import sqlite3
import time
from contextlib import closing
from dataclasses import dataclass
from typing import Optional

logger = logging.getLogger(__name__)

_SPEND_BY_PROVIDER_SQL = """
    SELECT u.billing_provider AS provider,
           COALESCE(SUM(u.input_tokens), 0) AS input_tokens,
           COALESCE(SUM(u.output_tokens), 0) AS output_tokens,
           COALESCE(SUM(CASE WHEN u.actual_cost_usd > 0 THEN u.actual_cost_usd
                             ELSE u.estimated_cost_usd END), 0) AS usd,
           COALESCE(SUM(CASE WHEN u.cost_status IS NOT NULL AND u.cost_status != 'unknown' THEN 1 ELSE 0 END), 0) AS priced_rows
    FROM session_model_usage u
    JOIN sessions s ON s.id = u.session_id
    WHERE s.started_at > ? AND u.billing_provider != ''
    GROUP BY u.billing_provider
"""


@dataclass(frozen=True)
class ProviderSpend:
    period_days: int
    usd: Optional[float]
    input_tokens: int
    output_tokens: int

    def to_wire(self) -> dict:
        return {"period_days": self.period_days, "usd": self.usd,
                "input_tokens": self.input_tokens, "output_tokens": self.output_tokens}


def _state_db_path():
    from hermes_constants import get_hermes_home

    return get_hermes_home() / "state.db"


def spend_by_provider(period_days: int, *, now: Optional[float] = None) -> Optional[dict[str, ProviderSpend]]:
    from hermes_cli.models import normalize_provider
    from hermes_state import SessionDB

    db_path = _state_db_path()
    try:
        if db_path.stat().st_size <= 0:
            return None
    except OSError:
        return None
    cutoff = (time.time() if now is None else now) - period_days * 86400
    try:
        with closing(SessionDB(db_path=db_path, read_only=True)) as db:
            rows = db._conn.execute(_SPEND_BY_PROVIDER_SQL, (cutoff,)).fetchall()
    except (sqlite3.Error, OSError):
        logger.debug("Provider spend read failed", exc_info=True)
        return None
    spend: dict[str, ProviderSpend] = {}
    for row in rows:
        provider = normalize_provider(str(row["provider"]))
        previous = spend.get(provider)
        usd = float(row["usd"]) if row["priced_rows"] else None
        spend[provider] = ProviderSpend(
            period_days=period_days,
            usd=usd if previous is None else _sum_usd(previous.usd, usd),
            input_tokens=int(row["input_tokens"]) + (previous.input_tokens if previous else 0),
            output_tokens=int(row["output_tokens"]) + (previous.output_tokens if previous else 0),
        )
    return spend


def _sum_usd(first: Optional[float], second: Optional[float]) -> Optional[float]:
    if first is None:
        return second
    return first if second is None else first + second


def empty_spend(period_days: int) -> ProviderSpend:
    return ProviderSpend(period_days=period_days, usd=0.0, input_tokens=0, output_tokens=0)
