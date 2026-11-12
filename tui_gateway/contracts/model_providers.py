from __future__ import annotations

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class ModelProviderKind(WireEnum):
    api_key = "api_key"
    device_code = "device_code"
    oauth_paste = "oauth_paste"
    unsupported = "unsupported"


class ModelProviderState(WireEnum):
    configured = "set"
    not_set = "not_set"
    expired = "expired"
    unsupported = "unsupported"


class ModelProviderScope(WireEnum):
    profile = "profile"
    account = "account"


class ModelProvider(Result):
    """One model provider's setup state for the bot profile. ``scope`` account means the login is shared by
    every profile on the host, so only the main profile may change it. ``base_url`` is the address override
    (plain, not a secret), ``default_base_url`` what applies without one. No credential value is ever carried."""

    id: str
    name: str
    kind: ModelProviderKind
    state: ModelProviderState
    scope: ModelProviderScope
    base_url_editable: bool
    base_url: str | None = None
    default_base_url: str | None = None
    reason: str | None = None
    can_remove: bool


class ModelProvidersResult(Result):
    profile: str
    providers: list[ModelProvider]


method("model.providers.list", params=ProfileParams, result=ModelProvidersResult,
       doc="Every model provider with whether its credential is set, expired or missing for the profile. "
           "Setting or replacing a credential goes through auth.begin with service provider:<id>.")


class ModelProviderRemoveParams(ProfileParams):
    provider: str


class ModelProviderRemoveOutcome(WireEnum):
    removed = "removed"
    nothing_to_remove = "nothing_to_remove"
    still_set = "still_set"
    refused = "refused"
    unsupported = "unsupported"
    failed = "failed"


class ModelProviderRemoveResult(Result):
    outcome: ModelProviderRemoveOutcome
    reason: str | None = None
    provider: ModelProvider | None = None


method("model.providers.remove", params=ModelProviderRemoveParams, result=ModelProviderRemoveResult,
       doc="Remove a provider's stored credential for the profile, as `hermes auth remove` / `hermes logout` do. "
           "still_set: something outside Pal (the host's environment, a shared provider key) still supplies one.")


class ModelProviderBaseUrlParams(ProfileParams):
    provider: str
    base_url: str | None = None


class ModelProviderBaseUrlOutcome(WireEnum):
    saved = "saved"
    reset = "reset"
    invalid = "invalid"
    unsupported = "unsupported"
    failed = "failed"


class ModelProviderBaseUrlResult(Result):
    outcome: ModelProviderBaseUrlOutcome
    reason: str | None = None
    provider: ModelProvider | None = None


method("model.providers.set_base_url", params=ModelProviderBaseUrlParams, result=ModelProviderBaseUrlResult,
       doc="Set the provider's address (an http(s) URL), or reset it to the default when base_url is null.")
