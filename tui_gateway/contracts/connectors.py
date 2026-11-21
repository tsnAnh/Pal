"""Contracts for connector catalog, authorization, and tool-list reads."""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import Field, model_validator

from .base import Result, WireEnum
from .common import ConnectorOwner, ProfileParams
from .connectors_operation import ConnectionOperationStatus
from .registry import method

ConnectorSlug = Annotated[str, Field(pattern=r"^[a-z0-9][a-z0-9_-]*$")]
# The name of one hosted account of a connector (the gateway's account alias format).
ConnectorAlias = Annotated[str, Field(pattern=r"^[a-z0-9][a-z0-9-]{0,31}$")]


class ConnectorErrorReason(WireEnum):
    invalid_params = "INVALID_PARAMS"
    not_owner = "NOT_OWNER"
    unsupported_runtime = "UNSUPPORTED_RUNTIME"
    connector_request_failed = "CONNECTOR_REQUEST_FAILED"
    invalid_connector_response = "INVALID_CONNECTOR_RESPONSE"
    unknown_target = "UNKNOWN_TARGET"
    link_still_valid = "LINK_STILL_VALID"
    reissue_refused = "REISSUE_REFUSED"
    unknown_operation = "UNKNOWN_OPERATION"
    invalid_answer = "INVALID_ANSWER"
    needs_nous_auth = "NEEDS_NOUS_AUTH"
    connector_not_found = "CONNECTOR_NOT_FOUND"
    tools_unavailable = "TOOLS_UNAVAILABLE"
    connectors_unavailable = "CONNECTORS_UNAVAILABLE"
    catalog_unavailable = "CATALOG_UNAVAILABLE"
    accounts_unavailable = "ACCOUNTS_UNAVAILABLE"
    connection_not_found = "CONNECTION_NOT_FOUND"
    policy_unavailable = "POLICY_UNAVAILABLE"
    policy_conflict = "POLICY_CONFLICT"
    forbidden_scope = "FORBIDDEN_SCOPE"
    org_required = "ORG_REQUIRED"
    org_access_denied = "ORG_ACCESS_DENIED"
    invalid_policy = "INVALID_POLICY"
    alias_taken = "ALIAS_TAKEN"
    needs_setup = "NEEDS_SETUP"
    needs_public_url = "NEEDS_PUBLIC_URL"
    invalid_client = "INVALID_CLIENT"
    client_unreadable = "CLIENT_UNREADABLE"
    connect_failed = "CONNECT_FAILED"
    invalid_token = "INVALID_TOKEN"
    check_unavailable = "CHECK_UNAVAILABLE"
    admin_approval_pending = "ADMIN_APPROVAL_PENDING"


class ConnectorsListParams(ProfileParams):
    owner: ConnectorOwner


class ConnectorRow(Result):
    connector: str
    enabled: bool
    connected: bool
    connection_status: Literal["pending", "active", "failed", "expired", "revoked", "inactive"] | None
    status_reason: str | None
    gateway_disabled_tools: list[str]


class ConnectorsListResult(Result):
    available: bool
    connectors: list[ConnectorRow]


method(
    "connectors.list",
    params=ConnectorsListParams,
    result=ConnectorsListResult,
    doc="Connector catalog + connection state for one session or profile account owner.",
)


class ConnectorsConnectParams(ProfileParams):
    owner: ConnectorOwner
    connectors: list[ConnectorSlug] = Field(min_length=1)
    reconnect: bool = False
    # Connects (or, with ``reconnect``, repairs) the account of that name; one connector per call.
    alias: ConnectorAlias | None = None
    # With ``reconnect``: repairs this existing account, the only way to address an unnamed one.
    connection_id: str | None = Field(default=None, min_length=1)

    @model_validator(mode="after")
    def _one_connector_per_alias(self):
        if self.alias is not None and len(self.connectors) != 1:
            raise ValueError("alias names one account, so it takes exactly one connector")
        if self.connection_id is not None and (not self.reconnect or len(self.connectors) != 1 or self.alias):
            raise ValueError("connection_id repairs one account: it needs reconnect, one connector and no alias")
        return self


class ConnectorsConnectResult(ConnectionOperationStatus):
    """``methods_connectors._reissue`` / ``managed._off_desktop_result``: the operation the connect opened; ``status``/``note`` ride along from the tool result."""

    status: Literal["initiated", "settled"] | None = None
    note: str | None = None


method(
    "connectors.connect",
    params=ConnectorsConnectParams,
    result=ConnectorsConnectResult,
    doc="Start or re-initiate authorization for named connectors on a session or account operation.",
)


class ConnectorToolsParams(ProfileParams):
    slug: str
    refresh: bool = False


class ConnectorToolFacet(WireEnum):
    read = "read"
    write = "write"
    destructive = "destructive"
    unclassified = "unclassified"


class ConnectorToolRow(Result):
    model_config = Result.model_config | {"from_attributes": True}

    slug: str
    name: str
    description: str
    facet: ConnectorToolFacet
    hints: list[str]
    categories: list[str]
    no_auth: bool
    deprecated: bool


class ConnectorToolsSource(WireEnum):
    cache = "cache"
    network = "network"
    revalidated = "revalidated"


class ConnectorToolsResult(Result):
    model_config = Result.model_config | {"from_attributes": True}

    connector: str
    toolkit_version: str
    etag: str
    fetched_at: float
    source: ConnectorToolsSource
    stale: bool
    tools: list[ConnectorToolRow]


method(
    "connectors.tools",
    params=ConnectorToolsParams,
    result=ConnectorToolsResult,
    doc="The scoped profile's cached or current tool list for one connector.",
)


class ConnectorCatalogStatus(WireEnum):
    connected = "connected"
    needs_reconnect = "needs_reconnect"
    not_connected = "not_connected"
    needs_setup = "needs_setup"


class ConnectionAccountStatus(WireEnum):
    connected = "connected"
    needs_reconnect = "needs_reconnect"
    not_connected = "not_connected"


class ConnectionAccountRow(Result):
    name: str
    status: ConnectionAccountStatus
    reason: str | None = None


class SetupStepKind(WireEnum):
    public_url = "public_url"
    open_page = "open_page"
    paste = "paste"
    server_picker = "server_picker"
    access = "access"


class SetupCheckKind(WireEnum):
    google_client = "google_client"
    github_token = "github_token"
    canva_client = "canva_client"
    discord_bot = "discord_bot"


class SetupLinkRow(Result):
    label: str
    url: str


class SetupCopyRow(Result):
    label: str
    value: str


class SetupFieldRow(Result):
    id: str
    label: str
    secret: bool
    prefixes: list[str]
    suffix: str | None = None


class SetupProblemKind(WireEnum):
    not_https = "not_https"
    ip_host = "ip_host"


class SetupFallbackRow(Result):
    label: str
    body: str
    links: list[SetupLinkRow]


class SetupStepRow(Result):
    id: str
    kind: SetupStepKind
    title: str
    body: str
    links: list[SetupLinkRow]
    copies: list[SetupCopyRow]
    fields: list[SetupFieldRow]
    check: SetupCheckKind | None = None
    problem: SetupProblemKind | None = None
    problem_host: str | None = None
    fallback: SetupFallbackRow | None = None


class SetupGuide(Result):
    steps: list[SetupStepRow]


class SetupProgress(Result):
    step_id: str
    saved: list[str]


class ConnectorCatalogRow(Result):
    model_config = Result.model_config | {"from_attributes": True}

    slug: str
    name: str
    description: str
    category: str
    logo_url: str | None = None
    icon: str | None = None
    method: str | None = None
    verified: bool | None = None
    mcp_url: str | None = None
    status: ConnectorCatalogStatus | None = None
    notes: str | None = None
    setup_guide: SetupGuide | None = None
    setup_progress: SetupProgress | None = None
    featured: bool = False
    multi_account: bool = False
    accounts: list[ConnectionAccountRow] = []


class ConnectorsCatalogResult(Result):
    model_config = Result.model_config | {"from_attributes": True}

    connectors: list[ConnectorCatalogRow]


method(
    "connectors.catalog",
    params=ProfileParams,
    result=ConnectorsCatalogResult,
    doc="The Pal-owned connector catalog with each entry's direct connection status for the scoped profile. "
        "A connector that can hold several accounts is multi_account and lists them in accounts, each with its own "
        "status and reconnect reason; the entry's status is connected while any account is, needs_reconnect when "
        "none is but one needs it, else not_connected. "
        "A bot_app entry is set up per bot through the chat install verbs, so its status here is always not_connected.",
)


class OAuthClientSlugParams(ProfileParams):
    slug: str


class OAuthClientSaveParams(OAuthClientSlugParams):
    client_id_item: str
    client_secret_item: str


class OAuthClientRemoveParams(OAuthClientSlugParams):
    remove_client: bool = False
    account: str | None = None


class OAuthClientConnectParams(OAuthClientSlugParams):
    client_redirect_uri: str | None = None
    account: str | None = None
    create: bool = False


class OAuthClientSetupResult(Result):
    slug: str
    configured: bool
    console_url: str
    redirect_url: str | None


class OAuthClientConnectResult(Result):
    slug: str
    auth_url: str
    session_id: str | None


class OAuthClientRemoveResult(Result):
    slug: str
    removed: bool


method(
    "connectors.oauth_client.setup",
    params=OAuthClientSlugParams,
    result=OAuthClientSetupResult,
    doc="Whether the owner's OAuth client for an oauth_client catalog entry is saved, the console page to "
        "register it on and the redirect URL to register; redirect_url is null until the gateway has a public https address.",
)

method(
    "connectors.oauth_client.save",
    params=OAuthClientSaveParams,
    result=OAuthClientSetupResult,
    doc="Owner only. Save the OAuth client once for every profile and device: both values are Vault item ids "
        "the app wrote with vault.add.",
)

method(
    "connectors.oauth_client.connect",
    params=OAuthClientConnectParams,
    result=OAuthClientConnectResult,
    doc="Start the scoped profile's sign-in. With session_id the app relays the loopback redirect through "
        "mcp.servers.oauth.callback and polls mcp.servers.oauth.poll; without it the provider redirects to the "
        "gateway and the app polls connectors.catalog.",
)

method(
    "connectors.oauth_client.remove",
    params=OAuthClientRemoveParams,
    result=OAuthClientRemoveResult,
    doc="Remove the scoped profile's sign-in. The owner's saved OAuth client stays unless remove_client is true; "
        "then, owner only, the saved client record and its Vault items are deleted too.",
)


class ConnectorSetupCheckParams(OAuthClientSlugParams):
    values: dict[str, str]


class ConnectorSetupCheckResult(Result):
    slug: str
    ok: bool
    reason: ConnectorErrorReason | None = None
    message: str | None = None
    account: str | None = None


class SetupProgressDevice(WireEnum):
    mac = "mac"
    iphone = "iphone"
    ipad = "ipad"


class SetupProgressGetParams(ProfileParams):
    connector: str | None = None
    bot: str | None = None


class SetupProgressSetParams(ProfileParams):
    connector: str
    bot: str | None = None
    step_id: str
    completed: list[str]
    device: SetupProgressDevice
    finished: bool = False


class SetupProgressRecordRow(Result):
    connector: str
    bot: str | None = None
    step_id: str
    completed: list[str]
    device: SetupProgressDevice
    updated_at: float


class SetupProgressGetResult(Result):
    records: list[SetupProgressRecordRow]


class SetupProgressSetResult(Result):
    record: SetupProgressRecordRow | None = None


method(
    "connectors.setup.progress.get",
    params=SetupProgressGetParams,
    result=SetupProgressGetResult,
    doc="Where each connector's guided setup stands, newest first: the step to resume at, the step ids already "
        "done and the kind of device that last moved it. connector and bot narrow the list. Holds step ids only, "
        "never a value the owner pasted. A connection that is not the owner's gets an empty list.",
)

method(
    "connectors.setup.progress.set",
    params=SetupProgressSetParams,
    result=SetupProgressSetResult,
    doc="Owner only. Record that the guided setup of connector (and bot, where the setup is per bot) is at step_id "
        "with completed done. Every id must be a short slug; anything else is refused. finished true removes the "
        "record and answers with none.",
)


class DiscordTokenParams(ProfileParams):
    item: str


class DiscordBotResult(Result):
    bot_name: str
    application_id: str


class DiscordGuildRow(Result):
    id: str
    name: str


class DiscordGuildsResult(Result):
    guilds: list[DiscordGuildRow]
    allowed: list[str]
    read_only: bool


class DiscordSaveParams(ProfileParams):
    guild_ids: list[str]
    read_only: bool


class DiscordSaveResult(Result):
    tools: int
    read_only: bool
    guild_ids: list[str]


method(
    "connectors.discord.token",
    params=DiscordTokenParams,
    result=DiscordBotResult,
    doc="Owner only. Check the bot token in Vault item item with Discord and save it to the profile's .env as "
        "DISCORD_TOKEN. Returns the bot's name and application id only, never the token.",
)

method(
    "connectors.discord.guilds",
    params=ProfileParams,
    result=DiscordGuildsResult,
    doc="Owner only. The servers the saved bot is in, read live from Discord, with the saved allow-list and "
        "read-only choice.",
)

method(
    "connectors.discord.save",
    params=DiscordSaveParams,
    result=DiscordSaveResult,
    doc="Owner only. Save the Discord stdio server with DISCORD_ALLOWED_GUILDS from guild_ids (at least one, each "
        "a server the bot is in) and DISCORD_MCP_READ_ONLY from read_only, then run the MCP handshake. A failed "
        "handshake restores the previous server config and is an error; a live server restarts with the new env.",
)


class GoogleAdsSaveParams(ProfileParams):
    login_customer_id: str | None = None


class GoogleAdsState(WireEnum):
    needs_setup = "needs_setup"
    needs_sign_in = "needs_sign_in"
    signed_in = "signed_in"
    needs_reconnect = "needs_reconnect"


class GoogleAdsStatusResult(Result):
    state: GoogleAdsState
    configured: bool
    login_customer_id: str | None


class GoogleAdsSaveResult(Result):
    tools: int
    login_customer_id: str | None


class GoogleAdsCheck(WireEnum):
    ready = "ready"
    explorer_access_needed = "explorer_access_needed"
    needs_reauth = "needs_reauth"
    unreachable = "unreachable"


class GoogleAdsVerifyResult(Result):
    check: GoogleAdsCheck
    accounts: int | None


method(
    "connectors.google_ads.status",
    params=ProfileParams,
    result=GoogleAdsStatusResult,
    doc="Owner only. Where the Google Ads sign-in stands: needs_setup (no Google client saved yet), needs_sign_in, "
        "signed_in or needs_reconnect, whether the read-only Ads server is saved, and the saved manager account id. "
        "Never returns a token.",
)

method(
    "connectors.google_ads.save",
    params=GoogleAdsSaveParams,
    result=GoogleAdsSaveResult,
    doc="Owner only. Write the Google Ads credentials file from the saved Google client and the Ads sign-in, save "
        "the read-only Ads stdio server with the optional manager account id (digits only, else INVALID_PARAMS), then "
        "run the MCP handshake. A failed handshake restores the previous config and is an error.",
)

method(
    "connectors.google_ads.verify",
    params=ProfileParams,
    result=GoogleAdsVerifyResult,
    doc="Owner only. One live Google Ads call with the signed-in account. A refusal is a check value, never an RPC "
        "error: explorer_access_needed when Google has not approved the owner's Cloud project, needs_reauth when the "
        "refresh token was revoked or expired, unreachable when Google did not answer.",
)


method(
    "connectors.setup.check",
    params=ConnectorSetupCheckParams,
    result=ConnectorSetupCheckResult,
    doc="Owner only. Test a guided-setup paste step with one call to the provider. values maps each field id to "
        "the Vault item id the app wrote with vault.add. A provider rejection is ok false with a reason, never "
        "an RPC error; the secret is never returned or logged.",
)


class ConnectorAccountStatus(WireEnum):
    pending = "pending"
    active = "active"
    failed = "failed"
    expired = "expired"
    revoked = "revoked"
    inactive = "inactive"


class ConnectorAccountsParams(ProfileParams):
    connector: ConnectorSlug | None = None


class ConnectorAccountRow(Result):
    connection_id: str
    connector: str
    status: ConnectorAccountStatus
    status_reason: str | None = None
    label: str
    alias: str | None = None
    active: bool
    # Retired by a reconnect that replaced it; kept, never selectable.
    disabled: bool = False
    created_at: str
    updated_at: str


class ConnectorAccountsResult(Result):
    accounts: list[ConnectorAccountRow]


method(
    "connectors.accounts",
    params=ConnectorAccountsParams,
    result=ConnectorAccountsResult,
    doc="The scoped member's hosted connector accounts, optionally filtered by connector slug.",
)


class ConnectorAccountsRemoveParams(ProfileParams):
    connection_id: str = Field(min_length=1)


class ConnectorAccountsRemoveResult(Result):
    connection_id: str
    connector: str
    status: Literal["removed"]


method(
    "connectors.accounts.remove",
    params=ConnectorAccountsRemoveParams,
    result=ConnectorAccountsRemoveResult,
    doc="Remove one hosted connector account owned by the scoped member.",
)


class ConnectorAccountsRenameParams(ProfileParams):
    connection_id: str = Field(min_length=1)
    alias: ConnectorAlias


method(
    "connectors.accounts.rename",
    params=ConnectorAccountsRenameParams,
    result=ConnectorAccountRow,
    doc="Name or rename one hosted connector account owned by the scoped member.",
)


class ConnectorPolicyLayerKind(WireEnum):
    org = "org"
    role = "role"
    member = "member"


class ConnectorPolicyTags(Result):
    enable: list[str] | None = None
    disable: list[str] | None = None


class ConnectorPolicyUnrestrictedBody(Result):
    mode: Literal["unrestricted"]


class ConnectorPolicyDenyAllBody(Result):
    mode: Literal["deny-all"]


class ConnectorPolicyAllowBody(Result):
    mode: Literal["allow"]
    connectors: list[str]
    tools: dict[str, list[str]]
    tags: ConnectorPolicyTags | None = None


class ConnectorPolicyDenyBody(Result):
    mode: Literal["deny"]
    disabled_connectors: list[str]
    tools: dict[str, list[str]]
    tags: ConnectorPolicyTags | None = None


ConnectorPolicyBody = (
    ConnectorPolicyUnrestrictedBody
    | ConnectorPolicyDenyAllBody
    | ConnectorPolicyAllowBody
    | ConnectorPolicyDenyBody
)


class ConnectorPolicyEffectiveBase(Result):
    version: Literal[1]
    revision: str
    issued_at_ms: int


class ConnectorPolicyEffectiveUnrestricted(ConnectorPolicyEffectiveBase):
    mode: Literal["unrestricted"]


class ConnectorPolicyEffectiveDenyAll(ConnectorPolicyEffectiveBase):
    mode: Literal["deny-all"]


class ConnectorPolicyEffectiveAllow(ConnectorPolicyEffectiveBase):
    mode: Literal["allow"]
    connectors: list[str]
    tools: dict[str, list[str]]
    tags: ConnectorPolicyTags | None = None


class ConnectorPolicyEffectiveDeny(ConnectorPolicyEffectiveBase):
    mode: Literal["deny"]
    disabled_connectors: list[str]
    tools: dict[str, list[str]]
    tags: ConnectorPolicyTags | None = None


ConnectorPolicyEffective = (
    ConnectorPolicyEffectiveUnrestricted
    | ConnectorPolicyEffectiveDenyAll
    | ConnectorPolicyEffectiveAllow
    | ConnectorPolicyEffectiveDeny
)


class ConnectorPolicyLayer(Result):
    kind: ConnectorPolicyLayerKind
    revision: str
    body: ConnectorPolicyBody = Field(discriminator="mode")


class ConnectorPolicyGetResult(Result):
    layers: list[ConnectorPolicyLayer]
    effective: ConnectorPolicyEffective = Field(discriminator="mode")


method(
    "connectors.policy.get",
    params=ProfileParams,
    result=ConnectorPolicyGetResult,
    doc="Policy layers for the scoped member, from organization to member scope.",
)


class ToolsChange(Result):
    type: Literal["tools"]
    connector: str
    disabled_tools: list[str] = Field(max_length=2000)


class ConnectorChange(Result):
    type: Literal["connector"]
    connector: str
    enabled: bool


ConnectorPolicyChange = ToolsChange | ConnectorChange
ConnectorPolicyRevision = Annotated[str, Field(pattern=r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")]


class ConnectorPolicySetParams(ProfileParams):
    change: ConnectorPolicyChange = Field(discriminator="type")
    expected_revision: ConnectorPolicyRevision


class ConnectorPolicySetResult(Result):
    revision: str
    effective: ConnectorPolicyEffective = Field(discriminator="mode")


method(
    "connectors.policy.set",
    params=ConnectorPolicySetParams,
    result=ConnectorPolicySetResult,
    doc="Apply one scoped member connector or tool-list policy change.",
)
