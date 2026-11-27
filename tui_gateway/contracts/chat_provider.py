"""Provider-neutral chat workspace install contract (Slack first, later Discord and Telegram).

No model carries a secret: a secret lives in the Vault and the wire names only its item id. The
``chat.*`` methods and the ``chat.install.changed`` event register with their handlers, because the
catalog rejects a contract that has no handler or emitter.
"""

from __future__ import annotations

from pydantic import Field, model_validator

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
    needs_owner = "needs_owner"
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
    owner_confirmed = "owner_confirmed"
    installed = "installed"
    failed = "failed"
    retry = "retry"
    reopen_step = "reopen_step"
    revoked = "revoked"


class NextActionKind(WireEnum):
    none = "none"
    paste_credential = "paste_credential"
    open_link = "open_link"
    copy_text = "copy_text"
    enter_text = "enter_text"
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


class AdapterState(WireEnum):
    online = "online"
    connecting = "connecting"
    failed = "failed"
    not_started = "not_started"


class AdapterFailure(WireEnum):
    invalid_token = "invalid_token"
    missing_intent = "missing_intent"
    missing_permission = "missing_permission"
    restart_needed = "restart_needed"
    adapter_offline = "adapter_offline"


class AdapterStatus(Result):
    state: AdapterState
    reason: AdapterFailure | None = None


class SetupError(Result):
    code: SetupErrorCode
    fix: FixAction
    reason: str | None = None
    permissions: list[str] = Field(default_factory=list)
    retry_after_seconds: int | None = Field(default=None, ge=0)


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


class ChatProviderParams(ProfileParams):
    provider_id: str = Field(min_length=1)


class ChatInstallParams(ChatProviderParams):
    workspace: str = ""


class ChatInstallBeginParams(ChatInstallParams):
    app_scheme: str | None = None


class ChatInstallAdvanceParams(ChatInstallBeginParams):
    event: SetupEventKind
    expected_revision: int = Field(ge=0)
    manual_step: ProviderCapability | None = None
    vault_item_id: str | None = None
    refresh_vault_item_id: str | None = None
    owner_member_id: str | None = None


class IdentityUpdateOutcome(WireEnum):
    updated = "updated"
    needs_manual_avatar = "needs_manual_avatar"


class ChatSpaceJoinParams(ChatInstallParams):
    space_id: str = Field(min_length=1)
    hello: bool = False


class SpaceLeaveOutcome(WireEnum):
    left = "left"
    not_member = "not_member"


class AudiencePolicyKind(WireEnum):
    owner_only = "owner_only"
    workspace = "workspace"
    listed = "listed"


class ReportDestinationKind(WireEnum):
    owner_dm = "owner_dm"
    space = "space"


class DeskItemKind(WireEnum):
    ask = "ask"
    handoff = "handoff"
    send = "send"


class DeskItemState(WireEnum):
    posting = "posting"
    open = "open"
    approved = "approved"
    executing = "executing"
    done = "done"
    declined = "declined"
    expired = "expired"
    unknown = "unknown"
    cancelled = "cancelled"
    failed = "failed"


class DeskChoice(WireEnum):
    approve = "approve"
    decline = "decline"


MAX_AUDIENCE_MEMBERS = 500
MAX_TURNS_PER_HOUR = 1000


class Person(Result):
    id: str
    name: str
    display_name: str = ""
    is_restricted: bool = False


class AudienceMember(Result):
    id: str
    name: str = ""


class ReportDestination(Result):
    kind: ReportDestinationKind
    space_id: str | None = None
    name: str = ""

    @model_validator(mode="after")
    def _space_has_id(self) -> ReportDestination:
        if (self.kind is ReportDestinationKind.space) != bool(self.space_id):
            raise ValueError("a channel destination needs its space_id and an owner DM has none")
        return self


class DeskPerson(Result):
    id: str
    name: str = ""


class DeskPlace(Result):
    conversation_id: str = ""
    thread_ts: str | None = None
    label: str = ""


class DeskRecipient(Result):
    user_id: str | None = None
    conversation_id: str | None = None
    direct: bool = False


class DeskItemWire(Result):
    id: str
    kind: DeskItemKind
    state: DeskItemState
    revision: int = Field(ge=0)
    created_at: float
    expires_at: float
    requester: DeskPerson | None = None
    where: DeskPlace
    text: str
    why: str | None = None
    recipient: DeskRecipient | None = None


class ChatSpaceLeaveParams(ChatInstallParams):
    space_id: str = Field(min_length=1)


class ChatInstallSetIconParams(ChatInstallParams):
    data: str = Field(min_length=1)


class ChatAudienceSetParams(ChatInstallParams):
    policy: AudiencePolicyKind
    members: list[str] | None = Field(default=None, max_length=MAX_AUDIENCE_MEMBERS)
    include_restricted: bool | None = None
    member_turns_per_hour: int | None = Field(default=None, ge=1, le=MAX_TURNS_PER_HOUR)
    expected_revision: int = Field(ge=0)


class ChatPeopleListParams(ChatInstallParams):
    query: str = Field(default="", max_length=100)
    cursor: str = ""


class ChatReportSetParams(ChatInstallParams):
    destination: ReportDestination


class ChatDeskListParams(ProfileParams):
    states: list[DeskItemState] | None = None
    kinds: list[DeskItemKind] | None = None


class ChatDeskDecideParams(ProfileParams):
    item_id: str = Field(min_length=1)
    choice: DeskChoice
    expected_revision: int = Field(ge=0)


class ChatSpaceLeaveResult(Result):
    outcome: SpaceLeaveOutcome


class ChatInstallSetIconResult(Result):
    ok: bool


class ChatAudienceResult(Result):
    policy: AudiencePolicyKind
    members: list[AudienceMember]
    include_restricted: bool
    member_turns_per_hour: int
    revision: int = Field(ge=0)


class ChatPeopleListResult(Result):
    people: list[Person]
    next_cursor: str | None = None


class ChatReportResult(Result):
    destination: ReportDestination


class ChatDeskListResult(Result):
    items: list[DeskItemWire]


class ChatDeskDecideResult(Result):
    item: DeskItemWire


class ChatDeskChangedPayload(Payload):
    item: DeskItemWire


class ChatProviderListResult(Result):
    providers: list[Capabilities]


class ChatInstallStatusResult(Result):
    state: SetupState
    installation: Installation | None = None
    adapter: AdapterStatus | None = None


class ChatIdentityUpdateResult(Result):
    outcome: IdentityUpdateOutcome
    identity: IdentityProjection
    next_action: NextAction


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
       doc="Persisted setup state for one bot, provider and workspace, plus the installation once ready. A fresh client resumes from it. "
           "Discord also answers adapter: the live state of the shared connection in the running gateway, never the install record.")
method("chat.install.reconnect", params=ChatInstallParams, result=ChatInstallStatusResult,
       doc="Rebuild the chat adapter behind a ready install in the running gateway, with no process restart, and wait up to 45 s. "
           "adapter says whether it is online or why not. no_installation unless the install is ready; not_implemented for "
           "providers without a shared adapter. Owner connections only.")
method("chat.install.begin", params=ChatInstallBeginParams, result=ChatInstallStatusResult,
       doc="Start or resume setup. Answers needs_public_url (with a button next_action in error data) when the gateway has no https public URL "
           "and the provider installs through a redirect (Discord does not). "
           "app_scheme is the URL scheme of the Pal build that asked, so the page after Allow returns to it; "
           "only dev.tsnanh.hermes.bot and dev.tsnanh.hermes.bot.dev are used, anything else or absent means the first.")
method("chat.install.advance", params=ChatInstallAdvanceParams, result=ChatInstallStatusResult,
       doc="Send one setup event with the revision the client last saw. stale_revision when another client moved first; "
           "invalid_event when the event does not apply. allow_granted with vault_item_id adopts a pasted bot token. "
           "credential_saved takes refresh_vault_item_id with the config refresh token. manual_step_done for app_level_credential "
           "requires vault_item_id with the pasted key (invalid_event without it). owner_confirmed takes owner_member_id. "
           "reopen_step goes back: manual_step names a guided step already done, which and every guided step after it are asked "
           "for again (needs_manual_step); without manual_step it reissues the allow link. From needs_manual_step, needs_allow "
           "or an error in either; invalid_event for an automatic step, one not yet reached or any other state. "
           "app_scheme is read as in chat.install.begin.")
method("chat.spaces.list", params=ChatInstallParams, result=ChatSpacesListResult,
       doc="Channels the installed bot can see, with whether it has joined.")
method("chat.space.join", params=ChatSpaceJoinParams, result=ChatSpaceJoinResult,
       doc="Join a public channel, or get the invite steps for a private one. hello asks for one short greeting once live.")
method("chat.binding.list", params=ChatInstallParams, result=ChatBindingListResult,
       doc="Channels this bot is bound to and whether it is live in each.")
method("chat.install.update_identity", params=ChatInstallParams, result=ChatIdentityUpdateResult,
       doc="Send the bot's current name and display name to the chat app, and its picture when the provider can set it. "
           "needs_manual_avatar with a button next_action when the picture is still a guided step. Owner connections only.")
method("chat.install.revoke", params=ChatInstallParams, result=ChatInstallStatusResult,
       doc="Remove the installation, stop the bot's adapter and clear its tokens and allowed users. Deletes the chat app, "
           "so a reinstall starts from a fresh one and the revoked state carries no app id. "
           "Discord has no app per bot: it deletes the bot's webhook and routes and keeps the bot's channel, so its history stays.")
method("chat.install.set_icon", params=ChatInstallSetIconParams, result=ChatInstallSetIconResult,
       doc="Store the bot's own picture (a PNG data URL) for the chat app and push the bot's name and picture to every active "
           "install of that bot. The push runs after the answer; a failed push is retried on the next connect or identity change. "
           "Owner connections only.")
method("chat.space.leave", params=ChatSpaceLeaveParams, result=ChatSpaceLeaveResult,
       doc="Remove the bot from a channel, forget its binding there and retire the questions still waiting on answers in it. "
           "Safe to repeat: not_member when the bot was already out.")
method("chat.audience.get", params=ChatInstallParams, result=ChatAudienceResult,
       doc="Who may talk to the bot besides its owner, with the revision to send back on a change. Owner connections only.")
method("chat.audience.set", params=ChatAudienceSetParams, result=ChatAudienceResult,
       doc="Change who may talk to the bot. Takes effect on the next message. stale_revision when another device changed it first. "
           "Owner connections only.")
method("chat.people.list", params=ChatPeopleListParams, result=ChatPeopleListResult,
       doc="People in the bot's workspace who can be allowed to talk to it, with an optional name filter and a cursor. "
           "Bots, removed accounts and people from other organizations are left out.")
method("chat.report.get", params=ChatInstallParams, result=ChatReportResult,
       doc="Where the bot sends its reports and owner questions: the owner's direct messages or a channel it has joined.")
method("chat.report.set", params=ChatReportSetParams, result=ChatReportResult,
       doc="Choose where the bot sends its reports: the owner's direct messages or a channel it has joined. "
           "not_joined when the bot is not in that channel.")
method("chat.desk.list", params=ChatDeskListParams, result=ChatDeskListResult,
       doc="Questions, hand-offs and sends the bot is holding for its owner, with the exact texts. Defaults to everything still waiting.")
method("chat.desk.decide", params=ChatDeskDecideParams, result=ChatDeskDecideResult,
       doc="Approve or decline one waiting item, the same decision the owner's chat card makes. "
           "stale_revision when it moved since the client last saw it; not_found when it is gone.")
event("chat.desk.changed", ChatDeskChangedPayload,
      doc="A desk item was created or moved, sent for the bot's profile. A burst between two checks arrives as the latest revision.")
event("chat.install.changed", ChatInstallChangedPayload,
      doc="A chat setup state moved, or a binding went live or not live. Exactly one per setup revision.")

WIRE_MODELS: tuple[type[Params | Result | Payload], ...] = (
    ChatProviderParams, ChatInstallParams, ChatInstallAdvanceParams, ChatSpaceJoinParams,
    ChatProviderListResult, ChatInstallStatusResult, ChatSpacesListResult, ChatSpaceJoinResult,
    ChatBindingListResult, ChatInstallChangedPayload, ChatIdentityUpdateResult, IdentityProjection,
    ChatSpaceLeaveParams, ChatInstallSetIconParams, ChatAudienceSetParams, ChatPeopleListParams, ChatReportSetParams,
    ChatDeskListParams, ChatDeskDecideParams, ChatSpaceLeaveResult, ChatInstallSetIconResult, ChatAudienceResult,
    ChatPeopleListResult, ChatReportResult, ChatDeskListResult, ChatDeskDecideResult, ChatDeskChangedPayload,
    Person, AudienceMember, ReportDestination, DeskPerson, DeskPlace, DeskRecipient, DeskItemWire,
)
