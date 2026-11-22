import Foundation
import Observation
import PalProtocol

public struct ChatInstallAdvance: Sendable, Hashable {
    public var event: ChatSetupEventKind
    public var expectedRevision: Int
    public var manualStep: ChatProviderCapability?
    public var vaultItemId: String?
    public var refreshVaultItemId: String?
    public var ownerMemberId: String?

    public init(
        event: ChatSetupEventKind, expectedRevision: Int, manualStep: ChatProviderCapability? = nil, vaultItemId: String? = nil,
        refreshVaultItemId: String? = nil, ownerMemberId: String? = nil
    ) {
        self.event = event
        self.expectedRevision = expectedRevision
        self.manualStep = manualStep
        self.vaultItemId = vaultItemId
        self.refreshVaultItemId = refreshVaultItemId
        self.ownerMemberId = ownerMemberId
    }
}

public struct ChatInstallScope: Sendable, Hashable {
    public var provider: String
    public var workspace: String

    public init(provider: String, workspace: String) {
        self.provider = provider
        self.workspace = workspace
    }
}

public protocol ChatInstallClient: Sendable {
    func providers() async throws -> [ChatCapabilitiesWire]
    func status(_ scope: ChatInstallScope) async throws -> ChatInstallStatusResult
    func begin(_ scope: ChatInstallScope) async throws
    func advance(_ scope: ChatInstallScope, _ advance: ChatInstallAdvance) async throws
    func spaces(_ scope: ChatInstallScope) async throws -> [ChatSpaceRefWire]
    func join(_ scope: ChatInstallScope, spaceId: String) async throws -> ChatSpaceJoinResult
    func bindings(_ scope: ChatInstallScope) async throws -> [ChatBindingWire]
    func revoke(_ scope: ChatInstallScope) async throws
    func updateIdentity(_ scope: ChatInstallScope) async throws -> ChatIdentityUpdateResult
    func setIcon(_ scope: ChatInstallScope, png: Data) async throws
    func storeSecret(label: String, value: String) async throws -> String
}

public enum ChatInstallScreen: Hashable, Sendable {
    case loading
    case unavailable
    case unsupported
    case providers
    case intro(again: Bool)
    case credential
    case setup(task: ChatProviderCapability?)
    case allow(URL?)
    case owner
    case ready
    case error(ChatSetupErrorCode, fix: ChatFixAction)
}

public enum ChatInstallAction: Hashable, Sendable {
    case reload
    case begin
    case saveCredential
    case confirmOwner
    case markDone(ChatProviderCapability)
    case openLink(URL)
    case copy(String)
    case openAllow(URL)
    case checkAgain
    case copyAdminMessage
    case fix(ChatFixAction)
    case disconnect
}

public enum ChatInstallNotice: Hashable, Sendable {
    case offline
    case notSaved
}

public struct ChatSetupChecklistItem: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case workspace, createApp, manual(ChatProviderCapability), allow, install
    }

    public enum Status: Hashable, Sendable { case done, active, pending }

    public var kind: Kind
    public var status: Status
    public var id: Kind { kind }
}

public enum ChatSpaceStatus: Hashable, Sendable {
    case available, needsInvite, joining, live
}

public enum ChatSpacesPhase: Hashable, Sendable {
    case loading, loaded, failed
}

public struct ChatSpaceRow: Hashable, Sendable, Identifiable {
    public var space: ChatSpaceRefWire
    public var status: ChatSpaceStatus
    public var invite: ChatNextActionWire?
    public var id: String { space.id }
}

@MainActor
@Observable
public final class ChatInstallModel {
    public static let guidedSteps: [ChatProviderCapability] = [.setIcon, .appLevelCredential, .gatewayRedirect]
    private static let botTokenActionId = "bot_token"

    public private(set) var providers: [ChatCapabilitiesWire] = []
    public private(set) var provider: ChatCapabilitiesWire?
    public private(set) var snapshot: ChatInstallStatusResult?
    public private(set) var spaces: [ChatSpaceRow] = []
    public private(set) var spacesPhase = ChatSpacesPhase.loading
    public private(set) var isWorking = false
    public private(set) var notice: ChatInstallNotice?
    public private(set) var noticeError: ChatInstallClientError?
    public private(set) var identityUpdate: ChatIdentityUpdateResult?
    public private(set) var loadError: ChatInstallClientError?
    private var unsupported = false
    private var invites: [String: ChatNextActionWire] = [:]

    public let botName: String
    private let preferredProvider: String?
    let client: any ChatInstallClient

    public init(botName: String, preferredProvider: String?, client: any ChatInstallClient) {
        self.botName = botName
        self.preferredProvider = preferredProvider
        self.client = client
    }

    public var state: ChatSetupStateWire? { snapshot?.state }

    public var screen: ChatInstallScreen {
        if unsupported { return .unsupported }
        guard provider != nil else {
            if loadError != nil { return .unavailable }
            return providers.isEmpty ? .loading : .providers
        }
        guard let state else { return loadError != nil ? .unavailable : .loading }
        switch state.step {
        case .notStarted: return .intro(again: false)
        case .revoked: return .intro(again: true)
        case .needsCredential: return .credential
        case .creatingApp, .installing: return .setup(task: nil)
        case .needsManualStep: return .setup(task: pendingTask)
        case .needsAllow: return .allow(state.nextAction.link.flatMap(URL.init(string:)))
        case .needsOwner: return .owner
        case .ready: return .ready
        case .error:
            guard let error = state.error else { return .unavailable }
            return .error(error.code, fix: error.fix)
        case .unknown: return .unavailable
        }
    }

    public var primaryAction: ChatInstallAction? {
        switch screen {
        case .loading, .providers, .ready: nil
        case .unavailable: .reload
        case .unsupported: nil
        case .intro: .begin
        case .credential: .saveCredential
        case .owner: .confirmOwner
        case .setup(let task): task.map(ChatInstallAction.markDone)
        case .allow(let url): url.map(ChatInstallAction.openAllow) ?? .checkAgain
        case .error(_, let fix): .fix(fix)
        }
    }

    public var secondaryActions: [ChatInstallAction] {
        switch screen {
        case .setup(.some):
            guard let action = state?.nextAction else { return [] }
            return [action.link.flatMap(URL.init(string:)).map(ChatInstallAction.openLink), action.copyText.map(ChatInstallAction.copy)]
                .compactMap { $0 }
        case .allow(.some): return [.checkAgain, .copyAdminMessage]
        case .ready: return [.disconnect]
        default: return []
        }
    }

    public var offersBotToken: Bool {
        state?.step == .needsAllow && state?.fallbackAction?.actionId == Self.botTokenActionId
    }

    public func load() async {
        loadError = nil
        do {
            providers = try await client.providers()
            if provider == nil, let pick = providers.first(where: { $0.providerId == preferredProvider }) ?? (providers.count == 1 ? providers.first : nil) {
                provider = pick
            }
        } catch ChatInstallClientError.unsupported {
            unsupported = true
            return
        } catch is CancellationError {
            return
        } catch {
            loadError = ChatInstallClientError(error)
            return
        }
        await refresh()
    }

    public func choose(_ capabilities: ChatCapabilitiesWire) async {
        provider = capabilities
        snapshot = nil
        await refresh()
    }

    public func refresh() async {
        guard let scope else { return }
        do {
            adopt(try await client.status(scope))
            loadError = nil
        } catch is CancellationError {
        } catch {
            if snapshot == nil { loadError = ChatInstallClientError(error) } else { setNotice(error, as: .offline) }
        }
        if state?.step == .ready { await refreshSpaces() }
    }

    public func receive(_ payload: ChatInstallChangedPayload) async {
        let incoming = payload.state
        guard incoming.bot == botName, incoming.providerId == provider?.providerId else { return }
        guard let current = state else { return await refresh() }
        guard incoming.revision > current.revision else { return }
        guard incoming.revision == current.revision + 1 else { return await refresh() }
        snapshot?.state = incoming
        if incoming.step == .ready { await refreshSpaces() }
    }

    public func begin() async {
        guard let scope, let state, state.step == .notStarted || state.step == .revoked else { return }
        await mutate { try await self.client.begin(scope) }
    }

    public func saveCredential(access: String, refresh: String?) async {
        guard let scope, let state, state.step == .needsCredential else { return }
        let label = credentialLabel
        await mutate {
            let id = try await self.client.storeSecret(label: label, value: access)
            var refreshId: String?
            if let refresh, !refresh.isEmpty { refreshId = try await self.client.storeSecret(label: label + " (refresh)", value: refresh) }
            try await self.client.advance(
                scope, ChatInstallAdvance(event: .credentialSaved, expectedRevision: state.revision, vaultItemId: id, refreshVaultItemId: refreshId)
            )
        }
    }

    public func confirmOwner(_ memberId: String) async {
        let member = memberId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope, let state, state.step == .needsOwner, !member.isEmpty else { return }
        await mutate {
            try await self.client.advance(scope, ChatInstallAdvance(event: .ownerConfirmed, expectedRevision: state.revision, ownerMemberId: member))
        }
    }

    public func adoptBotToken(_ token: String) async {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope, let state, offersBotToken, !value.isEmpty else { return }
        let label = credentialLabel + " bot token"
        await mutate {
            let id = try await self.client.storeSecret(label: label, value: value)
            try await self.client.advance(scope, ChatInstallAdvance(event: .allowGranted, expectedRevision: state.revision, vaultItemId: id))
        }
    }

    public func updateIdentity() async {
        guard let scope, state?.step == .ready else { return }
        isWorking = true
        setNotice()
        defer { isWorking = false }
        do {
            identityUpdate = try await client.updateIdentity(scope)
        } catch is CancellationError {
        } catch {
            setNotice(error)
        }
    }

    public func markDone(_ step: ChatProviderCapability, secret: String? = nil) async {
        guard let scope, let state, state.step == .needsManualStep, pendingTask == step else { return }
        let label = credentialLabel + " app key"
        await mutate {
            var id: String?
            if let secret { id = try await self.client.storeSecret(label: label, value: secret) }
            try await self.client.advance(scope, ChatInstallAdvance(event: .manualStepDone, expectedRevision: state.revision, manualStep: step, vaultItemId: id))
        }
    }

    public func fix() async {
        guard let scope, let state, state.step == .error else { return }
        await mutate { try await self.client.advance(scope, ChatInstallAdvance(event: .retry, expectedRevision: state.revision)) }
    }

    public func disconnect() async {
        guard let scope else { return }
        await mutate { try await self.client.revoke(scope) }
        identityUpdate = nil
        spaces = []
        spacesPhase = .loading
        invites = [:]
    }

    public func join(_ spaceId: String) async {
        guard let scope else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await client.join(scope, spaceId: spaceId)
            if result.outcome == .needsInvite { invites[spaceId] = result.nextAction } else { invites[spaceId] = nil }
        } catch is CancellationError {
        } catch {
            setNotice(error, as: .notSaved)
        }
        await refreshSpaces()
    }

    public func refreshSpaces() async {
        guard let scope, state?.step == .ready else { return }
        if spaces.isEmpty { spacesPhase = .loading }
        do {
            async let listed = client.spaces(scope)
            async let bound = client.bindings(scope)
            let (spaceList, bindings) = try await (listed, bound)
            let live = Set(bindings.filter(\.live).map(\.spaceId))
            spaces = spaceList.filter { $0.kind != .direct }.map { space in
                let status: ChatSpaceStatus
                if live.contains(space.id) {
                    status = .live
                } else if space.joined {
                    status = .joining
                } else {
                    status = space.kind == .private ? .needsInvite : .available
                }
                return ChatSpaceRow(space: space, status: status, invite: status == .live ? nil : invites[space.id])
            }
            spacesPhase = .loaded
        } catch is CancellationError {
        } catch {
            spacesPhase = spaces.isEmpty ? .failed : .loaded
            setNotice(error, as: .offline)
        }
    }

    public func dismissNotice() { setNotice() }

    private func setNotice(_ error: (any Error)? = nil, as fixed: ChatInstallNotice? = nil) {
        let known = error.map { ChatInstallClientError($0) }
        noticeError = known
        notice = known.map { fixed ?? ($0.isUnreachable ? .offline : .notSaved) }
    }

    var scope: ChatInstallScope? {
        provider.map { ChatInstallScope(provider: $0.providerId, workspace: state?.workspace ?? "") }
    }

    private var credentialLabel: String {
        let provider = provider?.providerId.capitalized ?? ""
        return "\(provider) setup for \(botName)"
    }

    private func adopt(_ result: ChatInstallStatusResult) {
        if let current = state, result.state.revision < current.revision { return }
        snapshot = result
    }

    func mutate(_ work: @escaping @MainActor () async throws -> Void) async {
        isWorking = true
        setNotice()
        defer { isWorking = false }
        do {
            try await work()
        } catch is CancellationError {
            return
        } catch ChatInstallClientError.staleRevision {
        } catch {
            setNotice(error)
        }
        await refresh()
    }
}
