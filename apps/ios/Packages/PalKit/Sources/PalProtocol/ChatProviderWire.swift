import Foundation

public protocol ChatWireEnum: RawRepresentable, Decodable, Sendable, Hashable where RawValue == String {
    static var unknown: Self { get }
}

extension ChatWireEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum ChatCapabilityMode: String, ChatWireEnum {
    case automatic = "automatic", guided = "guided", unsupported = "unsupported", unknown
}

public enum ChatProviderCapability: String, ChatWireEnum {
    case setIcon = "set_icon", appLevelCredential = "app_level_credential", gatewayRedirect = "gateway_redirect"
    case unattendedRefresh = "unattended_refresh", joinPublicSpace = "join_public_space"
    case joinPrivateSpace = "join_private_space", unknown
}

public enum ChatSetupStep: String, ChatWireEnum {
    case notStarted = "not_started", needsCredential = "needs_credential", creatingApp = "creating_app"
    case needsManualStep = "needs_manual_step", needsAllow = "needs_allow", needsOwner = "needs_owner"
    case installing = "installing", ready = "ready", error = "error", revoked = "revoked", unknown
}

public enum ChatSetupEventKind: String, ChatWireEnum {
    case begin = "begin", credentialSaved = "credential_saved", appCreated = "app_created"
    case manualStepDone = "manual_step_done", allowGranted = "allow_granted", ownerConfirmed = "owner_confirmed"
    case installed = "installed", failed = "failed", retry = "retry", reopenStep = "reopen_step", revoked = "revoked", unknown
}

public enum ChatNextActionKind: String, ChatWireEnum {
    case noAction = "none", pasteCredential = "paste_credential", openLink = "open_link"
    case copyText = "copy_text", enterText = "enter_text", button = "button", unknown
}

public enum ChatSetupErrorCode: String, ChatWireEnum {
    case credentialRejected = "credential_rejected", credentialExpired = "credential_expired"
    case appCreateFailed = "app_create_failed", allowDenied = "allow_denied", installFailed = "install_failed"
    case providerUnreachable = "provider_unreachable", unknown
}

public enum ChatFixAction: String, ChatWireEnum {
    case reenterCredential = "reenter_credential", retry = "retry", restartAllow = "restart_allow", unknown
}

public enum ChatInstallationStatus: String, ChatWireEnum {
    case active = "active", needsReauth = "needs_reauth", revoked = "revoked", unknown
}

public enum ChatSpaceKind: String, ChatWireEnum {
    case `public` = "public", `private` = "private", direct = "direct", unknown
}

public enum ChatSpaceJoinOutcome: String, ChatWireEnum {
    case joined = "joined", alreadyJoined = "already_joined", needsInvite = "needs_invite", unknown
}

public enum ChatIdentityUpdateOutcome: String, ChatWireEnum {
    case updated = "updated", needsManualAvatar = "needs_manual_avatar", unknown
}

// swiftlint:disable redundant_string_enum_value
public enum ChatSpaceLeaveOutcome: String, ChatWireEnum {
    case left = "left", notMember = "not_member", unknown
}

public enum ChatAudiencePolicy: String, ChatWireEnum {
    case ownerOnly = "owner_only", workspace = "workspace", listed = "listed", unknown
}

public enum ChatReportDestinationKind: String, ChatWireEnum {
    case ownerDirectMessages = "owner_dm", space = "space", unknown
}

public enum ChatDeskItemKind: String, ChatWireEnum {
    case ask = "ask", handoff = "handoff", send = "send", unknown
}

public enum ChatDeskItemState: String, ChatWireEnum {
    case posting = "posting", open = "open", approved = "approved", executing = "executing", done = "done"
    case declined = "declined", expired = "expired", cancelled = "cancelled", failed = "failed", unknown = "unknown"
}

public enum ChatDeskChoice: String, ChatWireEnum {
    case approve = "approve", decline = "decline", unknown
}

// swiftlint:enable redundant_string_enum_value

public enum ChatRpcErrorReason: String, ChatWireEnum {
    case providerUnknown = "provider_unknown", notImplemented = "not_implemented"
    case staleRevision = "stale_revision", noInstallation = "no_installation", notJoined = "not_joined", unknown
}

public struct ChatCapabilityEntryWire: Decodable, Sendable, Hashable {
    public var capability: ChatProviderCapability
    public var mode: ChatCapabilityMode
}

public struct ChatIdentityPolicyWire: Decodable, Sendable, Hashable {
    public var appNameMax: Int
    public var displayNameMax: Int
    public var usernameMax: Int
    public var avatarMaxBytes: Int
    public var avatarMinPx: Int

    enum CodingKeys: String, CodingKey {
        case appNameMax = "app_name_max", displayNameMax = "display_name_max", usernameMax = "username_max"
        case avatarMaxBytes = "avatar_max_bytes", avatarMinPx = "avatar_min_px"
    }
}

public struct ChatCapabilitiesWire: Decodable, Sendable, Hashable {
    public var providerId: String
    public var requiresConfigCredential: Bool
    public var createsApp: Bool
    public var capabilities: [ChatCapabilityEntryWire]
    public var identityPolicy: ChatIdentityPolicyWire

    enum CodingKeys: String, CodingKey {
        case capabilities
        case providerId = "provider_id", requiresConfigCredential = "requires_config_credential"
        case createsApp = "creates_app", identityPolicy = "identity_policy"
    }
}

public struct ChatIdentityProjectionWire: Decodable, Sendable, Hashable {
    public var appName: String
    public var displayName: String
    public var username: String
    public var avatarRef: String?
    public var avatarBytes: Int?

    enum CodingKeys: String, CodingKey {
        case username
        case appName = "app_name", displayName = "display_name", avatarRef = "avatar_ref", avatarBytes = "avatar_bytes"
    }
}

public struct ChatNextActionWire: Decodable, Sendable, Hashable {
    public var kind: ChatNextActionKind
    public var actionId: String
    public var link: String?
    public var copyText: String?

    enum CodingKeys: String, CodingKey {
        case kind, link
        case actionId = "action_id", copyText = "copy_text"
    }
}

public struct ChatSetupErrorWire: Decodable, Sendable, Hashable {
    public var code: ChatSetupErrorCode
    public var fix: ChatFixAction
}

public struct ChatSetupStateWire: Decodable, Sendable, Hashable {
    public var bot: String
    public var providerId: String
    public var workspace: String
    public var step: ChatSetupStep
    public var revision: Int
    public var appId: String?
    public var installationId: String?
    public var manualStepsDone: [ChatProviderCapability]
    public var resumeStep: ChatSetupStep?
    public var nextAction: ChatNextActionWire
    public var fallbackAction: ChatNextActionWire?
    public var error: ChatSetupErrorWire?
    public var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case bot, workspace, step, revision, error
        case providerId = "provider_id", appId = "app_id", installationId = "installation_id"
        case manualStepsDone = "manual_steps_done", resumeStep = "resume_step"
        case nextAction = "next_action", fallbackAction = "fallback_action", updatedAt = "updated_at"
    }
}

public struct ChatInstallationWire: Decodable, Sendable, Hashable {
    public var id: String
    public var providerId: String
    public var bot: String
    public var workspaceId: String
    public var workspaceName: String
    public var status: ChatInstallationStatus
    public var createdAt: Double
    public var updatedAt: Double
    public var vaultItemIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, bot, status
        case providerId = "provider_id", workspaceId = "workspace_id", workspaceName = "workspace_name"
        case createdAt = "created_at", updatedAt = "updated_at", vaultItemIds = "vault_item_ids"
    }
}

public struct ChatSpaceRefWire: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var kind: ChatSpaceKind
    public var joined: Bool
}

public struct ChatBindingWire: Decodable, Sendable, Hashable {
    public var bot: String
    public var spaceId: String
    public var installationId: String
    public var live: Bool

    enum CodingKeys: String, CodingKey {
        case bot, live
        case spaceId = "space_id", installationId = "installation_id"
    }
}

public struct ChatProviderListResult: Decodable, Sendable, Hashable {
    public var providers: [ChatCapabilitiesWire]
}

public struct ChatInstallStatusResult: Decodable, Sendable, Hashable {
    public var state: ChatSetupStateWire
    public var installation: ChatInstallationWire?
}

public struct ChatSpacesListResult: Decodable, Sendable, Hashable {
    public var spaces: [ChatSpaceRefWire]
}

public struct ChatSpaceJoinResult: Decodable, Sendable, Hashable {
    public var outcome: ChatSpaceJoinOutcome
    public var nextAction: ChatNextActionWire

    enum CodingKeys: String, CodingKey {
        case outcome
        case nextAction = "next_action"
    }
}

public struct ChatIdentityUpdateResult: Decodable, Sendable, Hashable {
    public var outcome: ChatIdentityUpdateOutcome
    public var identity: ChatIdentityProjectionWire
    public var nextAction: ChatNextActionWire

    enum CodingKeys: String, CodingKey {
        case outcome, identity
        case nextAction = "next_action"
    }
}

public struct ChatBindingListResult: Decodable, Sendable, Hashable {
    public var bindings: [ChatBindingWire]
}

public struct ChatInstallChangedPayload: Decodable, Sendable, Hashable {
    public var state: ChatSetupStateWire
}
