"""Provider-neutral chat workspace install contract (Slack first, later Discord and Telegram).

No model carries a secret: a secret lives in the Vault and the wire names only its item id. The
``chat.*`` methods and the ``chat.install.changed`` event register with their handlers, because the
catalog rejects a contract that has no handler or emitter.
"""

from __future__ import annotations

from pydantic import Field

from .base import Params, Payload, Result, WireEnum
from .common import ProfileParams
from .registry import event, method


class CapabilityMode(WireEnum):
    automatic = "automatic"
    guided = "guided"
    unsupported = "unsupported"


class ProviderCapability(WireEnum):
    set_icon = "set_icon"
    app_level_credential = "app_level_credential"
    gateway_redirect = "gateway_redirect"
    unattended_refresh = "unattended_refresh"
    join_public_space = "join_public_space"
    join_private_space = "join_private_space"


class CapabilityEntry(Result):
    capability: ProviderCapability
    mode: CapabilityMode


class IdentityPolicy(Result):
    app_name_max: int = Field(ge=1)
    display_name_max: int = Field(ge=1)
    username_max: int = Field(ge=1)
    avatar_max_bytes: int = Field(ge=1)
    avatar_min_px: int = Field(ge=1)


class Capabilities(Result):
    provider_id: str
    requires_config_credential: bool
    creates_app: bool
    capabilities: list[CapabilityEntry]
    identity_policy: IdentityPolicy


class IdentityProjection(Result):
    app_name: str
    display_name: str
    username: str
    avatar_ref: str | None = None
    avatar_bytes: int | None = None


class SetupStep(WireEnum):
    not_started = "not_started"
    needs_credential = "needs_credential"
    creating_app = "creating_app"
    needs_manual_step = "needs_manual_step"
    needs_allow = "needs_allow"
    installing = "installing"
    ready = "ready"
    error = "error"
    revoked = "revoked"


class SetupEventKind(WireEnum):
    begin = "begin"
    credential_saved = "credential_saved"
    app_created = "app_created"
    manual_step_done = "manual_step_done"
    allow_granted = "allow_granted"
    installed = "installed"
    failed = "failed"
    retry = "retry"
    revoked = "revoked"


class NextActionKind(WireEnum):
    none = "none"
    paste_credential = "paste_credential"
    open_link = "open_link"
    copy_text = "copy_text"
    button = "button"


class NextAction(Result):
    kind: NextActionKind
    action_id: str
    link: str | None = None
    copy_text: str | None = None


class SetupErrorCode(WireEnum):
    credential_rejected = "credential_rejected"
    credential_expired = "credential_expired"
    app_create_failed = "app_create_failed"
    allow_denied = "allow_denied"
    install_failed = "install_failed"
    provider_unreachable = "provider_unreachable"


class FixAction(WireEnum):
    reenter_credential = "reenter_credential"
    retry = "retry"
    restart_allow = "restart_allow"


class SetupError(Result):
    code: SetupErrorCode
    fix: FixAction


class SetupState(Result):
    bot: str
    provider_id: str
    workspace: str
    step: SetupStep
    revision: int = Field(ge=0)
    app_id: str | None = None
    installation_id: str | None = None
    manual_steps_done: list[ProviderCapability] = Field(default_factory=list)
    resume_step: SetupStep | None = None
    next_action: NextAction
    fallback_action: NextAction | None = None
    error: SetupError | None = None
    updated_at: float


class InstallationStatus(WireEnum):
    active = "active"
    needs_reauth = "needs_reauth"
    revoked = "revoked"


class Installation(Result):
    id: str
    provider_id: str
    bot: str
    workspace_id: str
    workspace_name: str
    status: InstallationStatus
    created_at: float
    updated_at: float
    vault_item_ids: list[str]
    owner_user_id: str | None = None


class SpaceKind(WireEnum):
    public = "public"
    private = "private"
    direct = "direct"


class SpaceRef(Result):
    id: str
    name: str
    kind: SpaceKind
    joined: bool


class Binding(Result):
    bot: str
    space_id: str
    installation_id: str
    live: bool


class SpaceJoinOutcome(WireEnum):
    joined = "joined"
    already_joined = "already_joined"
    needs_invite = "needs_invite"


class ChatRpcErrorReason(WireEnum):
    provider_unknown = "provider_unknown"
    not_implemented = "not_implemented"
    stale_revision = "stale_revision"
    no_installation = "no_installation"
    owner_only = "owner_only"
    needs_public_url = "needs_public_url"
    invalid_event = "invalid_event"
    provider_failed = "provider_failed"


class ChatProviderParams(ProfileParams):
    provider_id: str = Field(min_length=1)


class ChatInstallParams(ChatProviderParams):
    workspace: str = ""


class ChatInstallAdvanceParams(ChatInstallParams):
    event: SetupEventKind
    expected_revision: int = Field(ge=0)
    manual_step: ProviderCapability | None = None
    vault_item_id: str | None = None


class ChatSpaceJoinParams(ChatInstallParams):
    space_id: str = Field(min_length=1)
    hello: bool = False


class ChatProviderListResult(Result):
    providers: list[Capabilities]


class ChatInstallStatusResult(Result):
    state: SetupState
    installation: Installation | None = None


class ChatSpacesListResult(Result):
    spaces: list[SpaceRef]


class ChatSpaceJoinResult(Result):
    outcome: SpaceJoinOutcome
    next_action: NextAction


class ChatBindingListResult(Result):
    bindings: list[Binding]


class ChatInstallChangedPayload(Payload):
    state: SetupState


method("chat.provider.list", params=ProfileParams, result=ChatProviderListResult,
       doc="Chat providers this gateway can install a bot into, with what each can do automatically. Owner connections only.")
method("chat.install.status", params=ChatInstallParams, result=ChatInstallStatusResult,
       doc="Persisted setup state for one bot, provider and workspace, plus the installation once ready. A fresh client resumes from it.")
method("chat.install.begin", params=ChatInstallParams, result=ChatInstallStatusResult,
       doc="Start or resume setup. Answers needs_public_url (with a button next_action in error data) when the gateway has no https public URL.")
method("chat.install.advance", params=ChatInstallAdvanceParams, result=ChatInstallStatusResult,
       doc="Send one setup event with the revision the client last saw. stale_revision when another client moved first; "
           "invalid_event when the event does not apply. allow_granted with vault_item_id adopts a pasted bot token.")
method("chat.spaces.list", params=ChatInstallParams, result=ChatSpacesListResult,
       doc="Channels the installed bot can see, with whether it has joined.")
method("chat.space.join", params=ChatSpaceJoinParams, result=ChatSpaceJoinResult,
       doc="Join a public channel, or get the invite steps for a private one. hello asks for one short greeting once live.")
method("chat.binding.list", params=ChatInstallParams, result=ChatBindingListResult,
       doc="Channels this bot is bound to and whether it is live in each.")
method("chat.install.revoke", params=ChatInstallParams, result=ChatInstallStatusResult,
       doc="Remove the installation, stop the bot's adapter and clear its tokens and allowed users. Keeps the app id for reinstall.")
event("chat.install.changed", ChatInstallChangedPayload,
      doc="A chat setup state moved, or a binding went live or not live. Exactly one per setup revision.")

WIRE_MODELS: tuple[type[Params | Result | Payload], ...] = (
    ChatProviderParams, ChatInstallParams, ChatInstallAdvanceParams, ChatSpaceJoinParams,
    ChatProviderListResult, ChatInstallStatusResult, ChatSpacesListResult, ChatSpaceJoinResult,
    ChatBindingListResult, ChatInstallChangedPayload, IdentityProjection,
)
