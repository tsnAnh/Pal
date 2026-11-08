from __future__ import annotations

from typing import Literal

from pydantic import Field

from .base import Result
from .common import ProfileParams
from .config_free_tier_control import ProviderUsageWindow
from .registry import method


class AccountSubscriptionsParams(ProfileParams):
    refresh: bool = False


class AccountSubscriptionSpend(Result):
    period_days: int
    usd: float | None = None
    input_tokens: int
    output_tokens: int


class AccountSubscription(Result):
    id: str
    provider: str
    provider_label: str
    account_label: str | None = None
    kind: Literal["subscription", "api_key"]
    plan: str | None = None
    active: bool
    state: Literal["ready", "limited", "unknown", "unavailable"]
    windows: list[ProviderUsageWindow] = Field(default_factory=list)
    spend: AccountSubscriptionSpend | None = None
    unavailable_reason: str | None = None
    fetched_at: str | None = None


class AccountSubscriptionsResult(Result):
    subscriptions: list[AccountSubscription]


method("account.subscriptions", params=AccountSubscriptionsParams, result=AccountSubscriptionsResult,
       doc="Every model-provider credential the profile holds (credential pool plus standalone logins and keys), "
           "active provider first then subscriptions then API keys, each with its usage windows and recent spend. "
           "refresh=false answers from the usage cache with no network call; refresh=true fetches all accounts "
           "concurrently within a 10s bound.")
