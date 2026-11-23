from __future__ import annotations

from .base import Result, WireEnum
from .common import ProfileParams
from .registry import method


class ModelProviderKind(WireEnum):
    api_key = "api_key"
    device_code = "device_code"
    oauth_paste = "oauth_paste"
    cli_plan = "cli_plan"
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
    """One model provider's setup state for the bot profile. ``kind`` cli_plan is a subscription that runs
    through a command-line tool on the Hermes host (Claude Direct SDK): it has no sign-in flow here, ``state``
    is set once the tool, its plugin and its sign-in are all present, and ``reason`` carries what is missing
    (see model.providers.host_check / install_plugin). ``scope`` account means the login is shared by
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


class ModelProviderTestParams(ProfileParams):
    provider: str
    model: str
    base_url: str | None = None
    api_key: str | None = None
    timeout_s: float | None = None


class ModelProviderTestErrorKind(WireEnum):
    auth = "auth"
    network = "network"
    timeout = "timeout"
    model = "model"
    quota = "quota"
    unsupported = "unsupported"
    other = "other"


class ModelProviderTestError(Result):
    code: str
    reason: str
    retryable: bool
    kind: ModelProviderTestErrorKind


class ModelProviderTestResult(Result):
    ok: bool
    provider: str
    model: str
    latency_ms: int
    reply_preview: str | None = None
    error: ModelProviderTestError | None = None


method("model.providers.test", params=ModelProviderTestParams, result=ModelProviderTestResult,
       doc="Send one real request (a few tokens) to the provider and model and report whether it answered, how "
           "long it took and, on failure, why. Nothing is saved: a staged api_key lives in memory for the call "
           "only and is never written, logged or echoed. api_key applies only to api_key providers; sign-in and "
           "cli_plan providers are tested with their stored login and ignore it. base_url is honoured only where "
           "the provider's address is editable. timeout_s defaults to 30 and is capped at 60. A provider that "
           "cannot be tested here answers ok=false, error.kind unsupported, code unsupported_provider. Malformed "
           "params are RPC error 4001; a login shared by every profile tested from another profile is 4095.")


class ModelProviderHostCheckParams(ProfileParams):
    provider: str


class ModelProviderHostCheckResult(Result):
    cli_found: bool
    cli_version: str | None = None
    signed_in: bool
    plan: str | None = None
    plugin_installed: bool
    plugin_version: str | None = None
    install_hint: str | None = None
    disclosure: str | None = None


method("model.providers.host_check", params=ModelProviderHostCheckParams, result=ModelProviderHostCheckResult,
       doc="What the Hermes host has for a cli_plan provider: the command-line tool, a sign-in it can see, and "
           "the provider plugin. install_hint is the next step in plain words (absent when ready); disclosure is "
           "the plugin's billing and account notice to show before installing. cli_version and plan are absent "
           "until the plugin reports them. Any other provider answers cli_found false with install_hint "
           "\"This provider has no host check.\"")


class ModelProviderInstallPluginOutcome(WireEnum):
    installed = "installed"
    already_installed = "already_installed"
    refused = "refused"
    unsupported = "unsupported"
    failed = "failed"


class ModelProviderInstallPluginResult(Result):
    outcome: ModelProviderInstallPluginOutcome
    reason: str | None = None
    provider: ModelProvider | None = None


method("model.providers.install_plugin", params=ModelProviderHostCheckParams, result=ModelProviderInstallPluginResult,
       doc="Install the plugin behind a cli_plan provider from the plugin catalog, as the plugins screen does. "
           "already_installed: nothing was run. refused: the host is managed or the command-line tool is missing "
           "(reason says which). The provider row is refreshed in the result.")
